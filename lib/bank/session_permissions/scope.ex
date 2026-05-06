defmodule Bank.SessionPermissions.Scope do
  @moduledoc """
  Canonical scope summary for the MVP browser-driven session
  permission install (#171).

  Phoenix's outer policy gate already enforces every transfer,
  swap, and Morpho deposit independently of the on-chain
  validator. The scope here is the *summary* the user sees and
  consents to before the install dispatches — and the same
  summary persists onto the delegation row so the operator can
  audit what the agent was authorized to do.

  ## What is allowed

    * `usdc_transfer`     — USDC transfers under Phoenix policy.
    * `zero_x_swap`       — 0x-routed swaps on Base Sepolia.
    * `morpho_4626_deposit` — ERC-4626 deposit into the single
      allowlisted Morpho USDC vault.

  ## What is explicitly denied

    * `withdraw` / `redeem` — operator-only paths that must never
      land in an agent permission.
    * `arbitrary_calldata` — no raw calldata escape hatch.
    * `unlimited_approvals` — every approval is per-call, bounded
      by policy.
    * `borrow` / `leverage` / `looping` — out of MVP scope, must
      stay out of the agent permission.
    * `mainnet` — Base mainnet (8453) is post-MVP.

  ## Why this lives in Phoenix and not the adapter

  v0.1 adapter installs a sudo `PermissionPlugin` (see
  `chain_adapter/src/chains/base/grant.ts`); the on-chain
  validator does not yet encode these scopes. The browser-flow
  contract is therefore: Phoenix is the source of truth for the
  scope summary the user authorized; the runtime gate enforces it
  per dispatch; the on-chain validator widens the trust surface
  later (#171 follow-up tracked under wagmi/viem SDK adoption).
  """

  @scope_version "1"
  @kernel_version "v3.1"
  @chain_id 84_532

  @allowed [
    %{
      "kind" => "usdc_transfer",
      "policy_gated" => true,
      "label" => "Transfer USDC under Phoenix policy",
      "rationale" =>
        "Per-call limits, recipient allowlist, and pause gates are enforced at the runtime decision layer."
    },
    %{
      "kind" => "zero_x_swap",
      "policy_gated" => true,
      "label" => "Execute 0x swap routes on Base Sepolia",
      "rationale" =>
        "Quote source, route, slippage cap, and counterparty allowlist are gated by the swap decision pipeline."
    },
    %{
      "kind" => "morpho_4626_deposit",
      "policy_gated" => true,
      "label" => "Deposit USDC into the allowlisted Morpho ERC-4626 vault",
      "rationale" =>
        "Single-vault allowlist; deposit-only path; redeem is operator-only and excluded from the agent permission."
    }
  ]

  @denied [
    %{"kind" => "withdraw_redeem", "label" => "Withdraw or redeem from any vault"},
    %{"kind" => "arbitrary_calldata", "label" => "Arbitrary calldata"},
    %{"kind" => "unlimited_approvals", "label" => "Unlimited token approvals"},
    %{"kind" => "borrow_leverage", "label" => "Borrow / leverage / looping"},
    %{"kind" => "mainnet", "label" => "Mainnet execution (Base or Ethereum mainnet)"}
  ]

  @doc """
  Return the canonical scope map for the MVP install. The same
  shape is persisted on the delegation row's `scope` JSON column
  and surfaced in the audit `after_ref`.
  """
  @spec default() :: map()
  def default do
    %{
      "version" => @scope_version,
      "kernel_version" => @kernel_version,
      "chain_id" => @chain_id,
      "allowed" => @allowed,
      "denied" => @denied
    }
  end

  @doc """
  Allowed action summaries for UI rendering. Each entry has
  `kind`, `label`, and `rationale` keys.
  """
  @spec allowed() :: [map()]
  def allowed, do: @allowed

  @doc """
  Denied action summaries for UI rendering.
  """
  @spec denied() :: [map()]
  def denied, do: @denied

  @doc """
  Chain id this scope is valid on.
  """
  @spec chain_id() :: integer()
  def chain_id, do: @chain_id

  @doc """
  Build the audit `after_ref` body — the same shape as
  `default/0` minus any field that could be revisited as user-
  identifying or scope-leaking. Right now the scope itself is
  fully public, so this returns the full default. The function
  exists so audit redaction has a single seam to thread future
  redactions through.
  """
  @spec audit_summary() :: map()
  def audit_summary, do: default()
end
