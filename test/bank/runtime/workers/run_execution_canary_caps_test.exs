defmodule Bank.Runtime.Workers.RunExecutionCanaryCapsTest do
  @moduledoc """
  Defense-in-depth integration test for the canary cap gate
  (#181) inside `Bank.Runtime.Workers.RunExecution`.

  The unit-level cases for `Bank.Chains.CanaryCaps.validate/4` live
  in `test/bank/chains/canary_caps_test.exs`. This file proves the
  end-to-end wiring: a plan whose `(chain, asset, amount)` violates
  the active cap is aborted by the worker before any
  `Bank.AdapterClient` call leaves the test process.

  Posture: mirrors `Bank.MainnetGateTest`'s "dispatch worker gate"
  describe block — install a `Req.Test.stub` on `Bank.AdapterClient`
  that pings parent on every call, then `refute_receive
  :adapter_was_called`.
  """

  use Bank.DataCase, async: false

  alias Bank.Decisions
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Delegations
  alias Bank.Repo
  alias Bank.Runtime.Workers.RunExecution
  alias Bank.Security.PauseState
  alias Bank.Workspaces

  import Bank.Fixtures

  setup do
    # `Bank.Security.PauseState` is a process-global GenServer; a
    # prior test in the suite ordering may have left the runtime
    # paused, which would short-circuit this test's
    # `Decisions.request_manual_execution/2` at `validate_not_paused/2`.
    # Mirror `run_execution_test.exs`'s setup pattern.
    PauseState.reset()

    # Defensive verification: assert the GenServer actually came
    # back unpaused. If a concurrent `async: true` test races a
    # pause in between reset and the test body, surface it here as
    # a clear setup failure instead of a confusing
    # `:runtime_paused` cancel inside the worker.
    refute Bank.Security.paused?(:global), "global pause leaked into setup"

    :ok
  end

  defp mainnet_workspace do
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Workspaces.create_workspace(%{
        slug: "canary-caps-#{suffix}",
        name: "Canary caps #{suffix}",
        mainnet_enabled: true
      })

    ws
  end

  defp build_executable_plan(workspace_id, amount, opts \\ []) do
    suffix = System.unique_integer([:positive])
    smart_account_id = Keyword.get(opts, :smart_account_id, "sa-canary-#{suffix}")
    delegation_id = "del-canary-#{suffix}"

    cp = counterparty(workspace_id: workspace_id)

    hex = suffix |> Integer.to_string(16) |> String.pad_leading(40, "0")

    _ =
      address_label(
        counterparty: cp,
        chain: "base",
        address: "0x" <> hex
      )

    intent =
      agent_intent(
        workspace_id: workspace_id,
        counterparty: cp,
        chain: "base",
        asset: "USDC",
        amount: amount,
        state: :decided
      )

    envelope = decision_envelope(intent: intent, current: true, outcome: :auto_exec)

    {:ok, _} = Delegations.grant(smart_account_id, delegation_id, %{workspace_id: workspace_id})

    {:ok, plan} = Decisions.request_manual_execution(envelope.id, smart_account_id)

    %{envelope: envelope, plan: plan, intent: intent}
  end

  defp put_caps_env(overrides) when is_list(overrides) do
    prior = Application.get_env(:bank, Bank.Chains.CanaryCaps, [])

    Application.put_env(
      :bank,
      Bank.Chains.CanaryCaps,
      Keyword.merge(prior, overrides)
    )

    on_exit(fn ->
      Application.put_env(:bank, Bank.Chains.CanaryCaps, prior)
    end)
  end

  describe "verify_canary_caps/1 — :canary_amount_exceeded" do
    test "aborts the plan and never calls Bank.AdapterClient when amount > cap" do
      # Tight cap so the default fixture's $10.50 USDC trips it.
      put_caps_env(amount_caps: %{"USDC" => "1.00"})

      ws = mainnet_workspace()
      %{envelope: envelope, plan: plan} = build_executable_plan(ws.id, Decimal.new("5.00"))

      parent = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        send(parent, :adapter_was_called)
        Req.Test.json(conn, %{accepted: true})
      end)

      assert {:cancel, :canary_amount_exceeded} =
               RunExecution.perform(%Oban.Job{args: %{"decision_id" => envelope.id}})

      refute_receive :adapter_was_called, 50

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :aborted
      assert reloaded.final_outcome == :aborted
      assert reloaded.final_reason == "canary_amount_exceeded"
    end

    test "tx_refs stays empty on cap-aborted plans (no broadcast happened)" do
      # The runbook's "public artifacts" contract — tx_refs is the
      # canonical source for tx hashes — must remain empty when the
      # cap aborts the plan. This pins that no tx hash leaks into
      # the artifact path even on a cap-rejected plan.
      put_caps_env(amount_caps: %{"USDC" => "1.00"})

      ws = mainnet_workspace()
      %{envelope: envelope, plan: plan} = build_executable_plan(ws.id, Decimal.new("5.00"))

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.json(conn, %{accepted: true})
      end)

      _ = RunExecution.perform(%Oban.Job{args: %{"decision_id" => envelope.id}})

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.tx_refs == []
    end
  end

  describe "verify_canary_caps/1 — happy path through the cap" do
    test "plan within the cap proceeds to dispatch (gate is not a no-op)" do
      # Use the test-env default cap ($1M USDC). The fixture's
      # $5 plan is well under, so the cap clears and the worker
      # progresses to the adapter stub.
      ws = mainnet_workspace()
      %{envelope: envelope, plan: plan} = build_executable_plan(ws.id, Decimal.new("5.00"))

      parent = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        send(parent, :adapter_was_called)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          202,
          Jason.encode!(%{"accepted" => true, "execution_plan_id" => plan.id})
        )
      end)

      assert :ok = RunExecution.perform(%Oban.Job{args: %{"decision_id" => envelope.id}})

      assert_receive :adapter_was_called, 200
    end
  end

  describe "verify_canary_caps/1 — testnet bypass" do
    test "Base Sepolia plan with above-mainnet-cap amount still proceeds (gate only fires on mainnet chains)" do
      # Build the plan via direct insert because
      # `Decisions.request_manual_execution/3` hard-codes `chain:
      # "base"`. We're proving the cap module's testnet bypass
      # propagates through the worker, so we go around the helper.
      put_caps_env(amount_caps: %{"USDC" => "1.00"})

      ws = mainnet_workspace()

      cp = counterparty(workspace_id: ws.id)

      _ =
        address_label(
          counterparty: cp,
          chain: "base-sepolia",
          address:
            "0x" <>
              String.pad_leading(
                Integer.to_string(System.unique_integer([:positive]), 16),
                40,
                "0"
              )
        )

      intent =
        agent_intent(
          workspace_id: ws.id,
          counterparty: cp,
          chain: "base-sepolia",
          asset: "USDC",
          amount: Decimal.new("999.00"),
          state: :decided
        )

      envelope = decision_envelope(intent: intent, current: true, outcome: :auto_exec)

      smart_account_id = "sa-canary-testnet-#{System.unique_integer([:positive])}"
      {:ok, _} = Delegations.grant(smart_account_id, "del-canary-testnet", %{workspace_id: ws.id})

      # Insert a testnet plan directly. The chain="base-sepolia"
      # bypasses both `validate_mainnet_allowed/2` (testnet) and
      # `Bank.Chains.CanaryCaps.validate/4` (testnet bypass).
      {:ok, plan} =
        %ExecutionPlan{}
        |> ExecutionPlan.changeset(%{
          decision_id: envelope.id,
          intent_id: intent.id,
          chain: "base-sepolia",
          asset: "USDC",
          smart_account_id: smart_account_id,
          execution_status: :prepared,
          signing_requirements: %{},
          workspace_id: ws.id
        })
        |> Repo.insert()

      parent = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        send(parent, :adapter_was_called)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          202,
          Jason.encode!(%{"accepted" => true, "execution_plan_id" => plan.id})
        )
      end)

      assert :ok = RunExecution.perform(%Oban.Job{args: %{"decision_id" => envelope.id}})

      assert_receive :adapter_was_called, 200

      # The cap was NOT consulted on this testnet plan — confirm
      # the plan progressed past `:prepared`.
      reloaded = Repo.get!(ExecutionPlan, plan.id)

      assert reloaded.execution_status in [
               :signing,
               :broadcasting,
               :pending_confirmation,
               :confirmed
             ]
    end
  end
end
