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

  describe "GET /v1/health/deep" do
    test "returns ok when every check passes", %{conn: conn} do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.json(conn, %{status: "ok"})
      end)

      conn = get(conn, ~p"/v1/health/deep")
      body = json_response(conn, 200)
      assert body["status"] == "ok"
      assert body["checks"]["database"]["status"] == "ok"
      assert body["checks"]["adapter"]["status"] == "ok"
      assert body["checks"]["stuck_plans"]["status"] == "ok"
      assert body["checks"]["stuck_plans"]["count"] == 0
    end

    test "returns 503 when the adapter is unreachable", %{conn: conn} do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      conn = get(conn, ~p"/v1/health/deep")
      body = json_response(conn, 503)
      assert body["status"] == "degraded"
      assert body["checks"]["adapter"]["status"] == "error"
    end
  end
end
