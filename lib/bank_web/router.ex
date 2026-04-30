defmodule BankWeb.Router do
  use BankWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BankWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug BankWeb.Plugs.FetchCurrentUser
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # API key bearer auth (#218b). Reads `Authorization: Bearer
  # cb_<body>`, verifies via `Bank.APIKeys.verify_key/1`, populates
  # `conn.assigns.current_scope` so downstream `RequireRole` and
  # controllers can authorize without re-querying. Health endpoints
  # stay on the bare `:api` pipeline; everything else under `/v1`
  # goes through this authenticator.
  pipeline :api_authenticated do
    plug BankWeb.Plugs.VerifyAPIKey
  end

  # Operator-tier role gate (#218b). Composes on top of
  # `:api_authenticated` for routes that mutate runtime state
  # (cancel, execute, approve/reject, security pause/resume/revoke,
  # policy mutations, audit reads). Mirrors the LiveView
  # `:require_role, :operator` gate from #159a so session- and
  # key-authenticated callers share one role hierarchy.
  pipeline :api_operator do
    plug BankWeb.Plugs.RequireRole, :operator
  end

  # Admin-tier role gate (#218c). Composes on top of
  # `:api_authenticated` for surfaces that issue or revoke
  # credentials — currently the API key management endpoints. Owner
  # is admitted by the role hierarchy (`viewer < operator < admin
  # < owner`), so this gate is "admin or owner".
  pipeline :api_admin do
    plug BankWeb.Plugs.RequireRole, :admin
  end

  # Adapter callback pipeline — shared bearer secret check on top of
  # the JSON API pipeline. In production mTLS is terminated at the
  # ingress; this plug is defense in depth. See
  # `BankWeb.Plugs.VerifyAdapterAuth` and `docs/security.md`.
  pipeline :internal_adapter do
    plug :accepts, ["json"]
    plug BankWeb.Plugs.VerifyAdapterAuth
  end

  # Dev-only pipeline that attaches the external `/v1` OpenAPI spec to
  # `conn.private` so `OpenApiSpex.Plug.RenderSpec` can serve it (see
  # `BankWeb.ApiSpec`, issue #86). The route is mounted under the
  # `dev_routes`-gated block below; the pipeline itself is always
  # compiled so prod builds stay one code path.
  pipeline :dev_openapi do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: BankWeb.ApiSpec
  end

  # Telegram webhook ingress pipeline. Verifies the
  # `X-Telegram-Bot-Api-Secret-Token` header echoed back by Telegram
  # (registered alongside the webhook URL via setWebhook). See
  # `BankWeb.Plugs.VerifyTelegramWebhook` (issue #69).
  pipeline :internal_telegram do
    plug :accepts, ["json"]
    plug BankWeb.Plugs.VerifyTelegramWebhook
  end

  # Liveness probe — no DB touch, safe for a load balancer.
  scope "/", BankWeb do
    pipe_through :api

    get "/health", HealthController, :liveness
  end

  # Readiness probe lives at /v1/health but uses the shared HealthController.
  # It is a sibling scope so it escapes the API.V1 module prefix below.
  scope "/v1", BankWeb do
    pipe_through :api

    get "/health", HealthController, :readiness
    get "/health/deep", HealthController, :deep
  end

  # External v1 API. Three role-gated blocks (#159b refines the
  # split that #218b introduced):
  #
  #   * viewer+ — read-only inspection: intent/decision/policy
  #     show, replay, list, screening lookup, audit (audit reads
  #     are workspace-scoped via the read-hint column from #158d-b).
  #   * operator+ — state-advancing actions: intent submit /
  #     simulate / cancel, decision execute, approval flow,
  #     counterparty / address-label / trust-assertion CRUD,
  #     connect dispatch.
  #   * admin+ — governance / kill-switch: policy create / revise
  #     / archive, security pause / resume / revoke, API key
  #     management.
  #
  # Health endpoints stay on the bare `:api` pipeline (separate
  # scope earlier in this router).
  #
  # ## Per-controller workspace scoping
  #
  # Each `/v1` controller action that takes a resource id MUST
  # filter or look up the resource scoped by
  # `current_scope.workspace.id`. Cross-workspace ids return
  # `404 not_found` rather than `403 forbidden` so the response
  # cannot confirm a row exists in a sibling tenant. The shared
  # `BankWeb.Controllers.WorkspaceScope.not_found_for_workspace_mismatch/1`
  # convention is documented in each scoped getter on the
  # context (see #159b's per-context `*_in_workspace/2` helpers).
  #
  # Globally-scoped routes (intentionally NOT workspace-filtered)
  # are explicitly named:
  #   * `GET /v1/screening/:chain/:address` — wallet screening is
  #     reference data keyed by `(chain, address)`, not workspace.
  #   * `POST /v1/security/{pause,resume,revoke_delegation}` —
  #     deployment-global kill switches; affect every workspace.
  #     The admin-tier role gate guards them.
  scope "/v1", BankWeb.API.V1, as: :api_v1 do
    pipe_through [:api, :api_authenticated]

    # Intent reads — viewer-readable.
    get "/intents/:id", IntentController, :show
    get "/intents/:id/replay", IntentController, :replay

    # Decision reads — viewer-readable.
    get "/decisions/:id", DecisionController, :show

    # Counterparty list — viewer-readable.
    get "/counterparties", CounterpartyController, :index

    # Policy list — viewer-readable.
    get "/policies", PolicyController, :index

    # Wallet screening read — viewer-readable. Reference data,
    # globally scoped (NOT workspace-filtered).
    get "/screening/:chain/:address", ScreeningController, :show
  end

  scope "/v1", BankWeb.API.V1, as: :api_v1_operator do
    pipe_through [:api, :api_authenticated, :api_operator]

    # Intent state-advancing actions.
    post "/intents", IntentController, :create
    post "/intents/:id/simulate", IntentController, :simulate
    post "/intents/:id/cancel", IntentController, :cancel

    # Decision execute — operator-only manual dispatch.
    post "/decisions/:id/execute", DecisionController, :execute

    # Approval flow.
    get "/approvals", ApprovalController, :index
    post "/approvals/:decision_id/approve", ApprovalController, :approve
    post "/approvals/:decision_id/reject", ApprovalController, :reject

    # Counterparty CRUD — policy-impacting catalog edits.
    post "/counterparties", CounterpartyController, :create
    patch "/counterparties/:id", CounterpartyController, :update
    post "/counterparties/:id/addresses", CounterpartyController, :add_address
    post "/counterparties/:id/evidence", CounterpartyController, :add_evidence

    # Address labels.
    patch "/address_labels/:id", AddressLabelController, :update

    # Trust assertions — manual trust overrides feed decisioning.
    post "/trust_assertions", TrustAssertionController, :create

    # Audit reads — operator+ for sensitivity (audit can replay
    # business-impactful state).
    get "/audit", AuditController, :index

    # Browser wallet connect (v1.1 scaffolding — see docs/wallet-connect.md).
    post "/connect/smart_account", ConnectController, :request
  end

  scope "/v1", BankWeb.API.V1, as: :api_v1_admin do
    pipe_through [:api, :api_authenticated, :api_admin]

    # Policy CRUD — governance-level. Rules drive decisioning and
    # cannot be changed casually by an on-call operator.
    post "/policies", PolicyController, :create
    post "/policies/:id/revise", PolicyController, :revise
    post "/policies/:id/archive", PolicyController, :archive

    # Security kill-switches — global, deployment-wide. Admin-only
    # because pause halts every workspace's runtime, not just the
    # caller's.
    post "/security/pause", SecurityController, :pause
    post "/security/resume", SecurityController, :resume
    post "/security/revoke_delegation", SecurityController, :revoke_delegation

    # API key management (#218c). Admin-only — credential issuance.
    get "/api_keys", APIKeyController, :index
    post "/api_keys", APIKeyController, :create
    delete "/api_keys/:id", APIKeyController, :delete
  end

  # Internal adapter callback — private network, not part of /v1/.
  # Authenticated via shared bearer secret; mTLS at ingress in prod.
  scope "/internal/adapter", BankWeb.Internal do
    pipe_through :internal_adapter

    post "/callback", AdapterCallbackController, :callback
  end

  # Telegram bot webhook — ingress for bot updates. Authenticated via
  # the webhook secret Telegram echoes on every call. Controller only
  # authenticates and normalizes; command / approval dispatch lands in
  # later sub-issues of epic #54. See issue #69.
  scope "/internal/telegram", BankWeb.Internal do
    pipe_through :internal_telegram

    post "/webhook", TelegramWebhookController, :webhook
  end

  # Auth surface — Google OAuth identity (epic #153, issue #154).
  # Identity-only: a successful callback creates a `:pending_access`
  # user and starts a session. Workspace access is granted by the
  # invite/approval flow in #156-#157, not here.
  scope "/", BankWeb do
    pipe_through :browser

    get "/login", SessionController, :login
    get "/pending", SessionController, :pending
    get "/unauthorized", SessionController, :unauthorized

    get "/auth/google", AuthController, :request
    get "/auth/google/callback", AuthController, :callback

    delete "/logout", AuthController, :delete
    post "/logout", AuthController, :delete
  end

  # Web control tower — LiveView-based operator console.
  # Issue #13 replaced the default landing page with the
  # connection/delegation dashboard; #14, #15, #16, and #44 added the
  # action queue, counterparty/policy management, audit / replay /
  # security console, and the intents explorer respectively. #157
  # wraps the lot in a `live_session` so the on_mount hook can refuse
  # anonymous and pending users at the LiveView boundary. #159a
  # splits the console into two role-gated live_sessions: viewer-
  # readable explorers and operator-required surfaces.
  scope "/", BankWeb do
    pipe_through :browser

    # Read-only explorer pages — anyone with a workspace membership
    # (viewer+) can mount. No mutations live here; refresh / filter
    # / paginate are view-only.
    live_session :workspace_viewer,
      on_mount: {BankWeb.LiveAuth, {:require_role, :viewer}} do
      live "/dashboard", DashboardLive
      live "/intents", IntentsLive
      live "/audit", AuditLive
      live "/audit/replay/:intent_id", IntentReplayLive
    end

    # Operator surfaces — pages that carry mutations (approvals,
    # counterparty/policy CRUD, runtime controls). Mount requires
    # `:operator` minimum; admin-only individual handle_event
    # callbacks (pause/resume/revoke, archive) check role inside the
    # callback.
    live_session :workspace_operator,
      on_mount: {BankWeb.LiveAuth, {:require_role, :operator}} do
      live "/", ControlLive
      live "/queue", QueueLive
      live "/counterparties", CounterpartiesLive
      live "/counterparties/:id", CounterpartyDetailLive
      live "/policies", PoliciesLive
      live "/security", SecurityLive
    end
  end

  # Admin surface — bootstrap private-alpha approve / reject (#157).
  # Gated by `Bank.Access.can_admin_access?/1` (BANK_ADMIN_EMAILS
  # allowlist) until role-based authz lands in #159.
  scope "/admin", BankWeb do
    pipe_through :browser

    live_session :admin, on_mount: {BankWeb.LiveAuth, :require_admin} do
      live "/access", AccessAdminLive, :index
    end
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:bank, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: BankWeb.Telemetry
    end

    # Inspection-only handle on the generated external `/v1` OpenAPI
    # document. Dev-gated on purpose — the artifact path for SDK /
    # CI consumers lands with issue #90.
    scope "/dev" do
      pipe_through :dev_openapi

      get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
    end
  end
end
