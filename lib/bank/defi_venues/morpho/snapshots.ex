defmodule Bank.DefiVenues.Morpho.Snapshots do
  @moduledoc """
  Persistence + freshness context for Morpho vault snapshots (#199).

  Bridges the in-memory `Bank.DefiVenues.Morpho.VaultSnapshot`
  struct produced by `Bank.DefiVenues.Morpho.Client` (#198) to
  the `morpho_vault_snapshots` table. The persistence layer is
  workspace-agnostic — a vault snapshot identifies a public
  on-chain contract by `(chain_id, vault_address)`, the same
  for every workspace. Decision-time evidence ties the
  persisted row to a workspace-scoped intent / decision in
  later issues (#208 audit + replay).

  ## API

    * `persist/1` — take a `%VaultSnapshot{}`, supersede the
      prior `current` row for the same vault (if any), insert
      a successor with `current: true`. Idempotent on
      `payload_hash`: if the upstream returned the same body
      we already persisted, return the existing row.
    * `get_current/2` — fast read of the current snapshot for
      `(chain_id, vault_address)`.
    * `get/1` — read by row id (replay).
    * `freshness_for/3` — three-state `:fresh | :stale |
      :expired` for one of the four design-doc fields
      (`:identity | :allocation | :warnings | :apy`).
    * `freshness_summary/2` — convenience: returns a map with
      one freshness value per field.

  ## Freshness model

      :fresh    — `now < fetched_at + ttl`
      :stale    — `fetched_at + ttl <= now < fetched_at + 2*ttl`
      :expired  — `now >= fetched_at + 2*ttl`

  The "stale window" gives the decision pipeline a graceful
  "use-but-warn" zone before forcing a refetch. `:expired`
  corresponds to the design doc's "fallback hold" case. (The
  hold routing itself lands in #203.)
  """

  import Ecto.Query

  alias Bank.DefiVenues.Morpho.PersistedVaultSnapshot
  alias Bank.DefiVenues.Morpho.VaultSnapshot
  alias Bank.Repo

  @freshness_fields ~w(identity allocation warnings apy)a

  @type freshness_state :: :fresh | :stale | :expired
  @type freshness_field :: :identity | :allocation | :warnings | :apy

  @type freshness_summary :: %{
          identity: freshness_state(),
          allocation: freshness_state(),
          warnings: freshness_state(),
          apy: freshness_state()
        }

  @type persist_result ::
          {:ok, PersistedVaultSnapshot.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :supersession_failed}

  @doc """
  Persist a normalized snapshot. See module doc for semantics.
  """
  @spec persist(VaultSnapshot.t(), keyword()) :: persist_result()
  def persist(%VaultSnapshot{} = snap, opts \\ []) do
    chain_id = snap.chain_id
    vault_address = lowercase_address(snap.vault_address)
    payload_hash = source_field(snap, :payload_hash)

    case get_current(chain_id, vault_address) do
      %PersistedVaultSnapshot{payload_hash: ^payload_hash} = existing ->
        # Same upstream body. The persistence layer is
        # idempotent on payload-hash so a redundant fetch
        # cannot inflate the supersession chain.
        {:ok, existing}

      existing ->
        do_supersede_and_insert_with_dedupe(
          snap,
          chain_id,
          vault_address,
          payload_hash,
          existing,
          opts
        )
    end
  end

  # #199 P2: two concurrent persists of the same successor payload
  # can both observe `existing` as the OLD current. The first
  # transaction wins the partial unique index; the second hits
  # `morpho_vault_snapshots_current_uidx` and would otherwise
  # surface a changeset error. Catch that case, refetch the
  # winning row, and treat it as a benign idempotent no-op when
  # the winning row carries the same `payload_hash`. A
  # genuinely-different payload race still surfaces the error so
  # callers don't silently mask a real conflict.
  defp do_supersede_and_insert_with_dedupe(
         snap,
         chain_id,
         vault_address,
         payload_hash,
         existing,
         opts
       ) do
    case do_supersede_and_insert(snap, vault_address, existing, opts) do
      {:ok, row} ->
        {:ok, row}

      {:error, %Ecto.Changeset{} = changeset} = err ->
        if current_uidx_violation?(changeset) do
          case get_current(chain_id, vault_address) do
            %PersistedVaultSnapshot{payload_hash: ^payload_hash} = winner ->
              {:ok, winner}

            _ ->
              err
          end
        else
          err
        end

      other ->
        other
    end
  end

  defp current_uidx_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_msg, opts}} ->
        Keyword.get(opts, :constraint) == :unique and
          Keyword.get(opts, :constraint_name) == "morpho_vault_snapshots_current_uidx"

      _ ->
        false
    end)
  end

  @doc """
  Fetch the current row for `(chain_id, vault_address)` or
  `nil` when no snapshot has been persisted yet.
  """
  @spec get_current(integer(), String.t()) :: PersistedVaultSnapshot.t() | nil
  def get_current(chain_id, vault_address)
      when is_integer(chain_id) and is_binary(vault_address) do
    addr = lowercase_address(vault_address)

    Repo.one(
      from(s in PersistedVaultSnapshot,
        where:
          s.chain_id == ^chain_id and s.vault_address == ^addr and
            s.current == true,
        limit: 1
      )
    )
  end

  def get_current(_, _), do: nil

  @doc "Fetch a row by id, current or superseded."
  @spec get(Ecto.UUID.t()) :: PersistedVaultSnapshot.t() | nil
  def get(id) when is_binary(id), do: Repo.get(PersistedVaultSnapshot, id)
  def get(_), do: nil

  @doc """
  Three-state freshness for one of the documented field
  buckets (`:identity | :allocation | :warnings | :apy`).
  Pass a `now` to keep the function pure in tests.
  """
  @spec freshness_for(PersistedVaultSnapshot.t(), freshness_field(), DateTime.t()) ::
          freshness_state()
  def freshness_for(%PersistedVaultSnapshot{} = row, field, now)
      when field in @freshness_fields do
    ttl = ttl_for(row, field)
    expiry = DateTime.add(row.fetched_at, ttl, :second)
    expired_cutoff = DateTime.add(row.fetched_at, ttl * 2, :second)

    cond do
      DateTime.compare(now, expiry) == :lt -> :fresh
      DateTime.compare(now, expired_cutoff) == :lt -> :stale
      true -> :expired
    end
  end

  @doc """
  Per-field summary of the four freshness buckets.
  """
  @spec freshness_summary(PersistedVaultSnapshot.t(), DateTime.t()) :: freshness_summary()
  def freshness_summary(%PersistedVaultSnapshot{} = row, now) do
    Map.new(@freshness_fields, fn field -> {field, freshness_for(row, field, now)} end)
  end

  # --- Internal --------------------------------------------------------

  defp do_supersede_and_insert(%VaultSnapshot{} = snap, vault_address, prior, opts) do
    Repo.transaction(fn ->
      # 1. Demote the prior current row (if any).
      case prior do
        %PersistedVaultSnapshot{} = existing ->
          case existing
               |> PersistedVaultSnapshot.mark_not_current()
               |> Repo.update() do
            {:ok, _demoted} -> :ok
            {:error, changeset} -> Repo.rollback({:error, :supersession_failed, changeset})
          end

        nil ->
          :ok
      end

      # 2. Insert the successor with `current: true` and the
      # `supersedes_id` link (if the prior row exists).
      attrs = build_attrs(snap, vault_address, prior, opts)

      case attrs
           |> PersistedVaultSnapshot.create_changeset()
           |> Repo.insert() do
        {:ok, row} -> row
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, {:error, :supersession_failed, _changeset}} -> {:error, :supersession_failed}
    end
  end

  defp build_attrs(%VaultSnapshot{} = snap, vault_address, prior, opts) do
    # Normalize every nested JSON-bound value to string keys so
    # the in-memory row Ecto returns from `Repo.insert/1` matches
    # the shape a subsequent `Repo.get/1` reload would produce.
    # Without this, callers see `row.state[:apy]` immediately
    # after a write but `row.state["apy"]` after a refetch.
    base = %{
      chain_id: snap.chain_id,
      vault_address: vault_address,
      network: snap.network,
      name: snap.name,
      symbol: snap.symbol,
      listed: snap.listed,
      deposit_asset: stringify_keys(snap.deposit_asset || %{}),
      state: stringify_keys(snap.state || %{}),
      allocations: ensure_list(snap.allocations) |> Enum.map(&stringify_keys/1),
      warnings: ensure_list(snap.warnings) |> Enum.map(&stringify_keys/1),
      pending_caps: ensure_list(snap.pending_caps) |> Enum.map(&stringify_keys/1),
      allocators: ensure_list(snap.allocators) |> Enum.map(&stringify_keys/1),
      source: stringify_keys(snap.source || %{}),
      fetched_at: source_field(snap, :fetched_at),
      payload_hash: source_field(snap, :payload_hash),
      current: true,
      supersedes_id: supersedes_id_of(prior)
    }

    base
    |> maybe_put(:freshness_seconds_identity, opts)
    |> maybe_put(:freshness_seconds_allocation, opts)
    |> maybe_put(:freshness_seconds_warnings, opts)
    |> maybe_put(:freshness_seconds_apy, opts)
  end

  defp ttl_for(%PersistedVaultSnapshot{freshness_seconds_identity: v}, :identity), do: v
  defp ttl_for(%PersistedVaultSnapshot{freshness_seconds_allocation: v}, :allocation), do: v
  defp ttl_for(%PersistedVaultSnapshot{freshness_seconds_warnings: v}, :warnings), do: v
  defp ttl_for(%PersistedVaultSnapshot{freshness_seconds_apy: v}, :apy), do: v

  defp source_field(%VaultSnapshot{source: %{} = source}, key), do: Map.get(source, key)
  defp source_field(_, _), do: nil

  defp lowercase_address(addr) when is_binary(addr), do: String.downcase(addr)
  defp lowercase_address(addr), do: addr

  defp ensure_list(nil), do: []
  defp ensure_list(list) when is_list(list), do: list
  defp ensure_list(_), do: []

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_keys(other), do: other

  # Recursively normalize nested maps and lists so an
  # `%{items: [%{kind: "foo"}]}` value with mixed atom/string
  # keys round-trips uniformly.
  defp stringify_value(v) when is_map(v) and not is_struct(v), do: stringify_keys(v)
  defp stringify_value(v) when is_list(v), do: Enum.map(v, &stringify_value/1)
  defp stringify_value(v), do: v

  defp supersedes_id_of(%PersistedVaultSnapshot{id: id}), do: id
  defp supersedes_id_of(_), do: nil

  defp maybe_put(map, key, opts) do
    case Keyword.get(opts, key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end
end
