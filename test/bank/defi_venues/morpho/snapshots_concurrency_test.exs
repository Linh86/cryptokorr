defmodule Bank.DefiVenues.Morpho.SnapshotsConcurrencyTest do
  @moduledoc """
  Concurrency tests for `Bank.DefiVenues.Morpho.Snapshots.persist/2`
  (#199 P2 regression).

  Lives in its own `async: false` file so the shared-sandbox
  pattern can host concurrent task allocations without leaking
  into the rest of the suite.

  Pre-fix: two concurrent persists of the same successor payload
  could both observe the OLD current row, both attempt to insert
  the new current, and the loser would get a unique-constraint
  changeset error instead of being deduped to the winning row.

  Post-fix: the loser catches the
  `morpho_vault_snapshots_current_uidx` violation, refetches the
  current row, and — if it carries the same `payload_hash` —
  returns `{:ok, winner}`. Genuinely-different payload races still
  surface as errors.
  """

  use Bank.DataCase, async: false

  alias Bank.DefiVenues.Morpho.{PersistedVaultSnapshot, Snapshots, VaultSnapshot}
  alias Bank.Repo

  @chain_id 1
  @vault_address "0xbeef000000000000000000000000000000000099"

  defp build_snapshot(overrides) do
    fetched_at = Keyword.get(overrides, :fetched_at, ~U[2026-05-04 12:00:00.000000Z])
    payload_hash = Keyword.get(overrides, :payload_hash, "concurrent-hash")

    %VaultSnapshot{
      vault_address: @vault_address,
      name: "Steakhouse USDC",
      symbol: "steakUSDC",
      chain_id: @chain_id,
      network: "mainnet",
      listed: true,
      deposit_asset: %{address: "0xusdc", symbol: "USDC", decimals: 6},
      state: %{apy: "0.045", net_apy: "0.041", total_assets: "1234567", fee: "0.04"},
      allocations: [],
      warnings: [],
      pending_caps: [],
      allocators: [],
      source: %{
        fetched_at: fetched_at,
        source_name: "morpho_blue_graphql",
        source_schema_version: "1",
        source_warnings: [],
        payload_hash: payload_hash
      }
    }
  end

  describe "persist/2 — concurrent same-payload race (#199 P2)" do
    test "two concurrent persists of the same successor payload both return {:ok, winner}" do
      # Seed an OLD current row so both tasks observe it as
      # `existing` before either completes its insert.
      assert {:ok, old} = Snapshots.persist(build_snapshot(payload_hash: "old"))
      assert old.current == true
      assert old.payload_hash == "old"

      successor = build_snapshot(payload_hash: "new-shared")

      # Two concurrent persists of the SAME successor.
      results =
        1..2
        |> Task.async_stream(
          fn _ ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), self())
            Snapshots.persist(successor)
          end,
          ordered: false,
          max_concurrency: 2,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      # Both tasks must return {:ok, _}; pre-fix the loser would
      # have returned {:error, %Ecto.Changeset{}} from the unique
      # constraint.
      assert length(results) == 2
      assert Enum.all?(results, &match?({:ok, %PersistedVaultSnapshot{}}, &1))

      # Both tasks see the SAME winning row id (the loser was
      # deduped to it).
      [{:ok, r1}, {:ok, r2}] = results
      assert r1.id == r2.id
      assert r1.payload_hash == "new-shared"

      # Exactly one current row exists for the vault; no inflated
      # supersession chain (only old + winner).
      current = current_rows()
      assert length(current) == 1
      assert hd(current).payload_hash == "new-shared"

      # Total row count: old + winner only — the loser did NOT
      # leave a duplicate row behind.
      assert all_rows_count() == 2
    end

    test "concurrent DIFFERENT-payload races still surface as an error (no silent dedupe)" do
      # Seed an old current.
      assert {:ok, _old} = Snapshots.persist(build_snapshot(payload_hash: "old"))

      # Two concurrent persists of DIFFERENT successors. The fix
      # must NOT mask this as `{:ok, _}` for the loser — the
      # caller's job is to retry against the new winner.
      first_succ = build_snapshot(payload_hash: "diff-first")
      second_succ = build_snapshot(payload_hash: "diff-second")

      results =
        [first_succ, second_succ]
        |> Task.async_stream(
          fn snap ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), self())
            Snapshots.persist(snap)
          end,
          ordered: false,
          max_concurrency: 2,
          timeout: 5_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      ok_count = Enum.count(results, &match?({:ok, _}, &1))
      err_count = Enum.count(results, &match?({:error, _}, &1))

      # Exactly one wins, exactly one errors out — the genuinely-
      # different payload race surfaces, the caller can retry.
      assert ok_count == 1
      assert err_count == 1

      # Only one current row at any time, regardless of who won.
      assert length(current_rows()) == 1
    end
  end

  defp current_rows do
    addr_l = String.downcase(@vault_address)

    import Ecto.Query, only: [from: 2]

    Repo.all(
      from(s in PersistedVaultSnapshot,
        where:
          s.chain_id == ^@chain_id and s.vault_address == ^addr_l and
            s.current == true
      )
    )
  end

  defp all_rows_count, do: Repo.aggregate(PersistedVaultSnapshot, :count)
end
