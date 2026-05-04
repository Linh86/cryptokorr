defmodule Bank.DefiVenues.Morpho.Snapshots do
  @moduledoc """
  Morpho vault-snapshot persistence + freshness context (#199).

  The bridge between the in-memory
  `Bank.DefiVenues.Morpho.VaultSnapshot` (transient, returned by
  `Bank.DefiVenues.Morpho.Client.fetch_vault_by_address/3`) and
  the durable `Bank.DefiVenues.Morpho.SnapshotRecord` row.

  ## Public surface

      create_from_snapshot(snapshot, opts) :: {:ok, record}
                                            | {:duplicate, existing}
                                            | {:error, changeset}

      get(id) :: SnapshotRecord.t() | nil
      get_by_correlation(correlation_id) :: [SnapshotRecord.t()]
      latest_for_vault(chain_id, vault_address, opts) :: SnapshotRecord.t() | nil
      list_for_workspace(workspace_id, opts) :: [SnapshotRecord.t()]

      freshness(record, opts) :: %{
        vault_identity: :fresh | :stale | :expired,
        allocation: :fresh | :stale | :expired,
        warnings: :fresh | :stale | :expired,
        apy: :fresh | :stale | :expired
      }

  ## Idempotency

  `create_from_snapshot/2` is idempotent on
  `(workspace_id, payload_hash)` — re-importing the same upstream
  payload returns `{:duplicate, existing}` without raising on the
  unique constraint. Two workspaces observing the same upstream
  payload get separate rows (the dedupe scope is per-workspace).

  ## Read-only contract

  This module never:

    * dispatches a chain transaction,
    * signs a payload,
    * calls `Bank.AdapterClient`,
    * enqueues an Oban job,
    * mutates any decision / intent / execution-plan row.

  Future risk-aggregation surfaces (#201, #202) read this table.

  ## Workspace boundary

  Every read helper takes a `workspace_id` (or accepts `nil` for
  workspace-agnostic background snapshots). Cross-workspace
  reads are explicitly opt-in via the helpers; there is no
  global `Repo.get` exposed.

  ## Freshness

  Per-category max-age thresholds default to the
  `docs/morpho-risk-explanation.md` recommendations and can be
  overridden via
  `Application.get_env(:bank, Bank.DefiVenues.Morpho.Snapshots,
  [])[:freshness]`. Each category resolves to one of:

    * `:fresh` — `age <= max_age`
    * `:stale` — `max_age < age <= 2 * max_age`
    * `:expired` — `age > 2 * max_age`

  Downstream (#202) decides what each state means for a
  decision. For example, `:expired` allocation routes to `hold`,
  while `:stale` apy is informational only.
  """

  import Ecto.Query

  alias Bank.DefiVenues.Morpho.SnapshotRecord
  alias Bank.DefiVenues.Morpho.VaultSnapshot
  alias Bank.Repo

  @categories ~w(vault_identity allocation warnings apy)a

  # Recommended freshness defaults from
  # docs/morpho-risk-explanation.md. Each value is the per-category
  # max-age in seconds.
  @default_freshness %{
    vault_identity: 24 * 60 * 60,
    allocation: 5 * 60,
    warnings: 5 * 60,
    apy: 60 * 60
  }

  @typedoc "Result of `create_from_snapshot/2`."
  @type create_result ::
          {:ok, SnapshotRecord.t()}
          | {:duplicate, SnapshotRecord.t()}
          | {:error, Ecto.Changeset.t()}

  @typedoc "Per-category freshness state."
  @type freshness_state :: :fresh | :stale | :expired

  @typedoc "Freshness map returned by `freshness/2`."
  @type freshness_map :: %{
          vault_identity: freshness_state(),
          allocation: freshness_state(),
          warnings: freshness_state(),
          apy: freshness_state()
        }

  @doc """
  Persist a `%VaultSnapshot{}` as a `%SnapshotRecord{}`. Idempotent
  on `(workspace_id, payload_hash)`.

  ## Args

    * `snapshot` — the in-memory `%VaultSnapshot{}` returned by
      `Bank.DefiVenues.Morpho.Client.fetch_vault_by_address/3`.
    * `opts`:
      * `:workspace_id` — optional binary UUID. When absent the
        row is workspace-agnostic (NULL); cross-workspace
        snapshots cannot collide because the dedupe index is
        `(workspace_id, payload_hash)`.
      * `:correlation_id` — optional binary UUID linking the
        snapshot to a decision/intent for replay.

  Returns `{:ok, record}` for a fresh insert, `{:duplicate,
  existing}` if the `(workspace_id, payload_hash)` pair already
  exists, or `{:error, changeset}` for any other validation
  failure.
  """
  @spec create_from_snapshot(VaultSnapshot.t(), keyword()) :: create_result()
  def create_from_snapshot(%VaultSnapshot{} = snapshot, opts \\ []) do
    attrs = to_attrs(snapshot, opts)
    changeset = SnapshotRecord.create_changeset(%SnapshotRecord{}, attrs)

    case Repo.insert(changeset) do
      {:ok, %SnapshotRecord{} = record} ->
        {:ok, record}

      {:error, %Ecto.Changeset{} = cs} ->
        if dedupe_violation?(cs) do
          case fetch_existing(attrs) do
            %SnapshotRecord{} = existing -> {:duplicate, existing}
            nil -> {:error, cs}
          end
        else
          {:error, cs}
        end
    end
  end

  @doc """
  Fetch a snapshot by id. Returns `nil` for unknown ids.

  Workspace boundary: this lookup is intentionally global —
  callers that need workspace scoping should pass the result
  through `belongs_to_workspace?/2` or use
  `list_for_workspace/2` instead.
  """
  @spec get(String.t() | nil) :: SnapshotRecord.t() | nil
  def get(nil), do: nil
  def get(id) when is_binary(id), do: Repo.get(SnapshotRecord, id)
  def get(_), do: nil

  @doc """
  Snapshots linked to a `correlation_id` (decision/intent for
  replay). Newest fetched_at first.
  """
  @spec get_by_correlation(String.t() | nil) :: [SnapshotRecord.t()]
  def get_by_correlation(nil), do: []

  def get_by_correlation(correlation_id) when is_binary(correlation_id) do
    Repo.all(
      from(s in SnapshotRecord,
        where: s.correlation_id == ^correlation_id,
        order_by: [desc: s.fetched_at, desc: s.id]
      )
    )
  end

  def get_by_correlation(_), do: []

  @doc """
  Most-recently-fetched snapshot for `(chain_id, vault_address)`.

  ## Options

    * `:workspace_id` — narrow to one workspace's snapshots
      (including workspace-agnostic NULL rows when
      `:include_global` is true). Default `nil` returns the
      newest row regardless of workspace (used by background
      refresh paths that have no workspace context).
    * `:include_global` — when `:workspace_id` is set, also
      include workspace-NULL rows. Default `false`.
  """
  @spec latest_for_vault(integer(), String.t(), keyword()) :: SnapshotRecord.t() | nil
  def latest_for_vault(chain_id, vault_address, opts \\ [])

  def latest_for_vault(chain_id, vault_address, _opts)
      when not is_integer(chain_id) or not is_binary(vault_address),
      do: nil

  def latest_for_vault(chain_id, vault_address, opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    include_global? = Keyword.get(opts, :include_global, false)
    lowered = String.downcase(vault_address)

    SnapshotRecord
    |> where(
      [s],
      s.chain_id == ^chain_id and s.vault_address == ^lowered
    )
    |> apply_workspace_filter(workspace_id, include_global?)
    |> order_by([s], desc: s.fetched_at, desc: s.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  All snapshots for a workspace, newest fetched_at first. Capped
  at `:limit` (default 50).
  """
  @spec list_for_workspace(String.t() | nil, keyword()) :: [SnapshotRecord.t()]
  def list_for_workspace(workspace_id, opts \\ [])
  def list_for_workspace(nil, _opts), do: []

  def list_for_workspace(workspace_id, opts) when is_binary(workspace_id) do
    limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(500)

    Repo.all(
      from(s in SnapshotRecord,
        where: s.workspace_id == ^workspace_id,
        order_by: [desc: s.fetched_at, desc: s.id],
        limit: ^limit
      )
    )
  end

  def list_for_workspace(_, _), do: []

  @doc """
  Per-category freshness state for a snapshot record.

  Default thresholds come from the design doc:

    * vault_identity → 24h
    * allocation → 5m
    * warnings → 5m
    * apy → 1h

  Thresholds can be overridden globally via
  `Application.get_env(:bank, Bank.DefiVenues.Morpho.Snapshots,
  [])[:freshness]` or per-call via `:freshness` opt and `:now`
  for clock injection.
  """
  @spec freshness(SnapshotRecord.t() | nil, keyword()) :: freshness_map() | nil
  def freshness(nil, _opts), do: nil

  def freshness(%SnapshotRecord{fetched_at: %DateTime{} = fetched_at}, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    thresholds = resolve_thresholds(opts)
    age_seconds = DateTime.diff(now, fetched_at, :second)

    Map.new(@categories, fn category ->
      max_age = Map.fetch!(thresholds, category)
      {category, classify(age_seconds, max_age)}
    end)
  end

  def freshness(_, _), do: nil

  @doc "Categories `freshness/2` returns. Stable for callers / tests."
  @spec categories() :: [atom()]
  def categories, do: @categories

  @doc "Default per-category max-age thresholds in seconds."
  @spec default_thresholds() :: map()
  def default_thresholds, do: @default_freshness

  # --- internals --------------------------------------------------------

  defp to_attrs(%VaultSnapshot{} = snap, opts) do
    %{
      workspace_id: Keyword.get(opts, :workspace_id),
      correlation_id: Keyword.get(opts, :correlation_id),
      venue: "morpho",
      chain_id: snap.chain_id,
      vault_address: String.downcase(snap.vault_address),
      fetched_at: snap.source.fetched_at,
      payload_hash: snap.source.payload_hash,
      name: snap.name,
      symbol: snap.symbol,
      listed: snap.listed,
      network: snap.network,
      deposit_asset_address: get_in(snap.deposit_asset, [:address]),
      deposit_asset_symbol: get_in(snap.deposit_asset, [:symbol]),
      deposit_asset_decimals: get_in(snap.deposit_asset, [:decimals]),
      apy: get_in(snap.state, [:apy]),
      net_apy: get_in(snap.state, [:net_apy]),
      total_assets: get_in(snap.state, [:total_assets]),
      fee: get_in(snap.state, [:fee]),
      timelock: get_in(snap.state, [:timelock]),
      allocations: %{"items" => Enum.map(snap.allocations, &allocation_attrs/1)},
      warnings: %{"items" => Enum.map(snap.warnings, &warning_attrs/1)},
      pending_caps: %{"items" => Enum.map(snap.pending_caps, &pending_cap_attrs/1)},
      allocators: %{"items" => Enum.map(snap.allocators, &allocator_attrs/1)},
      source_name: snap.source.source_name,
      source_schema_version: snap.source.source_schema_version,
      source_warnings: %{"items" => snap.source.source_warnings || []}
    }
  end

  defp allocation_attrs(allocation) when is_map(allocation) do
    %{
      "market_unique_key" => allocation[:market_unique_key],
      "loan_asset" => allocation[:loan_asset],
      "collateral_asset" => allocation[:collateral_asset],
      "oracle" => allocation[:oracle],
      "irm" => allocation[:irm],
      "lltv" => allocation[:lltv],
      "supply_cap" => allocation[:supply_cap],
      "supplied_assets" => allocation[:supplied_assets],
      "supplied_assets_usd" => allocation[:supplied_assets_usd]
    }
  end

  defp warning_attrs(warning) when is_map(warning) do
    %{
      "raw_type" => warning[:raw_type],
      "raw_level" => warning[:raw_level]
    }
  end

  defp pending_cap_attrs(pc) when is_map(pc) do
    %{
      "market_unique_key" => pc[:market_unique_key],
      "cap" => pc[:cap],
      "valid_at" => pc[:valid_at]
    }
  end

  defp allocator_attrs(allocator) when is_map(allocator) do
    %{"address" => allocator[:address]}
  end

  @dedupe_index_names ~w(
    morpho_vault_snapshots_workspace_dedupe_idx
    morpho_vault_snapshots_global_dedupe_idx
  )

  defp dedupe_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} ->
        Keyword.get(opts, :constraint) == :unique and
          Keyword.get(opts, :constraint_name) in @dedupe_index_names
    end)
  end

  defp fetch_existing(attrs) do
    payload_hash = attrs[:payload_hash]

    case attrs[:workspace_id] do
      nil ->
        Repo.one(
          from(s in SnapshotRecord,
            where: s.payload_hash == ^payload_hash and is_nil(s.workspace_id),
            limit: 1
          )
        )

      workspace_id when is_binary(workspace_id) ->
        Repo.one(
          from(s in SnapshotRecord,
            where: s.payload_hash == ^payload_hash and s.workspace_id == ^workspace_id,
            limit: 1
          )
        )

      _ ->
        nil
    end
  end

  defp apply_workspace_filter(query, nil, _include_global?), do: query

  defp apply_workspace_filter(query, workspace_id, true) when is_binary(workspace_id) do
    where(query, [s], s.workspace_id == ^workspace_id or is_nil(s.workspace_id))
  end

  defp apply_workspace_filter(query, workspace_id, false) when is_binary(workspace_id) do
    where(query, [s], s.workspace_id == ^workspace_id)
  end

  defp resolve_thresholds(opts) do
    overrides =
      case Keyword.get(opts, :freshness) do
        m when is_map(m) -> m
        _ -> Application.get_env(:bank, __MODULE__, [])[:freshness] || %{}
      end

    Map.merge(@default_freshness, overrides)
  end

  defp classify(age_seconds, max_age)
       when is_integer(age_seconds) and is_integer(max_age) and max_age > 0 do
    cond do
      age_seconds <= max_age -> :fresh
      age_seconds <= 2 * max_age -> :stale
      true -> :expired
    end
  end

  defp classify(_, _), do: :expired
end
