import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :bank, Bank.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "bank_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :bank, BankWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "U/KaH0NwBy/LUHwAbmYNk1+2dw/MlkxfafLD8ns4mFJk+6WNd4vdcxrZqdAW3s4c",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Oban runs in manual/inline testing mode under the test env.
config :bank, Oban, testing: :manual

# Adapter HTTP requests are routed to Req.Test under the test env so
# individual tests can stub per-test responses without a real server.
# Two distinct secrets so tests can see (and assert on) which direction
# of the trust boundary is being exercised.
config :bank, Bank.AdapterClient,
  base_url: "http://adapter.test",
  dispatch_secret: "test-adapter-dispatch-secret",
  callback_secret: "test-adapter-callback-secret",
  req_options: [plug: {Req.Test, Bank.AdapterClient}]

# Telegram operator bot (epic #54): disabled by default under the test
# env. Tests that exercise the config / webhook / transport boundaries
# opt in explicitly via `Application.put_env/3` under `async: false`
# — see test/bank/telegram/config_test.exs and
# test/bank_web/plugs/verify_telegram_webhook_test.exs.
config :bank, Bank.Telegram.Config,
  enabled: false,
  bot_token: nil,
  webhook_secret: nil,
  operators: []

# Transport HTTP requests are routed to Req.Test under the test env so
# individual tests can stub per-test responses without a real server.
# The base_url is a synthetic host — requests never hit the real
# Telegram Bot API during tests.
config :bank, Bank.Telegram.Transport,
  base_url: "http://telegram.test",
  req_options: [plug: {Req.Test, Bank.Telegram.Transport}]

# Disable the operational health telemetry poller in tests.
# `Bank.Ops.Health.emit_telemetry/0` issues an HTTP call to the
# adapter via `Req.Test`, whose stubs are per-process. The poller
# runs in its own process with no stub installed, which would
# otherwise produce a `cannot find mock/stub Bank.AdapterClient`
# error every time it fired during a test run. The deep health
# endpoint and `emit_telemetry/0` itself are still exercised
# directly by tests that own the calling process.
config :bank, BankWeb.Telemetry, periodic_measurements: []

# Wallet screening feed ingestion uses Req.Test so tests can stub
# feed responses without hitting real sanctions / scam feed servers.
config :bank, Bank.WalletScreening.Ingestion,
  ofac_url: "http://ofac-feed.test/sanctions.json",
  opensanctions_url: "http://opensanctions-feed.test/entities.ftm.json",
  scamsniffer_url: "http://scamsniffer-feed.test/blacklist.json",
  etherscamdb_url: "http://etherscamdb-feed.test/scams.yaml",
  btc_abuse_url: "http://btcabuse-feed.test/reports.csv",
  graphsense_url: "http://graphsense-feed.test/tagpack.yaml",
  req_options: [plug: {Req.Test, Bank.WalletScreening.Ingestion}]

# 0x swap adapter: route HTTP to Req.Test so tests can stub per-process.
config :bank, Bank.Stablecoins.Providers.ZeroX,
  base_url: "http://zerox.test",
  api_key: "test-0x-api-key",
  req_options: [plug: {Req.Test, Bank.Stablecoins.Providers.ZeroX}]

# 1inch swap adapter: route HTTP to Req.Test so tests can stub per-process.
config :bank, Bank.Stablecoins.Providers.OneInch,
  base_url: "http://oneinch.test",
  api_key: "test-1inch-api-key",
  req_options: [plug: {Req.Test, Bank.Stablecoins.Providers.OneInch}]

# Jupiter swap adapter: route HTTP to Req.Test so tests can stub per-process.
config :bank, Bank.Stablecoins.Providers.Jupiter,
  base_url: "http://jupiter.test",
  req_options: [plug: {Req.Test, Bank.Stablecoins.Providers.Jupiter}]

# Morpho Blue GraphQL client (#198): route HTTP to Req.Test so tests
# stub per-process. The default base_url is the literal real
# endpoint; tests override `:req_options` so no live network call
# can leak from the test pool.
config :bank, Bank.DefiVenues.Morpho.Client,
  base_url: "http://morpho.test",
  req_options: [plug: {Req.Test, Bank.DefiVenues.Morpho.Client}]

# Auth foundation (epic #153, issue #154): use the deterministic
# in-process stub instead of calling Google.
config :bank, Bank.Accounts.OAuthProvider, provider: Bank.Accounts.OAuthProvider.Stub
config :bank, Bank.Accounts.OAuthProvider.Stub, %{}

# Bootstrap admin allowlist (epic #153, issue #157). Empty by
# default so tests explicitly opt in via `Application.put_env/3` per
# case.
config :bank, :admin_emails, []

# Rate limit (#221) — high default in test env so ordinary controller
# tests that fire many requests against the same api_key (or
# workspace) do not accidentally trip the limiter. Tests that
# exercise rate-limit / auth-failure-lockout / workspace-bucket
# behaviour override these via `Application.put_env/3` per case.
config :bank, Bank.RateLimit,
  requests_per_window: 10_000,
  window_seconds: 60,
  workspace_requests_per_window: 100_000,
  workspace_window_seconds: 60,
  auth_failure_per_window: 10_000,
  auth_failure_window_seconds: 300,
  auth_failure_enabled?: true,
  chain_action_per_window: 10_000,
  chain_action_window_seconds: 60
