defmodule BankWeb.HealthControllerTest do
  use BankWeb.ConnCase, async: true

  describe "GET /health" do
    test "returns 200 with liveness payload", %{conn: conn} do
      conn = get(conn, ~p"/health")
      body = json_response(conn, 200)
      assert body["status"] == "ok"
      assert body["service"] == "bank"
      assert is_binary(body["version"])
    end
  end

  describe "GET /v1/health" do
    test "returns 200 with ok checks when the database is reachable", %{conn: conn} do
      conn = get(conn, ~p"/v1/health")
      body = json_response(conn, 200)
      assert body["status"] == "ok"
      assert body["checks"]["database"] == "ok"
    end
  end
end
