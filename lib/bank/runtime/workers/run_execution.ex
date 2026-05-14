defmodule Bank.Runtime.Workers.RunExecution do
  @moduledoc """
  Hand a decided, auto-executable envelope off to the TypeScript
  chain adapter.

  Scope: transfer path on Base + USDC (issue #30) and swap path on
  Base Sepolia + USDC (issue #193, MVP). This worker performs the
  outbound half of the contract in `priv/adapter/contract.md`:

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
    5. Fork by plan kind:
       * **transfer** — POST `{adapter_base}/dispatch/transfer` via
         `Bank.AdapterClient.dispatch_transfer/1`.
       * **swap** (#193) — reconstitute the route from
         `plan.steps` via `SwapRouteArtifacts.route_from_steps/1`,
         run the centralized #191 safety gate
         (`SwapDispatchSafety.validate/3`), then POST
         `{adapter_base}/dispatch/swap` via
         `Bank.AdapterClient.dispatch_swap/1`. A safety-gate
         failure (`:swap_*` atoms, `:runtime_paused`,
         `:chain_paused`, `:mainnet_disabled`) is a fail-closed
         abort; the adapter is never reached.
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
      `:delegation_not_active`, `:runtime_paused`, `:chain_paused`,
      `:mainnet_disabled`, `:canary_chain_not_allowed`,
      `:canary_asset_not_allowed`, `:canary_amount_exceeded`,
      `:target_not_resolvable`, `:adapter_rejected`, `:malformed_args`,
      `{:swap_safety_gate, atom}` (#193 — every
      `SwapDispatchSafety.failure()` atom).
  """

  use Oban.Worker,
    queue: :executions_run,
    max_attempts: 5

  require Logger

  import Ecto.Query

  alias Bank.AdapterClient
  alias Bank.Audit.Events
  alias Bank.Decisions

  alias Bank.Decisions.{
    DecisionEnvelope,
    ExecutionPlan,
    MorphoDispatchSafety,
    SwapDispatchSafety,
    SwapRouteArtifacts
  }

  alias Bank.Delegations
  alias Bank.Intents.AgentIntent
  alias Bank.Repo
  alias Bank.Runtime
  alias Bank.Runtime.Notifier
  alias Bank.Security

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"decision_id" => decision_id}} = job) do
    with {:ok, envelope} <- load_envelope(decision_id),
         {:ok, plan} <- load_active_plan(envelope),
         :ok <- verify_delegation(plan),
         :ok <- verify_not_paused(plan),
         :ok <- verify_mainnet_allowed(plan),
         :ok <- verify_canary_caps(plan),
         {:ok, claimed} <- claim_or_cancel(plan) do
      dispatch_and_progress(envelope, claimed, job)
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("RunExecution: malformed args: #{inspect(args)}")
    {:cancel, :malformed_args}
  end

  # Last-attempt guard: if Oban is on its final allowed try and the
  # failure is a transient class (`:adapter_unavailable` / 5xx),
  # escalate to a terminal abort instead of letting Oban discard the
  # job silently. Without this the plan rusts at `:prepared` forever
  # and the UI watchdog sits on "Still processing" with no terminal
  # PubSub event — which is exactly what the manual tester observed
  # when the chain_adapter was down.
  defp last_attempt?(%Oban.Job{attempt: a, max_attempts: m}) when is_integer(a) and is_integer(m),
    do: a >= m

  defp last_attempt?(_), do: false

  # Atomically transition the plan `:prepared → :signing` BEFORE any
  # adapter call (#230 P1). Closes the abort-vs-dispatch race: an
  # operator's `Decisions.abort_plan/3` that wins the row lock leaves
  # the plan `:aborted`; the claim then sees a non-`:prepared` status
  # and cancels without calling the adapter.
  defp claim_or_cancel(%ExecutionPlan{} = plan) do
    case Decisions.claim_plan_for_dispatch(plan) do
      {:ok, claimed} ->
        {:ok, claimed}

      {:cancel, {:not_prepared, status}} ->
        Logger.info(
          "RunExecution: plan #{plan.id} no longer :prepared at claim time (#{status}); cancelling"
        )

        {:cancel, {:already_dispatched, status}}

      {:cancel, :not_found} ->
        Logger.warning("RunExecution: plan #{plan.id} disappeared at claim time")
        {:cancel, :not_found}

      {:error, changeset} ->
        Logger.error(
          "RunExecution: claim update failed for plan #{plan.id}: #{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
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

  # Pre-dispatch pause gate. Global pause keeps its existing
  # `"runtime_paused"` reason and `{:cancel, :runtime_paused}`
  # cancellation shape so existing audit/replay consumers see no
  # change. The chain-pause check (#228 Phase 1) layers on top:
  # when the plan's workspace+chain is paused at the DB level, we
  # abort with `"chain_paused"` and `{:cancel, :chain_paused}`.
  defp verify_not_paused(%ExecutionPlan{} = plan) do
    cond do
      Security.paused?(:global) ->
        abort_for_pause(plan, "runtime_paused", :runtime_paused)

      is_binary(plan.workspace_id) and is_binary(plan.chain) and
          Security.paused?(plan.workspace_id, {:chain, plan.chain}) ->
        abort_for_pause(plan, "chain_paused", :chain_paused)

      true ->
        :ok
    end
  end

  # Defense-in-depth mainnet gate (#178). The decision-pipeline gate
  # in `Bank.Decisions.create_execution_plan/3` already refuses to
  # write a plan for a mainnet chain when the workspace flag is off,
  # so a plan that reaches this worker should never be on a
  # disallowed mainnet chain. Re-checking here means a future code
  # path that bypasses `create_execution_plan/3` (e.g. an admin
  # override that flips a workspace's mainnet flag *off* between
  # plan creation and dispatch) still fails closed without
  # broadcasting.
  defp verify_mainnet_allowed(%ExecutionPlan{} = plan) do
    if Bank.Chains.mainnet_allowed_for?(plan.chain, plan.workspace_id) do
      :ok
    else
      abort_for_pause(plan, "mainnet_disabled", :mainnet_disabled)
    end
  end

  # Capped Base mainnet canary gate (#181). Layered on top of
  # `verify_mainnet_allowed/1`: a plan that reaches this point has
  # already cleared the workspace eligibility flag and is on a
  # mainnet chain (or testnet, in which case the cap module
  # short-circuits with `:ok`). The cap bounds the first mainnet
  # broadcast to a documented (chain, asset, amount) tuple — see
  # `Bank.Chains.CanaryCaps` for the v0.1 defaults and the failure
  # allowlist (`:canary_chain_not_allowed`,
  # `:canary_asset_not_allowed`, `:canary_amount_exceeded`).
  #
  # On failure: plan is aborted with `final_reason: "canary_<reason>"`,
  # the worker returns `{:cancel, :canary_<reason>}`, and
  # `Bank.AdapterClient` is never called. The runbook
  # `docs/runbooks/base-mainnet-canary.md` documents the operator
  # response for each failure mode.
  defp verify_canary_caps(%ExecutionPlan{intent: %AgentIntent{amount: amount}} = plan) do
    case Bank.Chains.CanaryCaps.validate(plan.chain, plan.asset, amount) do
      :ok ->
        :ok

      {:error, reason_atom} ->
        abort_for_pause(plan, Atom.to_string(reason_atom), reason_atom)
    end
  end

  defp verify_canary_caps(%ExecutionPlan{} = plan) do
    # Defensive fallback — `load_active_plan/1` always preloads
    # `:intent`, so this clause should be unreachable in production.
    # If it ever fires (e.g. a future code path that bypasses
    # `load_active_plan/1`), fail closed.
    abort_for_pause(plan, "canary_amount_exceeded", :canary_amount_exceeded)
  end

  defp abort_for_pause(%ExecutionPlan{} = plan, reason, cancel_tag) do
    prior_status = plan.execution_status

    case mark_plan_aborted(plan, reason) do
      {:ok, updated_plan, intent_transition} ->
        emit_aborted_side_effects(updated_plan, prior_status, intent_transition, reason)
        {:cancel, cancel_tag}

      {:error, changeset} ->
        Logger.error(
          "RunExecution: abort-for-pause update failed for plan #{plan.id}: #{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  # --- Dispatch -----------------------------------------------------------

  # `claimed` is the plan struct post-`:prepared → :signing` claim,
  # with `intent` preloaded by `Decisions.claim_plan_for_dispatch/1`.
  # The adapter receives this struct because its `execution_status`
  # reflects the committed DB state. Audits use `:prepared` as the
  # `prior_status` because that was the row's state immediately
  # before the claim transaction committed.
  defp dispatch_and_progress(
         %DecisionEnvelope{} = envelope,
         %ExecutionPlan{} = claimed,
         %Oban.Job{} = job
       ) do
    case adapter_dispatch(claimed) do
      {:ok, _} ->
        progress_after_dispatch(claimed, envelope)

      {:error, {:morpho_safety, reason}} ->
        Logger.warning(
          "RunExecution: Morpho dispatch safety gate refused plan #{claimed.id}: #{inspect(reason)}"
        )

        abort_for_morpho_safety(claimed, reason)

      {:error, :adapter_unavailable} ->
        if last_attempt?(job) do
          Logger.warning(
            "RunExecution: adapter unavailable for plan #{claimed.id} on final attempt #{job.attempt}/#{job.max_attempts}; aborting instead of retry"
          )

          abort_for_adapter_exhausted(claimed, :adapter_unavailable)
        else
          revert_after_adapter_failure(claimed, :adapter_unavailable)

          Logger.warning(
            "RunExecution: adapter unavailable for plan #{claimed.id}; reverted claim; retrying via Oban"
          )

          {:error, :adapter_unavailable}
        end

      {:error, {:adapter_error, status, _body}} ->
        if last_attempt?(job) do
          Logger.warning(
            "RunExecution: adapter 5xx #{status} for plan #{claimed.id} on final attempt #{job.attempt}/#{job.max_attempts}; aborting instead of retry"
          )

          abort_for_adapter_exhausted(claimed, {:adapter_error, status})
        else
          revert_after_adapter_failure(claimed, {:adapter_error, status})

          Logger.warning(
            "RunExecution: adapter 5xx #{status} for plan #{claimed.id}; reverted claim; retrying via Oban"
          )

          {:error, {:adapter_error, status}}
        end

      {:error, {:adapter_rejected, status, body}} ->
        Logger.warning(
          "RunExecution: adapter rejected plan #{claimed.id} (HTTP #{status}): #{inspect(body)}"
        )

        abort_for_adapter_rejection(claimed, status, body)

      {:error, {:target_not_resolvable, cause}} ->
        Logger.warning(
          "RunExecution: plan #{claimed.id} has unresolvable target (#{cause}); aborting"
        )

        abort_for_target(claimed, cause)

      {:error, :invalid_response} ->
        Logger.error(
          "RunExecution: adapter returned 2xx with unexpected body for plan #{claimed.id}"
        )

        abort_for_adapter_rejection(claimed, 200, "invalid_response")

      {:error, {:swap_safety_gate, reason_atom}} ->
        Logger.warning(
          "RunExecution: swap safety gate refused plan #{claimed.id} (#{reason_atom}); aborting before adapter"
        )

        abort_for_swap_safety(claimed, reason_atom)

      {:error, {:invalid_swap_plan, cause}} ->
        Logger.error(
          "RunExecution: plan #{claimed.id} carries no usable swap route (#{cause}); aborting"
        )

        abort_for_swap_safety(claimed, cause)

      {:error, {:dispatch_aborted_paused, scope}} ->
        # Pause re-check (audit C3) tripped between claim and adapter
        # dispatch. `recheck_pause_before_dispatch/1` already reverted
        # the claim and emitted the `execution.dispatch_aborted_paused`
        # audit row. Snooze the Oban job so the next attempt re-runs
        # the full pause gate after the operator resumes — typical
        # operator response window is on the order of tens of seconds,
        # so 30 s avoids retry-storming while staying within the
        # bounded `max_attempts: 5` budget.
        Logger.info(
          "RunExecution: pause activated between claim and dispatch for plan #{claimed.id} " <>
            "(scope=#{inspect(scope)}); claim reverted, snoozing"
        )

        {:snooze, 30}
    end
  end

  # Fork the dispatch by plan kind. Transfer plans keep the legacy
  # `dispatch_transfer` path. Swap plans (#193) go through the
  # centralized #191 safety gate before the adapter call so a route
  # whose deadline expired between plan creation and dispatch, or
  # whose chain/amount drifted relative to the parent intent, is
  # refused locally instead of being broadcast. Morpho deposit
  # plans (#206, `:defi_yield_deposit`) go through their own
  # `MorphoDispatchSafety.validate/2` gate (vault allowlist,
  # snapshot freshness, material drift) before the adapter call.
  #
  # ## Pause re-check (audit C3)
  #
  # The pre-claim `verify_not_paused/1` runs once at job pick-up
  # while the plan is still `:prepared`. Between the claim
  # (`:prepared → :signing`) and the actual `AdapterClient.dispatch_*`
  # call there used to be no second check, so an operator hitting
  # the kill-switch after the claim landed but before the adapter
  # HTTP request left the BEAM would not stop that dispatch. We
  # re-check the same scopes (`:global` + workspace+chain) one more
  # time as the very first action of `adapter_dispatch/1`. On hit:
  # the adapter is NOT contacted, the plan is reverted to
  # `:prepared` via `Decisions.revert_claim/1` so a retry after
  # resume can re-claim, an `execution.dispatch_aborted_paused`
  # audit row is written, and the worker snoozes the Oban job.
  #
  # Exposed as `def`/`@doc false` so the runtime test suite can
  # exercise the re-check timing race deterministically: the test
  # claims the plan via `Decisions.claim_plan_for_dispatch/1`,
  # activates a pause, and calls `adapter_dispatch/1` directly to
  # reproduce the exact "after claim, before adapter" window.
  @doc false
  @spec adapter_dispatch(ExecutionPlan.t()) ::
          {:ok, term()}
          | {:error, term()}
          | {:error, {:dispatch_aborted_paused, map()}}
  def adapter_dispatch(%ExecutionPlan{} = plan) do
    case recheck_pause_before_dispatch(plan) do
      :ok -> do_adapter_dispatch(plan)
      {:error, _} = err -> err
    end
  end

  defp do_adapter_dispatch(%ExecutionPlan{steps: %{"kind" => "swap"} = steps} = plan) do
    with {:ok, route} <- SwapRouteArtifacts.route_from_steps(steps),
         {:ok, caps} <- SwapRouteArtifacts.caps_from_steps(steps) do
      context = %{intent: plan.intent, workspace_id: plan.workspace_id}

      # Re-validate with the SAME caps the approve path accepted.
      # The caps live on `steps["caps"]` — the worker must read them
      # back rather than falling through to `SwapRoute.caps/0`
      # defaults, otherwise an approved route can be rejected here
      # with e.g. `:asset_unsupported` because the worker's default
      # caps were narrower than approval's.
      case SwapDispatchSafety.validate(route, context, caps: caps) do
        :ok ->
          AdapterClient.dispatch_swap(plan)

        {:error, reason_atom} ->
          {:error, {:swap_safety_gate, reason_atom}}
      end
    else
      {:error, :not_a_swap} ->
        # Defensive — the outer head guards on `kind == "swap"`, but
        # if the steps shape ever drifts we fail closed rather than
        # falling through to a transfer dispatch.
        {:error, {:invalid_swap_plan, :missing_route}}

      {:error, {:malformed_steps, field}} ->
        {:error, {:invalid_swap_plan, field}}
    end
  end

  defp do_adapter_dispatch(%ExecutionPlan{intent: %AgentIntent{kind: :defi_yield_deposit}} = plan) do
    case MorphoDispatchSafety.validate(plan) do
      :ok -> AdapterClient.dispatch_morpho_deposit(plan)
      {:error, reason} -> {:error, {:morpho_safety, reason}}
    end
  end

  defp do_adapter_dispatch(%ExecutionPlan{} = plan), do: AdapterClient.dispatch_transfer(plan)

  # Mirrors `verify_not_paused/1`'s scope coverage exactly so a future
  # change to either gate is forced to update both. Returns `:ok` when
  # no covering pause is active; on hit, performs the abort side
  # effects (revert claim + audit emit) and returns the new
  # `{:dispatch_aborted_paused, scope}` error tuple that
  # `dispatch_and_progress/2` translates into a `{:snooze, _}` Oban
  # signal.
  defp recheck_pause_before_dispatch(%ExecutionPlan{} = plan) do
    cond do
      Security.paused?(:global) ->
        abort_dispatch_for_pause(plan, %{kind: :global})

      is_binary(plan.workspace_id) and is_binary(plan.chain) and
          Security.paused?(plan.workspace_id, {:chain, plan.chain}) ->
        abort_dispatch_for_pause(plan, %{
          kind: :chain,
          value: plan.chain,
          workspace_id: plan.workspace_id
        })

      true ->
        :ok
    end
  end

  defp abort_dispatch_for_pause(%ExecutionPlan{} = plan, scope) when is_map(scope) do
    prior_status = plan.execution_status

    # Revert the claim so a retry after resume can re-claim. Terminal
    # rows are not resurrected — `Decisions.revert_claim/1` is guarded
    # `:signing → :prepared` only.
    _ = Decisions.revert_claim(plan)

    _ =
      Runtime.emit_audit(
        Events.execution_dispatch_aborted_paused(plan, prior_status, scope, actor: :runtime)
      )

    {:error, {:dispatch_aborted_paused, scope}}
  end

  defp abort_for_swap_safety(%ExecutionPlan{} = plan, reason_atom) do
    reason = "swap_safety:#{Atom.to_string(reason_atom)}"
    prior_status = plan.execution_status

    case mark_plan_aborted(plan, reason) do
      {:ok, updated_plan, intent_transition} ->
        emit_aborted_side_effects(updated_plan, prior_status, intent_transition, reason)
        {:cancel, {:swap_safety_gate, reason_atom}}

      {:error, changeset} ->
        Logger.error(
          "RunExecution: abort-for-swap-safety update failed for plan #{plan.id}: #{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  defp abort_for_morpho_safety(%ExecutionPlan{} = plan, reason) do
    reason_str = "morpho_safety:#{reason}"
    prior_status = plan.execution_status

    case mark_plan_aborted(plan, reason_str) do
      {:ok, updated_plan, intent_transition} ->
        # Standard execution.aborted side effects.
        emit_aborted_side_effects(updated_plan, prior_status, intent_transition, reason_str)

        # Plus the Morpho-specific abort event for replay attribution.
        _ =
          Runtime.emit_audit(Events.morpho_deposit_aborted(updated_plan, reason, actor: :runtime))

        {:cancel, reason}

      {:error, changeset} ->
        Logger.error(
          "RunExecution: abort-for-morpho-safety update failed for plan #{plan.id}: #{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  # Best-effort revert after a non-rejection adapter failure
  # (`:adapter_unavailable` or 5xx). Guarded `:signing → :prepared`
  # in `Decisions.revert_claim/1` ensures terminal rows are not
  # resurrected — if a callback or operator abort already raced in
  # while the adapter call was in flight, the revert short-circuits
  # to `{:no_revert, status}` and the plan keeps its newer state.
  defp revert_after_adapter_failure(%ExecutionPlan{} = claimed, _adapter_error) do
    case Decisions.revert_claim(claimed) do
      {:ok, :reverted} ->
        :ok

      {:ok, {:no_revert, status}} ->
        Logger.info("RunExecution: revert skipped for plan #{claimed.id} — already at #{status}")

        :ok

      {:error, reason} ->
        Logger.error("RunExecution: revert failed for plan #{claimed.id}: #{inspect(reason)}")

        :ok
    end
  end

  # Plan is already `:signing` post-claim. Advance the parent intent
  # `:decided → :executing` (when applicable) and emit the
  # dispatched side effects with `prior_status: :prepared` so the
  # audit trail still reflects the original transition. `claimed`
  # carries `intent` preloaded by
  # `Decisions.claim_plan_for_dispatch/1`.
  defp progress_after_dispatch(
         %ExecutionPlan{intent: intent} = claimed,
         %DecisionEnvelope{} = _envelope
       ) do
    prior_intent_state = intent && intent.state

    result =
      Repo.transaction(fn ->
        intent_transition = advance_intent_to_executing(intent, claimed)
        {claimed, intent_transition}
      end)

    case result do
      {:ok, {updated_plan, intent_transition}} ->
        emit_dispatched_side_effects(updated_plan, :prepared, intent_transition,
          prior_intent_state: prior_intent_state
        )

        :ok

      {:error, reason} ->
        Logger.error(
          "RunExecution: progress txn failed for plan #{claimed.id}: #{inspect(reason)}"
        )

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

  # Terminal abort when the transient-class adapter failure
  # (`:adapter_unavailable` or 5xx) has exhausted Oban's
  # `max_attempts` budget. Without this the plan would sit at
  # `:prepared` forever, the UI watchdog would render
  # "Still processing" indefinitely, and no terminal
  # `:execution_updated` PubSub event would ever broadcast.
  # The abort mirrors the other terminal-abort helpers:
  # `mark_plan_aborted/2` flips the plan to `:aborted` with a
  # canonical `final_reason`, then
  # `emit_aborted_side_effects/4` audits + broadcasts so AgentLive
  # flips IntentResult to `:failed` ("Execution aborted.").
  defp abort_for_adapter_exhausted(%ExecutionPlan{} = plan, cause) do
    reason = "adapter_exhausted:#{cause_label(cause)}"
    prior_status = plan.execution_status

    case mark_plan_aborted(plan, reason) do
      {:ok, updated_plan, intent_transition} ->
        emit_aborted_side_effects(updated_plan, prior_status, intent_transition, reason)
        {:cancel, :adapter_exhausted}

      {:error, changeset} ->
        Logger.error(
          "RunExecution: abort-for-adapter-exhausted update failed for plan #{plan.id}: #{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  defp cause_label(:adapter_unavailable), do: "adapter_unavailable"
  defp cause_label({:adapter_error, status}), do: "adapter_error:#{status}"
  defp cause_label(other), do: inspect(other)

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

    # Morpho-specific dispatch event for replay attribution (#206 +
    # #208's `morpho.*` namespace). Emitted in addition to, not in
    # place of, `execution.<status>` so the standard execution
    # narrative stays uniform across kinds.
    maybe_emit_morpho_dispatched(plan)

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

  defp maybe_emit_morpho_dispatched(
         %ExecutionPlan{
           intent: %AgentIntent{kind: :defi_yield_deposit, amount: %Decimal{} = amount}
         } = plan
       ) do
    _ = Runtime.emit_audit(Events.morpho_deposit_dispatched(plan, amount, actor: :runtime))
    :ok
  end

  defp maybe_emit_morpho_dispatched(_plan), do: :ok

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
