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

# Configure esbuild (the version is required).
#
# Two profiles:
#   * `:bank` — main app bundle (LiveView socket, hooks, vendor libs).
#   * `:theme_init` — tiny synchronous bootstrap for `data-theme`
#     (audit M7). Built as a separate entry so the inline `<script>`
#     in root.html.heex can be removed and CSP `script-src 'self'`
#     can stay strict. Output path lines up with the verified-route
#     reference in root.html.heex.
config :esbuild,
  version: "0.25.4",
  bank: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  theme_init: [
    args: ~w(js/theme-init.js --bundle --target=es2022 --outdir=../priv/static/assets/js),
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

# Request log redaction (audit M5). Phoenix's request logger and
# Plug.Parsers expose params under `[$request_id]` log lines; without
# a filter list any param key matching one of the strings below
# would be written verbatim to the log target. Substring match (not
# exact) so e.g. `:api_key_id` is also redacted, not only `:api_key`.
config :phoenix, :filter_parameters, [
  "secret",
  "bearer",
  "password",
  "authorization",
  "signature",
  "private_key",
  "api_key",
  "token",
  "_csrf_token",
  "session"
]

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
    # Browser-signed install on-chain verification (#474).
    # Workers do read-only `eth_call`/`eth_getCode` against the
    # configured Base Sepolia RPC; concurrency 3 matches the
    # other delegation-side queues.
    delegations_verify_install: 3,
    # Browser-signed install bundler-receipt poller (#500). Each
    # job hits `eth_getUserOperationReceipt` once and either
    # snoozes (null receipt) or terminates (success → enqueue
    # verifier; revert/timeout → mark install_failed). Concurrency
    # 5 covers a small burst of concurrent installs across
    # workspaces; raise if real traffic warrants.
    delegations_poll_install_receipt: 5,
    # API key usage aggregation (#218d). One concurrent job is
    # plenty — the daily cron schedules at most one job per day
    # and operator-driven backfill jobs are explicit.
    api_key_usage: 1,
    # Operational scans — currently the stuck-plan detector
    # (#230-b). Concurrency 1 because the detector serialises
    # its per-plan dedupe via an audit-row pre-check that is
    # not atomic at the SQL level (same constraint as
    # `:api_key_usage`).
    ops_scan: 1
  ],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Daily aggregation of API key usage (#218d). Runs at 00:30
    # UTC and emits `api_key.used` audit rows for every key whose
    # `last_used_at` falls in the prior calendar day.
    #
    # Periodic stuck-plan detection (#230-b). Runs every 2 minutes
    # and emits one `ops.stuck_plan_detected` audit row per plan
    # past its per-status threshold (deduped on a 5-minute aligned
    # window).
    # Auto-resume sweeper for scoped chain pauses with `expires_at`
    # set (#228 Phase 1.5). Runs every minute; per-row idempotency
    # is owned by `Bank.Security.Pauses.expire/2` so an extra tick
    # is harmless.
    # Refresh of the cached adapter health snapshot (#229) so
    # LiveView consumers can read it without blocking on the
    # adapter's `/healthz` endpoint themselves.
    {Oban.Plugins.Cron,
     crontab: [
       {"30 0 * * *", Bank.Runtime.Workers.AggregateAPIKeyUsage},
       {"*/2 * * * *", Bank.Runtime.Workers.ScanStuckPlans},
       {"* * * * *", Bank.Runtime.Workers.SweepExpiredPauses},
       {"* * * * *", Bank.Runtime.Workers.RefreshAdapterHealth}
     ]}
  ]

# Per-key rate limit for /v1 (#221, first slice). Defaults to 1 RPS
# sustained per key (60 requests / 60 second window). Operators can
# tune downward via runtime config when product calibration data
# arrives. Chain-action stricter caps land in a subsequent slice.
#
# Per-workspace rate limit (#221, third slice) — collective ceiling
# across all keys in a workspace. Default 10× the per-key budget so
# a workspace with up to 10 quietly-busy keys is uncapped while
# malicious or misconfigured workspaces with many runaway keys hit
# a deterministic ceiling. Sits in the same plug AFTER the per-key
# check so a single noisy key trips its own bucket first and does
# not poison quiet keys in the same workspace.
#
# Auth-failure lockout (#221, second slice). Independently tunable
# from the success-path bucket. Default ceiling is 10 failed auth
# attempts per 5 minutes per (id-or-prefix-or-ip), high enough that
# a real user can re-paste a typo a few times and low enough that
# automated probing trips quickly. Set `auth_failure_enabled?:
# false` to disable in environments that have edge-level WAF
# protection instead.
config :bank, Bank.RateLimit,
  requests_per_window: 60,
  window_seconds: 60,
  workspace_requests_per_window: 600,
  workspace_window_seconds: 60,
  auth_failure_per_window: 10,
  auth_failure_window_seconds: 300,
  auth_failure_enabled?: true,
  # Chain-action stricter cap (#221, fourth slice). Applies ONLY to
  # `/v1/security/*` (pause / resume / revoke_delegation). Default
  # ceiling: 5 requests / 60 s per calling key. Pausing the runtime
  # 5 times in a minute is far above any legitimate operator pace
  # and well below the rate a runaway agent could trip. Tune up for
  # incident-response drills or down for hardened deployments.
  chain_action_per_window: 5,
  chain_action_window_seconds: 60

# Bank.Ops.Health stuck-plan detector (#230-b). Per-status
# thresholds (in seconds) that the periodic scanner uses to flag a
# non-terminal execution plan as stuck. Defaults are tuned to the
# adapter's observed SLA: the dispatch path moves a `:prepared`
# plan to `:signing` within seconds, so a 10-minute dwell is
# already a strong signal something is wrong; bundler-bound
# `:pending_confirmation` plans legitimately wait minutes on
# mainnet, so 30 minutes is the threshold there. Tune downward in
# tests / staging for tighter signal, upward in deployments with
# slow upstream bundlers.
config :bank, Bank.Ops.Health,
  stuck_plan_thresholds: [
    prepared: 600,
    signing: 300,
    broadcasting: 600,
    pending_confirmation: 1_800
  ]

# Bank.AdapterClient: connection to the TypeScript chain adapter is
# configured per-environment. dev/test set local defaults below;
# production must provide ADAPTER_BASE_URL, ADAPTER_DISPATCH_SECRET
# and ADAPTER_CALLBACK_SECRET via env (see config/runtime.exs). No
# default is set here so that a misconfigured production boot fails
# fast instead of silently using a development secret.

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
