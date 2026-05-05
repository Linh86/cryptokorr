defmodule Bank.Chains do
  @moduledoc """
  Chain identifier classification (#178).

  Single source of truth for "is this chain string a mainnet?" The
  runtime, decision pipeline, dispatch worker, and HTTP controllers
  all consume `mainnet?/1` and the workspace-aware
  `mainnet_allowed_for?/2` to fail closed on mainnet chains when
  the calling workspace has not been explicitly cleared for
  mainnet operation.

  ## Classification

  Chain strings are partitioned into three sets:

    * **mainnet** — `#{inspect(~w(base ethereum))}`. Mainnet
      classification is the conservative default for any
      production-like chain identifier the codebase knows about.
    * **testnet** — `#{inspect(~w(base-sepolia sepolia goerli))}`.
      Testnet chains are always allowed; the mainnet eligibility
      flag has no effect on them.
    * **unknown** — anything else. `mainnet?/1` returns `false`
      for unknown chains because the runtime's intent-submission
      surface (`Bank.Intents.require_chain/1`) already rejects
      unsupported chains at the wire boundary; an unknown string
      can never reach a gate where `mainnet?/1` would matter, but
      classifying it as not-mainnet keeps the gate's failure mode
      predictable for any latent bug.

  The same partition is documented in
  `Bank.Decisions.Report.flags_section/2` (the `:mainnet?` /
  `:testnet?` flags rendered into the human-readable decision
  report). This module is the canonical source; Report consumes
  it via `mainnet?/1` so the classification cannot drift.

  ## Mainnet eligibility

  `mainnet_allowed_for?(chain, workspace_id)` answers the gate
  question every chain-touching boundary needs:

    * Testnet (or unknown) chain ⇒ always `true`.
    * Mainnet chain + workspace flag on ⇒ `true`.
    * Mainnet chain + workspace flag off ⇒ `false`.
    * Mainnet chain + `nil` workspace_id ⇒ `true` (legacy
      pass-through).

  The `nil` workspace_id pass-through mirrors the precedent set
  by `Bank.Decisions.validate_not_paused/2`: legacy unscoped code
  paths (#158 tail) skip workspace-scoped gates entirely. Every
  controller and worker that reaches a mainnet broadcast in
  production goes through workspace-scoped auth, so a nil
  workspace_id at a chain-touching boundary is by construction
  a test-only or admin-bootstrap path. New code must always carry
  a workspace_id; this fallback is documented and tested but
  intentionally a transitional shape.

  ## Why a separate module

  The classification lives outside `Bank.Workspaces` because the
  *chain* belongs to a different ownership domain than the
  *workspace eligibility flag*. Keeping them apart means a future
  change to chain identifiers (e.g. adding `:base-mainnet` as a
  distinct alias for `:base`) is one edit in one place.

  ## Read-only / no chain side effects

  This module never:

    * makes any chain RPC call,
    * issues any HTTP request,
    * persists or mutates DB rows,
    * reads or writes config beyond the in-process `Application` env
      lookup `Bank.Workspaces.mainnet_enabled?/1` performs against the
      caller-supplied workspace id.
  """

  alias Bank.Workspaces

  @mainnet_chains ~w(base ethereum)
  @testnet_chains ~w(base-sepolia sepolia goerli)

  @doc """
  Return the canonical mainnet chain identifiers.

  Stable across releases — adding a chain here is an explicit
  product decision, not a fixture change.
  """
  @spec mainnet_chains() :: [String.t()]
  def mainnet_chains, do: @mainnet_chains

  @doc """
  Return the canonical testnet chain identifiers.
  """
  @spec testnet_chains() :: [String.t()]
  def testnet_chains, do: @testnet_chains

  @doc """
  True iff `chain` is a mainnet identifier.

  Returns `false` for `nil`, empty strings, and any string not in
  `mainnet_chains/0`. Never raises — every gate that consumes this
  is a fail-closed boundary that already rejects empty/nil chains
  earlier in the pipeline.
  """
  @spec mainnet?(any()) :: boolean()
  def mainnet?(chain) when is_binary(chain), do: chain in @mainnet_chains
  def mainnet?(_), do: false

  @doc """
  True iff `chain` is a testnet identifier.

  Companion to `mainnet?/1`; both can be `false` for an unknown
  chain string.
  """
  @spec testnet?(any()) :: boolean()
  def testnet?(chain) when is_binary(chain), do: chain in @testnet_chains
  def testnet?(_), do: false

  @doc """
  Classify `chain` into `:mainnet`, `:testnet`, or `:unknown`.

  Useful for telemetry and operator display where a single tag is
  more readable than two booleans.
  """
  @spec classify(any()) :: :mainnet | :testnet | :unknown
  def classify(chain) when is_binary(chain) do
    cond do
      chain in @mainnet_chains -> :mainnet
      chain in @testnet_chains -> :testnet
      true -> :unknown
    end
  end

  def classify(_), do: :unknown

  @doc """
  True iff the workspace is allowed to use `chain`.

  The gate only restricts mainnet chains. Testnet and unknown
  chains pass through unchanged — they're handled by the
  intent-submission allowlist (`Bank.Intents.require_chain/1`)
  and the chain-pause surface (`Bank.Security.paused?/2`),
  respectively.

  A `nil` `workspace_id` is treated as "no workspace" → mainnet
  rejected. This is the legacy-safe default for callers that
  have not yet been workspace-scoped.
  """
  @spec mainnet_allowed_for?(any(), Ecto.UUID.t() | nil) :: boolean()
  def mainnet_allowed_for?(chain, workspace_id) do
    cond do
      not mainnet?(chain) -> true
      is_nil(workspace_id) -> true
      is_binary(workspace_id) -> Workspaces.mainnet_enabled?(workspace_id)
      true -> false
    end
  end

  @doc """
  Validate that `chain` is allowed for the given `workspace_id`.

  Returns `:ok` when the workspace either does not target a
  mainnet chain or has explicitly opted into mainnet. Returns
  `{:error, :mainnet_disabled}` otherwise.

  This is the canonical gate every chain-touching boundary
  (intent submission, decision pipeline, dispatch worker, revoke)
  uses to fail closed on mainnet without an explicit eligibility
  flag.
  """
  @spec validate_mainnet_allowed(any(), Ecto.UUID.t() | nil) ::
          :ok | {:error, :mainnet_disabled}
  def validate_mainnet_allowed(chain, workspace_id) do
    if mainnet_allowed_for?(chain, workspace_id),
      do: :ok,
      else: {:error, :mainnet_disabled}
  end
end
