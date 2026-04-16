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
config :bank, Bank.AdapterClient,
  base_url: "http://adapter.test",
  auth_secret: "test-adapter-secret",
  req_options: [plug: {Req.Test, Bank.AdapterClient}]
