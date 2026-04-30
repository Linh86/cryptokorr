defmodule Bank.Workspaces.Backfill do
  @moduledoc """
  Idempotent, cursor-batched backfill of `workspace_id` on rows
  created before workspace scoping landed (#158a–c). Used to clean
  the legacy NULL tail in `audit_events` and `delegations` (#158d-d)
  and any other #158 nullable workspace columns whose value can be
  safely derived from existing FK chains.

  ## Tables and derivation strategy

  | Table             | Source                                                                |
  |-------------------|-----------------------------------------------------------------------|
  | `delegations`     | latest `execution_plans` with same `smart_account_id` and `workspace_id` set |
  | `execution_plans` | `agent_intents.workspace_id` via `intent_id`                          |
  | `audit_events`    | the row at `(subject_type, subject_id)`; derived subject types take one extra hop to the intent |

  Anchor tables (`agent_intents`, `counterparties`, `policy_rules`)
  are intentionally out of scope — they have no FK chain that lets us
  derive a workspace_id without inventing one. Filling them is the
  job of a future pass that picks a default workspace per
  installation, NOT a mechanical derivation.

  ## Safety

    * Idempotent — only touches rows where `workspace_id IS NULL`.
    * Cursor-batched — paginates by `id ASC` with `LIMIT batch_size`,
      so the UPDATE never holds a long lock and a crashed run can be
      resumed by re-invoking.
    * Transactional per batch.
    * Dry-run by default — `apply?: true` is required to actually
      write. Tests and operators run dry-run first to see counts.
    * No deletes, no NOT NULL flips, no index changes.

  ## Skip semantics

  When the parent row is missing or its own `workspace_id` is NULL,
  we leave the target row's `workspace_id` NULL and count the row as
  skipped (with a reason). The caller decides whether to re-run after
  the parent is filled.
  """

  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Counterparties.{AddressLabel, Counterparty}
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan, SimulationReport, TrustAssessment}
  alias Bank.Delegations.Delegation
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.PolicyRule
  alias Bank.Repo
  alias Bank.Workspaces.Membership

  @default_batch_size 1000

  @type stats :: %{
          required(:table) => atom(),
          required(:scanned) => non_neg_integer(),
          required(:updated) => non_neg_integer(),
          required(:skipped) => non_neg_integer(),
          required(:apply?) => boolean(),
          required(:by_subject_type) => %{optional(String.t()) => map()},
          required(:skip_reasons) => %{optional(atom()) => non_neg_integer()}
        }

  @tables [:delegations, :execution_plans, :audit_events]

  @doc """
  Tables this backfiller knows how to derive. Order matters when
  running all of them in one pass: `execution_plans` should run
  before `delegations` and `audit_events` so transitively-derived
  targets see the freshly-filled parents.
  """
  @spec tables() :: [atom()]
  def tables, do: @tables

  @doc """
  Run backfill for one table.

  Options:
    * `:apply?` (default `false`) — when `false`, count what would
      change but write nothing. Set `true` to actually update.
    * `:batch_size` (default 1000) — rows fetched/updated per page.
    * `:limit` — total cap on rows scanned across all batches.
      Default `nil` (no cap).
  """
  @spec run(atom(), keyword()) :: {:ok, stats()} | {:error, term()}
  def run(table, opts \\ [])

  def run(table, opts) when table in @tables do
    apply? = Keyword.get(opts, :apply?, false)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    limit = Keyword.get(opts, :limit)

    state = %{
      table: table,
      scanned: 0,
      updated: 0,
      skipped: 0,
      apply?: apply?,
      by_subject_type: %{},
      skip_reasons: %{}
    }

    {:ok, loop(table, nil, batch_size, limit, state)}
  end

  def run(table, _opts), do: {:error, {:unknown_table, table}}

  # Cursor-batched loop. Pulls one page of NULL-workspace rows
  # ordered by id, derives a workspace_id for each, and either writes
  # or counts. Uses `id > cursor` for pagination so OFFSET cost stays
  # at zero even on large tables.
  defp loop(_table, _cursor, _batch_size, limit, %{scanned: scanned} = state)
       when is_integer(limit) and scanned >= limit,
       do: state

  defp loop(table, cursor, batch_size, limit, state) do
    remaining =
      case limit do
        nil -> batch_size
        n -> min(batch_size, n - state.scanned)
      end

    rows = fetch_batch(table, cursor, remaining)

    case rows do
      [] ->
        state

      _ ->
        new_state = process_batch(table, rows, state)
        last_id = List.last(rows).id
        loop(table, last_id, batch_size, limit, new_state)
    end
  end

  defp process_batch(table, rows, state) do
    Repo.transaction(fn ->
      maybe_arm_audit_bypass(table, state)
      new_state = Enum.reduce(rows, state, &derive_and_update(table, &1, &2))
      maybe_disarm_audit_bypass(table, state)
      new_state
    end)
    |> case do
      {:ok, new_state} -> new_state
      {:error, _reason} -> state
    end
  end

  # `audit_events` carries a SQL-level append-only trigger (see
  # `priv/repo/migrations/20260415170600_lock_audit_events.exs`).
  # The trigger's relaxed branch (#158d-d migration
  # `20260430140000_allow_audit_workspace_backfill`) lets a
  # workspace_id-only UPDATE through iff the session-local setting
  # `bank.audit_workspace_backfill` is `'on'`. We arm it per batch
  # with `SET LOCAL` (transaction-scoped) and explicitly disarm at
  # the end of the work block. In production `SET LOCAL` already
  # clears at `COMMIT`; the disarm is belt-and-suspenders. In test
  # (Ecto.Sandbox) the `Repo.transaction` is a savepoint inside the
  # test's outer transaction, so committing the savepoint does NOT
  # clear `SET LOCAL` — the explicit disarm closes that gap so the
  # flag never bleeds across tests or back to the calling context.
  # On failure the savepoint rolls back and `SET LOCAL` reverts
  # automatically, so no try/after is needed.
  defp maybe_arm_audit_bypass(:audit_events, %{apply?: true}) do
    Repo.query!("SET LOCAL bank.audit_workspace_backfill = 'on'")
  end

  defp maybe_arm_audit_bypass(_table, _state), do: :ok

  defp maybe_disarm_audit_bypass(:audit_events, %{apply?: true}) do
    Repo.query!("SET LOCAL bank.audit_workspace_backfill = 'off'")
  end

  defp maybe_disarm_audit_bypass(_table, _state), do: :ok

  defp derive_and_update(table, row, state) do
    state = %{state | scanned: state.scanned + 1}
    state = bump_subject_count(state, table, row, :scanned)

    case derive(table, row) do
      {:ok, workspace_id} when is_binary(workspace_id) ->
        state = %{state | updated: state.updated + 1}
        state = bump_subject_count(state, table, row, :updated)

        if state.apply? do
          do_update(table, row.id, workspace_id)
        end

        state

      {:skip, reason} ->
        state = %{state | skipped: state.skipped + 1}
        state = bump_subject_count(state, table, row, :skipped)
        bump_skip_reason(state, reason)
    end
  end

  defp bump_subject_count(state, :audit_events, %{subject_type: subject_type}, key) do
    bucket = Map.get(state.by_subject_type, subject_type, %{scanned: 0, updated: 0, skipped: 0})
    bucket = Map.update!(bucket, key, &(&1 + 1))
    %{state | by_subject_type: Map.put(state.by_subject_type, subject_type, bucket)}
  end

  defp bump_subject_count(state, _table, _row, _key), do: state

  defp bump_skip_reason(state, reason) do
    %{state | skip_reasons: Map.update(state.skip_reasons, reason, 1, &(&1 + 1))}
  end

  # --- per-table fetch + update -----------------------------------------

  defp fetch_batch(:delegations, cursor, n) do
    Delegation
    |> select([d], %{id: d.id, smart_account_id: d.smart_account_id})
    |> where([d], is_nil(d.workspace_id))
    |> apply_cursor(cursor)
    |> order_by([d], asc: d.id)
    |> limit(^n)
    |> Repo.all()
  end

  defp fetch_batch(:execution_plans, cursor, n) do
    ExecutionPlan
    |> select([p], %{id: p.id, intent_id: p.intent_id})
    |> where([p], is_nil(p.workspace_id))
    |> apply_cursor(cursor)
    |> order_by([p], asc: p.id)
    |> limit(^n)
    |> Repo.all()
  end

  defp fetch_batch(:audit_events, cursor, n) do
    AuditEvent
    |> select([e], %{id: e.id, subject_type: e.subject_type, subject_id: e.subject_id})
    |> where([e], is_nil(e.workspace_id))
    |> apply_cursor(cursor)
    |> order_by([e], asc: e.id)
    |> limit(^n)
    |> Repo.all()
  end

  defp apply_cursor(query, nil), do: query
  defp apply_cursor(query, cursor), do: where(query, [r], r.id > ^cursor)

  defp do_update(:delegations, id, workspace_id) do
    Delegation
    |> where([d], d.id == ^id)
    |> Repo.update_all(set: [workspace_id: workspace_id])
  end

  defp do_update(:execution_plans, id, workspace_id) do
    ExecutionPlan
    |> where([p], p.id == ^id)
    |> Repo.update_all(set: [workspace_id: workspace_id])
  end

  defp do_update(:audit_events, id, workspace_id) do
    AuditEvent
    |> where([e], e.id == ^id)
    |> Repo.update_all(set: [workspace_id: workspace_id])
  end

  # --- per-table derivation ---------------------------------------------

  # `delegations.workspace_id` ←
  #   most recent `execution_plans.workspace_id` for the same
  #   `smart_account_id`. Plans are written runtime-side under #158d
  #   with workspace_id set; legacy plans stay NULL and the lookup
  #   simply finds none.
  defp derive(:delegations, %{smart_account_id: nil}), do: {:skip, :no_smart_account_id}

  defp derive(:delegations, %{smart_account_id: sa_id}) do
    workspace_id =
      ExecutionPlan
      |> where([p], p.smart_account_id == ^sa_id and not is_nil(p.workspace_id))
      |> order_by([p], desc: p.inserted_at)
      |> limit(1)
      |> select([p], p.workspace_id)
      |> Repo.one()

    case workspace_id do
      nil -> {:skip, :no_plan_with_workspace}
      id -> {:ok, id}
    end
  end

  # `execution_plans.workspace_id` ← intent.workspace_id via intent_id.
  defp derive(:execution_plans, %{intent_id: nil}), do: {:skip, :no_intent_id}

  defp derive(:execution_plans, %{intent_id: intent_id}) do
    # Select id alongside workspace_id so we can tell "intent not
    # found" apart from "intent found, workspace_id is NULL".
    case Repo.one(
           from i in AgentIntent,
             where: i.id == ^intent_id,
             select: {i.id, i.workspace_id}
         ) do
      nil -> {:skip, :intent_not_found}
      {_id, ws_id} when is_binary(ws_id) -> {:ok, ws_id}
      {_id, nil} -> {:skip, :intent_workspace_nil}
    end
  end

  # `audit_events.workspace_id` ← dispatched on subject_type.
  # Direct subject types (own workspace_id column on the parent
  # table): copy it. Derived subject types (FK chain through intent):
  # one extra hop. Workspace-blind subject types (`user`, `agent`,
  # `smart_account`): always skip.
  defp derive(:audit_events, %{subject_type: subject_type, subject_id: subject_id}) do
    do_derive_audit(subject_type, subject_id)
  end

  defp do_derive_audit(_subject_type, nil), do: {:skip, :no_subject_id}

  defp do_derive_audit(subject_type, subject_id)
       when subject_type in [
              "agent_intent",
              "delegation",
              "execution_plan",
              "counterparty",
              "policy_rule",
              "membership",
              "access_invite"
            ] do
    schema = direct_subject_schema(subject_type)
    lookup_workspace_id(schema, subject_id)
  end

  defp do_derive_audit(subject_type, subject_id)
       when subject_type in ["trust_assessment", "simulation_report", "decision_envelope"] do
    schema = derived_subject_schema(subject_type)

    case Repo.one(from r in schema, where: r.id == ^subject_id, select: r.intent_id) do
      nil -> {:skip, :subject_not_found}
      intent_id -> lookup_workspace_id(AgentIntent, intent_id)
    end
  end

  defp do_derive_audit("address_label", subject_id) do
    case Repo.one(
           from l in AddressLabel,
             where: l.id == ^subject_id,
             select: l.counterparty_id
         ) do
      nil -> {:skip, :subject_not_found}
      cp_id -> lookup_workspace_id(Counterparty, cp_id)
    end
  end

  defp do_derive_audit("user", _id), do: {:skip, :workspace_blind_subject}
  defp do_derive_audit("agent", _id), do: {:skip, :workspace_blind_subject}
  defp do_derive_audit("smart_account", _id), do: {:skip, :workspace_blind_subject}
  defp do_derive_audit(_unknown, _id), do: {:skip, :unknown_subject_type}

  defp direct_subject_schema("agent_intent"), do: AgentIntent
  defp direct_subject_schema("delegation"), do: Delegation
  defp direct_subject_schema("execution_plan"), do: ExecutionPlan
  defp direct_subject_schema("counterparty"), do: Counterparty
  defp direct_subject_schema("policy_rule"), do: PolicyRule
  defp direct_subject_schema("membership"), do: Membership
  defp direct_subject_schema("access_invite"), do: Bank.Access.AccessInvite

  defp derived_subject_schema("trust_assessment"), do: TrustAssessment
  defp derived_subject_schema("simulation_report"), do: SimulationReport
  defp derived_subject_schema("decision_envelope"), do: DecisionEnvelope

  defp lookup_workspace_id(schema, id) do
    case Repo.one(from r in schema, where: r.id == ^id, select: {r.id, r.workspace_id}) do
      nil -> {:skip, :subject_not_found}
      {_id, ws_id} when is_binary(ws_id) -> {:ok, ws_id}
      {_id, nil} -> {:skip, :subject_workspace_nil}
    end
  end
end
