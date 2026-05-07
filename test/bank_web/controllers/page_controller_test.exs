defmodule BankWeb.PageControllerTest do
  use BankWeb.ConnCase

  setup :register_and_log_in_user

  test "GET / serves the control tower LiveView for an authenticated workspace member",
       %{conn: conn} do
    conn = get(conn, ~p"/")
    # The route now serves a LiveView; a non-websocket GET returns
    # the static render (the LiveView mount HTML).
    assert html_response(conn, 200) =~ "Connection"
  end

  test "GET / redirects an anonymous user to /login", %{} do
    conn = Phoenix.ConnTest.build_conn() |> Plug.Test.init_test_session(%{})
    conn = get(conn, ~p"/")
    assert redirected_to(conn) =~ "/login"
  end

  describe "Content-Security-Policy header (audit M7)" do
    test "GET /login (browser pipeline) emits the strict CSP", %{} do
      conn = Phoenix.ConnTest.build_conn() |> get(~p"/login")
      [csp] = get_resp_header(conn, "content-security-policy")

      # Pinned directives — script/connect/object/frame-ancestors are
      # the load-bearing parts; exact string is documented on
      # `BankWeb.Plugs.PutCSP`.
      assert csp =~ "default-src 'self'"
      assert csp =~ "script-src 'self'"
      assert csp =~ "connect-src 'self'"
      assert csp =~ "frame-ancestors 'none'"
      assert csp =~ "object-src 'none'"
      assert csp =~ "base-uri 'self'"
      assert csp =~ "form-action 'self'"

      # `style-src 'unsafe-inline'` is intentional — Phoenix LiveView
      # injects per-element styles. Any tightening here is a
      # follow-up gated on upstream support.
      assert csp =~ "style-src 'self' 'unsafe-inline'"

      # `script-src` MUST NOT carry `'unsafe-inline'`; the audit's
      # whole point of externalising the theme-init script. Use a
      # bounded match so a future `'unsafe-inline'` in a different
      # directive doesn't accidentally satisfy this assertion.
      refute csp =~ "script-src 'self' 'unsafe-inline'"
    end

    test "GET / (authenticated browser route) emits the strict CSP overriding Phoenix default",
         %{conn: conn} do
      conn = get(conn, ~p"/")
      [csp] = get_resp_header(conn, "content-security-policy")

      # The Phoenix-default CSP is `base-uri 'self'; frame-ancestors
      # 'self';` — `frame-ancestors 'none'` proves our plug ran AFTER
      # `put_secure_browser_headers` and overwrote the default.
      assert csp =~ "frame-ancestors 'none'"
      refute csp =~ "frame-ancestors 'self';"
    end
  end

  describe "session cookie attributes (audit M6)" do
    test "GET /login sets HttpOnly on the session cookie", %{} do
      conn = Phoenix.ConnTest.build_conn() |> get(~p"/login")
      [set_cookie] = get_resp_header(conn, "set-cookie")

      # `http_only: true` is set explicitly in `@session_options`.
      # The Plug default is already true, but pinning the cookie
      # attribute lets us assert against a misconfiguration.
      assert set_cookie =~ "_bank_key="
      assert set_cookie =~ "HttpOnly"

      # `secure: true` is gated on `Mix.env() == :prod`. In :test the
      # flag is absent so the cookie still flows over HTTP — the
      # prod-mode behaviour is exercised in the dedicated session
      # test below.
      refute set_cookie =~ "secure"
    end
  end
end
