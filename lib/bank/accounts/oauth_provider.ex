defmodule Bank.Accounts.OAuthProvider do
  @moduledoc """
  Behaviour for the OAuth verify boundary used by
  `BankWeb.AuthController`.

  An implementation answers two questions on behalf of the
  controller:

    * "Where do I send the user's browser to start the OAuth flow?"
      — `c:authorize_url/2`
    * "Given the redirect parameters Google sent back, what verified
      identity claims do I keep?" — `c:fetch_user/3`

  ## Identity vs. tokens

  Implementations may briefly hold OAuth tokens (access / refresh /
  id) in memory while exchanging the auth code, but they MUST NOT
  return tokens to the caller. The behaviour's return map contains
  only identity claims:

      %{
        provider: :google,
        subject: "1234567890",   # Google `sub`, stable across email changes
        email: "user@example.com",
        name: "Linh Nguyen",
        avatar_url: "https://lh3.googleusercontent.com/..."
      }

  This is the contract `Bank.Accounts.find_or_create_from_oauth/1`
  consumes. A returning a token-shaped map will fail at the
  `Bank.Accounts.User` registration changeset (`reject_token_like_fields`).

  ## Logging hygiene

  Implementations MUST NOT log:

    * the auth code
    * the access / refresh / id token
    * the raw provider response body
    * tokenized URLs (e.g., redirect URIs that already carry secrets)

  Identity claims (sub, email, name, picture URL, hd) are OK to log
  at debug level; the runtime logs nothing of that here either, by
  default.

  ## Test injection

  Configure with:

      config :bank, Bank.Accounts.OAuthProvider, provider: Bank.Accounts.OAuthProvider.Stub

  for tests / dev fakes. Production reads the same key with the
  Google implementation.
  """

  @type provider_key :: :google
  @type session_state :: String.t()

  @type identity_claims :: %{
          required(:provider) => provider_key(),
          required(:subject) => String.t(),
          required(:email) => String.t(),
          optional(:name) => String.t() | nil,
          optional(:avatar_url) => String.t() | nil
        }

  @type fetch_error ::
          :missing_code
          | :invalid_state
          | :token_exchange_failed
          | :userinfo_failed
          | :provider_unavailable
          | {:provider_error, String.t()}

  @doc """
  Build the URL the browser should be redirected to in order to
  start the OAuth flow.

  `state` is a per-request CSRF token the controller stores in the
  session and verifies on the callback. The implementation embeds
  it in the OAuth `state` parameter unchanged.
  """
  @callback authorize_url(state :: session_state(), opts :: keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc """
  Verify the callback parameters Google sent back and return the
  identity claims.

  `params` is the unsanitised query-string map; the implementation
  validates and extracts what it needs. `expected_state` is the
  controller's previously-stored CSRF token; the implementation
  must compare it against `params["state"]` and reject mismatches
  with `{:error, :invalid_state}`.

  On success, returns `{:ok, identity_claims()}` — the tokens that
  were exchanged for these claims are NEVER returned. On failure,
  returns `{:error, fetch_error()}`.
  """
  @callback fetch_user(
              params :: map(),
              expected_state :: session_state(),
              opts :: keyword()
            ) :: {:ok, identity_claims()} | {:error, fetch_error()}

  @doc "Returns the configured provider module for this app."
  @spec provider() :: module()
  def provider do
    Application.get_env(:bank, __MODULE__, [])
    |> Keyword.get(:provider, Bank.Accounts.OAuthProvider.Google)
  end

  @doc "Forwards to `provider().authorize_url/2`."
  @spec authorize_url(session_state(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def authorize_url(state, opts \\ []), do: provider().authorize_url(state, opts)

  @doc "Forwards to `provider().fetch_user/3`."
  @spec fetch_user(map(), session_state(), keyword()) ::
          {:ok, identity_claims()} | {:error, fetch_error()}
  def fetch_user(params, expected_state, opts \\ []) do
    provider().fetch_user(params, expected_state, opts)
  end
end
