defmodule BankWeb.Router do
  use BankWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BankWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Adapter callback pipeline — shared bearer secret check on top of
  # the JSON API pipeline. In production mTLS is terminated at the
  # ingress; this plug is defense in depth. See
  # `BankWeb.Plugs.VerifyAdapterAuth` and `docs/security.md`.
  pipeline :internal_adapter do
    plug :accepts, ["json"]
    plug BankWeb.Plugs.VerifyAdapterAuth
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

  # External v1 API. Controllers are scaffolded in issue #3; individual
  # endpoint behaviour is filled in by the engine issues (#5-#12).
  scope "/v1", BankWeb.API.V1, as: :api_v1 do
    pipe_through :api

    # Intents
    post "/intents", IntentController, :create
    get "/intents/:id", IntentController, :show
    post "/intents/:id/simulate", IntentController, :simulate
    post "/intents/:id/cancel", IntentController, :cancel
    get "/intents/:id/replay", IntentController, :replay

    # Decisions
    get "/decisions/:id", DecisionController, :show
    post "/decisions/:id/execute", DecisionController, :execute

    # Approvals
    get "/approvals", ApprovalController, :index
    post "/approvals/:decision_id/approve", ApprovalController, :approve
    post "/approvals/:decision_id/reject", ApprovalController, :reject

    # Counterparties and address book
    get "/counterparties", CounterpartyController, :index
    post "/counterparties", CounterpartyController, :create
    patch "/counterparties/:id", CounterpartyController, :update
    post "/counterparties/:id/addresses", CounterpartyController, :add_address
    post "/counterparties/:id/evidence", CounterpartyController, :add_evidence

    # Address labels
    patch "/address_labels/:id", AddressLabelController, :update

    # Trust assertions
    post "/trust_assertions", TrustAssertionController, :create

    # Policies
    get "/policies", PolicyController, :index
    post "/policies", PolicyController, :create
    post "/policies/:id/revise", PolicyController, :revise
    post "/policies/:id/archive", PolicyController, :archive

    # Audit
    get "/audit", AuditController, :index

    # Security
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

  # Web control tower — LiveView-based operator console.
  # Issue #13 replaced the default landing page with the
  # connection/delegation dashboard; #14, #15, and #16 added the
  # action queue, counterparty/policy management, and the audit /
  # replay / security console respectively. The Intents page is the
  # remaining stub for a future issue.
  scope "/", BankWeb do
    pipe_through :browser

    live "/", ControlLive
    live "/dashboard", DashboardLive
    live "/queue", QueueLive
    live "/counterparties", CounterpartiesLive
    live "/counterparties/:id", CounterpartyDetailLive
    live "/policies", PoliciesLive
    live "/audit", AuditLive
    live "/audit/replay/:intent_id", IntentReplayLive
    live "/security", SecurityLive
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
  end
end
