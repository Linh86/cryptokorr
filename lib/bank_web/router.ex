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

  # External v1 API. Two role-gated blocks under #218b:
  #
  #   * authenticated-only — any valid API key reads/writes the
  #     workspace's data. Reads, drafts, address-book CRUD,
  #     screening, connect.
  #   * operator+ — runtime-mutating actions: cancel, execute,
  #     approval flow, policy CRUD, audit reads, security mutations.
  #
  # Health endpoints stay on the bare `:api` pipeline (separate
  # scope earlier in this router).
  scope "/v1", BankWeb.API.V1, as: :api_v1 do
    pipe_through [:api, :api_authenticated]

    # Intents — submit / read / simulate / replay are
    # authenticated-only. Cancel is below in the operator+ block.
    post "/intents", IntentController, :create
    get "/intents/:id", IntentController, :show
    post "/intents/:id/simulate", IntentController, :simulate
    get "/intents/:id/replay", IntentController, :replay

    # Decisions — read.
    get "/decisions/:id", DecisionController, :show

    # Counterparties and address book.
    get "/counterparties", CounterpartyController, :index
    post "/counterparties", CounterpartyController, :create
    patch "/counterparties/:id", CounterpartyController, :update
    post "/counterparties/:id/addresses", CounterpartyController, :add_address
    post "/counterparties/:id/evidence", CounterpartyController, :add_evidence

    # Address labels.
    patch "/address_labels/:id", AddressLabelController, :update

    # Trust assertions.
    post "/trust_assertions", TrustAssertionController, :create

    # Policies — read.
    get "/policies", PolicyController, :index

    # Wallet screening.
    get "/screening/:chain/:address", ScreeningController, :show

    # Browser wallet connect (v1.1 scaffolding — see docs/wallet-connect.md).
    post "/connect/smart_account", ConnectController, :request
  end

  scope "/v1", BankWeb.API.V1, as: :api_v1_operator do
    pipe_through [:api, :api_authenticated, :api_operator]

    # Intent mutation that takes the runtime out of an existing
    # commitment.
    post "/intents/:id/cancel", IntentController, :cancel

    # Decision execute — operator-only manual dispatch.
    post "/decisions/:id/execute", DecisionController, :execute

    # Approval flow.
    get "/approvals", ApprovalController, :index
    post "/approvals/:decision_id/approve", ApprovalController, :approve
    post "/approvals/:decision_id/reject", ApprovalController, :reject

    # Policy mutations.
    post "/policies", PolicyController, :create
    post "/policies/:id/revise", PolicyController, :revise
    post "/policies/:id/archive", PolicyController, :archive

    # Audit reads — sensitive cross-workspace data.
    get "/audit", AuditController, :index

    # Security mutations.
    post "/security/pause", SecurityController, :pause
    post "/security/resume", SecurityController, :resume
    post "/security/revoke_delegation", SecurityController, :revoke_delegation
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
