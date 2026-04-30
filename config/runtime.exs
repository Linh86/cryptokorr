import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/bank start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :bank, BankWeb.Endpoint, server: true
end

config :bank, BankWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Bank.AdapterClient: connection to the TypeScript chain adapter.
#
# Two distinct secrets gate the two directions of the trust boundary so
# either can be rotated independently and a leak in one direction does
# not let an attacker speak both ways:
#
#   * ADAPTER_DISPATCH_SECRET — Phoenix sends this on outbound
#     `POST /dispatch/*` requests; the TS adapter validates it.
#   * ADAPTER_CALLBACK_SECRET — the TS adapter sends this on inbound
#     `POST /internal/adapter/callback` requests; Phoenix's
#     `VerifyAdapterAuth` plug validates it.
#
# - :prod  — all four env vars MUST be set or the boot fails. A missing
#            secret would otherwise leave the corresponding direction
#            open to anyone reachable on the private network.
# - :dev   — falls back to the local defaults in config/dev.exs; env
#            var overrides are honored individually.
# - :test  — config/test.exs is authoritative (Req.Test stubbing).
case config_env() do
  :prod ->
    adapter_base_url =
      System.get_env("ADAPTER_BASE_URL") ||
        raise """
        environment variable ADAPTER_BASE_URL is missing.
        For example: https://adapter.internal:4100
        """

    adapter_dispatch_secret =
      System.get_env("ADAPTER_DISPATCH_SECRET") ||
        raise """
        environment variable ADAPTER_DISPATCH_SECRET is missing.
        Bearer that Phoenix sends on outbound POST /dispatch/* and the
        adapter validates. Generate with: openssl rand -hex 32
        """

    adapter_callback_secret =
      System.get_env("ADAPTER_CALLBACK_SECRET") ||
        raise """
        environment variable ADAPTER_CALLBACK_SECRET is missing.
        Bearer that the adapter sends on inbound POST
        /internal/adapter/callback and Phoenix validates. Generate
        with: openssl rand -hex 32
        """

    config :bank, Bank.AdapterClient,
      base_url: adapter_base_url,
      dispatch_secret: adapter_dispatch_secret,
      callback_secret: adapter_callback_secret,
      req_options: []

  :dev ->
    if base_url = System.get_env("ADAPTER_BASE_URL") do
      config :bank, Bank.AdapterClient, base_url: base_url
    end

    if dispatch_secret = System.get_env("ADAPTER_DISPATCH_SECRET") do
      config :bank, Bank.AdapterClient, dispatch_secret: dispatch_secret
    end

    if callback_secret = System.get_env("ADAPTER_CALLBACK_SECRET") do
      config :bank, Bank.AdapterClient, callback_secret: callback_secret
    end

  :test ->
    :ok
end

