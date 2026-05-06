defmodule Bank.Decisions.MorphoDispatchSafety do
  @moduledoc """
  Centralised pre-dispatch safety gate for Morpho ERC-4626 deposit
  execution plans (#206).

  Single function every Morpho dispatch path must call before
  handing the plan to the adapter. The gate is fail-closed and
  layered on top of the universal pause/mainnet/delegation gates
  already enforced by `Bank.Runtime.Workers.RunExecution`.

  Re-checks five Morpho-specific invariants at dispatch time:

    1. **Chain is Base Sepolia.** v0.1 Morpho is testnet only.
       `chain: "base"` (mainnet) is rejected here even though the
       universal mainnet gate would also rejected it once the
       workspace flag is the default. Belt and suspenders.
    2. **Asset is USDC.** Single-asset MVP.
    3. **Vault address is in the workspace's active Morpho
       allowlist.** Pulled fresh from `Bank.Policies` so a
       revocation between approval and dispatch is honoured.
    4. **Vault snapshot is fresh.** The current snapshot's
       per-field freshness summary must contain no `:expired`
       state for any required field. Stale `:stale` (degraded but
       not yet expired) is permitted; expired aborts.
    5. **Snapshot has not materially changed.** The current
       snapshot's `payload_hash` must match the hash captured on
       the plan at creation time. Material drift means the
       operator approved against a different vault state than the
       one we're about to broadcast against; fail closed and let
       the operator re-approve.

  The receiver smart account / delegation activeness is checked by
  the worker's existing `verify_delegation/1` gate before this
  function runs; we do not duplicate that here.

  ## Failure-mode atoms

    * `:morpho_chain_not_supported` — `plan.chain != "base-sepolia"`.
    * `:morpho_asset_not_supported` — `plan.asset != "USDC"`.
    * `:morpho_vault_not_allowlisted` — vault is not in the
      workspace's active Morpho `:allowed_vault` rule set.
    * `:morpho_snapshot_missing` — `Snapshots.get_current/2`
      returned nil for the (chain_id, vault_address) pair on the
      plan. The vault has no current snapshot row.
    * `:morpho_snapshot_expired` — at least one freshness bucket
      is `:expired`. The operator approved against a snapshot that
      is now too old to safely act on.
    * `:morpho_snapshot_drifted` — the current snapshot's
      `payload_hash` differs from the hash captured on the plan.
      Material drift; reapproval required.
    * `:morpho_steps_missing` — the plan's `:steps` JSON does not
      have the `"kind" => "morpho_deposit"` shape we expect. Defensive
      fallback that should never fire in production.

  ## Test injection

  `validate/2` accepts these keyword opts so tests stay
  deterministic without mutating global Application state:

    * `:now` — explicit `DateTime.t()` used for the freshness
      check (defaults to `DateTime.utc_now/0`).
    * `:rules_loader` — 1-arity function that takes the
      `workspace_id` and returns the workspace's active rules. The
      default uses `Bank.Policies.list_rules/2`.
    * `:snapshot_loader` — 2-arity function that takes
      `(chain_id, vault_address)` and returns a
      `PersistedVaultSnapshot.t()` or `nil`. The default uses
      `Bank.DefiVenues.Morpho.Snapshots.get_current/2`.
  """

  alias Bank.Decisions.ExecutionPlan
  alias Bank.DefiVenues.Morpho.{PersistedVaultSnapshot, Snapshots}
  alias Bank.Policies
  alias Bank.Policies.PolicyRule

  @type failure ::
          :morpho_chain_not_supported
          | :morpho_asset_not_supported
          | :morpho_vault_not_allowlisted
          | :morpho_snapshot_missing
          | :morpho_snapshot_expired
          | :morpho_snapshot_drifted
          | :morpho_steps_missing

  @supported_chain "base-sepolia"
  @supported_chain_id 84_532
  @supported_asset "USDC"

  @doc """
  Validate `plan` for Morpho dispatch.

  Returns `:ok` or `{:error, failure()}`. The check order is:
  cheap-and-deterministic first (chain, asset, plan steps shape),
  then policy lookup (workspace rules), then snapshot read.
  """
  @spec validate(ExecutionPlan.t(), keyword()) :: :ok | {:error, failure()}
  def validate(%ExecutionPlan{} = plan, opts \\ []) do
    with :ok <- validate_chain(plan.chain),
         :ok <- validate_asset(plan.asset),
         {:ok, steps} <- extract_steps(plan.steps),
         vault_address = Map.fetch!(steps, "vault_address"),
         :ok <- validate_vault_allowlist(plan.workspace_id, vault_address, opts),
         {:ok, current_snapshot} <-
           load_current_snapshot(@supported_chain_id, vault_address, opts),
         :ok <-
           validate_snapshot_fresh(current_snapshot, Keyword.get(opts, :now, DateTime.utc_now())),
         :ok <- validate_no_material_drift(steps, current_snapshot) do
      :ok
    end
  end

  # --- gate implementations --------------------------------------------------

  defp validate_chain(@supported_chain), do: :ok
  defp validate_chain(_), do: {:error, :morpho_chain_not_supported}

  defp validate_asset(@supported_asset), do: :ok
  defp validate_asset(_), do: {:error, :morpho_asset_not_supported}

  defp extract_steps(%{"kind" => "morpho_deposit", "vault_address" => v} = steps)
       when is_binary(v) and v != "" do
    {:ok, steps}
  end

  defp extract_steps(_), do: {:error, :morpho_steps_missing}

  defp validate_vault_allowlist(workspace_id, vault_address, opts) do
    loader =
      Keyword.get(opts, :rules_loader, fn ws_id ->
        Policies.list_rules(%{rule_type: :allowed_vault}, workspace_id: ws_id)
      end)

    rules = loader.(workspace_id)
    allowlisted = Enum.any?(rules, &rule_matches_vault?(&1, vault_address))

    if allowlisted, do: :ok, else: {:error, :morpho_vault_not_allowlisted}
  end

  defp rule_matches_vault?(
         %PolicyRule{rule_type: :allowed_vault, params: %{} = params},
         vault_address
       ) do
    case Map.get(params, "vault_address") || Map.get(params, :vault_address) do
      addr when is_binary(addr) -> String.downcase(addr) == String.downcase(vault_address)
      _ -> false
    end
  end

  defp rule_matches_vault?(_rule, _vault), do: false

  defp load_current_snapshot(chain_id, vault_address, opts) do
    loader =
      Keyword.get(opts, :snapshot_loader, fn ci, va -> Snapshots.get_current(ci, va) end)

    case loader.(chain_id, vault_address) do
      %PersistedVaultSnapshot{} = snapshot -> {:ok, snapshot}
      _ -> {:error, :morpho_snapshot_missing}
    end
  end

  defp validate_snapshot_fresh(%PersistedVaultSnapshot{} = snapshot, now) do
    summary = Snapshots.freshness_summary(snapshot, now)

    if Enum.any?(summary, fn {_field, state} -> state == :expired end) do
      {:error, :morpho_snapshot_expired}
    else
      :ok
    end
  end

  # Material-drift gate: the snapshot's payload_hash must not have
  # changed since the operator approved the plan. A change means
  # the underlying Morpho data shifted (allocations rebalanced, a
  # warning toggled, allocator change, etc.) — the operator's
  # approval no longer applies; force reapproval rather than
  # broadcasting against drift.
  defp validate_no_material_drift(steps, %PersistedVaultSnapshot{payload_hash: current_hash}) do
    case Map.get(steps, "snapshot_payload_hash") do
      nil ->
        # No hash captured at plan creation (e.g. snapshot was nil
        # then). Conservative: any current hash is "drift" and we
        # refuse to dispatch. Operator must reapprove against the
        # now-existing snapshot.
        {:error, :morpho_snapshot_drifted}

      ^current_hash ->
        :ok

      _other ->
        {:error, :morpho_snapshot_drifted}
    end
  end
end
