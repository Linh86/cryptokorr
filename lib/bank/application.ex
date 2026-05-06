defmodule Bank.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BankWeb.Telemetry,
      Bank.Repo,
      {DNSCluster, query: Application.get_env(:bank, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Bank.PubSub},
      # In-memory registry for pause/resume (see Bank.Security.PauseState).
      Bank.Security.PauseState,
      # Feed freshness tracking for wallet screening sources.
      Bank.WalletScreening.FeedHealth,
      # Node-local health tracking for stablecoin quote providers.
      Bank.Stablecoins.ProviderHealth,
      # Node-local health tracking for live/stub quote providers (#176).
      Bank.Quotes.ProviderHealth,
      # Per-key rate-limit buckets for /v1 (#221).
      Bank.RateLimit,
      # Generic audit-emission dedupe (#222) — used by VerifyAPIKey
      # to collapse api_key.denied spam.
      Bank.Audit.DedupeWindow,
      # Cached, sanitized adapter health snapshot for non-blocking UI
      # reads (#229). Refreshed out-of-band by
      # `Bank.Runtime.Workers.RefreshAdapterHealth`.
      Bank.Ops.AdapterHealthSnapshot,
      # Delegation state is now durable in Postgres (see Bank.Delegations).
      # Background workers for runtime orchestration (see Bank.Runtime).
      {Oban, Application.fetch_env!(:bank, Oban)},
      # Start to serve requests, typically the last entry
      BankWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bank.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BankWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
