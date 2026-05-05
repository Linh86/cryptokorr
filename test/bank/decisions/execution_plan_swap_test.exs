defmodule Bank.Decisions.ExecutionPlanSwapTest do
  @moduledoc """
  Coverage for #190: extending `Bank.Decisions` plan creation to
  produce swap execution plans from a validated swap route.

  Asserts that the route is validated through `Bank.Intents.SwapRoute`
  (the failure-atom vocabulary is single-sourced from #189), that the
  resulting plan persists normalised route artifacts and a
  deterministic `route_hash` in `:steps`, that `chain` and `asset`
  come from the route (not the transfer-default `"base"`/`"USDC"`),
  that the existing `(decision_id) WHERE active` partial unique
  index already blocks duplicate active swap plans, and that the
  `execution.manually_requested` / `execution.auto_dispatched` audit
  rows surface `route_hash` + `route_provider` in `after_ref` for
  replay.
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Bank.Fixtures
  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Decisions.SwapRouteArtifacts
  alias Bank.Delegations
  alias Bank.Security.PauseState

  setup do
    PauseState.reset()
    :ok
  end

  defp valid_route(overrides \\ %{}) do
    deadline =
      DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:microsecond)

    quote_ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Map.merge(
      %{
        source_asset: "USDC",
        destination_asset: "USDC",
        source_token_address: "0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
        destination_token_address: "0xBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
        input_amount: Decimal.new("100"),
        expected_output_amount: Decimal.new("99"),
        minimum_output_amount: Decimal.new("98"),
        spender: "0xCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC",
        swap_target_contract: "0xDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD",
        calldata: "0xdeadbeef",
        value: Decimal.new("0"),
        route_provider: "test_provider",
        quote_timestamp: quote_ts,
        deadline: deadline,
        chain: "base-sepolia",
        chain_id: 84_532,
        slippage_bps: 50
      },
      overrides
    )
  end

  defp swap_envelope do
    intent = agent_intent(kind: :swap, chain: "base-sepolia")
    decision_envelope(intent: intent, outcome: :auto_exec, current: true)
  end

  defp grant(prefix) do
    sa = "sa_#{prefix}_#{System.unique_integer([:positive])}"
    {:ok, _} = Delegations.grant(sa, "del_#{prefix}_#{System.unique_integer([:positive])}")
    sa
  end

  describe "request_manual_execution/3 — swap kind" do
    test "happy path: builds plan whose chain/asset come from the route" do
      envelope = swap_envelope()
      sa = grant("happy")

      assert {:ok, plan} =
               Decisions.request_manual_execution(envelope.id, sa, swap_route: valid_route())

      assert plan.decision_id == envelope.id
      assert plan.intent_id == envelope.intent_id
      assert plan.execution_status == :prepared
      assert plan.active == true
      assert plan.chain == "base-sepolia"
      # Asset comes from the route's destination side.
      assert plan.asset == "USDC"
    end

    test "happy path: persists normalised route artifacts on plan.steps" do
      envelope = swap_envelope()
      sa = grant("steps")
      route = valid_route()

      assert {:ok, plan} =
               Decisions.request_manual_execution(envelope.id, sa, swap_route: route)

      expected_hash = SwapRouteArtifacts.route_hash(route)

      assert plan.steps["kind"] == "swap"
      assert plan.steps["route_hash"] == expected_hash
      assert plan.steps["route_provider"] == "test_provider"
      assert plan.steps["chain"] == "base-sepolia"
      assert plan.steps["chain_id"] == 84_532
      assert plan.steps["source_asset"] == "USDC"
      assert plan.steps["destination_asset"] == "USDC"
      assert plan.steps["input_amount"] == "100"
      assert plan.steps["minimum_output_amount"] == "98"
      assert plan.steps["slippage_bps"] == 50
      assert is_binary(plan.steps["deadline"])
      assert is_binary(plan.steps["quote_timestamp"])
    end

    test "missing :swap_route opt is rejected before any plan is written" do
      envelope = swap_envelope()
      sa = grant("missing")

      assert {:error, :swap_route_missing} =
               Decisions.request_manual_execution(envelope.id, sa)

      refute Decisions.active_plan_for(envelope.id)
    end

    test "stale route (deadline in the past) is rejected with the validator's atom" do
      envelope = swap_envelope()
      sa = grant("stale")

      stale_deadline =
        DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:microsecond)

      route = valid_route(%{deadline: stale_deadline})

      assert {:error, :swap_deadline_expired} =
               Decisions.request_manual_execution(envelope.id, sa, swap_route: route)

      refute Decisions.active_plan_for(envelope.id)
    end

    test "unsupported chain is rejected with :swap_chain_not_supported" do
      envelope = swap_envelope()
      sa = grant("chain")
      route = valid_route(%{chain: "ethereum", chain_id: 1})

      assert {:error, :swap_chain_not_supported} =
               Decisions.request_manual_execution(envelope.id, sa, swap_route: route)

      refute Decisions.active_plan_for(envelope.id)
    end

    test "unsupported asset is rejected with :swap_asset_not_supported" do
      envelope = swap_envelope()
      sa = grant("asset")
      route = valid_route(%{source_asset: "ETH"})

      assert {:error, :swap_asset_not_supported} =
               Decisions.request_manual_execution(envelope.id, sa, swap_route: route)

      refute Decisions.active_plan_for(envelope.id)
    end

    test "incomplete route (missing required field) is rejected" do
      envelope = swap_envelope()
      sa = grant("incomplete")
      route = valid_route() |> Map.delete(:calldata)

      assert {:error, :swap_route_field_missing} =
               Decisions.request_manual_execution(envelope.id, sa, swap_route: route)

      refute Decisions.active_plan_for(envelope.id)
    end

    test "duplicate active swap plan for the same envelope is blocked" do
      envelope = swap_envelope()
      sa = grant("dup1")

      assert {:ok, _first} =
               Decisions.request_manual_execution(envelope.id, sa, swap_route: valid_route())

      sa2 = grant("dup2")

      assert {:error, :active_plan_exists} =
               Decisions.request_manual_execution(envelope.id, sa2, swap_route: valid_route())
    end

    test "preserves workspace_id stamping from the parent intent" do
      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "swap-stamp",
          name: "Swap stamp",
          mainnet_enabled: false
        })

      intent = agent_intent(kind: :swap, chain: "base-sepolia", workspace_id: ws.id)
      envelope = decision_envelope(intent: intent, outcome: :auto_exec, current: true)
      sa = grant("ws")

      assert {:ok, plan} =
               Decisions.request_manual_execution(envelope.id, sa, swap_route: valid_route())

      assert plan.workspace_id == ws.id
    end
  end

  describe "audit + replay surfaces" do
    test "execution.manually_requested after_ref carries route_hash and route_provider" do
      envelope = swap_envelope()
      sa = grant("audit")
      route = valid_route()
      expected_hash = SwapRouteArtifacts.route_hash(route)

      assert {:ok, plan} =
               Decisions.request_manual_execution(envelope.id, sa, swap_route: route)

      event =
        Repo.one!(
          from(e in AuditEvent,
            where: e.subject_id == ^plan.id and e.event_type == "execution.manually_requested"
          )
        )

      assert event.after_ref["route_hash"] == expected_hash
      assert event.after_ref["route_provider"] == "test_provider"
      # Existing fields remain.
      assert event.after_ref["smart_account_id"] == sa
      assert event.after_ref["execution_status"] == "prepared"
    end

    test "transfer plan audit row is unchanged (no route_metadata leakage)" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)
      sa = grant("transfer")

      assert {:ok, plan} = Decisions.request_manual_execution(envelope.id, sa)

      event =
        Repo.one!(
          from(e in AuditEvent,
            where: e.subject_id == ^plan.id and e.event_type == "execution.manually_requested"
          )
        )

      refute Map.has_key?(event.after_ref, "route_hash")
      refute Map.has_key?(event.after_ref, "route_provider")
    end
  end

  describe "schema invariants still apply for swap plans" do
    test "deactivating the first swap plan lets a second insert" do
      envelope = swap_envelope()
      sa = grant("deact1")

      assert {:ok, first} =
               Decisions.request_manual_execution(envelope.id, sa, swap_route: valid_route())

      {:ok, _} =
        first
        |> ExecutionPlan.deactivate()
        |> Repo.update()

      sa2 = grant("deact2")

      assert {:ok, second} =
               Decisions.request_manual_execution(envelope.id, sa2, swap_route: valid_route())

      assert second.id != first.id
      assert second.active
    end
  end
end
