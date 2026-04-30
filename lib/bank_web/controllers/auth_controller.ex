defmodule BankWeb.AuthController do
  @moduledoc """
  Browser auth surface for Google OAuth (epic #153, issue #154).

  Three actions:

    * `GET /auth/google` — `request/2` mints a per-session CSRF
      `state` and redirects to Google's authorize URL.
    * `GET /auth/google/callback` — `callback/2` verifies the state,
      asks `Bank.Accounts.OAuthProvider` for identity claims,
      idempotent-creates a user via `Bank.Accounts`, and starts a
      session (or refuses one for `:disabled` users).
    * `DELETE /logout` (also `POST /logout`) — `delete/2` clears
      the session.

  ## Session contract

  We store ONLY `user_id` (a UUID) in the session. No tokens, no
  email, no role. The user struct is reloaded on every request by
  `BankWeb.Plugs.FetchCurrentUser`, which is the single source of
  truth for `conn.assigns.current_user` / `conn.assigns.current_scope`.

  ## Pending access

  A successful OAuth callback for a `:pending_access` user still
  starts a session — they just see the pending-access screen
  (issue #157). `:disabled` users get a flash and no session.

  ## Invite consumption

  Between the identity upsert and the scope re-resolution we call
  `Bank.Access.apply_invites_for_user/1` (issue #156). An active
  exact-email invite turns into a fresh membership; an active
  domain invite stays pending. The scope resolution that follows
  picks up any newly created membership without a second login.

  ## Logging hygiene

  This controller never logs `params` (which carry the auth code)
  and never logs the OAuth claims map (which carries email +
  identity). Failures log the failure atom only. The verify
  boundary in `Bank.Accounts.OAuthProvider.Google` enforces the
  same rule for token exchange + userinfo.
  """

  use BankWeb, :controller

  alias Bank.Access
  alias Bank.Accounts
  alias Bank.Accounts.OAuthProvider
  alias Bank.Audit
  alias Bank.Audit.Events
  alias Bank.Workspaces
  alias BankWeb.Plugs.FetchCurrentUser

  require Logger

  @state_session_key :oauth_state

  @doc """
  Start the OAuth flow: mint a state token, store it in the
  session, redirect to the provider.
  """
  def request(conn, _params) do
    state = generate_state()

    case OAuthProvider.authorize_url(state) do
      {:ok, url} ->
        conn
        |> put_session(@state_session_key, state)
        |> redirect(external: url)

      {:error, :provider_unavailable} ->
        Logger.warning("AuthController: provider not configured")

        conn
        |> put_flash(
          :error,
          "Google sign-in is not configured. " <>
            "Set GOOGLE_OAUTH_CLIENT_ID / SECRET / REDIRECT_URI and try again."
        )
        |> redirect(to: ~p"/login")

      {:error, reason} ->
        Logger.warning("AuthController: authorize_url failed (reason=#{inspect(reason)})")

        conn
        |> put_flash(:error, "Could not start Google sign-in. Please try again.")
        |> redirect(to: ~p"/login")
    end
  end

  @doc """
  Handle the OAuth callback. Verifies state, fetches identity,
  starts a session if allowed, otherwise renders an error and
  clears any partial state.
  """
  def callback(conn, params) do
    expected_state = get_session(conn, @state_session_key)

    if is_binary(expected_state) and expected_state != "" do
      do_callback(conn, params, expected_state)
    else
      Logger.warning("AuthController: callback without session state")

      conn
      |> delete_session(@state_session_key)
      |> put_flash(:error, "Sign-in session expired. Please try again.")
      |> redirect(to: ~p"/login")
    end
  end

  defp do_callback(conn, params, expected_state) do
    case OAuthProvider.fetch_user(params, expected_state) do
      {:ok, claims} ->
        # Identity is verified at this point. Drop the OAuth state
        # token from the session — it's single-use.
        conn = delete_session(conn, @state_session_key)
        upsert_and_login(conn, claims)

      {:error, reason} ->
        Logger.warning("AuthController: OAuth callback failed (reason=#{inspect(reason)})")

        conn
        |> delete_session(@state_session_key)
        |> put_flash(:error, callback_error_message(reason))
        |> redirect(to: ~p"/login")
    end
  end

  defp upsert_and_login(conn, claims) do
    case Accounts.find_or_create_from_oauth(claims) do
      {:ok, user} ->
        if Accounts.session_allowed?(user) do
          # Apply any active invite for this user before resolving
          # scope so a brand-new exact-email invite turns into the
          # workspace landing on the very first login (#156).
          _ = Access.apply_invites_for_user(user)

          resolution = Workspaces.resolve_scope(user)

          safe_audit(Events.auth_login_succeeded(user))

          conn
          |> renew_session()
          |> put_session(FetchCurrentUser.session_key(), user.id)
          |> put_flash(:info, login_flash(user, resolution))
          |> redirect(to: post_login_path(user, resolution))
        else
          Logger.warning("AuthController: refused session for disabled user")

          safe_audit(Events.auth_login_denied(user, :disabled))

          conn
          |> put_flash(
            :error,
            "Your account is disabled. Contact an operator to re-enable it."
          )
          |> redirect(to: ~p"/login")
        end

      {:error, changeset} ->
        Logger.warning("AuthController: user upsert failed (errors=#{inspect(changeset.errors)})")

        conn
        |> put_flash(:error, "Could not complete sign-in. Please try again.")
        |> redirect(to: ~p"/login")
    end
  end

  # Audit failure must never block a redirect — swallow + log.
  defp safe_audit(attrs) do
    case Audit.append_event(attrs) do
      {:ok, _event} ->
        :ok

      {:error, reason} ->
        Logger.warning("AuthController: audit emission failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Sign the current user out and redirect to the login page."
  def delete(conn, _params) do
    conn
    |> renew_session()
    |> put_flash(:info, "You are signed out.")
    |> redirect(to: ~p"/login")
  end

  # --- internals ---

  # Per OWASP — generate a fresh session id on every privilege
  # transition (login, logout). `clear_session/1` drops the data,
  # `configure_session(renew: true)` re-issues the cookie.
  defp renew_session(conn) do
    conn
    |> clear_session()
    |> configure_session(renew: true)
  end

  defp generate_state do
    24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  # Workspace state — not `User.status` — decides whether the user
  # enters the app. `:active` from `Accounts` only means "not
  # disabled". A user with no active membership (or with an
  # ambiguous set of memberships, until the picker in #157) lands on
  # `/pending` instead of silently entering some workspace.
  defp post_login_path(_user, {:single, _membership}), do: ~p"/"
  defp post_login_path(_user, :no_membership), do: ~p"/pending"
  defp post_login_path(_user, {:ambiguous, _memberships}), do: ~p"/pending"

  defp login_flash(%Bank.Accounts.User{name: name}, {:single, _})
       when is_binary(name) and name != "" do
    "Welcome back, #{name}."
  end

  defp login_flash(_user, {:single, _}), do: "Welcome back."

  defp login_flash(_user, :no_membership) do
    "Signed in. Your workspace access is pending operator approval."
  end

  defp login_flash(_user, {:ambiguous, _}) do
    "Signed in. You belong to multiple workspaces — an operator will help you select one."
  end

  defp callback_error_message(:invalid_state),
    do: "The sign-in request expired or was tampered with. Please try again."

  defp callback_error_message(:missing_code), do: "Google did not return an authorization code."

  defp callback_error_message(:provider_unavailable),
    do: "Google sign-in is temporarily unavailable. Please try again."

  defp callback_error_message(:token_exchange_failed),
    do: "Google rejected our credentials. Please try again."

  defp callback_error_message(:userinfo_failed),
    do: "Could not read your Google profile. Please try again."

  defp callback_error_message({:provider_error, _msg}),
    do: "Google rejected the sign-in. Please try again."

  defp callback_error_message(_), do: "Sign-in failed. Please try again."
end
