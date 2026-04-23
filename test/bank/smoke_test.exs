defmodule Bank.SmokeTest do
  use Bank.DataCase, async: true

  alias Bank.Delegations
  alias Bank.Smoke

  describe "run_revoke/1" do
    # Regression: commit 12dfc62 made `delegation_id` required on
    # `Bank.AdapterClient.dispatch_revoke_delegation/2`. The smoke task
    # was still calling it with only `smart_account_id + reason`, which
    # would raise `FunctionClauseError` the first time an operator ran
    # `mix bank.smoke.revoke`. This test pins that the smoke task reads
    # the delegation row and threads the id into the dispatch payload.
    test "threads delegation_id from the Delegations projection into the dispatch payload" do
      smart_account_id = "sa_smoke_#{Ecto.UUID.generate()}"
      delegation_id = "del_smoke_#{Ecto.UUID.generate()}"
      {:ok, _} = Delegations.grant(smart_account_id, delegation_id)

      test_pid = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:dispatch, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          202,
          Jason.encode!(%{"accepted" => true, "smart_account_id" => smart_account_id})
        )
      end)

      # `timeout_ms: 1` causes `await_revoked` to bail immediately
      # after the first poll — the delegation stays `:active`, so the
      # smoke run returns `{:error, {:timeout, :active}}`. We only
      # care that the dispatch body carried the right fields before
      # that point.
      assert {:error, {:timeout, :active}} =
               Smoke.run_revoke(
                 smart_account_id: smart_account_id,
                 reason: "smoke_test",
                 timeout_ms: 1
               )

      assert_received {:dispatch, payload}
      assert payload["action"] == "revoke_delegation"
      assert payload["smart_account_id"] == smart_account_id
      assert payload["delegation_id"] == delegation_id
      assert payload["reason"] == "smoke_test"
    end

    test "returns :no_active_delegation when no delegation row exists" do
      # Pre-existing behaviour — not the new code path, just guarding
      # against regressions in the else-branch after the pattern was
      # extended to destructure `delegation_id`.
      assert {:error, :no_active_delegation} =
               Smoke.run_revoke(
                 smart_account_id: "sa_smoke_absent_#{Ecto.UUID.generate()}",
                 reason: "smoke_test",
                 timeout_ms: 1
               )
    end
  end
end
