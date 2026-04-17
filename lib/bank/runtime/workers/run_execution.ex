defmodule Bank.Runtime.Workers.RunExecution do
  @moduledoc """
  Hand a decided, auto-executable envelope off to the TypeScript
  chain adapter.

  Scope: transfer path, Base + USDC only (issue #30). This worker
  performs the outbound half of the contract in
  `priv/adapter/contract.md`:

    1. Load the decision envelope; gate it as `current` + `:auto_exec`
       + `:decided`.
    2. Locate the active `ExecutionPlan` for the envelope. A plan is
       written up front by whoever enqueued the execution — today
       that's `Bank.Decisions.request_manual_execution/3`.
    3. Re-verify the delegation is executable. A revoke that landed
       between plan creation and dispatch is a hard stop: we mark the
       plan aborted and emit `execution.aborted` locally rather than
       ever touching the adapter.
    4. Re-verify the runtime is not globally paused. The pause is
       checked again here — independent of any earlier check — to
       cover the race where pause is toggled on between plan
       enqueue and worker dispatch. If paused, we mark the plan
       aborted with `final_reason: "runtime_paused"` and never call
       the adapter. This is the canonical fail-closed gate that
       keeps the invariant "nothing enters `:executing` while paused"
       intact end-to-end.
    5. POST the dispatch to `{adapter_base}/dispatch/transfer` via
       `Bank.AdapterClient.dispatch_transfer/1`.
    6. On adapter 202, atomically advance the plan `:prepared` →
       `:signing` and the intent `:decided` → `:executing`. Emit an
       `execution.signing` audit event, broadcast the lifecycle
       update, and return `:ok`.
    7. On adapter rejection (4xx), mark the plan `:aborted` with
       `final_reason: "adapter_rejected:<status>"`, advance the
       intent to `:blocked`, emit the matching audit pair, and cancel
       the job.
    8. On adapter unavailability (network, 5xx), return `{:error,
       :adapter_unavailable}` so Oban backs off and retries. `max_attempts:
       5` keeps this bounded.

  The plan stays `:prepared` only in two windows: before this worker
  runs, and between a retry's failed dispatch and the next retry.
  A plan in `:signing` or later is the adapter's to drive forward via
  callbacks.

  ## Retry posture

    * `:ok` — dispatch accepted.
    * `{:error, :adapter_unavailable}` — transient; Oban retries.
    * `{:cancel, reason}` — deterministic terminal:
      `:not_found`, `:not_current`, `{:wrong_outcome, outcome}`,
      `:no_active_plan`, `{:already_dispatched, status}`,
      `:delegation_not_active`, `:runtime_paused`,
      `:target_not_resolvable`, `:adapter_rejected`, `:malformed_args`.
  """

  use Oban.Worker,
    queue: :executions_run,
    max_attempts: 5

  require Logger

  import Ecto.Query

  alias Bank.AdapterClient
  alias Bank.Audit.Events
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Delegations
  alias Bank.Intents.AgentIntent
  alias Bank.Repo
  alias Bank.Runtime
  alias Bank.Runtime.Notifier
  alias Bank.Security

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"decision_id" => decision_id}}) do
    with {:ok, envelope} <- load_envelope(decision_id),
         {:ok, plan} <- load_active_plan(envelope),
         :ok <- verify_delegation(plan),
         :ok <- verify_not_paused(plan) do
      dispatch_and_progress(envelope, plan)
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("RunExecution: malformed args: #{inspect(args)}")
    {:cancel, :malformed_args}
  end

  # --- Gates --------------------------------------------------------------

  defp load_envelope(decision_id) do
    case Repo.get(DecisionEnvelope, decision_id) do
      nil ->
        Logger.warning("RunExecution: decision #{decision_id} not found")
        {:cancel, :not_found}

      %DecisionEnvelope{current: false} ->
        {:cancel, :not_current}

      %DecisionEnvelope{outcome: :auto_exec, state: :decided} = env ->
        {:ok, env}

      %DecisionEnvelope{outcome: outcome} ->
        {:cancel, {:wrong_outcome, outcome}}
    end
  end

  defp load_active_plan(%DecisionEnvelope{id: decision_id}) do
    query =
      from(p in ExecutionPlan,
        where: p.decision_id == ^decision_id and p.active == true,
        preload: [:intent]
      )

    case Repo.one(query) do
      nil ->
        {:cancel, :no_active_plan}

      %ExecutionPlan{execution_status: :prepared} = plan ->
        {:ok, plan}

      %ExecutionPlan{execution_status: status} ->
        # Plan moved past :prepared already — either a concurrent dispatch
        # or a stale retry. Fail terminal rather than double-dispatch.
        {:cancel, {:already_dispatched, status}}
    end
  end

  defp verify_delegation(%ExecutionPlan{smart_account_id: sa_id} = plan) do
    if Delegations.executable?(sa_id) do
      :ok
    else
      abort_for_delegation(plan)
    end
  end

  defp abort_for_delegation(%ExecutionPlan{} = plan) do
    prior_status = plan.execution_status
    reason = "delegation_not_active"

    case mark_plan_aborted(plan, reason) do
      {:ok, updated_plan, intent_transition} ->
        emit_aborted_side_effects(updated_plan, prior_status, intent_transition, reason)
        {:cancel, :delegation_not_active}

      {:error, changeset} ->
        Logger.error(
          "RunExecution: abort-for-delegation update failed for plan #{plan.id}: #{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  defp verify_not_paused(%ExecutionPlan{} = plan) do
    if Security.paused?(:global) do
      abort_for_pause(plan)
    else
      :ok
    end
  end

  defp abort_for_pause(%ExecutionPlan{} = plan) do
    prior_status = plan.execution_status
    reason = "runtime_paused"

    case mark_plan_aborted(plan, reason) do
      {:ok, updated_plan, intent_transition} ->
        emit_aborted_side_effects(updated_plan, prior_status, intent_transition, reason)
        {:cancel, :runtime_paused}

      {:error, changeset} ->
        Logger.error(
          "RunExecution: abort-for-pause update failed for plan #{plan.id}: #{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  # --- Dispatch -----------------------------------------------------------

  defp dispatch_and_progress(%DecisionEnvelope{} = envelope, %ExecutionPlan{} = plan) do
    case AdapterClient.dispatch_transfer(plan) do
      {:ok, _} ->
        progress_after_dispatch(plan, envelope)

      {:error, :adapter_unavailable} ->
        Logger.warning("RunExecution: adapter unavailable for plan #{plan.id}; retrying via Oban")

        {:error, :adapter_unavailable}

      {:error, {:adapter_error, status, _body}} ->
        Logger.warning(
          "RunExecution: adapter 5xx #{status} for plan #{plan.id}; retrying via Oban"
        )

        {:error, {:adapter_error, status}}

      {:error, {:adapter_rejected, status, body}} ->
        Logger.warning(
          "RunExecution: adapter rejected plan #{plan.id} (HTTP #{status}): #{inspect(body)}"
        )

        abort_for_adapter_rejection(plan, status, body)

      {:error, {:target_not_resolvable, cause}} ->
        Logger.warning(
          "RunExecution: plan #{plan.id} has unresolvable target (#{cause}); aborting"
        )

        abort_for_target(plan, cause)

      {:error, :invalid_response} ->
        Logger.error(
          "RunExecution: adapter returned 2xx with unexpected body for plan #{plan.id}"
        )

        abort_for_adapter_rejection(plan, 200, "invalid_response")
    end
  end

  defp progress_after_dispatch(%ExecutionPlan{} = plan, %DecisionEnvelope{} = _envelope) do
    prior_status = plan.execution_status
    prior_intent_state = plan.intent.state

    result =
      Repo.transaction(fn ->
        {:ok, updated_plan} =
          plan
          |> ExecutionPlan.progress_changeset(%{execution_status: :signing})
          |> Repo.update()

        intent_transition = advance_intent_to_executing(plan.intent, updated_plan)
        {updated_plan, intent_transition}
      end)

    case result do
      {:ok, {updated_plan, intent_transition}} ->
        emit_dispatched_side_effects(updated_plan, prior_status, intent_transition,
          prior_intent_state: prior_intent_state
        )

        :ok

      {:error, reason} ->
        Logger.error("RunExecution: progress txn failed for plan #{plan.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp advance_intent_to_executing(
         %AgentIntent{state: :decided} = intent,
         %ExecutionPlan{} = plan
       ) do
    {:ok, updated_intent} =
      intent
      |> AgentIntent.current_pointer_changeset(%{
        state: :executing,
        current_execution_plan_id: plan.id
      })
      |> Repo.update()

    {:transitioned, intent.state, updated_intent}
  end

  defp advance_intent_to_executing(%AgentIntent{state: state}, _plan) do
    # Already past :decided (e.g. a retry after a partial crash). Don't
    # downgrade; just keep the intent where it is. The caller still
    # emits plan-level audit.
    {:no_transition, state}
  end

  # --- Abort helpers ------------------------------------------------------

  defp abort_for_adapter_rejection(%ExecutionPlan{} = plan, status, body) do
    reason = "adapter_rejected:#{status}:#{summarise_body(body)}"
    prior_status = plan.execution_status

    case mark_plan_aborted(plan, reason) do
      {:ok, updated_plan, intent_transition} ->
        emit_aborted_side_effects(updated_plan, prior_status, intent_transition, reason)
        {:cancel, :adapter_rejected}

      {:error, changeset} ->
        Logger.error(
          "RunExecution: abort-for-rejection update failed for plan #{plan.id}: #{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  defp abort_for_target(%ExecutionPlan{} = plan, cause) do
    reason = "target_not_resolvable:#{cause}"
    prior_status = plan.execution_status

    case mark_plan_aborted(plan, reason) do
      {:ok, updated_plan, intent_transition} ->
        emit_aborted_side_effects(updated_plan, prior_status, intent_transition, reason)
        {:cancel, :target_not_resolvable}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp mark_plan_aborted(%ExecutionPlan{} = plan, reason) do
    Repo.transaction(fn ->
      {:ok, updated_plan} =
        plan
        |> ExecutionPlan.progress_changeset(%{
          execution_status: :aborted,
          final_outcome: :aborted,
          final_reason: reason
        })
        |> Repo.update()

      intent_transition =
        case plan.intent do
          %AgentIntent{state: state} = intent when state in [:decided, :executing] ->
            {:ok, updated_intent} =
              intent
              |> AgentIntent.current_pointer_changeset(%{
                state: :blocked,
                current_execution_plan_id: updated_plan.id
              })
              |> Repo.update()

            {:transitioned, state, updated_intent}

          %AgentIntent{state: state} ->
            {:no_transition, state}

          nil ->
            {:no_transition, nil}
        end

      {updated_plan, intent_transition}
    end)
    |> case do
      {:ok, {updated_plan, intent_transition}} -> {:ok, updated_plan, intent_transition}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Side effects -------------------------------------------------------

  defp emit_dispatched_side_effects(plan, prior_status, intent_transition, opts) do
    _ =
      Runtime.emit_audit(Events.execution_transition(plan, prior_status, actor: :runtime))

    Notifier.execution_progressed(plan, prior_status)

    case intent_transition do
      {:transitioned, from, updated_intent} ->
        _ =
          Runtime.emit_audit(
            Events.intent_state_changed(updated_intent, from, updated_intent.state,
              actor: :runtime
            )
          )

        Notifier.intent_lifecycle(updated_intent, :state_changed, %{
          from: from,
          to: updated_intent.state,
          execution_plan_id: plan.id
        })

      {:no_transition, _state} ->
        _ = Keyword.get(opts, :prior_intent_state)
        :ok
    end
  end

  defp emit_aborted_side_effects(plan, prior_status, intent_transition, reason) do
    _ =
      Runtime.emit_audit(Events.execution_transition(plan, prior_status, actor: :runtime))

    Notifier.execution_progressed(plan, prior_status)

    case intent_transition do
      {:transitioned, from, updated_intent} ->
        _ =
          Runtime.emit_audit(
            Events.intent_state_changed(updated_intent, from, updated_intent.state,
              actor: :runtime
            )
          )

        Notifier.intent_lifecycle(updated_intent, :state_changed, %{
          from: from,
          to: updated_intent.state,
          execution_plan_id: plan.id,
          reason: reason
        })

      {:no_transition, _state} ->
        :ok
    end
  end

  defp summarise_body(body) when is_binary(body), do: String.slice(body, 0, 80)

  defp summarise_body(%{"error" => %{"code" => code}}) when is_binary(code), do: code
  defp summarise_body(%{"code" => code}) when is_binary(code), do: code
  defp summarise_body(body), do: body |> inspect() |> String.slice(0, 80)
end
