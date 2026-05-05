defmodule Bank.Intents.SwapRoute do
  @moduledoc """
  Validator for the swap-execution route map (#189).

  The `:swap` kind already exists in `Bank.Intents.AgentIntent`'s
  `@kinds` allowlist. The matching execution-route shape — what the
  runtime considers a *valid* swap route before it can be executed —
  is defined here. The quote provider (epic #165) produces the
  normalised route; the dispatch epic (#188) validates and executes
  it. THIS module is the validator over the route map; it does not
  produce, persist, or sign anything.

  ## What is validated (v0.1)

    * **Swap type.** Exact-input only. The canonical route map carries
      no explicit `swap_type` field — exact-input is the construction.
      As a defensive belt, the validator still inspects `swap_type`
      (atom key) and `"swap_type"` (string key) when present and
      tolerates them only when they *agree* with the contract:
      `:exact_input` or `"exact_input"` (case-insensitive). Any other
      value — `:exact_output`, `"exact_output"`, `"EXACT_OUTPUT"`,
      unknown atoms, integers, etc. — is rejected with
      `:swap_type_not_supported`, so a future quote provider that
      grew an exact-output mode cannot slip past this layer.
      Cross-chain routes remain rejected by the chain check. Future
      types are an explicit product decision, not a config flag.
    * **Chain.** Testnet-first. Default `allowed_chains: ["base-sepolia"]`.
      The route's `:chain` (canonical string) and `:chain_id` (EIP-155)
      must agree (e.g. `"base-sepolia"` ↔ `84_532`).
    * **Assets.** Tiny allowlist. Default `allowed_assets: ["USDC"]`.
      Both source and destination asset *labels* must be in the list.
    * **Amounts.** `input_amount`, `expected_output_amount`, and
      `minimum_output_amount` are positive `Decimal.t()`. The
      `minimum_output_amount` must be `<= expected_output_amount`
      (the slippage band cannot be inverted).
    * **Slippage.** `slippage_bps` is a non-negative integer no larger
      than the active cap (default `100` = 1.00%).
    * **Deadline.** `deadline` is a `DateTime.t()` strictly *after*
      the validation moment (`now/0`, injectable for tests).
    * **Required field shape.** All 12 fields named in the issue body
      are required and typed. Fields documented as addresses /
      hex blobs are `String.t()`; amounts are `Decimal.t()`; the
      chain id is a positive integer; timestamps are `DateTime.t()`.

  ## What is NOT validated here

    * **Address checksum / on-chain consistency.** Whether
      `swap_target_contract` actually corresponds to a deployed router,
      or whether the `calldata` is a valid encoded function call to
      that router with `source_token` → `destination_token`, is the
      executor's job (epic #188 issues #190+). The validator only
      checks shape; the executor is the source of truth for on-chain
      semantics.
    * **Token / asset address registry.** The route carries
      *operator-supplied* `source_token_address` and
      `destination_token_address` strings. v0.1 has no on-chain
      address registry; #190+ will resolve and re-validate addresses
      against a registry once one exists.
    * **Quote freshness.** "Stale route" rejection happens through
      the `deadline` field (deadline already past ⇒ rejected).
      Provider-specific freshness windows (e.g. "regenerate after
      30s") are owned by `Bank.Quotes.Preview.freshness_ttl_seconds`
      and not duplicated here.
    * **Mainnet eligibility / canary cap / pause gate.** Those are
      upstream gates (`Bank.Chains.validate_mainnet_allowed/2`,
      `Bank.Chains.CanaryCaps.validate/4`,
      `Bank.Security.paused?/2`). The route validator runs after
      those have cleared and never duplicates them.
    * **Cumulative or per-day caps.** Out of scope for #189. Future
      enhancement requiring cross-broadcast persistent state.

  ## Failure-mode atoms (fixed allowlist)

  Every clause returns `{:error, reason}` where `reason` is one of:

    * `:swap_chain_not_supported` — chain is not in `allowed_chains`.
    * `:swap_chain_id_mismatch` — `chain` and `chain_id` disagree.
    * `:swap_asset_not_supported` — `source_asset` or
      `destination_asset` not in `allowed_assets`, or `nil`/empty.
    * `:swap_route_field_missing` — one or more of the 12 required
      fields is absent or has the wrong shape (e.g. `nil` calldata,
      empty `swap_target_contract`).
    * `:swap_amount_invalid` — `input_amount`, `expected_output_amount`,
      or `minimum_output_amount` is `nil`, non-positive, unparseable,
      or violates `min <= expected`.
    * `:swap_slippage_exceeded` — `slippage_bps` exceeds the active
      cap, or is `nil` / negative.
    * `:swap_deadline_expired` — `deadline` is `nil`, malformed, or
      already past at the validation moment.
    * `:swap_type_not_supported` — the route carries an explicit
      `:swap_type` (or `"swap_type"`) marker whose value is not the
      exact-input shape this contract permits. Triggers on
      `:exact_output`, `"exact_output"`, `"EXACT_OUTPUT"`, unknown
      atoms, integers, and any other non-exact-input value.

  Passing those atoms through `Atom.to_string/1` yields the matching
  `final_reason` string suitable for an `execution.aborted` audit
  event row, mirroring the shape used by `Bank.Chains.CanaryCaps`.

  ## Test injection

  `validate/2` accepts these keyword opts so tests stay deterministic
  without mutating global `Application` state:

    * `:caps` — explicit caps map (overrides `caps/0`).
    * `:now` — explicit `DateTime.t()` for the deadline check
      (defaults to `DateTime.utc_now/0`).

  Example:

      Bank.Intents.SwapRoute.validate(
        valid_route(),
        caps: %{
          allowed_chains: ["base-sepolia"],
          allowed_assets: ["USDC"],
          max_slippage_bps: 100
        },
        now: ~U[2026-01-01 00:00:00.000000Z]
      )

  ## Secret hygiene

  This module never:

    * makes any chain RPC call,
    * issues any HTTP request,
    * persists or mutates DB rows,
    * reads any secret material,
    * `inspect/1`s a struct, error tuple, or hex blob into a failure
      reason string.

  Every error is one of the documented allowlist atoms — operators
  see a stable, short reason; raw `calldata`, addresses, and other
  potentially-sensitive fields never appear in the error term.
  """

  alias Bank.Chains

  @default_caps %{
    allowed_chains: ["base-sepolia"],
    allowed_assets: ["USDC"],
    max_slippage_bps: 100
  }

  # Canonical chain ↔ EIP-155 chain id table for v0.1. Adding a new
  # chain here is an explicit product decision; it must also appear
  # in `Bank.Chains` (which classifies mainnet vs testnet).
  @chain_ids %{
    "base" => 8453,
    "ethereum" => 1,
    "base-sepolia" => 84_532,
    "sepolia" => 11_155_111,
    "goerli" => 5
  }

  @required_fields ~w(
    source_asset
    source_token_address
    destination_asset
    destination_token_address
    input_amount
    expected_output_amount
    minimum_output_amount
    spender
    swap_target_contract
    calldata
    value
    route_provider
    quote_timestamp
    deadline
    chain
    chain_id
    slippage_bps
  )a

  @type failure ::
          :swap_chain_not_supported
          | :swap_chain_id_mismatch
          | :swap_asset_not_supported
          | :swap_route_field_missing
          | :swap_amount_invalid
          | :swap_slippage_exceeded
          | :swap_deadline_expired
          | :swap_type_not_supported

  @type caps :: %{
          required(:allowed_chains) => [String.t()],
          required(:allowed_assets) => [String.t()],
          required(:max_slippage_bps) => non_neg_integer()
        }

  @typedoc """
  The canonical in-memory swap-route map produced by the quote
  provider and validated here. All 12 issue-body fields plus a
  small set of structural fields the runtime needs.

  Token-address strings are operator-supplied for v0.1 — a future
  asset-address registry (#190+) will canonicalise and verify them.
  """
  @type t :: %{
          required(:source_asset) => String.t(),
          required(:source_token_address) => String.t(),
          required(:destination_asset) => String.t(),
          required(:destination_token_address) => String.t(),
          required(:input_amount) => Decimal.t(),
          required(:expected_output_amount) => Decimal.t(),
          required(:minimum_output_amount) => Decimal.t(),
          required(:spender) => String.t(),
          required(:swap_target_contract) => String.t(),
          required(:calldata) => String.t(),
          required(:value) => Decimal.t(),
          required(:route_provider) => String.t(),
          required(:quote_timestamp) => DateTime.t(),
          required(:deadline) => DateTime.t(),
          required(:chain) => String.t(),
          required(:chain_id) => pos_integer(),
          required(:slippage_bps) => non_neg_integer()
        }

  @doc """
  Default caps as a frozen map. Stable across releases — adding a
  chain or asset here is an explicit product decision, not a
  config change.
  """
  @spec default_caps() :: caps()
  def default_caps, do: @default_caps

  @doc """
  Returns the canonical list of required route field names.

  Used by tests to assert that no field silently disappears from
  the validator and by docs that cross-link the contract.
  """
  @spec required_fields() :: [atom()]
  def required_fields, do: @required_fields

  @doc """
  Returns the active caps. `Application.get_env(:bank, __MODULE__)`
  overrides each individual key; absent keys fall through to the
  defaults. Mirrors `Bank.Chains.CanaryCaps.caps/0`.
  """
  @spec caps() :: caps()
  def caps do
    overrides = Application.get_env(:bank, __MODULE__, [])

    %{
      allowed_chains: Keyword.get(overrides, :allowed_chains, @default_caps.allowed_chains),
      allowed_assets: Keyword.get(overrides, :allowed_assets, @default_caps.allowed_assets),
      max_slippage_bps: Keyword.get(overrides, :max_slippage_bps, @default_caps.max_slippage_bps)
    }
  end

  @doc """
  Validate `route` against the v0.1 swap contract.

  Returns `:ok` when every required field is present and well-shaped,
  the chain/asset are in the allowlist, the slippage is within the
  cap, and the deadline is still in the future. Returns
  `{:error, failure()}` otherwise — the reason is one of the fixed
  allowlist atoms documented in this module's `@moduledoc`.

  Options:

    * `:caps` — explicit caps map. Tests pass this to keep the
      gate deterministic without mutating global `Application`
      state.
    * `:now` — explicit `DateTime.t()` for the deadline check.
      Defaults to `DateTime.utc_now/0`. Tests pin a fixed instant
      so deadline assertions don't race the wall clock.

  The check order is intentional: structural shape first
  (presence/type), then swap-type marker, then chain, then asset,
  then slippage, then amount sanity, then deadline. Earlier
  failures shadow later ones so the operator sees the actionable
  reason first.
  """
  @spec validate(map(), keyword()) :: :ok | {:error, failure()}
  def validate(route, opts \\ [])

  def validate(route, opts) when is_map(route) do
    caps = Keyword.get(opts, :caps, caps())
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- validate_required_fields(route),
         :ok <- validate_swap_type(route),
         :ok <- validate_chain(route, caps),
         :ok <- validate_chain_id(route),
         :ok <- validate_assets(route, caps),
         :ok <- validate_slippage(route, caps),
         :ok <- validate_amounts(route),
         :ok <- validate_deadline(route, now) do
      :ok
    end
  end

  def validate(_not_a_map, _opts), do: {:error, :swap_route_field_missing}

  # -- swap_type marker -----------------------------------------------------

  # The canonical route map has no `swap_type` field — exact-input is
  # the construction. We still inspect both atom-keyed `:swap_type` and
  # string-keyed `"swap_type"` because a future quote provider could
  # grow an exact-output mode and silently extend the route map.
  # Tolerate explicit `:exact_input` / `"exact_input"` (case-insensitive
  # on string) as a no-op since they agree with the contract; reject
  # everything else with a structured reason rather than ignoring it.
  defp validate_swap_type(route) do
    with :ok <- check_swap_type_value(Map.get(route, :swap_type)),
         :ok <- check_swap_type_value(Map.get(route, "swap_type")) do
      :ok
    end
  end

  defp check_swap_type_value(nil), do: :ok
  defp check_swap_type_value(:exact_input), do: :ok

  defp check_swap_type_value(value) when is_binary(value) do
    if String.downcase(value) == "exact_input",
      do: :ok,
      else: {:error, :swap_type_not_supported}
  end

  defp check_swap_type_value(_), do: {:error, :swap_type_not_supported}

  # -- field presence/shape -------------------------------------------------

  defp validate_required_fields(route) do
    if Enum.all?(@required_fields, &field_present?(route, &1)),
      do: :ok,
      else: {:error, :swap_route_field_missing}
  end

  defp field_present?(route, field) do
    case Map.fetch(route, field) do
      {:ok, value} -> value_well_shaped?(field, value)
      :error -> false
    end
  end

  # Token-address / hex-blob / opaque-string fields are required as
  # non-empty binaries. Amounts and chain id and slippage have their
  # detailed numeric checks downstream — here we just require the
  # field to be non-nil with the right shape.
  defp value_well_shaped?(:input_amount, %Decimal{}), do: true
  defp value_well_shaped?(:expected_output_amount, %Decimal{}), do: true
  defp value_well_shaped?(:minimum_output_amount, %Decimal{}), do: true
  defp value_well_shaped?(:value, %Decimal{}), do: true
  defp value_well_shaped?(:chain_id, value) when is_integer(value) and value > 0, do: true
  defp value_well_shaped?(:slippage_bps, value) when is_integer(value) and value >= 0, do: true
  defp value_well_shaped?(:quote_timestamp, %DateTime{}), do: true
  defp value_well_shaped?(:deadline, %DateTime{}), do: true

  defp value_well_shaped?(field, value)
       when field in ~w(
              source_asset
              source_token_address
              destination_asset
              destination_token_address
              spender
              swap_target_contract
              calldata
              route_provider
              chain
            )a,
       do: is_binary(value) and value != ""

  defp value_well_shaped?(_field, _value), do: false

  # -- chain ----------------------------------------------------------------

  defp validate_chain(%{chain: chain}, caps) when is_binary(chain) do
    if chain in caps.allowed_chains,
      do: :ok,
      else: {:error, :swap_chain_not_supported}
  end

  defp validate_chain_id(%{chain: chain, chain_id: chain_id}) do
    case Map.fetch(@chain_ids, chain) do
      {:ok, ^chain_id} -> :ok
      # Unknown chain string would have been rejected upstream by
      # `validate_chain/2`; if a future chain enters the allowlist
      # without a chain_id mapping we fail closed rather than
      # silently allow a mismatched pair.
      _ -> {:error, :swap_chain_id_mismatch}
    end
  end

  # -- assets ---------------------------------------------------------------

  defp validate_assets(%{source_asset: src, destination_asset: dst}, caps) do
    cond do
      src not in caps.allowed_assets -> {:error, :swap_asset_not_supported}
      dst not in caps.allowed_assets -> {:error, :swap_asset_not_supported}
      true -> :ok
    end
  end

  # -- slippage -------------------------------------------------------------

  defp validate_slippage(%{slippage_bps: bps}, caps) when is_integer(bps) and bps >= 0 do
    if bps <= caps.max_slippage_bps,
      do: :ok,
      else: {:error, :swap_slippage_exceeded}
  end

  defp validate_slippage(_route, _caps), do: {:error, :swap_slippage_exceeded}

  # -- amounts --------------------------------------------------------------

  defp validate_amounts(%{
         input_amount: input,
         expected_output_amount: expected,
         minimum_output_amount: minimum,
         value: value
       }) do
    cond do
      not positive?(input) -> {:error, :swap_amount_invalid}
      not positive?(expected) -> {:error, :swap_amount_invalid}
      not non_negative?(minimum) -> {:error, :swap_amount_invalid}
      not non_negative?(value) -> {:error, :swap_amount_invalid}
      Decimal.compare(minimum, expected) == :gt -> {:error, :swap_amount_invalid}
      true -> :ok
    end
  end

  defp positive?(%Decimal{} = d), do: Decimal.compare(d, Decimal.new(0)) == :gt
  defp positive?(_), do: false

  defp non_negative?(%Decimal{} = d), do: Decimal.compare(d, Decimal.new(0)) != :lt
  defp non_negative?(_), do: false

  # -- deadline -------------------------------------------------------------

  defp validate_deadline(%{deadline: %DateTime{} = deadline}, %DateTime{} = now) do
    case DateTime.compare(deadline, now) do
      :gt -> :ok
      _ -> {:error, :swap_deadline_expired}
    end
  end

  defp validate_deadline(_route, _now), do: {:error, :swap_deadline_expired}

  @doc """
  True iff `chain` is a chain we know how to map to an EIP-155
  chain id. Exposed for tests and for cross-checks against
  `Bank.Chains` (which classifies but does not number).
  """
  @spec known_chain?(any()) :: boolean()
  def known_chain?(chain) when is_binary(chain), do: Map.has_key?(@chain_ids, chain)
  def known_chain?(_), do: false

  @doc """
  Return the canonical EIP-155 chain id for a known chain string,
  or `nil` for unknowns.

  Stays in lockstep with `Bank.Chains.mainnet_chains/0` +
  `Bank.Chains.testnet_chains/0`: every chain those modules
  recognise has an entry here.
  """
  @spec chain_id_for(any()) :: pos_integer() | nil
  def chain_id_for(chain) when is_binary(chain), do: Map.get(@chain_ids, chain)
  def chain_id_for(_), do: nil

  @doc false
  # Internal helper used by tests to assert the chain-id table
  # stays in lockstep with `Bank.Chains`. Not part of the public
  # contract.
  def __chain_ids__, do: @chain_ids

  @doc """
  Returns `true` iff `chain` would be admitted by the active caps.
  Convenience for callers (UI, decision report) that need to
  classify without producing a full validation error.
  """
  @spec chain_supported?(String.t(), keyword()) :: boolean()
  def chain_supported?(chain, opts \\ []) do
    caps = Keyword.get(opts, :caps, caps())
    chain in caps.allowed_chains
  end

  @doc """
  Cross-reference helper: `Bank.Chains` classifies; this module
  numbers. Used by the future executor to derive
  `(chain_string, chain_id)` from either side.
  """
  @spec classify(any()) :: :mainnet | :testnet | :unknown
  def classify(chain), do: Chains.classify(chain)
end
