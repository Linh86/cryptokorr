defmodule Bank.Accounts.OAuthProvider.Google do
  @moduledoc """
  Google OAuth 2.0 / OIDC implementation of
  `Bank.Accounts.OAuthProvider`.

  The flow:

    1. Browser hits `GET /auth/google` — controller stores a
       per-session CSRF `state` and redirects to the URL this
       module returns from `authorize_url/2`.
    2. Browser bounces to Google, user consents.
    3. Browser hits `GET /auth/google/callback?code=...&state=...`.
    4. Controller calls `fetch_user/3`. We:
       - verify `params["state"]` matches the session CSRF token,
       - exchange `params["code"]` for an access + id token at
         Google's `/oauth2/v4/token`,
       - call `/oauth2/v3/userinfo` for `sub`, `email`,
         `email_verified`, `name`, `picture`,
       - drop the tokens, return identity claims.

  ## Logging hygiene

  This module logs **identity claims and structural failures only**.
  Specifically forbidden from logs:

    * the authorization code
    * the access / refresh / id tokens
    * the raw HTTP response body from token / userinfo
    * the request URL with the auth code in it

  Logged at `:warning` for failures: the failure reason atom and
  the HTTP status code. No secrets.

  ## Configuration

      config :bank, #{inspect(__MODULE__)},
        client_id: System.get_env("GOOGLE_OAUTH_CLIENT_ID"),
        client_secret: System.get_env("GOOGLE_OAUTH_CLIENT_SECRET"),
        redirect_uri: System.get_env("GOOGLE_OAUTH_REDIRECT_URI")

  All three are required at runtime. Missing values surface as
  `{:error, :provider_unavailable}` at the start of `authorize_url/2`
  rather than crashing — the runtime stays up if OAuth env is
  unset (useful for local dev without Google credentials).
  """

  @behaviour Bank.Accounts.OAuthProvider

  require Logger

  @authorize_endpoint "https://accounts.google.com/o/oauth2/v2/auth"
  @token_endpoint "https://oauth2.googleapis.com/token"
  @userinfo_endpoint "https://www.googleapis.com/oauth2/v3/userinfo"
  @scope "openid email profile"

  @impl true
  def authorize_url(state, _opts) when is_binary(state) do
    case config() do
      {:ok, %{client_id: client_id, redirect_uri: redirect_uri}} ->
        query =
          URI.encode_query(%{
            client_id: client_id,
            redirect_uri: redirect_uri,
            response_type: "code",
            scope: @scope,
            state: state,
            access_type: "online",
            prompt: "select_account"
          })

        {:ok, @authorize_endpoint <> "?" <> query}

      {:error, :provider_unavailable} = err ->
        err
    end
  end

  @impl true
  def fetch_user(%{} = params, expected_state, opts) when is_binary(expected_state) do
    with :ok <- verify_state(params, expected_state),
         {:ok, code} <- fetch_code(params),
         {:ok, %{client_id: client_id, client_secret: client_secret, redirect_uri: redirect_uri}} <-
           config(),
         {:ok, access_token} <-
           exchange_code(code, client_id, client_secret, redirect_uri, opts),
         {:ok, claims} <- userinfo(access_token, opts) do
      {:ok, claims}
    end
  end

  defp verify_state(%{"state" => provided}, expected) when is_binary(provided) do
    if Plug.Crypto.secure_compare(provided, expected),
      do: :ok,
      else: {:error, :invalid_state}
  end

  defp verify_state(_params, _expected), do: {:error, :invalid_state}

  defp fetch_code(%{"code" => code}) when is_binary(code) and code != "", do: {:ok, code}
  defp fetch_code(_params), do: {:error, :missing_code}

  defp exchange_code(code, client_id, client_secret, redirect_uri, opts) do
    body = %{
      code: code,
      client_id: client_id,
      client_secret: client_secret,
      redirect_uri: redirect_uri,
      grant_type: "authorization_code"
    }

    case http_request(:post, @token_endpoint, body: form_body(body), opts: opts) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} when is_binary(token) ->
        {:ok, token}

      {:ok, %{status: status}} ->
        Logger.warning("OAuth.Google: token exchange returned non-200 (status=#{status})")

        {:error, :token_exchange_failed}

      {:error, _reason} ->
        Logger.warning("OAuth.Google: token exchange transport error")
        {:error, :provider_unavailable}
    end
  end

  defp userinfo(access_token, opts) do
    case http_request(
           :get,
           @userinfo_endpoint,
           headers: [{"authorization", "Bearer " <> access_token}],
           opts: opts
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        case extract_claims(body) do
          {:ok, claims} ->
            {:ok, claims}

          {:error, reason} ->
            Logger.warning("OAuth.Google: userinfo claims malformed (reason=#{inspect(reason)})")
            {:error, :userinfo_failed}
        end

      {:ok, %{status: status}} ->
        Logger.warning("OAuth.Google: userinfo non-200 (status=#{status})")
        {:error, :userinfo_failed}

      {:error, _reason} ->
        Logger.warning("OAuth.Google: userinfo transport error")
        {:error, :provider_unavailable}
    end
  end

  defp extract_claims(%{"sub" => sub, "email" => email} = body)
       when is_binary(sub) and is_binary(email) and sub != "" and email != "" do
    {:ok,
     %{
       provider: :google,
       subject: sub,
       email: Bank.Accounts.normalise_email(email),
       name: Map.get(body, "name"),
       avatar_url: Map.get(body, "picture")
     }}
  end

  defp extract_claims(_), do: {:error, :missing_required_claims}

  defp http_request(method, url, opts) do
    headers = Keyword.get(opts, :headers, [])
    body = Keyword.get(opts, :body)
    req_opts = Keyword.get(opts[:opts] || [], :req_opts, [])

    request_opts =
      [method: method, url: url, headers: headers]
      |> Keyword.merge(req_opts)
      |> then(fn opts ->
        if body, do: Keyword.put(opts, :body, body), else: opts
      end)

    case Req.request(request_opts) do
      {:ok, %Req.Response{} = resp} -> {:ok, %{status: resp.status, body: resp.body}}
      {:error, _} = err -> err
    end
  end

  defp form_body(map) do
    map
    |> Enum.map(fn {k, v} -> "#{k}=#{URI.encode_www_form(to_string(v))}" end)
    |> Enum.join("&")
  end

  defp config do
    cfg = Application.get_env(:bank, __MODULE__, [])

    client_id = Keyword.get(cfg, :client_id)
    client_secret = Keyword.get(cfg, :client_secret)
    redirect_uri = Keyword.get(cfg, :redirect_uri)

    if is_binary(client_id) and client_id != "" and
         is_binary(client_secret) and client_secret != "" and
         is_binary(redirect_uri) and redirect_uri != "" do
      {:ok, %{client_id: client_id, client_secret: client_secret, redirect_uri: redirect_uri}}
    else
      {:error, :provider_unavailable}
    end
  end
end
