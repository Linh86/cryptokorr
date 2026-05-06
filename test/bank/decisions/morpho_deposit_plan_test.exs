defmodule Bank.Decisions.MorphoDepositPlanTest do
  @moduledoc """
  Coverage for `Bank.Decisions.create_execution_plan/4` extension
  for `:defi_yield_deposit` (#206).

  Verifies that an operator approval over a Morpho intent (a
  successor `:auto_exec` envelope) materialises an `ExecutionPlan`
  whose:

    * `chain` / `asset` come from the intent (Base Sepolia / USDC),
    * `:steps` payload is the canonical Morpho deposit shape with
      vault address, snapshot identity, receiver, policy rule ids,
      and the operator-approval actor pinned,
    * audit `execution.manually_requested` `after_ref` carries the
      Morpho metadata (vault address, snapshot id, snapshot
      payload hash) so replay can attribute the dispatch.

  Pre-dispatch safety gate (snapshot freshness, material drift,
  vault allowlist) lives in
  `Bank.Decisions.MorphoDispatchSafety` and runs at dispatch time
  in `Bank.Runtime.Workers.RunExecution`. Plan creation packages
  the artifacts; the gate is the source of truth at broadcast.
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Bank.Fixtures
  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions
  alias Bank.Delegations
  alias Bank.Security.PauseState

  setup do
    PauseState.reset()
    on_exit(fn -> PauseState.reset() end)
    :ok
  end

  defp morpho_envelope_with_delegation do
    intent = morpho_deposit_intent()
    snapshot = morpho_vault_snapshot()
    {:ok, _del} = Delegations.grant("sa_morpho", "del_morpho")

    envelope =
      decision_envelope(
        intent: intent,
        outcome: :auto_exec,
        current: true,
        policy_snapshot_ref: %{"rule_ids" => ["rule-uuid-aaa", "rule-uuid-bbb"]}
      )

    {envelope, intent, snapshot}
  end

  describe "request_manual_execution/3 — :defi_yield_deposit" do
    test "creates a Morpho deposit plan with chain/asset from the intent and morpho_deposit steps" do
      {envelope, intent, snapshot} = morpho_envelope_with_delegation()

      assert {:ok, plan} = Decisions.request_manual_execution(envelope.id, "sa_morpho")

      assert plan.intent_id == intent.id
      assert plan.decision_id == envelope.id
      assert plan.chain == "base-sepolia"
      assert plan.asset == "USDC"
      assert plan.execution_status == :prepared
      assert plan.smart_account_id == "sa_morpho"

      assert plan.steps["kind"] == "morpho_deposit"
      assert plan.steps["vault_address"] == intent.target_raw_address
      assert plan.steps["chain_id"] == 84_532
      assert plan.steps["asset"] == "USDC"
      assert plan.steps["receiver"] == "sa_morpho"
      assert plan.steps["snapshot_id"] == snapshot.id
      assert plan.steps["snapshot_payload_hash"] == snapshot.payload_hash
      assert is_binary(plan.steps["snapshot_fetched_at"])
      assert plan.steps["policy_rule_ids"] == ["rule-uuid-aaa", "rule-uuid-bbb"]
      assert plan.steps["decision_id"] == envelope.id
      assert plan.steps["approval_actor"] == "user"
    end

    test "audit event after_ref carries morpho metadata for replay" do
      {envelope, _intent, snapshot} = morpho_envelope_with_delegation()

      assert {:ok, plan} = Decisions.request_manual_execution(envelope.id, "sa_morpho")

      event =
        Repo.one!(
          from(e in AuditEvent,
            where:
              e.subject_id == ^plan.id and
                e.event_type == "execution.manually_requested"
          )
        )

      assert event.after_ref["morpho_vault_address"] == plan.steps["vault_address"]
      assert event.after_ref["morpho_snapshot_id"] == snapshot.id
      assert event.after_ref["morpho_snapshot_payload_hash"] == snapshot.payload_hash
      # Existing fields preserved.
      assert event.after_ref["smart_account_id"] == "sa_morpho"
      assert event.after_ref["execution_status"] == "prepared"
    end

    test "tolerates a missing snapshot at plan creation (snapshot_id is nil; gate fails closed at dispatch)" do
      # Intent points at a vault with no current snapshot. Plan
      # creation still succeeds — the dispatch gate is the
      # gatekeeper, not plan creation.
      intent =
        morpho_deposit_intent(target_raw_address: "0xfade000000000000000000000000000000000099")

      {:ok, _del} = Delegations.grant("sa_no_snap", "del_no_snap")

      envelope =
        decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      assert {:ok, plan} = Decisions.request_manual_execution(envelope.id, "sa_no_snap")

      assert plan.steps["snapshot_id"] == nil
      assert plan.steps["snapshot_payload_hash"] == nil
      assert plan.steps["vault_address"] == "0xfade000000000000000000000000000000000099"
    end

    test "transfer plan creation is unaffected (no morpho_deposit steps leak)" do
      envelope = decision_envelope(outcome: :auto_exec, current: true)
      {:ok, _del} = Delegations.grant("sa_transfer", "del_transfer")

      assert {:ok, plan} = Decisions.request_manual_execution(envelope.id, "sa_transfer")

      assert plan.chain == "base"
      assert plan.asset == "USDC"
      # Default empty-items shape, NOT a morpho_deposit shape.
      refute plan.steps["kind"] == "morpho_deposit"
      refute Map.has_key?(plan.steps, "vault_address")
    end
  end
end
