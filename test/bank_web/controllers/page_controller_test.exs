defmodule BankWeb.PageControllerTest do
  use BankWeb.ConnCase

  test "GET / redirects to the control tower LiveView", %{conn: conn} do
    conn = get(conn, ~p"/")
    # The route now serves a LiveView; a non-websocket GET returns
    # the static render (the LiveView mount HTML).
    assert html_response(conn, 200) =~ "Connection"
  end
end
