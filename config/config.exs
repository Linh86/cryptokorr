# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :bank,
  ecto_repos: [Bank.Repo],
  # binary_id is the UUID v4 primary-key type used across the domain.
  # utc_datetime_usec preserves microsecond precision for ordering
  # append-only records (audit, supersession chains).
  generators: [binary_id: true, timestamp_type: :utc_datetime_usec]

# Configure the endpoint
config :bank, BankWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BankWeb.ErrorHTML, json: BankWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Bank.PubSub,
  live_view: [signing_salt: "CQZmoS/E"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  bank: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  bank: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Oban: background workers for runtime orchestration.
#
# Queue names map to the runtime-flow doc's semantic queues.
# Oban uses atoms for queue names; we use underscores in code and document
# the canonical dotted semantic name in the left column.
#
#   intents.evaluate     -> :intents_evaluate     (initial policy/trust/simulation pipeline)
#   intents.reevaluate   -> :intents_reevaluate   (hold-TTL or trust-change driven re-eval)
#   approvals.expire     -> :approvals_expire     (approval TTL → successor block envelope)
#   executions.run       -> :executions_run       (prepare + hand off to the chain adapter)
#   executions.confirm   -> :executions_confirm   (poll chain confirmation state)
#   security.revoke      -> :security_revoke      (delegation revocation dispatch)
#
# Concurrency values are conservative starting points; they should be tuned
# once the engines have real throughput profiles (issue #6).
config :bank, Oban,
  engine: Oban.Engines.Basic,
  repo: Bank.Repo,
  queues: [
    intents_evaluate: 10,
    intents_reevaluate: 5,
    approvals_expire: 5,
    executions_run: 5,
    executions_confirm: 10,
    security_revoke: 3,
    delegations_grant: 3,
    # API key usage aggregation (#218d). One concurrent job is
    # plenty — the daily cron schedules at most one job per day
    # and operator-driven backfill jobs are explicit.
    api_key_usage: 1
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Daily aggregation of API key usage (#218d). Runs at 00:30
    # UTC and emits `api_key.used` audit rows for every key whose
    # `last_used_at` falls in the prior calendar day.
    {Oban.Plugins.Cron,
     crontab: [
       {"30 0 * * *", Bank.Runtime.Workers.AggregateAPIKeyUsage}
     ]}
  ]

# Per-key rate limit for /v1 (#221, first slice). Defaults to 1 RPS
# sustained per key (60 requests / 60 second window). Operators can
# tune downward via runtime config when product calibration data
# arrives. Per-workspace, chain-action, and auth-failure caps land
# in subsequent slices.
config :bank, Bank.RateLimit,
  requests_per_window: 60,
  window_seconds: 60

# Bank.AdapterClient: connection to the TypeScript chain adapter is
# configured per-environment. dev/test set local defaults below;
# production must provide ADAPTER_BASE_URL, ADAPTER_DISPATCH_SECRET
# and ADAPTER_CALLBACK_SECRET via env (see config/runtime.exs). No
# default is set here so that a misconfigured production boot fails
# fast instead of silently using a development secret.

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
