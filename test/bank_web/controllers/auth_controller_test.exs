defmodule BankWeb.AuthControllerTest do
  @moduledoc """
  End-to-end browser-flow tests for the OAuth surface (epic #153,
  issue #154). The provider is `Bank.Accounts.OAuthProvider.Stub`
  in the test env (configured in `config/test.exs`), so no network
  call leaves the test process; per-test claims are injected via
  `Application.put_env/3`.

  Cases pinned here:
    * GET /auth/google stores a session state and redirects out
    * callback success on first login → pending_access user, session
    * callback success on returning login → reuses user, refreshes name
    * callback failure → no session, no user written
    * disabled user → no session, redirect to /login
    * logout clears the session
    * no token-like data ends up persisted on the user row
  """

  use BankWeb.ConnCase, async: false

  alias Bank.Accounts
  alias Bank.Accounts.User
  alias Bank.Workspaces

  @stub Bank.Accounts.OAuthProvider.Stub

  setup do
    on_exit(fn -> Application.put_env(:bank, @stub, %{}) end)
    :ok
  end

  defp put_stub(cfg), do: Application.put_env(:bank, @stub, cfg)

  defp claims_for(subject, email, name \\ "Alice", avatar_url \\ nil) do
    %{
      provider: :google,
      subject: subject,
      email: email,
      name: name,
      avatar_url: avatar_url
    }
  end

  describe "GET /auth/google (request)" do
    test "redirects to the provider URL and stores state", %{conn: conn} do
      conn = get(conn, ~p"/auth/google")

      assert redirected_to(conn) =~ "/auth/google/callback?code=stub-code&state="
      assert is_binary(get_session(conn, :oauth_state))
      assert byte_size(get_session(conn, :oauth_state)) > 16
    end

    test "redirects back to /login with a flash when provider unconfigured", %{conn: conn} do
      put_stub(%{outcome: :provider_unavailable})

      conn = get(conn, ~p"/auth/google")
      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Google sign-in is not configured"
    end
  end

  describe "GET /auth/google/callback (success cases)" do
    test "first login creates a pending_access user and starts a session", %{conn: conn} do
      put_stub(%{claims: claims_for("google-sub-new", "newcomer@example.com", "Newcomer")})

      conn = get(conn, ~p"/auth/google")
      state = get_session(conn, :oauth_state)
      assert is_binary(state)

      callback_conn = get(conn, ~p"/auth/google/callback?code=stub-code&state=#{state}")

      assert redirected_to(callback_conn) == ~p"/pending"
      user_id = get_session(callback_conn, :user_id)
      assert is_binary(user_id)

      user = Accounts.get_user(user_id)
      assert user.email == "newcomer@example.com"
      assert user.status == :pending_access
      assert user.name == "Newcomer"

      # State token is single-use — gone after a successful callback.
      assert get_session(callback_conn, :oauth_state) == nil
    end

    test "returning login reuses the user and refreshes name", %{conn: conn} do
      sub = "returning-user-1"
      put_stub(%{claims: claims_for(sub, "alice@example.com", "Alice Original")})

      # First login.
      conn1 = get(conn, ~p"/auth/google")
      state1 = get_session(conn1, :oauth_state)
      conn1 = get(conn1, ~p"/auth/google/callback?code=stub-code&state=#{state1}")
      assert get_session(conn1, :user_id)
      user_id_first = get_session(conn1, :user_id)

      # Second login with refreshed display name.
      put_stub(%{claims: claims_for(sub, "alice@example.com", "Alice Renamed")})

      conn2 = get(build_conn(), ~p"/auth/google")
      state2 = get_session(conn2, :oauth_state)
      conn2 = get(conn2, ~p"/auth/google/callback?code=stub-code&state=#{state2}")

      user_id_second = get_session(conn2, :user_id)
      assert user_id_second == user_id_first

      user = Accounts.get_user(user_id_second)
      assert user.name == "Alice Renamed"
      assert Bank.Repo.aggregate(User, :count) == 1
    end

    test "user with no active membership lands on /pending", %{conn: conn} do
      put_stub(%{claims: claims_for("no-membership", "no-membership@example.com")})

      conn = get(conn, ~p"/auth/google")
      state = get_session(conn, :oauth_state)
      conn = get(conn, ~p"/auth/google/callback?code=stub-code&state=#{state}")

      assert redirected_to(conn) == ~p"/pending"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "pending operator approval"
    end

    test "user with a single active membership lands on /", %{conn: conn} do
      sub = "single-membership"
      put_stub(%{claims: claims_for(sub, "single@example.com", "Single")})

      # First login creates the user.
      conn1 = get(conn, ~p"/auth/google")
      state1 = get_session(conn1, :oauth_state)
      conn1 = get(conn1, ~p"/auth/google/callback?code=stub-code&state=#{state1}")
      assert redirected_to(conn1) == ~p"/pending"

      # Operator-driven workspace + membership setup (the operator
      # console / invite flow is #156-#157; we simulate it).
      user = Accounts.get_user(get_session(conn1, :user_id))
      {:ok, ws} = Workspaces.create_workspace(%{slug: "alpha", name: "Alpha"})

      {:ok, _} =
        Workspaces.create_membership(%{
          user_id: user.id,
          workspace_id: ws.id,
          role: :operator
        })

      put_stub(%{claims: claims_for(sub, "single@example.com", "Single")})

      conn2 = get(build_conn(), ~p"/auth/google")
      state2 = get_session(conn2, :oauth_state)
      conn2 = get(conn2, ~p"/auth/google/callback?code=stub-code&state=#{state2}")

      assert redirected_to(conn2) == ~p"/"
      assert Phoenix.Flash.get(conn2.assigns.flash, :info) =~ "Welcome"
    end

    test "user with multiple active memberships lands on /pending (ambiguous)", %{conn: conn} do
      sub = "multi-membership"
      put_stub(%{claims: claims_for(sub, "multi@example.com")})

      conn1 = get(conn, ~p"/auth/google")
      state1 = get_session(conn1, :oauth_state)
      conn1 = get(conn1, ~p"/auth/google/callback?code=stub-code&state=#{state1}")
      user = Accounts.get_user(get_session(conn1, :user_id))

      {:ok, ws1} = Workspaces.create_workspace(%{slug: "alpha", name: "Alpha"})
      {:ok, ws2} = Workspaces.create_workspace(%{slug: "bravo", name: "Bravo"})

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws1.id, role: :operator})

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws2.id, role: :viewer})

      put_stub(%{claims: claims_for(sub, "multi@example.com")})

      conn2 = get(build_conn(), ~p"/auth/google")
      state2 = get_session(conn2, :oauth_state)
      conn2 = get(conn2, ~p"/auth/google/callback?code=stub-code&state=#{state2}")

      assert redirected_to(conn2) == ~p"/pending"
      assert Phoenix.Flash.get(conn2.assigns.flash, :info) =~ "multiple workspaces"
    end
  end

  describe "GET /auth/google/callback (failure cases)" do
    test "missing session state redirects with flash", %{conn: conn} do
      # No prior /auth/google means no session-stored state.
      conn = get(conn, ~p"/auth/google/callback?code=stub-code&state=anything")

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Sign-in session expired"
      assert Bank.Repo.aggregate(User, :count) == 0
      assert get_session(conn, :user_id) == nil
    end

    test "mismatched state is rejected and clears the session state", %{conn: conn} do
      put_stub(%{claims: claims_for("never", "never@example.com")})

      conn = get(conn, ~p"/auth/google")
      _legit_state = get_session(conn, :oauth_state)

      conn = get(conn, ~p"/auth/google/callback?code=stub-code&state=tampered")

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "tampered"
      assert get_session(conn, :user_id) == nil
      assert get_session(conn, :oauth_state) == nil
      assert Bank.Repo.aggregate(User, :count) == 0
    end

    test "missing code is rejected", %{conn: conn} do
      put_stub(%{claims: claims_for("never", "never@example.com")})

      conn = get(conn, ~p"/auth/google")
      state = get_session(conn, :oauth_state)

      conn = get(conn, ~p"/auth/google/callback?state=#{state}")

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "authorization code"
      assert Bank.Repo.aggregate(User, :count) == 0
    end

    test "provider error is mapped to a generic error flash", %{conn: conn} do
      conn = get(conn, ~p"/auth/google")
      state = get_session(conn, :oauth_state)

      put_stub(%{outcome: {:provider_error, "consent_required"}})

      conn = get(conn, ~p"/auth/google/callback?code=stub-code&state=#{state}")

      assert redirected_to(conn) == ~p"/login"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Google rejected"
      assert Bank.Repo.aggregate(User, :count) == 0
    end

    test "disabled user is refused a session", %{conn: conn} do
      sub = "disabled-target"
      put_stub(%{claims: claims_for(sub, "disabled@example.com")})

      # First login as :pending_access.
      conn1 = get(conn, ~p"/auth/google")
      state1 = get_session(conn1, :oauth_state)
      conn1 = get(conn1, ~p"/auth/google/callback?code=stub-code&state=#{state1}")

      assert get_session(conn1, :user_id)
      user = Accounts.get_user(get_session(conn1, :user_id))
      {:ok, _} = Accounts.disable_user(user)

      # Repeat login — refused.
      put_stub(%{claims: claims_for(sub, "disabled@example.com")})

      conn2 = get(build_conn(), ~p"/auth/google")
      state2 = get_session(conn2, :oauth_state)
      conn2 = get(conn2, ~p"/auth/google/callback?code=stub-code&state=#{state2}")

      assert redirected_to(conn2) == ~p"/login"
      assert Phoenix.Flash.get(conn2.assigns.flash, :error) =~ "disabled"
      assert get_session(conn2, :user_id) == nil
    end
  end

  describe "DELETE /logout" do
    test "clears the session and redirects to /login", %{conn: conn} do
      put_stub(%{claims: claims_for("logout-target", "logout@example.com")})

      conn = get(conn, ~p"/auth/google")
      state = get_session(conn, :oauth_state)
      conn = get(conn, ~p"/auth/google/callback?code=stub-code&state=#{state}")
      assert get_session(conn, :user_id)

      conn = delete(conn, ~p"/logout")
      assert redirected_to(conn) == ~p"/login"
      assert get_session(conn, :user_id) == nil
    end

    test "POST /logout works for the form-driven sign-out button", %{conn: conn} do
      put_stub(%{claims: claims_for("logout-form-target", "logout-form@example.com")})

      conn = get(conn, ~p"/auth/google")
      state = get_session(conn, :oauth_state)
      conn = get(conn, ~p"/auth/google/callback?code=stub-code&state=#{state}")

      conn = post(conn, ~p"/logout", %{"_method" => "delete"})
      assert redirected_to(conn) == ~p"/login"
      assert get_session(conn, :user_id) == nil
    end
  end

  describe "secret hygiene" do
    test "no token-like attribute survives a successful login", %{conn: conn} do
      put_stub(%{claims: claims_for("hygiene-target", "hygiene@example.com")})

      conn = get(conn, ~p"/auth/google")
      state = get_session(conn, :oauth_state)
      conn = get(conn, ~p"/auth/google/callback?code=stub-code&state=#{state}")

      user = Accounts.get_user(get_session(conn, :user_id))
      fields = User.__schema__(:fields)

      forbidden =
        ~w(access_token refresh_token id_token raw_response token authorization auth_code)a

      for field <- forbidden do
        refute field in fields,
               "User schema must not declare a #{inspect(field)} field"
      end

      # Spot-check the persisted struct only carries identity.
      assert user.email == "hygiene@example.com"
      assert user.provider_subject == "hygiene-target"
    end
  end
end
