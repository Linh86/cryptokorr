defmodule BankWeb.API.V1.IntentControllerTest do
  @moduledoc """
  Smoke tests for the `/v1/intents` scaffold.

  These assert the stub contract only — once the intent engine lands
  (issue #7) each of these should flip to real behaviour checks.
  """

  use BankWeb.ConnCase, async: true

  test "POST /v1/intents returns the 501 envelope", %{conn: conn} do
    conn = post(conn, ~p"/v1/intents", %{})
    body = json_response(conn, 501)
    assert body["error"]["code"] == "not_implemented"
    assert body["error"]["retryable"] == false
    assert body["error"]["message"] =~ "/v1/intents"
  end

  test "GET /v1/intents/:id returns the 501 envelope", %{conn: conn} do
    conn = get(conn, ~p"/v1/intents/abc")
    body = json_response(conn, 501)
    assert body["error"]["code"] == "not_implemented"
  end
end
