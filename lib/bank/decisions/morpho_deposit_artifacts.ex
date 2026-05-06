defmodule Bank.Decisions.MorphoDepositArtifacts do
  @moduledoc """
  Pure transformer that derives the persisted/audited artifacts for a
  Morpho ERC-4626 deposit execution plan from an approved decision
  envelope (#206).

  An operator approval over a `:approval_required` Morpho decision
  produces a successor `:auto_exec` envelope; that successor is fed
  to `Bank.Decisions.create_execution_plan/4` via
  `Bank.Decisions.request_manual_execution/3`. This module reads the
  intent (vault address, asset, amount) and a freshly-resolved vault
  snapshot, and returns the JSON-friendly `:steps` payload + audit
  metadata to pin on the plan row.

  Snapshot freshness and material-drift gating happens at dispatch
  time in `Bank.Decisions.MorphoDispatchSafety`, NOT here. This
  module is concerned only with packaging artifacts; the gate is
  the source of truth for "is this still safe to broadcast?".

  Persisted `:steps` shape:

      %{
        "kind" => "morpho_deposit",
        "vault_address" => "0x…",
        "chain_id" => 84_532,
        "asset" => "USDC",
        "receiver" => "<smart_account_id>",
        "snapshot_id" => "<uuid>",
        "snapshot_payload_hash" => "<hex>",
        "snapshot_fetched_at" => "<iso8601>",
        "policy_rule_ids" => ["<uuid>", …],
        "decision_id" => "<uuid>",
        "approval_actor" => "user" | "runtime"
      }

  Audit metadata (surfaced on `execution.manually_requested` /
  `execution.auto_dispatched` `after_ref` and on the new
  `morpho.deposit_*` events):

      %{
        morpho_vault_address: "0x…",
        morpho_snapshot_id: "<uuid>",
        morpho_snapshot_payload_hash: "<hex>"
      }

  Calldata is NEVER persisted here — the adapter builds calldata
  from `vault_address` + `amount` + `receiver` itself and never
  accepts caller-supplied bytes (see #206 acceptance: "Adapter
  builds calldata itself").
  """

  alias Bank.Decisions.DecisionEnvelope
  alias Bank.DefiVenues.Morpho.PersistedVaultSnapshot
  alias Bank.Intents.AgentIntent

  @type audit_metadata :: %{
          required(:morpho_vault_address) => String.t(),
          required(:morpho_snapshot_id) => String.t() | nil,
          required(:morpho_snapshot_payload_hash) => String.t() | nil
        }

  @type t :: %{
          required(:chain) => String.t(),
          required(:asset) => String.t(),
          required(:steps) => map(),
          required(:audit_metadata) => audit_metadata()
        }

  @doc """
  Build the artifacts bundle from an approved Morpho intent + the
  current vault snapshot resolved at plan-creation time.

  The caller (plan creator) must have already verified that:

    * `intent.kind == :defi_yield_deposit`,
    * `intent.chain == "base-sepolia"` (#203 P2 boundary gate),
    * `snapshot` is the result of
      `Bank.DefiVenues.Morpho.Snapshots.get_current/2` for the
      intent's chain_id + vault_address.

  The receiver is the smart account id that the operator approved
  the dispatch for; the adapter resolves the on-chain account
  address from this id.
  """
  @spec from_intent(
          AgentIntent.t(),
          DecisionEnvelope.t(),
          PersistedVaultSnapshot.t() | nil,
          String.t(),
          [String.t()],
          atom()
        ) :: t()
  def from_intent(
        %AgentIntent{} = intent,
        %DecisionEnvelope{} = envelope,
        snapshot,
        smart_account_id,
        policy_rule_ids,
        approval_actor
      )
      when is_binary(smart_account_id) and is_list(policy_rule_ids) and is_atom(approval_actor) do
    chain_id = chain_id_for(intent.chain)

    %{
      chain: intent.chain,
      asset: intent.asset,
      steps:
        persisted_steps(
          intent,
          envelope,
          snapshot,
          chain_id,
          smart_account_id,
          policy_rule_ids,
          approval_actor
        ),
      audit_metadata: %{
        morpho_vault_address: intent.target_raw_address,
        morpho_snapshot_id: snapshot_id(snapshot),
        morpho_snapshot_payload_hash: snapshot_payload_hash(snapshot)
      }
    }
  end

  defp persisted_steps(
         intent,
         envelope,
         snapshot,
         chain_id,
         smart_account_id,
         policy_rule_ids,
         approval_actor
       ) do
    %{
      "kind" => "morpho_deposit",
      "vault_address" => intent.target_raw_address,
      "chain_id" => chain_id,
      "asset" => intent.asset,
      "receiver" => smart_account_id,
      "snapshot_id" => snapshot_id(snapshot),
      "snapshot_payload_hash" => snapshot_payload_hash(snapshot),
      "snapshot_fetched_at" => snapshot_fetched_at(snapshot),
      "policy_rule_ids" => policy_rule_ids,
      "decision_id" => envelope.id,
      "approval_actor" => Atom.to_string(approval_actor)
    }
  end

  defp snapshot_id(%PersistedVaultSnapshot{id: id}), do: id
  defp snapshot_id(_), do: nil

  defp snapshot_payload_hash(%PersistedVaultSnapshot{payload_hash: h}) when is_binary(h), do: h
  defp snapshot_payload_hash(_), do: nil

  defp snapshot_fetched_at(%PersistedVaultSnapshot{fetched_at: %DateTime{} = ts}),
    do: DateTime.to_iso8601(ts)

  defp snapshot_fetched_at(_), do: nil

  # Lockstep with `Bank.Decisions.MorphoEvaluator.chain_id_for/1` and
  # `Bank.Intents.SwapRoute`'s chain table. The MVP only writes
  # Morpho plans on `"base-sepolia"`; other chains are pre-rejected
  # at the boundary in `Bank.Intents.normalize/1` (#203 P2). Defense
  # in depth: return nil for unknown chains so a future upstream
  # change cannot silently land an unmappable chain id in `:steps`.
  defp chain_id_for("base-sepolia"), do: 84_532
  defp chain_id_for("base"), do: 8453
  defp chain_id_for(_), do: nil
end
