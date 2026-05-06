defmodule Bank.MainnetGateTest do
  @moduledoc """
  End-to-end regression suite for the explicit Base mainnet feature
  gates (#178).

  Each describe block exercises one of the four chain-touching
  boundaries the issue calls out by name: connect, execute,
  revoke, dispatch. Plus the intent-submission boundary, which is
  the earliest fail-closed gate (the controller's `Intents.submit/2`
  refuses to write any DB row for a mainnet intent on a workspace
  without `mainnet_enabled: true`).

  Posture per acceptance:

    * Mainnet disabled by default in all envs — every fresh
      workspace starts at `mainnet_enabled: false`.
    * Testnet paths continue to work when enabled — `chain:
      "base-sepolia"` is allowed regardless of the flag.
    * Mainnet request fails closed without creating execution
      plans or adapter dispatches — every gate either returns
      `{:error, :mainnet_disabled}` synchronously or aborts the
      worker with `{:cancel, :mainnet_disabled}`; no
      `Bank.Decisions.ExecutionPlan` row gets written and no
      `Bank.AdapterClient` HTTP call leaves the test process.
  """

  use Bank.DataCase, async: false

  alias Bank.Chains
  alias Bank.Decisions
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Delegations
  alias Bank.Intents
  alias Bank.Repo
  alias Bank.Runtime.Workers.RevokeDelegation
  alias Bank.Runtime.Workers.RunExecution
  alias Bank.Security
  alias Bank.Security.PauseState
  alias Bank.Workspaces

  import Bank.Fixtures

  # Reset the global PauseState before each test so a leaked
  # `:global` pause from a prior test file (e.g. control LiveView,
  # security LiveView, swap-dispatch-safety) cannot turn the
  # mainnet-gate assertions in this file into a `:runtime_paused`
  # flake. Same hygiene fix applied to
  # `test/bank/cross_account_isolation_test.exs` in #191's PR.
  setup do
    PauseState.reset()
    :ok
  end

  defp workspace_with_flag(flag) when is_boolean(flag) do
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Workspaces.create_workspace(%{
        slug: "mainnet-gate-#{flag}-#{suffix}",
        name: "Mainnet gate #{flag} #{suffix}",
        mainnet_enabled: flag
      })

    ws
  end

  defp counterparty_with_label(workspace_id) do
    cp = counterparty(workspace_id: workspace_id)

    # Unique 40-hex address per insertion so concurrent test cases
    # don't collide on `address_labels_chain_address_active_idx`.
    suffix = System.unique_integer([:positive])
    hex = suffix |> Integer.to_string(16) |> String.pad_leading(40, "0")

    label =
      address_label(
        counterparty: cp,
        chain: "base",
        address: "0x" <> hex
      )

    %{cp: cp, label: label}
  end

  defp submit_intent(workspace_id, chain) do
    suffix = System.unique_integer([:positive])
    %{cp: cp} = counterparty_with_label(workspace_id)

    Intents.submit(
      %{
        "agent_id" => "gate-agent-#{suffix}",
        "source" => "agent",
        "idempotency_key" => "gate-#{suffix}",
        "kind" => "transfer",
        "asset" => "USDC",
        "chain" => chain,
        "amount" => "1.00",
        "target" => %{"counterparty_id" => cp.id}
      },
      workspace_id: workspace_id
    )
  end

  describe "intent submit gate" do
    test "rejects a mainnet intent on a workspace without mainnet_enabled" do
      ws = workspace_with_flag(false)

      assert {:error, :mainnet_disabled} = submit_intent(ws.id, "base")

      # No intent row was written.
      assert Repo.aggregate(Bank.Intents.AgentIntent, :count) == 0
    end

    test "accepts a mainnet intent on a workspace with mainnet_enabled flipped on" do
      ws = workspace_with_flag(true)

      assert {:ok, %{intent: intent}} = submit_intent(ws.id, "base")
      assert intent.workspace_id == ws.id
      assert intent.chain == "base"
    end

    test "accepts a testnet intent regardless of the workspace flag" do
      ws_off = workspace_with_flag(false)
      ws_on = workspace_with_flag(true)

      assert {:ok, %{intent: intent_off}} = submit_intent(ws_off.id, "base-sepolia")
      assert intent_off.chain == "base-sepolia"

      assert {:ok, %{intent: intent_on}} = submit_intent(ws_on.id, "base-sepolia")
      assert intent_on.chain == "base-sepolia"
    end
  end

  describe "decision pipeline gate (execute)" do
    test "create_execution_plan refuses mainnet on workspace without mainnet_enabled" do
      ws = workspace_with_flag(false)

      # Build a decision envelope on a mainnet chain WITHOUT going
      # through `Intents.submit/2` (so we hit the decision-pipeline
      # gate, not the submit gate). Direct fixture insertion.
      intent = agent_intent(workspace_id: ws.id, chain: "base", state: :decided)
      envelope = decision_envelope(intent: intent, current: true, outcome: :auto_exec)

      # Grant a delegation so the only failing gate is the new
      # mainnet one — otherwise `:delegation_not_active` would
      # short-circuit first.
      {:ok, _} =
        Delegations.grant("sa-mainnet-exec-deny", "del-mainnet-exec-deny", %{workspace_id: ws.id})

      assert {:error, :mainnet_disabled} =
               Decisions.request_manual_execution(envelope.id, "sa-mainnet-exec-deny")

      # No execution plan was written for this decision.
      assert Repo.aggregate(ExecutionPlan, :count) == 0
    end

    test "create_execution_plan succeeds when mainnet is explicitly enabled" do
      ws = workspace_with_flag(true)
      intent = agent_intent(workspace_id: ws.id, chain: "base", state: :decided)
      envelope = decision_envelope(intent: intent, current: true, outcome: :auto_exec)

      {:ok, _} =
        Delegations.grant("sa-mainnet-exec-allow", "del-mainnet-exec-allow", %{
          workspace_id: ws.id
        })

      assert {:ok, plan} =
               Decisions.request_manual_execution(envelope.id, "sa-mainnet-exec-allow")

      assert plan.chain == "base"
      assert plan.workspace_id == ws.id
    end
  end

  describe "dispatch worker gate" do
    test "RunExecution aborts the plan with :mainnet_disabled if workspace flag flips off" do
      # Build a workspace + delegation + plan with mainnet_enabled=true,
      # then flip the flag off before the worker runs. The
      # defense-in-depth gate inside the worker must catch it and
      # cancel without calling AdapterClient.
      ws = workspace_with_flag(true)
      intent = agent_intent(workspace_id: ws.id, chain: "base", state: :decided)
      envelope = decision_envelope(intent: intent, current: true, outcome: :auto_exec)

      {:ok, _} =
        Delegations.grant("sa-mainnet-dispatch", "del-mainnet-dispatch", %{workspace_id: ws.id})

      {:ok, plan} =
        Decisions.request_manual_execution(envelope.id, "sa-mainnet-dispatch")

      # Race-flip the workspace flag to off after the plan is
      # written. The worker's `verify_mainnet_allowed/1` should now
      # abort the plan rather than dispatch it.
      {:ok, _} = Workspaces.set_mainnet_enabled(ws, false)

      # If RunExecution were to proceed, it would call
      # `Bank.AdapterClient.dispatch_transfer/1`. We pin "no chain
      # HTTP" by installing a stub that pings parent on call, then
      # asserting it never fires.
      parent = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        send(parent, :adapter_was_called)
        Req.Test.json(conn, %{accepted: true})
      end)

      assert {:cancel, :mainnet_disabled} =
               RunExecution.perform(%Oban.Job{args: %{"decision_id" => envelope.id}})

      refute_receive :adapter_was_called, 50

      # Plan is now :aborted with the documented reason.
      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :aborted
      assert reloaded.final_reason == "mainnet_disabled"
    end
  end

  describe "revoke gate (synchronous + worker defense-in-depth)" do
    test "Security.revoke_delegation refuses mainnet on workspace without mainnet_enabled" do
      ws = workspace_with_flag(false)

      {:ok, _} =
        Delegations.grant("sa-revoke-deny", "del-revoke-deny", %{
          workspace_id: ws.id,
          chain: "base"
        })

      assert {:error, :mainnet_disabled} = Security.revoke_delegation("sa-revoke-deny")
    end

    test "Security.revoke_delegation succeeds when mainnet is explicitly enabled" do
      ws = workspace_with_flag(true)

      {:ok, _} =
        Delegations.grant("sa-revoke-allow", "del-revoke-allow", %{
          workspace_id: ws.id,
          chain: "base"
        })

      assert {:ok, %Oban.Job{}} = Security.revoke_delegation("sa-revoke-allow")
    end

    test "RevokeDelegation worker cancels with :mainnet_disabled if flag flips off post-enqueue" do
      ws = workspace_with_flag(true)

      {:ok, _} =
        Delegations.grant("sa-revoke-race", "del-revoke-race", %{
          workspace_id: ws.id,
          chain: "base"
        })

      {:ok, _job} = Security.revoke_delegation("sa-revoke-race")

      # Flip mainnet off between enqueue and worker run.
      {:ok, _} = Workspaces.set_mainnet_enabled(ws, false)

      parent = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        send(parent, :adapter_was_called)
        Req.Test.json(conn, %{accepted: true})
      end)

      assert {:cancel, :mainnet_disabled} =
               RevokeDelegation.perform(%Oban.Job{
                 args: %{"smart_account_id" => "sa-revoke-race", "reason" => "operator_requested"}
               })

      refute_receive :adapter_was_called, 50
    end

    test "Security.revoke_delegation allows testnet revoke even when flag is off" do
      ws = workspace_with_flag(false)

      {:ok, _} =
        Delegations.grant("sa-revoke-testnet", "del-revoke-testnet", %{
          workspace_id: ws.id,
          chain: "base-sepolia"
        })

      assert {:ok, %Oban.Job{}} = Security.revoke_delegation("sa-revoke-testnet")
    end
  end

  describe "Bank.Chains contract" do
    test "validate_mainnet_allowed/2 returns :ok for testnet chains regardless of flag" do
      ws_off = workspace_with_flag(false)
      assert :ok = Chains.validate_mainnet_allowed("base-sepolia", ws_off.id)
    end

    test "validate_mainnet_allowed/2 fails closed for mainnet chain + workspace_id with flag off" do
      ws_off = workspace_with_flag(false)

      assert {:error, :mainnet_disabled} =
               Chains.validate_mainnet_allowed("base", ws_off.id)
    end

    test "validate_mainnet_allowed/2 returns :ok when flag is flipped on" do
      ws_on = workspace_with_flag(true)
      assert :ok = Chains.validate_mainnet_allowed("base", ws_on.id)
    end
  end
end
