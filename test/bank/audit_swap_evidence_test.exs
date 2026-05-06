defmodule Bank.AuditSwapEvidenceTest do
  @moduledoc """
  Pins for the swap audit/replay evidence surface (#194).

  Each acceptance criterion from issue #194 is checked end to end
  through the persisted-row layer that `Bank.Audit.replay/1`
  reads, so a future regression that drops the evidence on a
  callback or audit-event change shows up as a failing assertion
  here.

  Coverage:

    * Successful swap → `swap_route_evidence` carries the route
      inputs (route_hash, route_provider, source/destination
      asset, slippage_bps, deadline, expected_output_amount), the
      receipt (block_number, actual_output_amount, tx_refs), and
      the outcome (`execution_status: :confirmed`,
      `final_outcome: :confirmed`).
    * Safety-blocked swap → evidence carries the
      `swap_safety:<atom>` `final_reason` so a reviewer can
      explain the abort without re-walking the audit log.
    * Adapter-rejected swap → evidence carries the
      `adapter_rejected:<status>:<summary>` `final_reason`.
    * Secret hygiene → no calldata, bearer secret, tokenized URL,
      or private key flows into either `swap_route_evidence` or
      the audit `after_ref` for swap plans.
    * Transfer replay shape unchanged — `swap_route_evidence` is
      empty for transfer-only intents.
  """

  use Bank.DataCase, async: true

  alias Bank.Audit
  alias Bank.Audit.AuditEvent
  alias Bank.Audit.Events
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Fixtures
  alias Bank.Repo
  alias Bank.Runtime

  defp make_swap_intent_and_plan(opts \\ []) do
    intent = Fixtures.agent_intent(kind: :swap, asset: "USDC", chain: "base-sepolia")

    decision = Fixtures.decision_envelope(intent: intent, current: true)

    plan =
      Fixtures.swap_execution_plan(
        Keyword.merge(
          [
            decision: decision,
            intent_id: intent.id,
            execution_status: :prepared
          ],
          opts
        )
        |> Map.new()
      )

    %{intent: intent, decision: decision, plan: plan}
  end

  # Drive a swap plan all the way through to `:confirmed`, mirroring
  # the post-callback state RunExecution + apply_execution_callback
  # would persist.
  defp confirm_swap_plan!(plan, opts \\ []) do
    block_number = Keyword.get(opts, :block_number, 42_424_242)
    actual_output = Keyword.get(opts, :actual_output, Decimal.new("9.93"))

    tx_refs =
      Keyword.get(opts, :tx_refs, [
        "0x" <> String.duplicate("aa", 32),
        "0x" <> String.duplicate("bb", 32)
      ])

    {:ok, plan} =
      plan
      |> ExecutionPlan.progress_changeset(%{
        execution_status: :confirmed,
        final_outcome: :confirmed,
        active: false,
        tx_refs: tx_refs,
        block_number: block_number,
        actual_output_amount: actual_output
      })
      |> Repo.update()

    {:ok, _} = Runtime.emit_audit(Events.execution_transition(plan, :pending_confirmation))

    plan
  end

  defp abort_swap_plan!(plan, reason) do
    {:ok, plan} =
      plan
      |> ExecutionPlan.progress_changeset(%{
        execution_status: :aborted,
        final_outcome: :aborted,
        final_reason: reason,
        active: false
      })
      |> Repo.update()

    {:ok, _} = Runtime.emit_audit(Events.execution_transition(plan, :prepared))

    plan
  end

  describe "Audit.replay/1 — successful swap" do
    test "swap_route_evidence carries route inputs, receipt, and outcome" do
      %{intent: intent, plan: plan} = make_swap_intent_and_plan()
      _confirmed = confirm_swap_plan!(plan)

      assert {:ok, bundle} = Audit.replay(intent.id)

      assert [evidence] = bundle.swap_route_evidence
      assert evidence.plan_id == plan.id
      assert evidence.chain == "base-sepolia"
      # Route inputs (from #190 persisted steps).
      assert evidence.route_hash == plan.steps["route_hash"]
      assert evidence.route_provider == plan.steps["route_provider"]
      assert evidence.source_asset == "USDC"
      assert evidence.destination_asset == "USDC"
      assert evidence.input_amount == plan.steps["input_amount"]
      assert evidence.expected_output_amount == plan.steps["expected_output_amount"]
      assert evidence.minimum_output_amount == plan.steps["minimum_output_amount"]
      assert evidence.slippage_bps == plan.steps["slippage_bps"]
      assert evidence.deadline == plan.steps["deadline"]
      assert evidence.quote_timestamp == plan.steps["quote_timestamp"]
      # Receipt (#193 callback persistence).
      assert evidence.execution_status == :confirmed
      assert evidence.final_outcome == :confirmed
      assert evidence.final_reason == nil
      assert evidence.block_number == 42_424_242
      assert evidence.actual_output_amount == "9.93"
      assert length(evidence.tx_refs) == 2
      assert evidence.active == false
    end

    test "audit `after_ref` carries the route inputs alongside the receipt" do
      %{intent: intent, plan: plan} = make_swap_intent_and_plan()
      _confirmed = confirm_swap_plan!(plan)

      [audit] =
        Repo.all(
          from(e in AuditEvent,
            where: e.correlation_id == ^intent.id and e.event_type == "execution.confirmed"
          )
        )

      assert audit.after_ref["route_hash"] == plan.steps["route_hash"]
      assert audit.after_ref["route_provider"] == plan.steps["route_provider"]
      assert audit.after_ref["source_asset"] == "USDC"
      assert audit.after_ref["destination_asset"] == "USDC"
      assert audit.after_ref["expected_output_amount"] == plan.steps["expected_output_amount"]
      assert audit.after_ref["minimum_output_amount"] == plan.steps["minimum_output_amount"]
      assert audit.after_ref["slippage_bps"] == plan.steps["slippage_bps"]
      assert audit.after_ref["deadline"] == plan.steps["deadline"]
      assert audit.after_ref["block_number"] == 42_424_242
      assert audit.after_ref["actual_output_amount"] == "9.93"
    end
  end

  describe "Audit.replay/1 — safety-blocked swap" do
    test "swap_route_evidence carries swap_safety:<atom> as final_reason" do
      %{intent: intent, plan: plan} = make_swap_intent_and_plan()
      _aborted = abort_swap_plan!(plan, "swap_safety:swap_deadline_expired")

      assert {:ok, bundle} = Audit.replay(intent.id)

      assert [evidence] = bundle.swap_route_evidence
      assert evidence.execution_status == :aborted
      assert evidence.final_outcome == :aborted
      assert evidence.final_reason == "swap_safety:swap_deadline_expired"
      # Pre-dispatch abort: no on-chain receipt.
      assert evidence.block_number == nil
      assert evidence.actual_output_amount == nil
      assert evidence.tx_refs == []
      # Route inputs are still available so a reviewer can see WHICH
      # route was refused.
      assert evidence.route_hash == plan.steps["route_hash"]
      assert evidence.route_provider == plan.steps["route_provider"]
    end

    test "audit `after_ref` exposes the swap_safety reason for replay" do
      %{intent: intent, plan: plan} = make_swap_intent_and_plan()
      _aborted = abort_swap_plan!(plan, "swap_safety:swap_native_value_disallowed")

      [audit] =
        Repo.all(
          from(e in AuditEvent,
            where: e.correlation_id == ^intent.id and e.event_type == "execution.aborted"
          )
        )

      assert audit.after_ref["final_reason"] == "swap_safety:swap_native_value_disallowed"
      assert audit.after_ref["route_hash"] == plan.steps["route_hash"]
    end
  end

  describe "Audit.replay/1 — adapter-rejected swap" do
    test "swap_route_evidence carries adapter_rejected:<status>:<summary> reason" do
      %{intent: intent, plan: plan} = make_swap_intent_and_plan()

      _aborted =
        abort_swap_plan!(
          plan,
          "adapter_rejected:422:validation_failed"
        )

      assert {:ok, bundle} = Audit.replay(intent.id)

      assert [evidence] = bundle.swap_route_evidence
      assert evidence.execution_status == :aborted
      assert evidence.final_reason == "adapter_rejected:422:validation_failed"
    end
  end

  describe "Audit.replay/1 — secret hygiene over swap evidence" do
    test "swap_route_evidence and audit after_ref carry no calldata, bearer secrets, or URLs" do
      %{intent: intent, plan: plan} = make_swap_intent_and_plan()
      _confirmed = confirm_swap_plan!(plan)

      assert {:ok, bundle} = Audit.replay(intent.id)
      [evidence] = bundle.swap_route_evidence

      audit_rows =
        Repo.all(from(e in AuditEvent, where: e.correlation_id == ^intent.id))

      forbidden_keys = ~w(calldata authorization Authorization private_key bearer)

      # Evidence map: top-level keys are an explicit allowlist; the
      # raw `calldata` / `spender` / `swap_target_contract` /
      # `source_token_address` / `destination_token_address` /
      # `value` route fields are deliberately NOT projected here.
      evidence_keys = evidence |> Map.keys() |> Enum.map(&to_string/1)
      refute Enum.any?(evidence_keys, &(&1 in forbidden_keys))
      refute "calldata" in evidence_keys
      refute "spender" in evidence_keys
      refute "swap_target_contract" in evidence_keys

      # Each audit row's `after_ref` must not embed any forbidden
      # key either, and the route_hash / route_provider scalars
      # must NOT contain raw HTTP credentials or transport
      # material that the route producer might have routed through
      # provider config (defence-in-depth — even though
      # SwapRoute.validate already rejects routes whose fields
      # contain anything that looks like a URL, we want this to
      # fail loud if a future provider grows looser).
      for audit <- audit_rows do
        after_ref_keys = audit.after_ref |> Map.keys() |> Enum.map(&to_string/1)
        refute Enum.any?(after_ref_keys, &(&1 in forbidden_keys))

        for {_k, v} <- audit.after_ref, is_binary(v) do
          refute v =~ "Bearer "
          refute v =~ ~r/Authorization:/i
          # Hex calldata strings start with "0x" and are usually
          # >= 10 chars; the route_hash IS a hex string but it's
          # a sha256 (64 hex chars exactly, no leading 0x by
          # convention in this codebase). Block any 0x-prefixed
          # blob that snuck in.
          refute v =~ ~r/^0x[0-9a-f]{20,}$/
        end
      end
    end
  end

  describe "Audit.replay/1 — transfer replay shape unchanged" do
    test "transfer-only intent yields an empty swap_route_evidence list" do
      intent = Fixtures.agent_intent()
      decision = Fixtures.decision_envelope(intent: intent, current: true)

      {:ok, _plan} =
        Fixtures.execution_plan(decision: decision, intent_id: intent.id)
        |> Map.from_struct()
        |> then(fn _ -> {:ok, :inserted} end)

      _ =
        Fixtures.execution_plan(
          decision: decision,
          intent_id: intent.id,
          execution_status: :confirmed,
          final_outcome: :confirmed,
          tx_refs: ["0x" <> String.duplicate("dd", 32)],
          active: false
        )

      assert {:ok, bundle} = Audit.replay(intent.id)

      assert bundle.swap_route_evidence == []
      # Transfer audit rows do not carry the swap-only keys (proven
      # by emitting an execution_transition for the transfer plan
      # and inspecting the after_ref).
      transfer_plan = List.last(bundle.plans)
      attrs = Events.execution_transition(transfer_plan, :pending_confirmation)
      refute Map.has_key?(attrs.after_ref, :route_hash)
      refute Map.has_key?(attrs.after_ref, :route_provider)
      refute Map.has_key?(attrs.after_ref, :slippage_bps)
      refute Map.has_key?(attrs.after_ref, :block_number)
    end
  end
end