# Bank.Telegram.Config: identity / allowlist / role / secrets boundary
# for the operator Telegram bot (epic #54, issues #70, #69).
#
#   * TELEGRAM_BOT_ENABLED must be the literal string "true" to enable
#     the bot in :prod. Anything else is treated as disabled so a boot
#     with a missing value fails closed.
#   * TELEGRAM_BOT_TOKEN is the bot token issued by BotFather. Required
#     when enabled; rotated on staff change or milestone end.
#   * TELEGRAM_WEBHOOK_SECRET is the value we pass to setWebhook's
#     `secret_token` parameter; Telegram echoes it back in the
#     `X-Telegram-Bot-Api-Secret-Token` header on every inbound update.
#     `BankWeb.Plugs.VerifyTelegramWebhook` verifies it. Required when
#     enabled; generate with `openssl rand -hex 32`.
#   * TELEGRAM_OPERATORS is a pipe-separated allowlist of
#     USER_ID:CHAT_ID:ROLE:AUDIT_ACTOR records. Roles: viewer,
#     approver, security_operator, admin. See
#     `Bank.Telegram.Config.parse_operators_env!/1`.
#
# When the bot is explicitly disabled we still write a well-formed
# config with `enabled: false` so `Bank.Telegram.Config.load/0` can
# return a deterministic answer without touching env again.
#
# dev and test use the defaults in their own config files; env-var
# overrides are not currently honored there to keep local boots
# reproducible.
case config_env() do
  :prod ->
    telegram_enabled = System.get_env("TELEGRAM_BOT_ENABLED") == "true"

    if telegram_enabled do
      bot_token =
        System.get_env("TELEGRAM_BOT_TOKEN") ||
          raise """
          environment variable TELEGRAM_BOT_TOKEN is missing.
          TELEGRAM_BOT_ENABLED=true requires a bot token issued by
          BotFather. Rotate on staff change or milestone end.
          """

      webhook_secret =
        System.get_env("TELEGRAM_WEBHOOK_SECRET") ||
          raise """
          environment variable TELEGRAM_WEBHOOK_SECRET is missing.
          TELEGRAM_BOT_ENABLED=true requires a webhook secret so the
          webhook ingress plug can verify Telegram's echoed
          X-Telegram-Bot-Api-Secret-Token header. Generate with:
            openssl rand -hex 32
          Then register the webhook with:
            curl -X POST https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/setWebhook \\
                 -d url=https://<host>/internal/telegram/webhook \\
                 -d secret_token=$TELEGRAM_WEBHOOK_SECRET
          """

      operators_raw =
        System.get_env("TELEGRAM_OPERATORS") ||
          raise """
          environment variable TELEGRAM_OPERATORS is missing.

          Format: pipe-separated records, each record colon-separated:
            USER_ID:CHAT_ID:ROLE:AUDIT_ACTOR

          ROLE is one of: viewer, approver, security_operator, admin.
          Example:
            100200300:100200300:approver:ops-alice|100200301:-1001234567890:security_operator:ops-bob

          To disable the bot, set TELEGRAM_BOT_ENABLED to anything other
          than "true" instead of leaving this empty.
          """

      operators = Bank.Telegram.Config.parse_operators_env!(operators_raw)

      config :bank, Bank.Telegram.Config,
        enabled: true,
        bot_token: bot_token,
        webhook_secret: webhook_secret,
        operators: operators
    else
      config :bank, Bank.Telegram.Config,
        enabled: false,
        bot_token: nil,
        webhook_secret: nil,
        operators: []
    end

  _ ->
    :ok
end

# Bank.Accounts.OAuthProvider.Google: Google OAuth client for the
# private-alpha identity flow (epic #153, issue #154).
#
#   * GOOGLE_OAUTH_CLIENT_ID — OAuth 2.0 web-application client id
#     issued in Google Cloud console.
#   * GOOGLE_OAUTH_CLIENT_SECRET — paired client secret. Rotate on
#     staff change or credential leak.
#   * GOOGLE_OAUTH_REDIRECT_URI — must match the redirect URI
#     registered with the Google client and resolves to
#     `<PHX_HOST>/auth/google/callback`.
#
# In :prod all three env vars are required; the boot fails closed
# without them so we never silently fall back to a half-configured
# provider. In :dev / :test the test config wires the in-process
# `Bank.Accounts.OAuthProvider.Stub` instead, so this block is a no-op.
case config_env() do
  :prod ->
    google_client_id =
      System.get_env("GOOGLE_OAUTH_CLIENT_ID") ||
        raise """
        environment variable GOOGLE_OAUTH_CLIENT_ID is missing.
        Issue an OAuth 2.0 client id in Google Cloud console for the
        web application that hosts the operator console.
        """

    google_client_secret =
      System.get_env("GOOGLE_OAUTH_CLIENT_SECRET") ||
        raise """
        environment variable GOOGLE_OAUTH_CLIENT_SECRET is missing.
        Paired with GOOGLE_OAUTH_CLIENT_ID — rotate on staff change.
        """

    google_redirect_uri =
      System.get_env("GOOGLE_OAUTH_REDIRECT_URI") ||
        raise """
        environment variable GOOGLE_OAUTH_REDIRECT_URI is missing.
        Must match the redirect URI registered with the Google client.
        For example: https://<PHX_HOST>/auth/google/callback
        """

    config :bank, Bank.Accounts.OAuthProvider.Google,
      client_id: google_client_id,
      client_secret: google_client_secret,
      redirect_uri: google_redirect_uri

  _ ->
    :ok
end

# Bootstrap admin allowlist for the private-alpha approve / reject
# flow (epic #153, issue #157). Comma-separated list of operator
# emails — anyone in the list can hit `/admin/access` to approve or
# reject pending users until role-based authorization (issue #159)
# replaces this guard. Emails are normalised to lowercase + trimmed
# at read time so casing/whitespace in the env var is harmless.
admin_emails =
  case System.get_env("BANK_ADMIN_EMAILS") do
    nil ->
      []

    "" ->
      []

    raw ->
      raw
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
  end

config :bank, :admin_emails, admin_emails

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :bank, Bank.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :bank, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :bank, BankWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :bank, BankWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :bank, BankWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
