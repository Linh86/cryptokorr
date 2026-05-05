defmodule Bank.Chains.CanaryCaps do
  @moduledoc """
  Hard caps for the first capped Base mainnet canary broadcast (#181).

  The mainnet eligibility flag (#178) controls *whether* a workspace
  can broadcast on Base mainnet at all. The mainnet preflight (#179)
  verifies the deployment is wired to Base mainnet correctly. The
  no-broadcast rehearsal runbook (#180) walks the operator through
  proving both gates clear without touching chain state. THIS module
  is the next layer: when the rehearsal has cleared and the workspace
  is mainnet-eligible, the canary cap bounds the *first* mainnet
  broadcast to a small, documented amount of a documented asset on a
  documented chain.

  ## Where the cap fires

  In the dispatch worker (`Bank.Runtime.Workers.RunExecution`), AFTER
  `verify_mainnet_allowed/1` and BEFORE the row is claimed for
  dispatch. So a plan whose `(chain, asset, amount)` violates the cap
  is aborted with `final_reason: "canary_<reason>"` and **never**
  reaches `Bank.AdapterClient`. This is the load-bearing point — the
  cap is enforced **in code**, not just in the runbook, satisfying
  the issue's "Amount/asset/chain are capped in code or config, not
  only docs" acceptance criterion.

  Testnet plans bypass the cap entirely (`Bank.Chains.mainnet?/1`
  returns `false`). The cap only fires for mainnet plans, after the
  workspace `mainnet_enabled` gate has cleared.

  ## What's capped (v0.1 defaults)

    * **Chain.** Only `"base"` (Base mainnet). Adding other mainnet
      chains (e.g. `"ethereum"`) is a deliberate product decision,
      not a config flag — the default `allowed_chains` list ships
      with exactly one element.
    * **Asset.** Only `"USDC"`. Other ERC-20s and native ETH are
      blocked.
    * **Per-broadcast amount.** Defaults to `Decimal.new("10.00")`
      USDC. An operator can adjust the cap via
      `config :bank, Bank.Chains.CanaryCaps, amount_caps: %{...}`,
      but the v0.1 default is the smallest amount that's
      operationally meaningful while still capping a misconfigured
      transfer to a real-money loss the operator can recover from.

  ## What's NOT capped here

    * **Cumulative / daily caps.** Out of scope for #181. A
      per-day or per-workspace cumulative cap is a future
      enhancement that needs cross-broadcast persistent state.
    * **Workspace eligibility.** `Bank.Workspaces.Workspace.mainnet_enabled`
      is the existing #178 gate; `Bank.Chains.validate_mainnet_allowed/2`
      upstream of this module is the canonical fail-closed gate.
      The cap module assumes those have already cleared.
    * **Pause / kill switch.** `Bank.Security.paused?/1` is checked
      upstream by `verify_not_paused/1`. The canary cap layer does
      not duplicate that gate.

  ## Failure-mode atoms (fixed allowlist)

  Each clause returns `{:error, reason}` where `reason` is one of:

    * `:canary_chain_not_allowed` — chain is mainnet but not in
      `allowed_chains`.
    * `:canary_asset_not_allowed` — asset is `nil` or not in
      `allowed_assets`.
    * `:canary_amount_exceeded` — amount is `nil`, unparseable, or
      exceeds the per-asset cap.

  Passing those atoms through `Atom.to_string/1` yields the
  matching `final_reason` string used in the `execution.aborted`
  audit event row, mirroring the shape used by `mainnet_disabled`.

  ## Test injection

  `validate/4` accepts an `:caps` keyword option that overrides the
  default config-driven map. Tests pass `caps:` to keep the gate
  deterministic without mutating global `Application` state.

      Bank.Chains.CanaryCaps.validate(
        "base", "USDC", Decimal.new("5.00"),
        caps: %{
          allowed_chains: ["base"],
          allowed_assets: ["USDC"],
          amount_caps: %{"USDC" => Decimal.new("10.00")}
        }
      )

  ## No chain side effects

  This module never:

    * makes any chain RPC call,
    * issues any HTTP request,
    * persists or mutates DB rows,
    * reads any secret material.

  It is a pure (chain, asset, amount) → `:ok | {:error, atom}` gate
  read from `Application` config. Same posture as `Bank.Chains`
  itself.
  """

  alias Bank.Chains

  @default_caps %{
    allowed_chains: ["base"],
    allowed_assets: ["USDC"],
    amount_caps: %{"USDC" => Decimal.new("10.00")}
  }

  @type cap_failure ::
          :canary_chain_not_allowed
          | :canary_asset_not_allowed
          | :canary_amount_exceeded

  @type caps :: %{
          required(:allowed_chains) => [String.t()],
          required(:allowed_assets) => [String.t()],
          required(:amount_caps) => %{String.t() => Decimal.t()}
        }

  @doc """
  Default caps as a frozen map. Stable across releases — adding a
  chain or asset here is an explicit product decision, not a
  config flag.
  """
  @spec default_caps() :: caps()
  def default_caps, do: @default_caps

  @doc """
  Returns the active caps. `Application.get_env(:bank, __MODULE__)`
  overrides each individual key; absent keys fall through to the
  defaults.

  `amount_caps` values may be `Decimal.t()`, `String.t()`, or
  integer in the config map; they are normalized to `Decimal.t()`
  here so callers (and tests) can write `"1000000"` in
  `config/*.exs` without depending on `Decimal` being available at
  config compile time.
  """
  @spec caps() :: caps()
  def caps do
    overrides = Application.get_env(:bank, __MODULE__, [])

    amount_caps =
      overrides
      |> Keyword.get(:amount_caps, @default_caps.amount_caps)
      |> Map.new(fn {asset, value} -> {asset, normalize_cap(value)} end)

    %{
      allowed_chains: Keyword.get(overrides, :allowed_chains, @default_caps.allowed_chains),
      allowed_assets: Keyword.get(overrides, :allowed_assets, @default_caps.allowed_assets),
      amount_caps: amount_caps
    }
  end

  defp normalize_cap(%Decimal{} = cap), do: cap
  defp normalize_cap(value) when is_integer(value), do: Decimal.new(value)
  defp normalize_cap(value) when is_binary(value), do: Decimal.new(value)

  @doc """
  Validate `(chain, asset, amount)` against the canary caps.

  Testnet and unknown chains pass through (`:ok`) — the cap only
  fires for mainnet chains. Mainnet chains must (a) be in
  `allowed_chains`, (b) carry an asset in `allowed_assets`, and
  (c) carry an amount no larger than the per-asset cap.

  Options:

    * `:caps` — explicit caps map. Tests pass this to keep the
      gate deterministic without mutating global `Application`
      state.

  Returns `:ok` or `{:error, cap_failure()}`.
  """
  @spec validate(any(), any(), any(), keyword()) :: :ok | {:error, cap_failure()}
  def validate(chain, asset, amount, opts \\ []) do
    caps = Keyword.get(opts, :caps, caps())

    cond do
      not Chains.mainnet?(chain) ->
        :ok

      chain not in caps.allowed_chains ->
        {:error, :canary_chain_not_allowed}

      not (is_binary(asset) and asset in caps.allowed_assets) ->
        {:error, :canary_asset_not_allowed}

      true ->
        validate_amount(asset, amount, caps.amount_caps)
    end
  end

  defp validate_amount(asset, amount, amount_caps) do
    with {:ok, %Decimal{} = cap} <- Map.fetch(amount_caps, asset),
         {:ok, %Decimal{} = decimal} <- to_decimal(amount),
         :within <- compare(decimal, cap) do
      :ok
    else
      _ -> {:error, :canary_amount_exceeded}
    end
  end

  defp to_decimal(%Decimal{} = amount), do: {:ok, amount}

  defp to_decimal(amount) when is_integer(amount), do: {:ok, Decimal.new(amount)}

  defp to_decimal(amount) when is_binary(amount) do
    case Decimal.parse(amount) do
      {%Decimal{} = decimal, ""} -> {:ok, decimal}
      _ -> :error
    end
  end

  defp to_decimal(_), do: :error

  defp compare(%Decimal{} = amount, %Decimal{} = cap) do
    case Decimal.compare(amount, cap) do
      :gt -> :over
      _ -> :within
    end
  end
end
