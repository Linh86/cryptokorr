defmodule Bank.Audit do
  @moduledoc """
  Audit bounded context.

  Owns the `AuditEvent` append-only stream. Audit is a product feature,
  not a log: replay, explanation, and investigation all read from here.

  ## Public surface

      append_event(attrs)            # write one event
      append_events(list)            # write a batch atomically
      list_events(filters, opts)     # paged read for /v1/audit
      replay(intent_id)              # deterministic bundle for /v1/intents/:id/replay

  No mutation path is exposed. `AuditEvent` has no update changeset,
  the `audit_events` table has no `updated_at` column, and a DB
  trigger rejects any `UPDATE` or `DELETE` against the table
  (see migration `20260415170600_lock_audit_events.exs`). An accidental
  `Repo.update/1` on an event therefore fails loudly rather than
  silently corrupting the record.

  ## Correlation conventions

  Every state transition has a `correlation_id`. The conventions are:

    * **Intent-scoped events** — `correlation_id == intent_id`. This is
      the dominant case: every decision, simulation, approval, and
      execution event attached to an intent sets `correlation_id` to
      that intent's id. Replay reads the intent's events as the
      correlation-id slice.
    * **Counterparty / address-label admin events** — correlation_id
      is the counterparty id (or the label's owning counterparty id,
      never the label itself). This lets the operator tail a
      counterparty's history across all its labels.
    * **Policy admin events** — correlation_id is the rule's own id
      (the top of the supersession chain is not stable enough to
      correlate by). `subject_type` is `"policy_rule"`,
      `subject_id` is the same id.
    * **Runtime-global events** — `security.paused`, `security.resumed`,
      and similar have no natural correlation; they set
      `correlation_id` to `nil` and rely on `event_type` + `ts` for
      the read path.

  ## Event-type naming

  Event types are dotted, lowercase, `<object>.<verb>`, past tense
  where possible:

    * `intent.submitted`, `intent.cancelled`, `intent.state_changed`
    * `trust.assessed`, `simulation.produced`, `simulation.stale`
    * `decision.decided`, `decision.superseded`
    * `approval.granted`, `approval.rejected`, `approval.expired`
    * `execution.prepared`, `execution.broadcast`, `execution.confirmed`,
      `execution.reverted`, `execution.aborted`
    * `policy.created`, `policy.revised`, `policy.archived`
    * `counterparty.created`, `address_label.attached`,
      `trust_assertion.issued`, `evidence.attached`
    * `security.paused`, `security.resumed`, `delegation.revoked`

  Extending the vocabulary is a doc change, not a schema change — the
  column is a plain string.

  ## Payload hashing

  The hash stored in `payload_hash` is a sha256 of the canonical JSON
  encoding of the envelope's content fields (not the id and not
  `inserted_at`). See `Bank.Audit.Envelope` for the exact construction.
  That hash is the substrate for any later chain anchoring.

  ## What this context is NOT

  Not a general event bus. Not a search engine. Not an analytics
  pipeline. The `GET /v1/audit` surface is filter + page over a small
  set of fields; replay is a deterministic bundle. Aggregations and
  streaming live elsewhere.
  """

  import Ecto.Query

  alias Bank.Audit.{AuditEvent, Envelope}
  alias Bank.Decisions.{DecisionEnvelope, TrustAssessment, ExecutionPlan, SimulationReport}
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.PolicyRule
  alias Bank.Repo

  @default_page_limit 50
  @max_page_limit 500

  # --- Writer -----------------------------------------------------------

  @doc """
  Append a single audit event.

  Accepts a map or keyword list of envelope attrs (see
  `Bank.Audit.Envelope`). Returns `{:ok, %AuditEvent{}}` on success or
  an `{:error, ...}` tuple. Validation errors from the schema bubble
  up as `{:error, %Ecto.Changeset{}}`; missing required envelope
  fields surface as `{:error, {:missing_fields, [..]}}` before the
  insert is attempted.

  The writer is the only sanctioned way to get a row into
  `audit_events`. It is safe to call inside a `Ecto.Multi`.

  ## Options

    * `:dedupe` — when set to `:recurring_window`, the insert switches
      to `INSERT ... ON CONFLICT DO NOTHING` keyed on the partial
      unique index `audit_events_recurring_dedupe_idx`. Used by the
      `ScanStuckPlans` and `AggregateAPIKeyUsage` workers (audit M8)
      so two emitters in the same window collapse to one row at the
      SQL layer instead of relying on Oban queue concurrency. On
      conflict the call returns `{:ok, :already_exists}` rather than
      `{:ok, %AuditEvent{}}` so callers can tell the row is not new.
      Use only on event types covered by the index
      (`ops.stuck_plan_detected`, `api_key.used`); other event types
      ignore the option silently and behave as a regular insert
      (the partial index simply does not match them).
  """
  @spec append_event(map() | keyword(), keyword()) ::
          {:ok, AuditEvent.t()}
          | {:ok, :already_exists}
          | {:error, Ecto.Changeset.t()}
          | {:error, {:missing_fields, [atom()]}}
  def append_event(attrs, opts \\ []) do
    with {:ok, normalised} <- Envelope.build(attrs) do
      changeset =
        %AuditEvent{}
        |> AuditEvent.changeset(normalised)

      case Keyword.get(opts, :dedupe) do
        :recurring_window ->
          dedupe_recurring_window(changeset)

        nil ->
          Repo.insert(changeset)
      end
    end
  end

  # `INSERT ... ON CONFLICT (subject_id, after_ref->>'window_start')
  # WHERE event_type IN (...) DO NOTHING` keyed on the partial unique
  # index `audit_events_recurring_dedupe_idx`. The conflict target is
  # the index expression — Postgres requires it to match the partial
  # index exactly, including the WHERE predicate, which is why we
  # cannot simply pass `[:subject_id, ...]`.
  #
  # Implementation note: `Repo.insert/2` with `on_conflict: :nothing`
  # returns `{:ok, struct}` regardless of whether the row was actually
  # written or skipped — Ecto reports back the schema with the
  # client-generated id either way. To distinguish the two cases we
  # drop to `Repo.insert_all/3`, which returns `{affected_count, _}`
  # so the zero-affected-rows case is observable.
  defp dedupe_recurring_window(%Ecto.Changeset{valid?: false} = changeset) do
    {:error, %{changeset | action: :insert}}
  end

  defp dedupe_recurring_window(%Ecto.Changeset{} = changeset) do
    row = changeset_to_insert_row(changeset)

    result =
      Repo.insert_all(AuditEvent, [row],
        on_conflict: :nothing,
        conflict_target:
          {:unsafe_fragment,
           ~s|(subject_id, (after_ref->>'window_start')) WHERE event_type IN ('ops.stuck_plan_detected', 'api_key.used')|},
        returning: true
      )

    case result do
      {1, [%AuditEvent{} = event]} -> {:ok, event}
      {0, _} -> {:ok, :already_exists}
    end
  end

  # `Repo.insert_all/3` wants a flat map. Pull the applied changes
  # from the changeset and add the fields `Repo.insert/1` would
  # ordinarily fill in: an autogenerated primary key (the schema sets
  # `autogenerate: true`, but that runs only during `Repo.insert/1`)
  # and `inserted_at` (the table is insert-only and has no
  # `updated_at`).
  defp changeset_to_insert_row(%Ecto.Changeset{} = cs) do
    struct = Ecto.Changeset.apply_changes(cs)
    fields = AuditEvent.__schema__(:fields)
    now = DateTime.utc_now()

    fields
    |> Map.new(fn field -> {field, Map.get(struct, field)} end)
    |> put_if_nil(:id, Ecto.UUID.generate())
    |> put_if_nil(:inserted_at, now)
    |> put_if_nil(:ts, now)
  end

  defp put_if_nil(map, key, value) do
    case Map.get(map, key) do
      nil -> Map.put(map, key, value)
      _ -> map
    end
  end

  @doc """
  Append multiple events atomically. All-or-nothing: if any event
  fails to build or insert, the transaction rolls back and no rows
  are written.
  """
  @spec append_events([map() | keyword()]) ::
          {:ok, [AuditEvent.t()]}
          | {:error, term()}
  def append_events(events) when is_list(events) do
    Repo.transaction(fn ->
      Enum.map(events, fn attrs ->
        case append_event(attrs) do
          {:ok, event} -> event
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end)
  end

  # --- Query ------------------------------------------------------------

  @doc """
  List audit events matching the supplied filters.

  ## Filters

  All are optional; when multiple are supplied, the conjunction is
  applied.

    * `:correlation_id` — uuid; returns every event for a given trace
      (typically an intent id).
    * `:subject_type` — string (`"agent_intent"`, `"decision_envelope"`,
      ...).
    * `:subject_id` — string (uuid for domain rows, opaque id for
      smart accounts / on-chain subjects).
    * `:event_type` — string. Exact match; no wildcard in v1.
    * `:actor` — atom (`:user` | `:agent` | `:runtime` | `:adapter`).
    * `:from`, `:to` — `DateTime`s (inclusive); bound `ts`.
    * `:workspace_id` — uuid; narrow to one workspace's audit slice
      (#158b read hint). Existing rows with `workspace_id IS NULL`
      are *not* matched. Default `nil` keeps the legacy "all
      workspaces" path open.

  ## Options

    * `:limit` — default #{@default_page_limit}, capped at
      #{@max_page_limit}.
    * `:cursor` — opaque cursor from a prior page; see `cursor/1`.
    * `:order` — `:asc` (default, oldest first) or `:desc` (newest
      first). Ties on `ts` break on `id` for determinism.

  Returns `%{events: [...], next_cursor: binary() | nil}`. When
  `next_cursor` is `nil`, the last page has been read.
  """
  @spec list_events(map() | keyword(), keyword()) :: %{
          events: [AuditEvent.t()],
          next_cursor: String.t() | nil
        }
  def list_events(filters \\ %{}, opts \\ []) do
    filters = to_map(filters)
    limit = opts |> Keyword.get(:limit, @default_page_limit) |> clamp_limit()
    order = Keyword.get(opts, :order, :asc)

    base =
      AuditEvent
      |> apply_filters(filters)
      |> apply_order(order)

    base =
      case Keyword.get(opts, :cursor) do
        nil -> base
        cursor -> apply_cursor(base, cursor, order)
      end

    # Pull one extra row so we can tell whether another page exists.
    rows = base |> limit(^(limit + 1)) |> Repo.all()

    {page, has_more?} =
      case rows do
        rows when length(rows) > limit -> {Enum.take(rows, limit), true}
        rows -> {rows, false}
      end

    next_cursor =
      case {has_more?, List.last(page)} do
        {true, %AuditEvent{} = last} -> cursor(last)
        _ -> nil
      end

    %{events: page, next_cursor: next_cursor}
  end

  @doc """
  Encode an audit event's `(ts, id)` tuple as an opaque cursor string.
  """
  @spec cursor(AuditEvent.t()) :: String.t()
  def cursor(%AuditEvent{ts: ts, id: id}) do
    %{"ts" => DateTime.to_iso8601(ts), "id" => id}
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  @doc """
  Decode an opaque cursor back into `{ts, id}` (or return an error).
  Exposed mainly so the controller can translate decode failures into
  `422`s.
  """
  @spec decode_cursor(String.t()) :: {:ok, {DateTime.t(), Ecto.UUID.t()}} | :error
  def decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, raw} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"ts" => ts_str, "id" => id}} <- Jason.decode(raw),
         {:ok, ts, _} <- DateTime.from_iso8601(ts_str) do
      {:ok, {ts, id}}
    else
      _ -> :error
    end
  end

  def decode_cursor(_), do: :error

  # --- Replay -----------------------------------------------------------

  @doc """
  Assemble the replay bundle for an intent.

  Returns `{:ok, bundle}` or `{:error, :not_found}` if no intent with
  `intent_id` exists. The bundle is built entirely from persisted rows
  — no business logic is re-run. The cached `current_*_id` pointers on
  `agent_intents` are ignored in favour of the child tables and their
  supersession chains, which are the authoritative history.

  The returned structure:

      %{
        intent: %AgentIntent{},
        policy_snapshot: [%PolicyRule{}, ...],      # union of all
                                                     # snapshot_rule_ids
                                                     # captured across
                                                     # every decision
        trust_assessments: [%TrustAssessment{}, ...],        # oldest first
        simulations: [%SimulationReport{}, ...],    # oldest first
        decisions: [%DecisionEnvelope{}, ...],      # oldest first
        plans: [%ExecutionPlan{}, ...],             # oldest first
        audit: [%AuditEvent{}, ...],                # oldest first
        stablecoin_route_evidence: [%{}, ...],      # route evaluations captured in audit
        swap_route_evidence: [%{}, ...]             # one map per swap plan: route inputs + receipt + outcome
      }

  All children are ordered deterministically by `(inserted_at, id)`.
  The audit slice pulls events whose `correlation_id` equals the
  intent id, ordered `(ts, id)`.
  """
  @spec replay(Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def replay(intent_id) do
    case Repo.get(AgentIntent, intent_id) do
      nil ->
        {:error, :not_found}

      %AgentIntent{} = intent ->
        {:ok, build_replay_bundle(intent)}
    end
  end

  defp build_replay_bundle(intent) do
    # Each child collection orders by the domain timestamp that
    # semantically describes "when this happened in the world"
    # (generated_at, decided_at) rather than the DB-write clock. The
    # id tiebreak is still needed because timestamps can collide at
    # microsecond precision. ExecutionPlan has no domain timestamp so
    # it falls back to (inserted_at, id).
    decisions =
      DecisionEnvelope
      |> where([d], d.intent_id == ^intent.id)
      |> order_by([d], asc: d.decided_at, asc: d.id)
      |> Repo.all()

    claims =
      TrustAssessment
      |> where([c], c.intent_id == ^intent.id)
      |> order_by([c], asc: c.generated_at, asc: c.id)
      |> Repo.all()

    simulations =
      SimulationReport
      |> where([s], s.intent_id == ^intent.id)
      |> order_by([s], asc: s.generated_at, asc: s.id)
      |> Repo.all()

    plans =
      ExecutionPlan
      |> where([p], p.intent_id == ^intent.id)
      |> order_by([p], asc: p.inserted_at, asc: p.id)
      |> Repo.all()

    policy_rules = load_policy_snapshot(decisions)

    audit =
      AuditEvent
      |> where([e], e.correlation_id == ^intent.id)
      |> order_by([e], asc: e.ts, asc: e.id)
      |> Repo.all()

    %{
      intent: intent,
      policy_snapshot: policy_rules,
      trust_assessments: claims,
      simulations: simulations,
      decisions: decisions,
      plans: plans,
      audit: audit,
      screening_evidence: Bank.WalletScreening.Evidence.for_intent(intent),
      stablecoin_route_evidence: stablecoin_route_evidence(audit),
      morpho_evidence: morpho_evidence(audit),
      swap_route_evidence: swap_route_evidence(plans),
      matched_activities: Bank.Activity.Reconciliation.match_for_plans(plans)
    }
  end

  # One map per swap execution plan, pre-joining the persisted #190
  # route inputs (carried on `plan.steps`) with the runtime outcome
  # (status / final_outcome / final_reason) and the #193 receipt
  # columns (block_number / actual_output_amount / tx_refs). Replay
  # readers can render "swap N: route X dispatched, expected Y, got
  # Z, status confirmed" without re-walking the audit log or
  # dereferencing the steps blob themselves.
  #
  # Calldata, spender, swap_target_contract, source/destination
  # token addresses, and value are intentionally NOT in this
  # projection — they're operational inputs the dispatch needs but
  # not "evidence" a reviewer needs to read. They remain on
  # `plan.steps` for callers that want them.
  defp swap_route_evidence(plans) do
    plans
    |> Enum.filter(fn
      %ExecutionPlan{steps: %{"kind" => "swap"}} -> true
      _ -> false
    end)
    |> Enum.map(&swap_evidence_for_plan/1)
  end

  defp swap_evidence_for_plan(%ExecutionPlan{steps: steps} = plan) do
    %{
      plan_id: plan.id,
      decision_id: plan.decision_id,
      chain: plan.chain,
      route_hash: Map.get(steps, "route_hash"),
      route_provider: Map.get(steps, "route_provider"),
      source_asset: Map.get(steps, "source_asset"),
      destination_asset: Map.get(steps, "destination_asset"),
      input_amount: Map.get(steps, "input_amount"),
      expected_output_amount: Map.get(steps, "expected_output_amount"),
      minimum_output_amount: Map.get(steps, "minimum_output_amount"),
      slippage_bps: Map.get(steps, "slippage_bps"),
      deadline: Map.get(steps, "deadline"),
      quote_timestamp: Map.get(steps, "quote_timestamp"),
      execution_status: plan.execution_status,
      final_outcome: plan.final_outcome,
      final_reason: plan.final_reason,
      block_number: plan.block_number,
      actual_output_amount: swap_decimal_string(plan.actual_output_amount),
      tx_refs: plan.tx_refs || [],
      active: plan.active
    }
  end

  defp swap_decimal_string(nil), do: nil

  defp swap_decimal_string(%Decimal{} = d),
    do: d |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp swap_decimal_string(other), do: other

  defp stablecoin_route_evidence(events) do
    events
    |> Enum.filter(&(&1.event_type == "stablecoin.route_evaluated"))
    |> Enum.map(fn event ->
      event.after_ref["stablecoin_route"] ||
        event.after_ref[:stablecoin_route] ||
        event.after_ref
    end)
  end

  # Filtered, ordered slice of Morpho-specific audit rows for the
  # intent (#208). Carries `event_type`, `subject_*`, `ts`, and the
  # event's `after_ref` so replay readers can render a Morpho
  # narrative (risk_explained → snapshot_stale → policy_blocked) in
  # `(ts, id)` order without re-walking the full audit list.
  # Execution-side events (`morpho.deposit_*`, `morpho.withdraw_*`)
  # are gated on #206/#207 and will land here automatically once
  # those issues emit them under the same `morpho.` prefix.
  defp morpho_evidence(events) do
    events
    |> Enum.filter(&morpho_event?/1)
    |> Enum.map(fn event ->
      %{
        event_type: event.event_type,
        subject_type: event.subject_type,
        subject_id: event.subject_id,
        ts: event.ts,
        after_ref: event.after_ref
      }
    end)
  end

  defp morpho_event?(%{event_type: "morpho." <> _}), do: true
  defp morpho_event?(_), do: false

  # Union of every rule uuid captured in every decision's policy
  # snapshot, resolved to full PolicyRule rows. Order is by insertion
  # so replay readers see the historical snapshot in creation order.
  defp load_policy_snapshot(decisions) do
    rule_ids =
      decisions
      |> Enum.flat_map(&DecisionEnvelope.snapshot_rule_ids/1)
      |> Enum.uniq()

    case rule_ids do
      [] ->
        []

      ids ->
        PolicyRule
        |> where([r], r.id in ^ids)
        |> order_by([r], asc: r.inserted_at, asc: r.id)
        |> Repo.all()
    end
  end

  # --- Query plumbing ----------------------------------------------------

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:correlation_id, nil}, q -> q
      {:correlation_id, id}, q -> where(q, [e], e.correlation_id == ^id)
      {:subject_type, nil}, q -> q
      {:subject_type, t}, q -> where(q, [e], e.subject_type == ^t)
      {:subject_id, nil}, q -> q
      {:subject_id, id}, q -> where(q, [e], e.subject_id == ^id)
      {:event_type, nil}, q -> q
      {:event_type, t}, q -> where(q, [e], e.event_type == ^t)
      {:from, nil}, q -> q
      {:from, %DateTime{} = ts}, q -> where(q, [e], e.ts >= ^ts)
      {:to, nil}, q -> q
      {:to, %DateTime{} = ts}, q -> where(q, [e], e.ts <= ^ts)
      {:actor, nil}, q -> q
      {:actor, actor}, q when is_atom(actor) -> where(q, [e], e.actor == ^actor)
      {:workspace_id, nil}, q -> q
      {:workspace_id, id}, q when is_binary(id) -> where(q, [e], e.workspace_id == ^id)
      {_unknown, _}, q -> q
    end)
  end

  defp apply_order(query, :asc), do: order_by(query, [e], asc: e.ts, asc: e.id)
  defp apply_order(query, :desc), do: order_by(query, [e], desc: e.ts, desc: e.id)

  defp apply_cursor(query, cursor, order) do
    case decode_cursor(cursor) do
      {:ok, {ts, id}} -> apply_cursor_filter(query, ts, id, order)
      :error -> query
    end
  end

  defp apply_cursor_filter(query, ts, id, :asc) do
    where(query, [e], {e.ts, e.id} > {^ts, ^id})
  end

  defp apply_cursor_filter(query, ts, id, :desc) do
    where(query, [e], {e.ts, e.id} < {^ts, ^id})
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0 do
    min(limit, @max_page_limit)
  end

  defp clamp_limit(_), do: @default_page_limit

  defp to_map(filters) when is_map(filters), do: filters
  defp to_map(filters) when is_list(filters), do: Map.new(filters)
end
