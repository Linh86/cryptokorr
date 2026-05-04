defmodule Bank.Activity.Exposure do
  @moduledoc """
  Workspace-scoped exposure aggregation, opt-in by imported
  activity (#246).

  Imported chain activity carries a `:confidence` label
  (`:high | :medium | :low`) and a `:status` label
  (`:confirmed | :pending | :failed | :imported`). Most
  exposure callers (policy evaluation, dashboard tiles) want
  ONLY rows that are both confirmed AND high-confidence — those
  are the rows a chain explorer also corroborates. Rows that
  are pending, failed, imported-but-not-yet-confirmed, or that
  carry a weak provenance (`:medium` / `:low`) are NOT
  authoritative for exposure math.

  This module exposes that distinction as an explicit opt-in:

      # Default: imported activity is NOT included.
      Bank.Activity.Exposure.workspace_exposure_by_asset(workspace_id)
      # => %{}

      # Opt-in:
      Bank.Activity.Exposure.workspace_exposure_by_asset(
        workspace_id,
        include_imported_activity: true
      )
      # => %{"usdc" => %{inbound: ..., outbound: ..., net: ..., source_count: ...}}

  Callers can also widen the confidence set explicitly:

      Bank.Activity.Exposure.workspace_exposure_by_asset(
        workspace_id,
        include_imported_activity: true,
        min_confidence: :medium
      )

  but the default of `min_confidence: :high` reflects the #246
  contract that "weak provenance must not be treated as
  authoritative".

  ## Read-only

  Pure read against `imported_activities`. No row mutation, no
  Oban enqueue, no chain call.
  """

  import Ecto.Query

  alias Bank.Activity.ImportedActivity
  alias Bank.Repo

  @typedoc """
  Per-asset exposure aggregate. Amounts are sums of `Decimal`
  values from the matching activity rows; `net = inbound -
  outbound`. `source_count` is the number of activity rows
  that contributed.
  """
  @type asset_exposure :: %{
          inbound: Decimal.t(),
          outbound: Decimal.t(),
          net: Decimal.t(),
          source_count: non_neg_integer()
        }

  @typedoc """
  Map of asset symbol → per-asset exposure aggregate.
  """
  @type by_asset :: %{String.t() => asset_exposure()}

  # Confidence ranking (lower index = stronger).
  @confidence_rank %{high: 0, medium: 1, low: 2}

  @doc """
  Aggregate confirmed inbound/outbound activity per asset for a
  workspace.

  ## Options

    * `:include_imported_activity` — `boolean`, default `false`.
      The opt-in switch. When `false`, returns `%{}`.
    * `:min_confidence` — `:high | :medium | :low`, default
      `:high`. Only activity rows with confidence at or above
      this rank are included. The #246 contract says weak
      provenance must not be treated as authoritative; the
      default reflects that.
    * `:assets` — `[String.t()]` (optional). When set, restrict
      the aggregate to these asset symbols. Otherwise all assets
      with matching rows are returned.

  Always filters by `status: :confirmed`. A pending / failed /
  imported-but-not-confirmed row is never authoritative for
  exposure regardless of confidence.

  Returns `%{}` when no rows match (including when the opt-in
  switch is off).
  """
  @spec workspace_exposure_by_asset(binary(), keyword()) :: by_asset()
  def workspace_exposure_by_asset(workspace_id, opts \\ [])

  def workspace_exposure_by_asset(workspace_id, opts) when is_binary(workspace_id) do
    if Keyword.get(opts, :include_imported_activity, false) do
      do_aggregate(workspace_id, opts)
    else
      %{}
    end
  end

  def workspace_exposure_by_asset(_workspace_id, _opts), do: %{}

  defp do_aggregate(workspace_id, opts) do
    min_conf = Keyword.get(opts, :min_confidence, :high)
    allowed = allowed_confidences(min_conf)

    query =
      ImportedActivity
      |> where([a], a.workspace_id == ^workspace_id)
      |> where([a], a.status == ^:confirmed)
      |> where([a], a.confidence in ^allowed)
      |> maybe_filter_assets(Keyword.get(opts, :assets))

    query
    |> Repo.all()
    |> Enum.reduce(%{}, &accumulate_row/2)
  end

  defp allowed_confidences(min_conf) do
    rank = Map.fetch!(@confidence_rank, min_conf)

    @confidence_rank
    |> Enum.filter(fn {_conf, r} -> r <= rank end)
    |> Enum.map(fn {conf, _} -> conf end)
  end

  defp maybe_filter_assets(query, nil), do: query
  defp maybe_filter_assets(query, []), do: query

  defp maybe_filter_assets(query, assets) when is_list(assets),
    do: where(query, [a], a.asset in ^assets)

  defp accumulate_row(%ImportedActivity{} = a, acc) do
    asset = a.asset || "(unknown)"
    amount = a.amount || Decimal.new("0")

    bucket =
      Map.get(acc, asset, %{
        inbound: Decimal.new("0"),
        outbound: Decimal.new("0"),
        net: Decimal.new("0"),
        source_count: 0
      })

    bucket =
      case a.direction do
        :inbound ->
          %{bucket | inbound: Decimal.add(bucket.inbound, amount)}

        :outbound ->
          %{bucket | outbound: Decimal.add(bucket.outbound, amount)}

        _ ->
          bucket
      end

    bucket = %{
      bucket
      | net: Decimal.sub(bucket.inbound, bucket.outbound),
        source_count: bucket.source_count + 1
    }

    Map.put(acc, asset, bucket)
  end
end
