defmodule Bank.DefiVenues.Morpho.WithdrawPreview do
  @moduledoc """
  Pure preview computation for an operator-initiated Morpho ERC-4626
  withdraw / redeem (#207).

  This module is the "what would happen if I asked to withdraw N
  USDC from this vault right now?" gate. It does NOT broadcast
  anything, does NOT mutate any DB row, and does NOT make any chain
  RPC call. It reads a persisted vault snapshot (whose freshness
  the caller has already verified) and returns a structured
  preview the operator can inspect before authorising the actual
  on-chain withdraw via `Bank.DefiVenues.Morpho.OperatorWithdraw`.

  ## Why a snapshot-derived heuristic for v0.1

  The authoritative `IERC4626.maxWithdraw(owner)` value lives
  on-chain. v0.1 deliberately avoids a chain read at preview time —
  the preview layer's job is fail-closed safety, not strict
  precision. The snapshot's `state.total_assets` is the vault's
  absolute liquidity ceiling; an operator-initiated request larger
  than that is unambiguously blockable without a chain round-trip.

  At dispatch time the adapter performs the real
  `maxWithdraw(owner)` read against the chain (#207 follow-up); a
  delta between snapshot-time preview and chain-time max surfaces
  in the structured failure reason on the dispatch callback rather
  than in the preview itself. Treat preview's `:max_withdrawable`
  as an UPPER bound: actual chain maxWithdraw may be lower (other
  withdrawals, cap reductions, etc.) but never higher.

  ## Returned shape

  `preview/3` returns `{:ok, preview()}` where:

      %{
        chain: \"base-sepolia\",
        chain_id: 84_532,
        vault_address: \"0x...\",
        requested_assets: %Decimal{},
        # Snapshot-derived upper bound on the vault's liquidity.
        max_withdrawable: %Decimal{},
        # Operator-action gate signals.
        would_block?: boolean(),
        would_partial?: boolean(),
        snapshot_id: \"<uuid>\",
        snapshot_payload_hash: \"<hex>\",
        snapshot_fetched_at: \"<iso8601>\"
      }

  Failure cases (returned as `{:error, atom()}`):

    * `:morpho_withdraw_invalid_amount` — `requested_assets` is
      `nil`, non-positive, or not a `Decimal.t/0`.
    * `:morpho_withdraw_snapshot_invalid` — snapshot is `nil` or
      its `state.total_assets` field is missing/unparseable.

  Note: chain / asset / vault allowlist enforcement is the
  caller's responsibility (see
  `Bank.DefiVenues.Morpho.OperatorWithdraw.request_withdraw/4`);
  this module trusts the caller has cleared those gates.
  """

  alias Bank.DefiVenues.Morpho.PersistedVaultSnapshot

  @type preview :: %{
          required(:chain) => String.t(),
          required(:chain_id) => integer(),
          required(:vault_address) => String.t(),
          required(:requested_assets) => Decimal.t(),
          required(:max_withdrawable) => Decimal.t(),
          required(:would_block?) => boolean(),
          required(:would_partial?) => boolean(),
          required(:snapshot_id) => String.t(),
          required(:snapshot_payload_hash) => String.t(),
          required(:snapshot_fetched_at) => String.t()
        }

  @type failure :: :morpho_withdraw_invalid_amount | :morpho_withdraw_snapshot_invalid

  @doc """
  Compute a withdraw preview from `requested_assets` against the
  current `snapshot`.

  `chain_label` is the canonical chain string (`"base-sepolia"`)
  used for audit attribution; `chain_id` is read from the snapshot.
  """
  @spec preview(PersistedVaultSnapshot.t(), Decimal.t(), keyword()) ::
          {:ok, preview()} | {:error, failure()}
  def preview(snapshot, requested_assets, opts \\ [])

  def preview(%PersistedVaultSnapshot{} = snapshot, %Decimal{} = requested_assets, opts) do
    with :ok <- validate_amount(requested_assets),
         {:ok, max_withdrawable} <- vault_liquidity_ceiling(snapshot) do
      chain_label = Keyword.get(opts, :chain, "base-sepolia")

      {:ok,
       %{
         chain: chain_label,
         chain_id: snapshot.chain_id,
         vault_address: snapshot.vault_address,
         requested_assets: requested_assets,
         max_withdrawable: max_withdrawable,
         would_block?: would_block?(max_withdrawable),
         would_partial?: would_partial?(requested_assets, max_withdrawable),
         snapshot_id: snapshot.id,
         snapshot_payload_hash: snapshot.payload_hash,
         snapshot_fetched_at: DateTime.to_iso8601(snapshot.fetched_at)
       }}
    end
  end

  def preview(_snapshot, _requested, _opts), do: {:error, :morpho_withdraw_invalid_amount}

  defp validate_amount(%Decimal{} = amount) do
    case Decimal.compare(amount, Decimal.new(0)) do
      :gt -> :ok
      _ -> {:error, :morpho_withdraw_invalid_amount}
    end
  end

  # Vault liquidity ceiling from the persisted snapshot. v0.1 reads
  # `state.total_assets` (string-encoded raw token amount in the
  # vault's deposit-asset decimals); a missing or unparseable value
  # is fail-closed.
  defp vault_liquidity_ceiling(%PersistedVaultSnapshot{state: %{} = state}) do
    raw = Map.get(state, "total_assets") || Map.get(state, :total_assets)

    case decimal_from(raw) do
      {:ok, value} ->
        if Decimal.compare(value, Decimal.new(0)) == :lt,
          do: {:error, :morpho_withdraw_snapshot_invalid},
          else: {:ok, value}

      :error ->
        {:error, :morpho_withdraw_snapshot_invalid}
    end
  end

  defp vault_liquidity_ceiling(_), do: {:error, :morpho_withdraw_snapshot_invalid}

  defp decimal_from(nil), do: :error

  defp decimal_from(value) when is_binary(value) and value != "" do
    case Decimal.parse(value) do
      {decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp decimal_from(value) when is_integer(value), do: {:ok, Decimal.new(value)}
  defp decimal_from(%Decimal{} = d), do: {:ok, d}
  defp decimal_from(_), do: :error

  defp would_block?(%Decimal{} = max_withdrawable) do
    Decimal.compare(max_withdrawable, Decimal.new(0)) != :gt
  end

  defp would_partial?(%Decimal{} = requested, %Decimal{} = max_withdrawable) do
    Decimal.compare(requested, max_withdrawable) == :gt and
      Decimal.compare(max_withdrawable, Decimal.new(0)) == :gt
  end
end
