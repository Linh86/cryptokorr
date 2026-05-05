defmodule Bank.Intents do
  @moduledoc """
  Intents bounded context.

  Owns the `AgentIntent` lifecycle: `submitted → evaluating → decided →
  (executing → executed) | blocked | cancelled | expired`. Accepts agent
  submissions, applies idempotency-key dedupe, and coordinates the
  evaluation pipeline by enqueueing work on the `intents.evaluate` queue
  (see `Bank.Runtime`).

  Public surface scope in v0.1:

    * accept an intent (create + persist + enqueue evaluation)
    * look up an intent and its linked decision / simulation / plan
    * operator cancellation (pre-execution)
    * on-demand simulation (`simulate/3`) — produces a fresh
      `SimulationReport` without re-running policy / autonomy
    * replay bundle assembly (delegates to `Bank.Audit`)

  Evaluation, simulation engine, and decisioning belong to
  `Bank.Policies`, `Bank.Decisions`, and `Bank.Runtime` — this module
  is the agent-facing facade.
  """

  import Ecto.Query

  alias Bank.Audit
  alias Bank.Audit.Events, as: AuditEvents
  alias Bank.Decisions
  alias Bank.Decisions.SimulationReport
  alias Bank.Intents.AgentIntent
  alias Bank.Quotes
  alias Bank.Repo
  alias Bank.Runtime
  alias Bank.SmartAccounts
  alias Bank.SmartAccounts.SmartAccount
  alias Ecto.Multi

  @default_limit 50
  @max_limit 200

  # Two supported chain strings as of #178:
  #
  #   * `"base"` — Base mainnet (`Bank.Chains.mainnet?/1`). Subject to
  #     the workspace mainnet eligibility gate; rejected at submission
  #     when the workspace has not opted in.
  #   * `"base-sepolia"` — Base Sepolia testnet. Always allowed
  #     regardless of the workspace mainnet flag.
  #
  # The mainnet eligibility check itself lives in
  # `Bank.Chains.validate_mainnet_allowed/2`, called from `submit/2`
  # right after `stamp_workspace_id/2` so the rejection happens
  # before any DB row or audit event is written.
  @supported_chains ~w(base base-sepolia)
  @supported_assets ~w(USDC)

  @doc """
  List intents for the control-tower intents page.

  Opts:

    * `:state` — single `AgentIntent` state atom (or `:all`, default)
    * `:kind`  — single `AgentIntent` kind atom (or `:all`, default)
    * `:limit` — positive integer, capped at `#{@max_limit}`, default
      `#{@default_limit}`
    * `:search` — case-insensitive substring match on agent_id or
      intent id
    * `:workspace_id` — narrow to one workspace (#158b). Default
      `nil` keeps the legacy "all workspaces" path open until every
      caller is migrated.

  Returns intents newest-first with their target counterparty and
  address-label preloaded for rendering.
  """
  @spec list(keyword()) :: [AgentIntent.t()]
  def list(opts \\ []) do
    state = Keyword.get(opts, :state, :all)
    kind = Keyword.get(opts, :kind, :all)
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()
    search = opts |> Keyword.get(:search) |> normalise_search()
    workspace_id = Keyword.get(opts, :workspace_id)

    query =
      from(i in AgentIntent,
        order_by: [desc: i.submitted_at, desc: i.inserted_at],
        limit: ^limit,
        preload: [:target_counterparty, :target_address_label]
      )

    query
    |> apply_state_filter(state)
    |> apply_kind_filter(kind)
    |> apply_search_filter(search)
    |> scope_intent_to_workspace(workspace_id)
    |> Repo.all()
  end

  @doc """
  Count intents grouped by state, optionally scoped by the same
  non-state filters the intents page exposes.

  The breakdown itself slices by state, so the `:state` filter is
  intentionally ignored — applying it would leave every chip at zero
  except the one currently selected, which is useless. `:kind` and
  `:search` ARE applied, so an operator viewing `kind=transfer` sees
  the state distribution *within* their current scope rather than the
  global distribution across all kinds.

  Opts:

    * `:kind`   — single `AgentIntent` kind atom (or `:all`, default)
    * `:search` — case-insensitive substring match on agent_id or
      intent id
    * `:workspace_id` — narrow to one workspace (#158b). Default
      `nil` (all workspaces).

  Returns a map keyed by state atom with integer counts; all known
  states are present (missing states map to 0).
  """
  @spec counts_by_state(keyword()) :: %{atom() => non_neg_integer()}
  def counts_by_state(opts \\ []) do
    kind = Keyword.get(opts, :kind, :all)
    search = opts |> Keyword.get(:search) |> normalise_search()
    workspace_id = Keyword.get(opts, :workspace_id)

    base = %{
      submitted: 0,
      evaluating: 0,
      decided: 0,
      executing: 0,
      executed: 0,
      blocked: 0,
      cancelled: 0,
      expired: 0
    }

    from(i in AgentIntent, group_by: i.state, select: {i.state, count(i.id)})
    |> apply_kind_filter(kind)
    |> apply_search_filter(search)
    |> scope_intent_to_workspace(workspace_id)
    |> Repo.all()
    |> Enum.reduce(base, fn {state, n}, acc -> Map.put(acc, state, n) end)
  end

  @doc """
  Look up a single intent by id with decision / plan preloaded. Returns
  `nil` if no such intent exists (callers that need a 404 lift this to
  `{:error, :not_found}` themselves).
  """
  @spec get(String.t()) :: AgentIntent.t() | nil
  def get(id) when is_binary(id) do
    Repo.get(AgentIntent, id)
    |> Repo.preload([:target_counterparty, :target_address_label])
  end

  @doc """
  Workspace-scoped variant of `get/1` (#159b). Returns `nil` for
  intents that do not exist OR that belong to a different
  workspace — controllers lift to `404 not_found` so a caller in
  workspace A cannot confirm that an intent id exists in
  workspace B by status code.
  """
  @spec get_in_workspace(String.t(), String.t()) :: AgentIntent.t() | nil
  def get_in_workspace(id, workspace_id)
      when is_binary(id) and is_binary(workspace_id) do
    case Repo.one(
           from i in AgentIntent,
             where: i.id == ^id and i.workspace_id == ^workspace_id,
             preload: [:target_counterparty, :target_address_label]
         ) do
      nil -> nil
      %AgentIntent{} = intent -> intent
    end
  end

  @doc """
  Operator pre-execution cancellation.

  Accepts an intent id (UUID string) or an already-loaded
  `%AgentIntent{}`. Cancellation is allowed while the intent is in a
  pre-execution state; in-flight or already-terminal intents reject
  with `{:error, {:wrong_state, state}}`.

  `opts` is required to carry a `:reason` (string), which is persisted
  on the `intent.cancelled` audit event so replay records *why* the
  intent was withdrawn. `:actor_id` is optional and stamps the audit
  event when supplied.

  Allowed prior states: `:submitted`, `:evaluating`, `:decided`.

  Idempotency: re-cancelling an already-`:cancelled` intent returns
  `{:ok, :already_cancelled, intent}` without writing a new state
  transition or audit event. Any other terminal state
  (`:executed`, `:blocked`, `:expired`) and the in-flight `:executing`
  state reject with `{:error, {:wrong_state, state}}` — operators
  facing `:executing` must use the security-pause / revoke paths.

  Return shapes:

    * `{:ok, intent}` — newly cancelled.
    * `{:ok, :already_cancelled, intent}` — re-cancel of a
      `:cancelled` intent.
    * `{:error, :not_found}` — id did not resolve.
    * `{:error, {:wrong_state, state}}` — cancellation no longer
      makes sense.
    * `{:error, {:invalid, :reason_required}}` — `opts` missing the
      `:reason` string.
  """
  @spec cancel(AgentIntent.t() | String.t(), keyword()) ::
          {:ok, AgentIntent.t()}
          | {:ok, :already_cancelled, AgentIntent.t()}
          | {:error, :not_found}
          | {:error, {:wrong_state, atom()}}
          | {:error, {:invalid, :reason_required}}
  def cancel(id_or_intent, opts \\ [])

  def cancel(id, opts) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      :error ->
        {:error, :not_found}

      {:ok, uuid} ->
        case Repo.get(AgentIntent, uuid) do
          nil -> {:error, :not_found}
          %AgentIntent{} = intent -> cancel(intent, opts)
        end
    end
  end

  def cancel(%AgentIntent{} = intent, opts) when is_list(opts) do
    with {:ok, reason} <- require_cancel_reason(opts),
         {:ok, _state} <- check_cancellable(intent) do
      do_cancel(intent, reason, opts)
    else
      {:already_cancelled, intent} ->
        {:ok, :already_cancelled, preload_target(intent)}

      {:error, _} = err ->
        err
    end
  end

  defp require_cancel_reason(opts) do
    case Keyword.get(opts, :reason) do
      reason when is_binary(reason) and reason != "" ->
        {:ok, reason}

      _ ->
        {:error, {:invalid, :reason_required}}
    end
  end

  @cancel_allowed_states [:submitted, :evaluating, :decided]

  defp check_cancellable(%AgentIntent{state: state} = intent) do
    cond do
      state in @cancel_allowed_states -> {:ok, state}
      state == :cancelled -> {:already_cancelled, intent}
      true -> {:error, {:wrong_state, state}}
    end
  end

  defp do_cancel(%AgentIntent{} = intent, reason, opts) do
    prior_state = intent.state
    actor = Keyword.get(opts, :actor, :user)
    actor_id = Keyword.get(opts, :actor_id)

    audit_opts = [actor: actor]
    audit_opts = if actor_id, do: Keyword.put(audit_opts, :actor_id, actor_id), else: audit_opts

    multi =
      Multi.new()
      |> Multi.update(
        :intent,
        AgentIntent.current_pointer_changeset(intent, %{state: :cancelled})
      )
      |> Multi.run(:audit, fn _repo, %{intent: cancelled} ->
        attrs =
          cancelled
          |> AuditEvents.intent_state_changed(prior_state, :cancelled, audit_opts)
          |> Map.put(:event_type, "intent.cancelled")
          |> annotate_cancel_reason(reason)

        Audit.append_event(attrs)
      end)

    case Repo.transaction(multi) do
      {:ok, %{intent: cancelled, audit: event}} ->
        # Fan the persisted event out to the realtime audit stream the
        # same way `Bank.Runtime.emit_audit/1` does — the persistence
        # already happened atomically with the state update inside the
        # multi, so this call is just the broadcast step.
        Runtime.Notifier.audit_stream(event)
        {:ok, preload_target(cancelled)}

      {:error, :intent, %Ecto.Changeset{} = changeset, _} ->
        {:error, {:invalid, changeset}}

      {:error, :audit, audit_reason, _} ->
        {:error, {:invalid, {:audit_failed, audit_reason}}}
    end
  end

  defp annotate_cancel_reason(attrs, reason) do
    after_ref = Map.get(attrs, :after_ref) || %{}
    Map.put(attrs, :after_ref, Map.put(after_ref, :reason, reason))
  end

  # --- Simulation ---------------------------------------------------------

  @simulate_allowed_states [:submitted, :evaluating, :decided, :blocked]
  @simulate_supported_reasons ~w(pre_submit_dry_run refresh operator_inspection)

  @doc """
  Produce an on-demand `SimulationReport` for an intent.

  Reuses `Bank.Quotes.preview/2` for the dry-run output and
  `Bank.Decisions.simulation_attrs_from_preview/3` for the
  preview→attrs translation, so the report shape is identical to what
  `Bank.Decisions.evaluate_intent/2` writes during the live evaluation
  pipeline.

  ## Reason semantics

    * `"pre_submit_dry_run"` — produce a report (`current: false`)
      without touching the intent's `current_simulation_id`. Pure
      preview.
    * `"refresh"` — produce a report (`current: true`), demote the
      prior current simulation (if any), and update the intent's
      `current_simulation_id`. Inside one `Ecto.Multi`. Used to
      reset the active report decisioning reads.
    * `"operator_inspection"` — same shape as `pre_submit_dry_run`:
      `current: false`, no intent pointer change. The audit event
      records the operator's inspection trail; replay surfaces the
      report alongside the active one.

  In every case an `intent.cancelled`-style audit row is written
  (`simulation.requested` with the reason) so replay readers can
  reconstruct who asked, why, and whether the produced report became
  the active one.

  ## State guard

  Allowed source states: `:submitted`, `:evaluating`, `:decided`,
  `:blocked`. Anything else (`:executing`, `:executed`, `:cancelled`,
  `:expired`) returns `{:error, {:wrong_state, state}}` — there is no
  meaningful pre-flight simulation once execution is in flight or the
  intent is terminal.

  ## Returns

    * `{:ok, %{intent: intent, report: report, reason: reason,
      superseded: prior_or_nil, refreshed?: bool}}`
    * `{:error, :not_found}` — id did not resolve.
    * `{:error, {:wrong_state, state}}` — state guard.
    * `{:error, {:invalid_reason, reason}}` — `reason` not in the
      supported set.
    * `{:error, {:unsupported_chain, chain}}` — `Bank.Quotes.preview/2`
      rejected the chain at the boundary (e.g. not `"base"`).

  Idempotency: simulate is **not** idempotent — every call produces a
  fresh `SimulationReport` row. The OpenAPI body has no
  `idempotency_key` field for this reason; callers that need to dedupe
  must do so on their side.
  """
  @spec simulate(String.t() | AgentIntent.t(), String.t(), keyword()) ::
          {:ok,
           %{
             intent: AgentIntent.t(),
             report: SimulationReport.t(),
             reason: String.t(),
             superseded: SimulationReport.t() | nil,
             refreshed?: boolean()
           }}
          | {:error,
             :not_found
             | {:wrong_state, atom()}
             | {:invalid_reason, String.t() | nil}
             | {:unsupported_chain, String.t()}}
  def simulate(id_or_intent, reason, opts \\ [])

  def simulate(id, reason, opts) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      :error ->
        {:error, :not_found}

      {:ok, uuid} ->
        case Repo.get(AgentIntent, uuid) do
          nil -> {:error, :not_found}
          %AgentIntent{} = intent -> simulate(intent, reason, opts)
        end
    end
  end

  def simulate(%AgentIntent{} = intent, reason, opts) when is_list(opts) do
    with {:ok, validated_reason} <- validate_simulate_reason(reason),
         {:ok, _state} <- check_simulate_allowed(intent),
         {:ok, preview_result} <- run_preview(intent, opts) do
      do_simulate(intent, validated_reason, preview_result, opts)
    end
  end

  defp validate_simulate_reason(reason) when reason in @simulate_supported_reasons,
    do: {:ok, reason}

  defp validate_simulate_reason(reason), do: {:error, {:invalid_reason, reason}}

  defp check_simulate_allowed(%AgentIntent{state: state}) when state in @simulate_allowed_states,
    do: {:ok, state}

  defp check_simulate_allowed(%AgentIntent{state: state}), do: {:error, {:wrong_state, state}}

  defp run_preview(intent, opts) do
    case Quotes.preview(intent, opts) do
      {:ok, _preview} = ok ->
        {:ok, ok}

      {:error, {:unsupported, _msg}} ->
        {:error, {:unsupported_chain, intent.chain}}

      {:error, _other} = err ->
        # Provider unavailable / stale / simulation_failed are persisted
        # as a `:failed` SimulationReport row; replay records what we
        # asked for and what we got back.
        {:ok, err}
    end
  end

  @refresh_reason "refresh"

  defp do_simulate(intent, reason, preview_result, opts) do
    base_attrs =
      Decisions.simulation_attrs_from_preview(intent, preview_result)

    refreshed? = reason == @refresh_reason
    prior = if refreshed?, do: current_simulation_for(intent.id), else: nil

    sim_attrs =
      base_attrs
      |> Map.put(:current, refreshed?)
      |> Map.put(:supersedes_id, prior && prior.id)

    multi =
      Multi.new()
      |> maybe_demote_simulation(prior)
      |> Multi.insert(
        :report,
        SimulationReport.changeset(%SimulationReport{}, sim_attrs)
      )
      |> maybe_update_intent_pointer(intent, refreshed?)

    case Repo.transaction(multi) do
      {:ok, %{report: report} = changes} ->
        updated_intent = Map.get(changes, :intent, intent)
        emit_simulate_audits(report, reason, refreshed?, opts, intent.workspace_id)

        {:ok,
         %{
           intent: updated_intent,
           report: report,
           reason: reason,
           superseded: prior,
           refreshed?: refreshed?
         }}

      {:error, _step, reason_value, _changes} ->
        {:error, {:invalid, reason_value}}
    end
  end

  defp maybe_demote_simulation(multi, nil), do: multi

  defp maybe_demote_simulation(multi, %SimulationReport{} = prior) do
    Multi.update(multi, :demote_prior, SimulationReport.mark_not_current(prior))
  end

  defp maybe_update_intent_pointer(multi, _intent, false), do: multi

  defp maybe_update_intent_pointer(multi, intent, true) do
    Multi.update(multi, :intent, fn %{report: report} ->
      AgentIntent.current_pointer_changeset(intent, %{
        current_simulation_id: report.id
      })
    end)
  end

  defp current_simulation_for(intent_id) do
    Repo.one(
      from(s in SimulationReport,
        where: s.intent_id == ^intent_id and s.current == true,
        limit: 1
      )
    )
  end

  defp emit_simulate_audits(report, reason, refreshed?, opts, workspace_id) do
    audit_opts =
      [workspace_id: workspace_id]
      |> maybe_put_actor(opts)
      |> maybe_put_actor_id(opts)

    _ = Runtime.emit_audit(AuditEvents.simulation_requested(report, reason, audit_opts))

    if refreshed? do
      _ = Runtime.emit_audit(AuditEvents.simulation_produced(report, workspace_id: workspace_id))
    end

    :ok
  end

  defp maybe_put_actor(audit_opts, opts) do
    case Keyword.get(opts, :actor) do
      nil -> audit_opts
      actor -> Keyword.put(audit_opts, :actor, actor)
    end
  end

  defp maybe_put_actor_id(audit_opts, opts) do
    case Keyword.get(opts, :actor_id) do
      nil -> audit_opts
      actor_id -> Keyword.put(audit_opts, :actor_id, actor_id)
    end
  end

  @doc """
  Accept a freshly-submitted agent intent.

  `attrs` is the parsed `POST /v1/intents` body (string-keyed map). The
  facade normalises the body, computes a deterministic payload hash,
  enforces `(agent_id, idempotency_key)` idempotency, persists the
  `%AgentIntent{}` in `:submitted`, writes the `intent.submitted`
  audit event, and enqueues `EvaluateIntent` — all in a single
  `Ecto.Multi` so the four pieces stay consistent.

  Return shapes:

    * `{:ok, %{intent: intent, replay?: false}}` — first time we have
      seen this `(agent_id, idempotency_key)`.
    * `{:ok, %{intent: intent, replay?: true}}` — same `(agent_id,
      idempotency_key)` and a payload that hashes to the same value.
      No new row, no new audit event, no new job.
    * `{:error, {:idempotency_conflict, prior}}` — same key, different
      payload.
    * `{:error, {:unsupported_chain, chain}}` — `chain` was not `"base"`.
    * `{:error, {:unsupported_asset, asset}}` — `asset` was not `"USDC"`.
    * `{:error, {:invalid, reason}}` — caller supplied an unparseable
      shape (missing fields, bad amount, malformed UUID target,
      multiple/zero target keys); `reason` is a short atom or
      `%Ecto.Changeset{}`.

  This module is the only sanctioned write path for new intents.
  Callers must not insert `%AgentIntent{}` directly — doing so bypasses
  audit fan-out and the evaluation enqueue.
  """
  @spec submit(map(), keyword()) ::
          {:ok, %{intent: AgentIntent.t(), replay?: boolean()}}
          | {:error,
             {:idempotency_conflict, AgentIntent.t()}
             | {:unsupported_chain, String.t()}
             | {:unsupported_asset, String.t()}
             | :mainnet_disabled
             | :smart_account_not_found
             | :smart_account_chain_mismatch
             | :smart_account_required
             | {:invalid, term()}}
  def submit(attrs, opts \\ []) when is_map(attrs) do
    with {:ok, normalized} <- normalize(attrs) do
      normalized = stamp_workspace_id(normalized, opts)

      with :ok <-
             Bank.Chains.validate_mainnet_allowed(
               normalized.chain,
               Map.get(normalized, :workspace_id)
             ),
           :ok <- validate_smart_account(normalized) do
        case lookup_existing(normalized.agent_id, normalized.idempotency_key) do
          nil ->
            do_insert(normalized, opts)

          %AgentIntent{payload_hash: hash} = existing
          when hash == normalized.payload_hash ->
            {:ok, %{intent: preload_target(existing), replay?: true}}

          %AgentIntent{} = existing ->
            {:error, {:idempotency_conflict, existing}}
        end
      end
    end
  end

  # #184 / epic #167: enforce the explicit smart-account selector
  # contract.
  #
  #   * If `smart_account_id` is set, the row must belong to the
  #     intent's workspace AND its `chain` must match the intent's
  #     `chain`. A foreign-workspace id is indistinguishable from a
  #     non-existent one (404 semantics) so the runtime never leaks
  #     existence across workspaces.
  #   * If `smart_account_id` is nil, count the workspace's
  #     non-revoked smart accounts. Two-or-more is "ambiguous
  #     multi-account" and rejected; zero or one is the
  #     compatibility-mode auto-resolution path and allowed (the
  #     downstream executor still owns address selection from the
  #     single-account workspace's only row).
  #
  # Skipped entirely when `workspace_id` is nil — legacy un-scoped
  # callers cannot resolve the workspace row and predate this
  # contract; the schema FK still prevents inserting an unknown
  # smart_account_id.
  defp validate_smart_account(normalized) do
    case Map.get(normalized, :workspace_id) do
      nil ->
        :ok

      workspace_id ->
        case Map.get(normalized, :smart_account_id) do
          nil ->
            validate_no_ambiguous_account(workspace_id)

          smart_account_id when is_binary(smart_account_id) ->
            validate_explicit_account(smart_account_id, workspace_id, normalized.chain)
        end
    end
  end

  defp validate_explicit_account(smart_account_id, workspace_id, chain) do
    case SmartAccounts.get_in_workspace(smart_account_id, workspace_id) do
      {:ok, %SmartAccount{chain: ^chain}} ->
        :ok

      {:ok, %SmartAccount{}} ->
        {:error, :smart_account_chain_mismatch}

      {:error, :not_found} ->
        {:error, :smart_account_not_found}
    end
  end

  # `:revoked` is terminal for `smart_accounts.status`; everything
  # else (`:provisioning`, `:active`, `:inactive`) is a still-live
  # row the operator could legitimately target. Two-or-more such
  # rows means the runtime cannot guess an unambiguous default.
  @non_revoked_statuses [:provisioning, :active, :inactive]

  defp validate_no_ambiguous_account(workspace_id) do
    count =
      workspace_id
      |> SmartAccounts.list_for_workspace(status: @non_revoked_statuses, limit: 2)
      |> length()

    if count >= 2,
      do: {:error, :smart_account_required},
      else: :ok
  end

  # Caller-supplied `opts[:workspace_id]` is the only sanctioned
  # source of the workspace scope on an intent. `normalize/1` already
  # constructs the changeset attrs from a fixed field list (no
  # `"workspace_id"` is read from the JSON body), so this function
  # mainly defends against a future change that opens a body field.
  # Legacy callers that pass neither end up with `workspace_id: nil`.
  defp stamp_workspace_id(%{} = attrs, opts) do
    stripped = attrs |> Map.delete(:workspace_id) |> Map.delete("workspace_id")

    case Keyword.get(opts, :workspace_id) do
      nil -> stripped
      ws_id -> Map.put(stripped, :workspace_id, ws_id)
    end
  end

  defp do_insert(normalized, opts) do
    multi =
      Multi.new()
      |> Multi.insert(:intent, AgentIntent.changeset(%AgentIntent{}, normalized))
      |> Multi.run(:audit, fn _repo, %{intent: intent} ->
        intent
        |> AuditEvents.intent_submitted(audit_opts(opts))
        |> Audit.append_event()
      end)

    case Repo.transaction(multi) do
      {:ok, %{intent: intent}} ->
        case Runtime.enqueue_evaluation(intent.id) do
          {:ok, _job} ->
            {:ok, %{intent: preload_target(intent), replay?: false}}

          {:error, reason} ->
            {:error, {:invalid, {:enqueue_failed, reason}}}
        end

      {:error, :intent, %Ecto.Changeset{} = changeset, _} ->
        if idempotency_conflict?(changeset) do
          # The existence check above didn't see a row, but the unique
          # constraint did — concurrent submit raced us. Re-read so the
          # caller still gets the spec-shaped envelope.
          case lookup_existing(normalized.agent_id, normalized.idempotency_key) do
            %AgentIntent{payload_hash: hash} = existing
            when hash == normalized.payload_hash ->
              {:ok, %{intent: preload_target(existing), replay?: true}}

            %AgentIntent{} = existing ->
              {:error, {:idempotency_conflict, existing}}

            nil ->
              {:error, {:invalid, changeset}}
          end
        else
          {:error, {:invalid, changeset}}
        end

      {:error, :audit, reason, _} ->
        {:error, {:invalid, {:audit_failed, reason}}}
    end
  end

  defp idempotency_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:agent_id, {_msg, opts}} -> opts[:constraint] == :unique
      {:idempotency_key, {_msg, opts}} -> opts[:constraint] == :unique
      _ -> false
    end)
  end

  defp lookup_existing(agent_id, idempotency_key) do
    Repo.get_by(AgentIntent, agent_id: agent_id, idempotency_key: idempotency_key)
  end

  defp preload_target(%AgentIntent{} = intent) do
    Repo.preload(intent, [:target_counterparty, :target_address_label])
  end

  defp audit_opts(opts) do
    case Keyword.get(opts, :actor) do
      nil -> []
      actor -> [actor: actor]
    end
  end

  # --- normalisation ----------------------------------------------------

  @doc """
  Normalise a `POST /v1/intents` body into the attribute shape the
  `AgentIntent` changeset expects, validate the boundary invariants
  the runtime enforces today (`chain == "base"`, `asset == "USDC"`),
  and compute the deterministic `payload_hash`.

  Exposed for tests; the controller uses `submit/2`.
  """
  @spec normalize(map()) ::
          {:ok, map()}
          | {:error,
             {:unsupported_chain, String.t()}
             | {:unsupported_asset, String.t()}
             | {:invalid, atom()}}
  def normalize(attrs) when is_map(attrs) do
    with {:ok, agent_id} <- require_string(attrs, "agent_id"),
         {:ok, source} <- require_atom(attrs, "source", [:agent, :user, :runtime]),
         {:ok, idempotency_key} <- require_string(attrs, "idempotency_key"),
         {:ok, kind} <-
           require_atom(attrs, "kind", [:transfer, :swap, :scheduled_transfer]),
         {:ok, chain} <- require_chain(attrs),
         {:ok, asset} <- require_asset(attrs),
         {:ok, amount} <- require_amount(attrs),
         {:ok, target} <- normalise_target(Map.get(attrs, "target")),
         {:ok, smart_account_id} <- normalise_smart_account_id(attrs) do
      base = %{
        agent_id: agent_id,
        source: source,
        idempotency_key: idempotency_key,
        kind: kind,
        asset: asset,
        chain: chain,
        amount: amount,
        notes: optional_string(attrs, "notes"),
        submitted_at: DateTime.utc_now()
      }

      attrs_for_changeset =
        base
        |> Map.merge(target)
        |> maybe_put(:smart_account_id, smart_account_id)
        |> Map.put(:payload_hash, payload_hash(base, target, smart_account_id))

      {:ok, attrs_for_changeset}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Body keys are conventionally string-keyed at this layer (`require_*`
  # helpers all read string keys), but accept the atom key too so
  # tests and internal callers that hand-roll the attrs map don't have
  # to stringify just for one optional field.
  defp normalise_smart_account_id(attrs) do
    raw = Map.get(attrs, "smart_account_id") || Map.get(attrs, :smart_account_id)

    case string_or_nil(raw) do
      nil ->
        {:ok, nil}

      value ->
        if valid_uuid?(value),
          do: {:ok, value},
          else: {:error, {:invalid, :smart_account_id}}
    end
  end

  # Deterministic SHA-256 of the canonical body fields. Excludes
  # `submitted_at` and any header-derived value so retries hash
  # identically when the request body matches.
  defp payload_hash(base, target, smart_account_id) do
    canonical = %{
      "agent_id" => base.agent_id,
      "source" => Atom.to_string(base.source),
      "idempotency_key" => base.idempotency_key,
      "kind" => Atom.to_string(base.kind),
      "asset" => base.asset,
      "chain" => base.chain,
      "amount" => Decimal.to_string(base.amount, :normal),
      "notes" => base.notes,
      "target" => target_for_hash(target),
      "smart_account_id" => smart_account_id
    }

    :sha256
    |> :crypto.hash(Jason.encode!(canonical))
    |> Base.encode16(case: :lower)
  end

  defp target_for_hash(%{target_counterparty_id: cp_id} = t) when is_binary(cp_id) do
    %{
      "counterparty_id" => cp_id,
      "address_label_id" => Map.get(t, :target_address_label_id),
      "raw_address" => nil
    }
  end

  defp target_for_hash(%{target_raw_address: raw}) when is_binary(raw) do
    %{"counterparty_id" => nil, "address_label_id" => nil, "raw_address" => raw}
  end

  defp normalise_target(target) when is_map(target) do
    cp_id = string_or_nil(Map.get(target, "counterparty_id"))
    label_id = string_or_nil(Map.get(target, "address_label_id"))
    raw_address = string_or_nil(Map.get(target, "raw_address"))

    cond do
      cp_id && raw_address ->
        {:error, {:invalid, :target_ambiguous}}

      is_nil(cp_id) && is_nil(raw_address) ->
        {:error, {:invalid, :target_missing}}

      label_id && is_nil(cp_id) ->
        {:error, {:invalid, :target_label_without_counterparty}}

      cp_id && not valid_uuid?(cp_id) ->
        {:error, {:invalid, :target_counterparty_id}}

      label_id && not valid_uuid?(label_id) ->
        {:error, {:invalid, :target_address_label_id}}

      cp_id ->
        target = %{target_counterparty_id: cp_id}

        target =
          if label_id, do: Map.put(target, :target_address_label_id, label_id), else: target

        {:ok, target}

      true ->
        {:ok, %{target_raw_address: raw_address}}
    end
  end

  defp normalise_target(_), do: {:error, {:invalid, :target_missing}}

  defp valid_uuid?(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_), do: nil

  defp optional_string(attrs, key) do
    case Map.get(attrs, key) do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end

  defp require_string(attrs, key) do
    case Map.get(attrs, key) do
      v when is_binary(v) and v != "" -> {:ok, v}
      _ -> {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp require_atom(attrs, key, allowed) do
    case Map.get(attrs, key) do
      v when is_binary(v) ->
        atom = atom_from_allowed(v, allowed)

        if atom do
          {:ok, atom}
        else
          {:error, {:invalid, String.to_atom(key)}}
        end

      _ ->
        {:error, {:invalid, String.to_atom(key)}}
    end
  end

  defp atom_from_allowed(value, allowed) do
    Enum.find(allowed, fn atom -> Atom.to_string(atom) == value end)
  end

  defp require_chain(attrs) do
    case Map.get(attrs, "chain") do
      v when is_binary(v) and v != "" ->
        if v in @supported_chains, do: {:ok, v}, else: {:error, {:unsupported_chain, v}}

      _ ->
        {:error, {:invalid, :chain}}
    end
  end

  defp require_asset(attrs) do
    case Map.get(attrs, "asset") do
      v when is_binary(v) and v != "" ->
        if v in @supported_assets, do: {:ok, v}, else: {:error, {:unsupported_asset, v}}

      _ ->
        {:error, {:invalid, :asset}}
    end
  end

  defp require_amount(attrs) do
    case Map.get(attrs, "amount") do
      v when is_binary(v) and v != "" ->
        case Decimal.parse(v) do
          {decimal, ""} -> validate_positive(decimal)
          _ -> {:error, {:invalid, :amount}}
        end

      %Decimal{} = d ->
        validate_positive(d)

      _ ->
        {:error, {:invalid, :amount}}
    end
  end

  defp validate_positive(%Decimal{} = d) do
    if Decimal.compare(d, Decimal.new(0)) == :gt do
      {:ok, d}
    else
      {:error, {:invalid, :amount}}
    end
  end

  # --- private -----------------------------------------------------------

  defp clamp_limit(n) when is_integer(n) and n > 0, do: min(n, @max_limit)
  defp clamp_limit(_), do: @default_limit

  defp normalise_search(nil), do: nil
  defp normalise_search(""), do: nil

  defp normalise_search(term) when is_binary(term) do
    term
    |> String.trim()
    |> case do
      "" -> nil
      t -> t
    end
  end

  defp apply_state_filter(q, :all), do: q
  defp apply_state_filter(q, nil), do: q
  defp apply_state_filter(q, state) when is_atom(state), do: where(q, [i], i.state == ^state)

  # Optional workspace filter for #158b. Default `nil` keeps the
  # legacy "all workspaces" path open until every caller is migrated.
  defp scope_intent_to_workspace(q, nil), do: q

  defp scope_intent_to_workspace(q, workspace_id) when is_binary(workspace_id),
    do: where(q, [i], i.workspace_id == ^workspace_id)

  defp apply_kind_filter(q, :all), do: q
  defp apply_kind_filter(q, nil), do: q
  defp apply_kind_filter(q, kind) when is_atom(kind), do: where(q, [i], i.kind == ^kind)

  defp apply_search_filter(q, nil), do: q

  defp apply_search_filter(q, term) do
    pattern = "%" <> term <> "%"

    # id is a UUID field; cast explicitly so ILIKE matches on its textual
    # form. agent_id is already a string.
    where(
      q,
      [i],
      fragment("CAST(? AS text) ILIKE ?", i.id, ^pattern) or
        ilike(i.agent_id, ^pattern)
    )
  end
end
