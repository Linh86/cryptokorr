defmodule Bank.DefiVenues.Morpho.OperatorWithdraw do
  @moduledoc """
  Operator-only Morpho ERC-4626 withdraw / redeem safety path
  (#207).

  This module is the SINGLE entry point for an operator-initiated
  Morpho withdraw. Agents have no path here — there is no
  `:withdraw` value in `Bank.Intents.AgentIntent.@kinds`, and the
  public `Bank.Intents.normalize/1` boundary cannot map any
  request to a withdraw action regardless of the public string
  supplied.

  ## What this module does

    * Validates the caller is an operator (`actor_role: :operator`).
      Any other role is rejected with `:operator_role_required` —
      including `:agent`, `:runtime`, or a missing role.
    * Loads the workspace's allowlisted vault snapshot and runs
      `Bank.DefiVenues.Morpho.WithdrawPreview.preview/3` to compute
      max-withdrawable + would_block? + would_partial? signals.
    * Applies the block-or-explicit-partial gate per #207
      acceptance:
        * `would_block? == true` → `:morpho_withdraw_blocked`.
        * `would_partial? == true` and the caller did not pass
          `:allow_partial` → `:morpho_withdraw_partial_required`.
        * `would_partial? == true` and `:allow_partial` is true →
          the request is accepted with `effective_assets` clamped
          to `max_withdrawable` so the dispatch envelope cannot
          ask for more than the vault can give.
    * Emits a chain of `morpho.withdraw_*` audit events tagged
      with a per-request `correlation_id` so replay can rebuild
      the operator's narrative independently of any intent.
        * `morpho.withdraw_previewed` — preview snapshot; always
          emitted on a successful preview.
        * `morpho.withdraw_blocked` — emitted when the gate
          refuses (insufficient liquidity OR partial without
          explicit consent).
        * `morpho.withdraw_planned` — emitted when the request is
          accepted; the dispatch is the next slice (#207
          follow-up).

  ## What this module does NOT do (yet)

    * No on-chain broadcast. Adapter-side ERC-4626
      `withdraw(assets, receiver, owner)` dispatch is a follow-up
      slice — the safety path (preview + gate + audit + replay) is
      the value of #207. The audit row's `correlation_id` is
      forward-compatible: when adapter dispatch lands it can
      thread the same id through.
    * No `morpho_withdraw_requests` table row. The audit log is
      the source of truth for operator-action records;
      `Bank.Audit.replay/1` already filters morpho events by
      `event_type` prefix `morpho.` and groups by
      `correlation_id`, so the operator-initiated chain renders
      without a dedicated parent row.
    * No SDK / MCP / REST surface in this PR. The operator-only
      function is callable from `iex` / a future operator
      controller. Wire-level surface is a deliberate follow-up so
      the safety path can ship and be verified before any HTTP
      surface that could leak the operator privilege boundary.

  ## Hard safety boundaries

    * **Operator-only.** `actor_role: :operator` required; any
      other role refused. Agents have no callable path here.
    * **Base Sepolia + USDC + allowlisted vault only.** The
      caller must pass an `allowlisted` vault address; the
      workspace's `:allowed_vault` policy rules are the source of
      truth. Mismatch → `:morpho_withdraw_vault_not_allowlisted`.
    * **No arbitrary calldata.** The (future) adapter dispatch
      builds calldata itself from `vault_address`, `amount`, and
      `receiver` — the operator never supplies bytes.
    * **Withdraw is operator-only and never agent-initiated.**
      Verified by `Bank.Intents` agent boundary tests
      (`AgentIntent.@kinds` deliberately omits `:withdraw`).
  """

  alias Bank.Audit.Events
  alias Bank.DefiVenues.Morpho.{Snapshots, WithdrawPreview}
  alias Bank.Policies
  alias Bank.Policies.PolicyRule
  alias Bank.Runtime

  @chain "base-sepolia"
  @chain_id 84_532
  @asset "USDC"

  @type request_opts :: [
          actor_id: String.t(),
          actor_role: atom(),
          allow_partial: boolean(),
          rules_loader: (String.t() -> [PolicyRule.t()]),
          snapshot_loader: (integer(), String.t() -> any())
        ]

  @type accepted :: %{
          correlation_id: String.t(),
          preview: WithdrawPreview.preview(),
          effective_assets: Decimal.t(),
          partial?: boolean(),
          chain: String.t(),
          asset: String.t(),
          vault_address: String.t()
        }

  @type failure ::
          :operator_role_required
          | :morpho_withdraw_vault_not_allowlisted
          | :morpho_withdraw_snapshot_missing
          | :morpho_withdraw_blocked
          | :morpho_withdraw_partial_required
          | :morpho_withdraw_invalid_amount
          | :morpho_withdraw_snapshot_invalid

  @doc """
  Compute and return a withdraw preview WITHOUT requesting
  anything. Operator-only — same role gate as `request_withdraw/4`.

  Useful for operator-side inspection before authorising a real
  withdraw.

  Returns `{:ok, preview}` or `{:error, failure()}`.
  """
  @spec preview(String.t(), String.t(), Decimal.t(), request_opts()) ::
          {:ok, WithdrawPreview.preview()} | {:error, failure()}
  def preview(workspace_id, vault_address, requested_assets, opts \\ []) do
    with :ok <- validate_operator_role(opts),
         :ok <- validate_vault_allowlist(workspace_id, vault_address, opts),
         {:ok, snapshot} <- load_snapshot(vault_address, opts),
         {:ok, preview} <- WithdrawPreview.preview(snapshot, requested_assets, chain: @chain) do
      _ = emit_previewed(workspace_id, opts, preview)
      {:ok, preview}
    end
  end

  @doc """
  Operator-initiated withdraw request.

  Validates operator role + vault allowlist, computes preview,
  applies the block-or-explicit-partial gate, and emits the
  `morpho.withdraw_*` audit chain. Returns `{:ok, accepted}` with
  a stable `correlation_id` the operator can use for audit
  lookup, or `{:error, failure()}` with the structured refusal
  reason.

  Required opts:
    * `:actor_id` — operator user UUID (audit attribution).
    * `:actor_role` — must be `:operator`. Any other value is
      refused.

  Optional opts:
    * `:allow_partial` — when `true`, a request larger than
      `max_withdrawable` is clamped to `max_withdrawable`
      instead of rejected.
    * `:rules_loader` / `:snapshot_loader` — test-injectable
      loaders mirroring `MorphoDispatchSafety` (#206).
    * `:correlation_id` — pre-generated UUID; defaults to a
      fresh one. Stable across the audit chain so replay can
      group preview / blocked / planned rows.
  """
  @spec request_withdraw(String.t(), String.t(), Decimal.t(), request_opts()) ::
          {:ok, accepted()} | {:error, failure()}
  def request_withdraw(workspace_id, vault_address, requested_assets, opts) do
    correlation_id = Keyword.get(opts, :correlation_id, Ecto.UUID.generate())
    opts = Keyword.put(opts, :correlation_id, correlation_id)

    with :ok <- validate_operator_role(opts),
         :ok <- validate_vault_allowlist(workspace_id, vault_address, opts),
         {:ok, snapshot} <- load_snapshot(vault_address, opts),
         {:ok, preview} <- WithdrawPreview.preview(snapshot, requested_assets, chain: @chain),
         _ = emit_previewed(workspace_id, opts, preview),
         {:ok, effective, partial?} <- apply_block_or_partial(preview, opts) do
      _ = emit_planned(workspace_id, opts, preview, effective, partial?)

      {:ok,
       %{
         correlation_id: correlation_id,
         preview: preview,
         effective_assets: effective,
         partial?: partial?,
         chain: @chain,
         asset: @asset,
         vault_address: vault_address
       }}
    else
      {:error, reason} = err
      when reason in [:morpho_withdraw_blocked, :morpho_withdraw_partial_required] ->
        # Emit the blocked event so replay surfaces the refused
        # operator action even when no plan is created.
        emit_blocked_safe(workspace_id, opts, vault_address, reason)
        err

      err ->
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Gates
  # ---------------------------------------------------------------------------

  defp validate_operator_role(opts) do
    case Keyword.get(opts, :actor_role) do
      :operator -> :ok
      _ -> {:error, :operator_role_required}
    end
  end

  defp validate_vault_allowlist(workspace_id, vault_address, opts) do
    loader =
      Keyword.get(opts, :rules_loader, fn ws_id ->
        Policies.list_rules(%{rule_type: :allowed_vault}, workspace_id: ws_id)
      end)

    rules = loader.(workspace_id)

    if Enum.any?(rules, &rule_matches_vault?(&1, vault_address)) do
      :ok
    else
      {:error, :morpho_withdraw_vault_not_allowlisted}
    end
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

  defp load_snapshot(vault_address, opts) do
    loader = Keyword.get(opts, :snapshot_loader, fn ci, va -> Snapshots.get_current(ci, va) end)

    case loader.(@chain_id, vault_address) do
      nil -> {:error, :morpho_withdraw_snapshot_missing}
      snapshot -> {:ok, snapshot}
    end
  end

  # Block-or-explicit-partial gate. Returns `{:ok, effective_assets,
  # partial?}` on accept, structured error on refuse.
  defp apply_block_or_partial(%{would_block?: true}, _opts),
    do: {:error, :morpho_withdraw_blocked}

  defp apply_block_or_partial(%{would_partial?: true} = preview, opts) do
    if Keyword.get(opts, :allow_partial, false) do
      {:ok, preview.max_withdrawable, true}
    else
      {:error, :morpho_withdraw_partial_required}
    end
  end

  defp apply_block_or_partial(%{requested_assets: amount}, _opts), do: {:ok, amount, false}

  # ---------------------------------------------------------------------------
  # Audit emission
  # ---------------------------------------------------------------------------

  defp emit_previewed(workspace_id, opts, preview) do
    Runtime.emit_audit(
      Events.morpho_withdraw_previewed(workspace_id, preview,
        actor_id: Keyword.get(opts, :actor_id),
        correlation_id: Keyword.get(opts, :correlation_id)
      )
    )
  end

  defp emit_planned(workspace_id, opts, preview, effective_assets, partial?) do
    Runtime.emit_audit(
      Events.morpho_withdraw_planned(workspace_id, preview, effective_assets, partial?,
        actor_id: Keyword.get(opts, :actor_id),
        correlation_id: Keyword.get(opts, :correlation_id)
      )
    )
  end

  defp emit_blocked_safe(workspace_id, opts, vault_address, reason) do
    Runtime.emit_audit(
      Events.morpho_withdraw_blocked(workspace_id, vault_address, reason,
        actor_id: Keyword.get(opts, :actor_id),
        correlation_id: Keyword.get(opts, :correlation_id)
      )
    )
  end
end
