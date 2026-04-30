defmodule Bank.WalletScreening do
  @moduledoc """
  Wallet screening bounded context.

  Owns the shared screening record model, control-tier semantics,
  precedence rules, and the query interface for runtime screening
  lookups. Source-specific ingestion (issues #78, #76, #75, #81) writes
  records through this context; runtime evaluation reads through
  `screen/2`.

  ## Control tiers

  Every screening record carries exactly one tier:

    * `:hard_block` — legally grounded sanctions data (OFAC, OpenSanctions).
      A hit is an automatic block; the runtime must not execute.
    * `:challenge` — community scam/phishing signals (ScamSniffer,
      EtherScamDB, BTC abuse feeds). A hit routes to manual review.
    * `:context` — public attribution labels (GraphSense tagpacks).
      Enriches operator understanding; never blocks or challenges alone.
    * `:score_only` — internal suspicious-wallet scoring (Elliptic++-style).
      Advisory signal that widens review friction; never blocks alone.

  ## Precedence

  When multiple records match the same address, the highest-priority
  tier wins. Ties within a tier are resolved by recency.

      hard_block > challenge > context > score_only

  The screening outcome reflects the winning tier:

    * `hard_block` hit → outcome `:block`
    * `challenge` hit → outcome `:challenge`
    * `context` only → outcome `:clean` (enrichment-only)
    * `score_only` only → outcome `:clean` (advisory-only)
    * No records → outcome `:clean`

  ## Address normalisation

  Addresses are stored normalised: lowercased for case-insensitive
  chains (EVM), trimmed, and stored alongside the chain identifier.
  Lookups normalise the query address using the same rules before
  hitting the index.

  ## Public surface

      screen(chain, address, opts)       # runtime screening lookup
      upsert_record(attrs)               # write/update a screening record
      upsert_records(list)               # batch write
      list_records(filters, opts)        # operator listing
      get_record(id)                     # single record by id
      delete_expired_records(source, before)  # TTL cleanup
  """

  import Ecto.Query

  alias Bank.Repo
  alias Bank.WalletScreening.{ScreeningRecord, ScreeningOutcome}

  @type uuid :: String.t()

  @record_attr_keys [
    :chain,
    :address,
    :normalised_address,
    :control_tier,
    :source,
    :source_record_id,
    :category,
    :reason,
    :evidence_uri,
    :metadata,
    :first_seen_at,
    :last_seen_at,
    :expires_at,
    :score,
    :score_version
  ]

  # --- Screening lookup -------------------------------------------------

  @doc """
  Screen an address for wallet-risk hits.

  Returns a `%ScreeningOutcome{}` summarising the highest-priority
  hit, the full list of matching records, and the machine-readable
  outcome (`:block`, `:challenge`, or `:clean`).

  Options:

    * `:now` — override the clock for freshness checks (test seam).
    * `:include_expired` — when `true`, includes records past their
      `expires_at`; default `false`.
  """
  @spec screen(String.t(), String.t(), keyword()) :: ScreeningOutcome.t()
  def screen(chain, address, opts \\ []) when is_binary(chain) and is_binary(address) do
    normalised = normalise_address(chain, address)
    include_expired = Keyword.get(opts, :include_expired, false)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    records = load_matching_records(chain, normalised, include_expired, now)

    ScreeningOutcome.from_records(records)
  end

  # --- Write API --------------------------------------------------------

  @doc """
  Upsert a single screening record. On conflict
  `(chain, normalised_address, source, source_record_id)`, the
  existing row is updated with the new attributes.

  Returns `{:ok, %ScreeningRecord{}}` or `{:error, changeset}`.
  """
  @spec upsert_record(map()) :: {:ok, ScreeningRecord.t()} | {:error, Ecto.Changeset.t()}
  def upsert_record(attrs) when is_map(attrs) do
    attrs = normalise_record_attrs(attrs)

    %ScreeningRecord{}
    |> ScreeningRecord.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: [:chain, :normalised_address, :source, :source_record_id],
      returning: true
    )
  end

  @doc """
  Batch upsert screening records. All-or-nothing within a transaction.
  """
  @spec upsert_records([map()]) :: {:ok, non_neg_integer()} | {:error, term()}
  def upsert_records(records) when is_list(records) do
    Repo.transaction(fn ->
      Enum.reduce(records, 0, fn attrs, count ->
        case upsert_record(attrs) do
          {:ok, _record} -> count + 1
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
    end)
  end

  # --- Read API ---------------------------------------------------------

  @doc "Fetch a single screening record by id."
  @spec get_record(uuid()) :: {:ok, ScreeningRecord.t()} | {:error, :not_found}
  def get_record(id) when is_binary(id) do
    case Repo.get(ScreeningRecord, id) do
      nil -> {:error, :not_found}
      record -> {:ok, record}
    end
  end

  @doc """
  List screening records. Supports filters:

    * `:chain` — filter by chain
    * `:address` — filter by normalised address (will be normalised)
    * `:source` — filter by source name
    * `:control_tier` — filter by tier atom
    * `:limit` — default 50, max 500
    * `:workspace_id` — narrow to one workspace (#158b.2). Default
      `nil` keeps the legacy "all workspaces" path open until every
      caller is migrated.
  """
  @spec list_records(map() | keyword(), keyword()) :: [ScreeningRecord.t()]
  def list_records(filters \\ %{}, opts \\ []) do
    filters = if is_list(filters), do: Map.new(filters), else: filters
    limit = opts |> Keyword.get(:limit, 50) |> min(500)
    workspace_id = Keyword.get(opts, :workspace_id)

    ScreeningRecord
    |> apply_filters(filters)
    |> scope_screening_to_workspace(workspace_id)
    |> order_by([r], desc: r.updated_at, desc: r.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Delete records for a given source that were last updated before a
  cutoff. Used for TTL-based cleanup of stale feed data.
  """
  @spec delete_expired_records(String.t(), DateTime.t()) :: {non_neg_integer(), nil}
  def delete_expired_records(source, %DateTime{} = before) when is_binary(source) do
    ScreeningRecord
    |> where([r], r.source == ^source and r.updated_at < ^before)
    |> Repo.delete_all()
  end

  # --- Address normalisation -------------------------------------------

  @doc """
  Normalise an address for screening lookups. EVM-family chains are
  lowercased; all addresses are trimmed. Chain identification is
  case-insensitive.
  """
  @spec normalise_address(String.t(), String.t()) :: String.t()
  def normalise_address(chain, address) do
    address = String.trim(address)

    if evm_chain?(chain) do
      String.downcase(address)
    else
      address
    end
  end

  # --- Internals --------------------------------------------------------

  @evm_chains ~w(ethereum base arbitrum optimism polygon avalanche bsc)

  defp evm_chain?(chain) do
    canonical_chain(chain) in @evm_chains
  end

  defp normalise_record_attrs(attrs) do
    attrs = atomise_known_keys(attrs)
    chain = Map.get(attrs, :chain) || Map.get(attrs, "chain", "")
    address = Map.get(attrs, :address) || Map.get(attrs, "address", "")

    attrs
    |> Map.put(:normalised_address, normalise_address(chain, address))
    |> Map.put(:chain, canonical_chain(chain))
  end

  defp atomise_known_keys(attrs) do
    Enum.reduce(@record_attr_keys, attrs, fn key, acc ->
      string_key = Atom.to_string(key)

      case Map.fetch(acc, string_key) do
        {:ok, value} ->
          acc
          |> Map.delete(string_key)
          |> Map.put_new(key, value)

        :error ->
          acc
      end
    end)
  end

  defp load_matching_records(chain, normalised_address, include_expired, now) do
    query =
      from(r in ScreeningRecord,
        where: r.chain == ^canonical_chain(chain),
        where: r.normalised_address == ^normalised_address,
        order_by: [desc: r.updated_at, desc: r.id]
      )

    query =
      if include_expired do
        query
      else
        where(query, [r], is_nil(r.expires_at) or r.expires_at > ^now)
      end

    Repo.all(query)
  end

  defp apply_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:chain, chain}, q when is_binary(chain) ->
        where(q, [r], r.chain == ^canonical_chain(chain))

      {:address, addr}, q when is_binary(addr) ->
        chain = Map.get(filters, :chain, "")
        normalised = normalise_address(chain, addr)
        where(q, [r], r.normalised_address == ^normalised)

      {:source, source}, q when is_binary(source) ->
        where(q, [r], r.source == ^source)

      {:control_tier, tier}, q when is_atom(tier) ->
        where(q, [r], r.control_tier == ^tier)

      _, q ->
        q
    end)
  end

  # Optional workspace filter for #158b.2. `nil` (the default) leaves
  # the query untouched so legacy callers continue returning every
  # workspace's hits. `screen/3` (the runtime hot path) does NOT pass
  # this opt — wallet-screening hits apply globally regardless of the
  # workspace context, by design.
  defp scope_screening_to_workspace(query, nil), do: query

  defp scope_screening_to_workspace(query, workspace_id) when is_binary(workspace_id),
    do: where(query, [r], r.workspace_id == ^workspace_id)

  defp canonical_chain(chain) do
    chain
    |> String.trim()
    |> String.downcase()
  end
end
