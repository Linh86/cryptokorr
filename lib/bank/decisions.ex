defmodule Bank.Decisions do
  @moduledoc """
  Decisions bounded context.

  Owns the `DecisionEnvelope` lifecycle and the approval state machine
  that produces successor envelopes rather than editing them.

  The fixed v1 outcome vocabulary is `auto_exec`, `hold`,
  `approval_required`, `block`. The fixed v1 risk vocabulary is `low`,
  `moderate`, `elevated`, `severe`. Both are owned here to keep the
  decision surface small and explicit.

  ## Manual execution

  `request_manual_execution/3` is the operator path for triggering
  execution of a decided envelope. It requires:

    1. The envelope is current and outcome is `:auto_exec`
    2. No active execution plan already exists for this decision
    3. The runtime is not globally paused
    4. The smart account has an active delegation

  If all gates pass, an execution plan is created and enqueued. The
  plan references the delegation that was checked at the time of the
  request, so replay can verify the delegation was valid.
  """

  import Ecto.Query

  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Delegations
  alias Bank.Intents.AgentIntent
  alias Bank.Repo
  alias Bank.Runtime
  alias Bank.Security

  # --- Read API -----------------------------------------------------------

  @doc "Fetch a decision envelope by id."
  @spec get_envelope(String.t()) :: {:ok, DecisionEnvelope.t()} | {:error, :not_found}
  def get_envelope(id) when is_binary(id) do
    case Repo.get(DecisionEnvelope, id) do
      nil -> {:error, :not_found}
      envelope -> {:ok, envelope}
    end
  end

  @doc "Fetch a decision envelope with its execution plans preloaded."
  @spec get_envelope_with_plans(String.t()) :: {:ok, DecisionEnvelope.t()} | {:error, :not_found}
  def get_envelope_with_plans(id) when is_binary(id) do
    case Repo.get(DecisionEnvelope, id) |> Repo.preload(:execution_plans) do
      nil -> {:error, :not_found}
      envelope -> {:ok, envelope}
    end
  end

  @doc "Fetch the active execution plan for a decision, if any."
  @spec active_plan_for(String.t()) :: ExecutionPlan.t() | nil
  def active_plan_for(decision_id) do
    Repo.one(
      from(p in ExecutionPlan,
        where: p.decision_id == ^decision_id and p.active == true,
        limit: 1
      )
    )
  end

  @doc """
  List current decision envelopes with outcome `:approval_required`.

  Returns envelopes ordered by `decided_at` descending, preloaded with
  the parent intent. Used by the action queue to show pending approvals.
  """
  @spec list_pending_approvals() :: [DecisionEnvelope.t()]
  def list_pending_approvals do
    from(e in DecisionEnvelope,
      where: e.current == true and e.outcome == :approval_required,
      order_by: [desc: e.decided_at],
      preload: [:intent]
    )
    |> Repo.all()
  end

  @doc "Count of current envelopes awaiting approval."
  @spec count_pending_approvals() :: non_neg_integer()
  def count_pending_approvals do
    from(e in DecisionEnvelope,
      where: e.current == true and e.outcome == :approval_required,
      select: count(e.id)
    )
    |> Repo.one()
  end

  @doc """
  List recent current decision envelopes, most recent first.

  Accepts an optional `limit` (default 10). Preloads the parent intent
  for display in the dashboard.
  """
  @spec list_recent_decisions(pos_integer()) :: [DecisionEnvelope.t()]
  def list_recent_decisions(limit \\ 10) do
    from(e in DecisionEnvelope,
      where: e.current == true,
      order_by: [desc: e.decided_at],
      limit: ^limit,
      preload: [:intent]
    )
    |> Repo.all()
  end

  @doc """
  Count active (non-terminal) execution plans.

  Terminal statuses are `:confirmed`, `:reverted`, `:aborted`.
  """
  @spec count_active_executions() :: non_neg_integer()
  def count_active_executions do
    from(p in ExecutionPlan,
      where:
        p.active == true and
          p.execution_status not in [:confirmed, :reverted, :aborted],
      select: count(p.id)
    )
    |> Repo.one()
  end

  @doc """
  List active (non-terminal) execution plans, most recent first.

  Preloads the parent intent for display purposes.
  """
  @spec list_active_executions() :: [ExecutionPlan.t()]
  def list_active_executions do
    from(p in ExecutionPlan,
      where:
        p.active == true and
          p.execution_status not in [:confirmed, :reverted, :aborted],
      order_by: [desc: p.inserted_at],
      preload: [:intent]
    )
    |> Repo.all()
  end

  @doc """
  List current envelopes with outcome `:hold`, most recent first.
  Preloads the parent intent for the action queue held-items view.
  """
  @spec list_held_decisions() :: [DecisionEnvelope.t()]
  def list_held_decisions do
    from(e in DecisionEnvelope,
      where: e.current == true and e.outcome == :hold,
      order_by: [desc: e.decided_at],
      preload: [:intent]
    )
    |> Repo.all()
  end

  @doc """
  List current envelopes with outcome `:block`, most recent first.
  Preloads the parent intent for the action queue blocked-items view.
  """
  @spec list_blocked_decisions() :: [DecisionEnvelope.t()]
  def list_blocked_decisions(limit \\ 20) do
    from(e in DecisionEnvelope,
      where: e.current == true and e.outcome == :block,
      order_by: [desc: e.decided_at],
      limit: ^limit,
      preload: [:intent]
    )
    |> Repo.all()
  end

  # --- Manual execution ---------------------------------------------------

  @doc """
  Operator-triggered manual execution.

  Gates:
    1. Envelope must exist and be current with outcome `:auto_exec`
    2. No active execution plan already exists for this decision
    3. Runtime must not be globally paused
    4. Smart account delegation must be `:active`

  On success, creates an execution plan in `:prepared` state and
  enqueues it for execution via `Bank.Runtime.enqueue_execution/1`.

  Returns `{:ok, plan}` or `{:error, reason}`.
  """
  @spec request_manual_execution(String.t(), String.t(), keyword()) ::
          {:ok, ExecutionPlan.t()} | {:error, atom() | String.t()}
  def request_manual_execution(envelope_id, smart_account_id, opts \\ []) do
    with {:ok, envelope} <- get_envelope(envelope_id),
         :ok <- validate_executable_envelope(envelope),
         :ok <- validate_no_active_plan(envelope_id),
         :ok <- validate_not_paused(),
         :ok <- validate_delegation_active(smart_account_id) do
      reason = Keyword.get(opts, :reason, "manual_confirm")

      plan_attrs = %{
        decision_id: envelope.id,
        intent_id: envelope.intent_id,
        chain: "base",
        asset: "USDC",
        smart_account_id: smart_account_id,
        execution_status: :prepared,
        signing_requirements: build_signing_requirements(smart_account_id)
      }

      {:ok, plan} =
        %ExecutionPlan{}
        |> ExecutionPlan.changeset(plan_attrs)
        |> Repo.insert()

      # Audit
      audit_attrs =
        Bank.Audit.Events.execution_manually_requested(plan,
          actor: :user,
          actor_id: Keyword.get(opts, :actor_id)
        )

      _ = Runtime.emit_audit(audit_attrs)

      # Broadcast
      Runtime.broadcast_intent_lifecycle(envelope.intent_id, :execution_requested, %{
        decision_id: envelope.id,
        plan_id: plan.id,
        reason: reason
      })

      # Enqueue for adapter dispatch
      _ = Runtime.enqueue_execution(envelope.id)

      {:ok, plan}
    end
  end

  # --- Validation gates ---------------------------------------------------

  defp validate_executable_envelope(%DecisionEnvelope{current: true, outcome: :auto_exec}),
    do: :ok

  defp validate_executable_envelope(%DecisionEnvelope{current: false}),
    do: {:error, :not_current}

  defp validate_executable_envelope(%DecisionEnvelope{outcome: outcome}),
    do: {:error, :"outcome_is_#{outcome}"}

  defp validate_no_active_plan(envelope_id) do
    case active_plan_for(envelope_id) do
      nil -> :ok
      _plan -> {:error, :active_plan_exists}
    end
  end

  defp validate_not_paused do
    if Security.paused?(:global) do
      {:error, :runtime_paused}
    else
      :ok
    end
  end

  defp validate_delegation_active(smart_account_id) do
    if Delegations.executable?(smart_account_id) do
      :ok
    else
      {:error, :delegation_not_active}
    end
  end

  defp build_signing_requirements(smart_account_id) do
    case Delegations.get(smart_account_id) do
      %{delegation_id: del_id, scope: scope} ->
        %{"delegation_id" => del_id, "scope" => scope || %{}}

      _ ->
        %{}
    end
  end

  # --- Adapter callback application --------------------------------------

  @execution_callback_kinds ~w(execution.broadcast execution.confirmed execution.reverted execution.aborted)

  @doc """
  Apply an `execution.*` adapter callback to the referenced plan,
  atomically updating the plan's status (and final outcome for
  terminal callbacks) together with the owning intent's state.

  The returned shape exposes just enough information for the caller
  (the internal callback controller) to emit the matching audit
  events and realtime broadcasts, without having to re-query state.

      {:ok,
        %{
          plan: updated_plan,
          prior_plan_status: atom(),
          intent_transition:
            {:transitioned, prior_state, updated_intent}
            | {:no_transition, current_state}
            | :not_applicable
        }}
      | {:error, :plan_not_found}
      | {:error, :unknown_kind}
      | {:error, Ecto.Changeset.t()}

  Unknown `execution_plan_id` is the one soft-failure mode: the
  adapter is expected to dedupe on its side per
  `priv/adapter/contract.md §4`, so we log and return
  `{:error, :plan_not_found}` which the controller turns into
  `accepted_with_warning`.

  ### Kind → transitions

    * `execution.broadcast` → plan `:broadcasting`; intent unchanged
      (unless still `:decided`, in which case advance to
      `:executing` to recover from a dropped `RunExecution` side
      effect).
    * `execution.confirmed` → plan `:confirmed`, `final_outcome:
      :confirmed`; intent `:executing | :decided` → `:executed`.
    * `execution.reverted`  → plan `:reverted`, `final_outcome:
      :reverted`; intent `:executing | :decided` → `:blocked`.
    * `execution.aborted`   → plan `:aborted`, `final_outcome:
      :aborted`; intent `:executing | :decided` → `:blocked`.
  """
  @spec apply_execution_callback(map()) ::
          {:ok,
           %{
             plan: ExecutionPlan.t(),
             prior_plan_status: atom(),
             intent_transition:
               {:transitioned, atom(), AgentIntent.t()}
               | {:no_transition, atom()}
               | :not_applicable
           }}
          | {:error, :plan_not_found | :unknown_kind | Ecto.Changeset.t()}
  def apply_execution_callback(%{"kind" => kind, "execution_plan_id" => plan_id} = params)
      when kind in @execution_callback_kinds and is_binary(plan_id) do
    Repo.transaction(fn ->
      plan =
        Repo.get(ExecutionPlan, plan_id)
        |> case do
          nil -> nil
          found -> Repo.preload(found, :intent)
        end

      case plan do
        nil ->
          Repo.rollback(:plan_not_found)

        %ExecutionPlan{} = plan ->
          prior_status = plan.execution_status

          case progress_plan_for_kind(plan, kind, params) do
            {:ok, updated_plan} ->
              intent_transition = advance_intent_for_kind(plan.intent, updated_plan, kind)

              %{
                plan: updated_plan,
                prior_plan_status: prior_status,
                intent_transition: intent_transition
              }

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_execution_callback(_), do: {:error, :unknown_kind}

  defp progress_plan_for_kind(plan, "execution.broadcast", params) do
    plan
    |> ExecutionPlan.progress_changeset(
      attrs_with_tx_refs(%{execution_status: :broadcasting, nonce: first_nonce(params)}, params)
    )
    |> Repo.update()
  end

  defp progress_plan_for_kind(plan, "execution.confirmed", params) do
    plan
    |> ExecutionPlan.progress_changeset(
      attrs_with_tx_refs(
        %{execution_status: :confirmed, final_outcome: :confirmed},
        params
      )
    )
    |> Repo.update()
  end

  defp progress_plan_for_kind(plan, "execution.reverted", params) do
    plan
    |> ExecutionPlan.progress_changeset(
      attrs_with_tx_refs(
        %{
          execution_status: :reverted,
          final_outcome: :reverted,
          final_reason: Map.get(params, "reason")
        },
        params
      )
    )
    |> Repo.update()
  end

  defp progress_plan_for_kind(plan, "execution.aborted", params) do
    plan
    |> ExecutionPlan.progress_changeset(%{
      execution_status: :aborted,
      final_outcome: :aborted,
      final_reason: Map.get(params, "reason")
    })
    |> Repo.update()
  end

  defp attrs_with_tx_refs(attrs, params) do
    case tx_hashes(params) do
      [] -> attrs
      refs -> Map.put(attrs, :tx_refs, refs)
    end
  end

  defp advance_intent_for_kind(nil, _plan, _kind), do: :not_applicable

  defp advance_intent_for_kind(%AgentIntent{} = intent, %ExecutionPlan{} = plan, kind) do
    target_state = target_intent_state(kind)

    cond do
      is_nil(target_state) ->
        # execution.broadcast doesn't normally move the intent; the
        # only exception is recovering from a dropped RunExecution
        # side effect where the intent is still `:decided`.
        if intent.state == :decided do
          transition_intent(intent, plan, :executing)
        else
          {:no_transition, intent.state}
        end

      intent.state == target_state ->
        {:no_transition, intent.state}

      true ->
        transition_intent(intent, plan, target_state)
    end
  end

  defp transition_intent(%AgentIntent{state: prior} = intent, %ExecutionPlan{} = plan, target) do
    {:ok, updated} =
      intent
      |> AgentIntent.current_pointer_changeset(%{
        state: target,
        current_execution_plan_id: plan.id
      })
      |> Repo.update()

    {:transitioned, prior, updated}
  end

  defp target_intent_state("execution.broadcast"), do: nil
  defp target_intent_state("execution.confirmed"), do: :executed
  defp target_intent_state("execution.reverted"), do: :blocked
  defp target_intent_state("execution.aborted"), do: :blocked

  defp tx_hashes(%{"tx_refs" => refs}) when is_list(refs) do
    for %{"hash" => hash} <- refs, is_binary(hash), do: hash
  end

  defp tx_hashes(_), do: []

  defp first_nonce(%{"tx_refs" => [%{"nonce" => nonce} | _]}) when is_integer(nonce), do: nonce
  defp first_nonce(_), do: nil
end
