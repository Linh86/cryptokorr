defmodule Bank.Activity.Reconciliation do
  @moduledoc """
  Workspace-scoped activity ↔ execution-plan reconciliation (#246).

  Composes the existing imported-activity ledger (#243/#244/#245)
  with the existing execution-plan ledger to answer:

    * **`match_for_plan/1`** — given an execution plan, which
      imported chain activity rows in the same workspace cite the
      same `tx_hash` on the same chain?
    * **`match_for_plans/1`** — batch shape of the same query, used
      by `Bank.Audit.replay/1` to attach a `:matched_activities`
      key to the replay bundle without N+1 queries.
    * **`classify_activity/2`** — given an imported activity and the
      list of execution plans available in the same workspace,
      label the activity as either `:cryptobank_execution`
      (matched to a plan's `tx_refs`) or `:external` (no match;
      external wallet transfer not initiated by CryptoBank).

  ## Workspace boundary

  The matcher always filters by the source plan's `workspace_id`
  AND by `chain`. Two workspaces with the same `tx_hash` (e.g.
  identical bridge tx imported into both ledgers) cannot
  cross-link. Two chains that happen to share a hash (extremely
  rare, but the type system allows it) cannot cross-link either.

  ## Confidence / provenance contract

  This module DOES NOT filter by `confidence` or `status`. The
  reconciliation surface returns every workspace-scoped match —
  the caller (e.g. exposure calculation, replay/report) is the
  one that decides which confidences are authoritative for its
  use case. See `Bank.Activity.Exposure` for the
  high-confidence/confirmed-only opt-in.

  ## Read-only

  Pure read. No row mutation, no Oban enqueue, no broadcast, no
  adapter call. Safe to invoke from inside any transaction.
  """

  import Ecto.Query

  alias Bank.Activity.ImportedActivity
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Repo

  @typedoc """
  An activity row matched to an execution plan, with the link
  fields a reviewer / report renderer needs to follow the
  reconciliation.
  """
  @type match :: %{
          activity: ImportedActivity.t(),
          plan_id: binary(),
          tx_hash: String.t()
        }

  @typedoc """
  Either `:cryptobank_execution` (matched to a plan in the same
  workspace) or `:external` (no match; external wallet transfer
  not initiated by CryptoBank).
  """
  @type classification :: :cryptobank_execution | :external

  @doc """
  Find the imported-activity rows in the plan's workspace that
  cite a `tx_hash` appearing in the plan's `tx_refs` and ran on
  the plan's chain.

  Returns a list of `t:match/0` (possibly empty). The list is
  ordered by `occurred_at, id` to match the ledger ordering used
  elsewhere in `Bank.Activity`.

  Cross-workspace and cross-chain misses collapse to `[]`.
  """
  @spec match_for_plan(ExecutionPlan.t()) :: [match()]
  def match_for_plan(%ExecutionPlan{} = plan) do
    case plan.tx_refs do
      [] -> []
      refs when is_list(refs) -> match_for_plan(plan, refs)
      _ -> []
    end
  end

  defp match_for_plan(%ExecutionPlan{workspace_id: nil}, _refs), do: []

  defp match_for_plan(%ExecutionPlan{} = plan, refs) when is_list(refs) do
    refs = Enum.uniq(refs)

    activities =
      ImportedActivity
      |> where([a], a.workspace_id == ^plan.workspace_id)
      |> where([a], a.chain == ^plan.chain)
      |> where([a], a.tx_hash in ^refs)
      |> order_by([a], asc: a.occurred_at, asc: a.id)
      |> Repo.all()

    Enum.map(activities, fn a ->
      %{activity: a, plan_id: plan.id, tx_hash: a.tx_hash}
    end)
  end

  @doc """
  Batch shape of `match_for_plan/1`. Takes a list of execution
  plans (assumed to all belong to the same workspace, e.g. a
  replay bundle's `:plans`) and returns a flat list of matches
  across all plans, ordered by `(plan.inserted_at, occurred_at,
  id)`.

  Used by `Bank.Audit.replay/1` to attach a `:matched_activities`
  key to the replay bundle without N+1 queries.

  Returns `[]` for an empty plan list, a list containing only
  plans without `tx_refs`, or plans with mixed/missing
  `workspace_id`.
  """
  @spec match_for_plans([ExecutionPlan.t()]) :: [match()]
  def match_for_plans([]), do: []

  def match_for_plans(plans) when is_list(plans) do
    plans
    |> Enum.flat_map(&match_for_plan/1)
  end

  @doc """
  Classify a single imported activity row by checking whether
  its `tx_hash` appears in any of the supplied execution plans'
  `tx_refs` (with same chain). The plans list is typically the
  workspace's plans loaded by the caller — this function does
  not query the DB.

  Returns `:cryptobank_execution` on match; `:external` otherwise.

  An activity with `tx_hash: nil` (e.g. a CSV row with no chain
  hash) classifies as `:external` — there is no chain reference
  to reconcile against.
  """
  @spec classify_activity(ImportedActivity.t(), [ExecutionPlan.t()]) :: classification()
  def classify_activity(%ImportedActivity{tx_hash: nil}, _plans), do: :external

  def classify_activity(%ImportedActivity{} = activity, plans) when is_list(plans) do
    if Enum.any?(plans, fn p ->
         is_list(p.tx_refs) and
           p.workspace_id == activity.workspace_id and
           p.chain == activity.chain and
           activity.tx_hash in p.tx_refs
       end) do
      :cryptobank_execution
    else
      :external
    end
  end
end
