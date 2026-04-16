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
end
