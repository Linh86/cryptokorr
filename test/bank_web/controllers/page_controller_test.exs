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
end
