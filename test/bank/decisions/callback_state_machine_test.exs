defmodule Bank.Decisions.CallbackStateMachineTest do
  @moduledoc """
  Per-kind prior-state whitelist on `apply_execution_callback/1`
  (audit C2).

  The terminal-state lock in `apply_execution_callback/1` only
  rejects callbacks against rows that have already finalised. It
  does not stop a callback from skipping lifecycle stages — e.g.
  `kind: "execution.confirmed"` against a `:prepared` plan would
  pre-fix mark the plan succeeded without the row ever being in
  `:broadcasting` / `:pending_confirmation`. With a leaked
  `ADAPTER_CALLBACK_SECRET` that is a critical attack: a forged
  callback skips the entire on-chain lifecycle.

  The whitelist enforced here is:

    * `execution.broadcast`  ← `:signing`
    * `execution.confirmed`  ← `:broadcasting` | `:pending_confirmation`
    * `execution.reverted`   ← `:broadcasting` | `:pending_confirmation`
    * `execution.aborted`    ← `:prepared` | `:signing`

  Anything outside the whitelist is rejected with
  `{:error, {:illegal_transition, kind, current_status}}` and an
  audit row of category `execution.callback_rejected_illegal_transition`
  is emitted carrying the plan id, the attempted kind, and the
  observed current status — the forensic signal an operator
  needs to detect a leaked-secret abuse pattern.
  """

  use Bank.DataCase, async: false

  import Ecto.Query
  import Bank.Fixtures

  alias Bank.Decisions
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Intents.AgentIntent

  # --- Illegal transitions: must be rejected -------------------------------

  describe "apply_execution_callback/1 rejects illegal prior-state transitions" do
    test "execution.broadcast against a :prepared plan is rejected" do
      plan = build_plan(execution_status: :prepared)

      assert {:error, {:illegal_transition, "execution.broadcast", :prepared}} =
               Decisions.apply_execution_callback(%{
                 "kind" => "execution.broadcast",
                 "execution_plan_id" => plan.id
               })

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :prepared
      assert reloaded.final_outcome == nil

      assert audit_count(plan.id, "execution.callback_rejected_illegal_transition") == 1
      audit = audit_row(plan.id, "execution.callback_rejected_illegal_transition")
      assert audit.after_ref["attempted_kind"] == "execution.broadcast"
      assert audit.after_ref["current_status"] == "prepared"
      assert audit.subject_id == plan.id
    end

    test "execution.confirmed against a :prepared plan is rejected" do
      plan = build_plan(execution_status: :prepared)

      assert {:error, {:illegal_transition, "execution.confirmed", :prepared}} =
               Decisions.apply_execution_callback(%{
                 "kind" => "execution.confirmed",
                 "execution_plan_id" => plan.id,
                 "tx_hashes" => ["0xfake"]
               })

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :prepared
      assert reloaded.final_outcome == nil

      assert audit_count(plan.id, "execution.callback_rejected_illegal_transition") == 1
    end

    test "execution.confirmed against a :signing plan is rejected" do
      plan = build_plan(execution_status: :signing)

      assert {:error, {:illegal_transition, "execution.confirmed", :signing}} =
               Decisions.apply_execution_callback(%{
                 "kind" => "execution.confirmed",
                 "execution_plan_id" => plan.id
               })

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :signing
      assert reloaded.final_outcome == nil

      assert audit_count(plan.id, "execution.callback_rejected_illegal_transition") == 1
    end

    test "execution.reverted against a :prepared plan is rejected" do
      plan = build_plan(execution_status: :prepared)

      assert {:error, {:illegal_transition, "execution.reverted", :prepared}} =
               Decisions.apply_execution_callback(%{
                 "kind" => "execution.reverted",
                 "execution_plan_id" => plan.id,
                 "reason" => "chain_revert"
               })

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :prepared

      assert audit_count(plan.id, "execution.callback_rejected_illegal_transition") == 1
    end

    test "execution.aborted against a :broadcasting plan is rejected" do
      plan = build_plan(execution_status: :broadcasting)

      assert {:error, {:illegal_transition, "execution.aborted", :broadcasting}} =
               Decisions.apply_execution_callback(%{
                 "kind" => "execution.aborted",
                 "execution_plan_id" => plan.id,
                 "reason" => "stuck"
               })

      reloaded = Repo.get!(ExecutionPlan, plan.id)
      assert reloaded.execution_status == :broadcasting

      assert audit_count(plan.id, "execution.callback_rejected_illegal_transition") == 1
    end

    test "intent state is not advanced on a rejected callback" do
      # Forensic tail: a forged execution.confirmed against a
      # :prepared plan must NOT push the owning intent to
      # :executed. The whole point of the guard is that a leaked
      # secret cannot fast-forward state.
      intent = agent_intent(state: :decided)
      envelope = decision_envelope(intent: intent)
      plan = execution_plan(decision: envelope, execution_status: :prepared)

      assert {:error, {:illegal_transition, _, _}} =
               Decisions.apply_execution_callback(%{
                 "kind" => "execution.confirmed",
                 "execution_plan_id" => plan.id
               })

      assert %AgentIntent{state: :decided} = Repo.get!(AgentIntent, intent.id)
    end
  end

  # --- Legitimate transitions: must still pass -----------------------------

  describe "apply_execution_callback/1 accepts whitelisted prior-state transitions" do
    test "execution.broadcast from :signing succeeds" do
      plan = build_plan(execution_status: :signing)

      assert {:ok, %{plan: updated}} =
               Decisions.apply_execution_callback(%{
                 "kind" => "execution.broadcast",
                 "execution_plan_id" => plan.id
               })

      assert updated.execution_status == :broadcasting
      assert audit_count(plan.id, "execution.callback_rejected_illegal_transition") == 0
    end

    test "execution.confirmed from :broadcasting succeeds" do
      plan = build_plan(execution_status: :broadcasting)

      assert {:ok, %{plan: updated}} =
               Decisions.apply_execution_callback(%{
                 "kind" => "execution.confirmed",
                 "execution_plan_id" => plan.id
               })

      assert updated.execution_status == :confirmed
      assert updated.final_outcome == :confirmed
    end

    test "execution.confirmed from :pending_confirmation succeeds" do
      plan = build_plan(execution_status: :pending_confirmation)

      assert {:ok, %{plan: updated}} =
               Decisions.apply_execution_callback(%{
                 "kind" => "execution.confirmed",
                 "execution_plan_id" => plan.id
               })

      assert updated.execution_status == :confirmed
      assert updated.final_outcome == :confirmed
    end

    test "execution.reverted from :broadcasting succeeds" do
      plan = build_plan(execution_status: :broadcasting)

      assert {:ok, %{plan: updated}} =
               Decisions.apply_execution_callback(%{
                 "kind" => "execution.reverted",
                 "execution_plan_id" => plan.id,
                 "reason" => "chain_revert:out_of_gas"
               })

      assert updated.execution_status == :reverted
      assert updated.final_outcome == :reverted
    end

    test "execution.aborted from :prepared succeeds" do
      plan = build_plan(execution_status: :prepared)

      assert {:ok, %{plan: updated}} =
               Decisions.apply_execution_callback(%{
                 "kind" => "execution.aborted",
                 "execution_plan_id" => plan.id,
                 "reason" => "adapter_aborted:dropped"
               })

      assert updated.execution_status == :aborted
      assert updated.final_outcome == :aborted
    end

    test "execution.aborted from :signing succeeds" do
      plan = build_plan(execution_status: :signing)

      assert {:ok, %{plan: updated}} =
               Decisions.apply_execution_callback(%{
                 "kind" => "execution.aborted",
                 "execution_plan_id" => plan.id,
                 "reason" => "adapter_rejected_signing"
               })

      assert updated.execution_status == :aborted
      assert updated.final_outcome == :aborted
    end
  end

  # --- Helpers -------------------------------------------------------------

  defp build_plan(attrs) do
    intent = agent_intent(state: :executing)
    envelope = decision_envelope(intent: intent)
    execution_plan(Map.merge(%{decision: envelope, active: true}, Map.new(attrs)))
  end

  defp audit_count(plan_id, event_type) do
    Repo.aggregate(
      from(e in Bank.Audit.AuditEvent,
        where: e.event_type == ^event_type and e.subject_id == ^plan_id
      ),
      :count
    )
  end

  defp audit_row(plan_id, event_type) do
    Repo.one!(
      from e in Bank.Audit.AuditEvent,
        where: e.event_type == ^event_type and e.subject_id == ^plan_id,
        order_by: [desc: e.inserted_at],
        limit: 1
    )
  end
end
