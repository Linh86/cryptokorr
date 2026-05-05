# Swap execution route contract (v0.1)

Issue #189 — first issue in epic #188 (Full Swap Dispatch). Defines
the *contract* for swap execution before any execution code is
written. The validator lives in `Bank.Intents.SwapRoute`; this
document is the human-readable companion.

## Scope

| Dimension     | v0.1 default            | Notes                                                                          |
| ------------- | ----------------------- | ------------------------------------------------------------------------------ |
| Swap type     | exact-input only        | Exact-output and cross-chain are out of scope. No `swap_type` field; implicit. |
| Chain         | `base-sepolia`          | Testnet-first. Mainnet (`base`) not yet allowed at this layer.                 |
| Assets        | `USDC`                  | Both source and destination must be in the allowlist.                          |
| Slippage cap  | `100` bps (1.00%)       | `slippage_bps <= max_slippage_bps`. Stricter caps allowed via config.          |
| Deadline      | strictly future         | `deadline > now` at validation time. Equality fails closed.                    |

## Required route fields (12)

Every field is required. Token addresses are operator-supplied for
v0.1 — a future asset-address registry (epic #190+) will canonicalise
and verify them.

| Field                        | Type           | Notes                                                              |
| ---------------------------- | -------------- | ------------------------------------------------------------------ |
| `source_asset`               | `String.t()`   | Asset label, e.g. `"USDC"`. Must be in `allowed_assets`.           |
| `source_token_address`       | `String.t()`   | ERC-20 contract address.                                           |
| `destination_asset`          | `String.t()`   | Asset label. Must be in `allowed_assets`.                          |
| `destination_token_address`  | `String.t()`   | ERC-20 contract address.                                           |
| `input_amount`               | `Decimal.t()`  | Strictly positive.                                                 |
| `expected_output_amount`     | `Decimal.t()`  | Strictly positive.                                                 |
| `minimum_output_amount`      | `Decimal.t()`  | Non-negative; `<= expected_output_amount`.                         |
| `spender`                    | `String.t()`   | Allowance target / approve recipient.                              |
| `swap_target_contract`       | `String.t()`   | Router/aggregator the calldata targets.                            |
| `calldata`                   | `String.t()`   | Hex-encoded payload to send to `swap_target_contract`.             |
| `value`                      | `Decimal.t()`  | Native-token amount accompanying the call. Non-negative.           |
| `route_provider`             | `String.t()`   | Provider/source identifier (e.g. `"stub"`, `"0x"`).                |
| `quote_timestamp`            | `DateTime.t()` | When the quote was produced.                                       |
| `deadline`                   | `DateTime.t()` | Quote expiry / on-chain deadline. Must be strictly in the future.  |
| `chain`                      | `String.t()`   | Canonical chain string (e.g. `"base-sepolia"`).                    |
| `chain_id`                   | `pos_integer()`| EIP-155 id; must agree with `chain`.                               |
| `slippage_bps`               | `non_neg_integer()` | Bps; capped by `max_slippage_bps`.                            |

## Slippage and deadline semantics

* **Slippage** is expressed in basis points (1 bps = 0.01%). The
  validator only enforces the *upper bound* (`<= max_slippage_bps`);
  the executor is responsible for surfacing `minimum_output_amount`
  to the on-chain router.
* **Deadline** is a wall-clock instant. The validator rejects any
  route whose `deadline` is not strictly after `now` (equality fails
  closed). Tests inject `now` to stay deterministic.

## Rejection reasons (fixed-allowlist atoms)

The validator returns one of these atoms on failure. Each is stable
across releases — operators see them in audit rows and runbooks.

| Atom                            | Cause                                                                                  |
| ------------------------------- | -------------------------------------------------------------------------------------- |
| `swap_chain_not_supported`      | `chain` is not in `allowed_chains`.                                                    |
| `swap_chain_id_mismatch`        | `chain` and `chain_id` disagree (or `chain` has no canonical id mapping).              |
| `swap_asset_not_supported`      | `source_asset` or `destination_asset` is not in `allowed_assets`.                      |
| `swap_route_field_missing`      | A required field is absent or has the wrong shape (nil, empty string, wrong type).     |
| `swap_amount_invalid`           | An amount is non-positive, negative, or `min > expected`.                              |
| `swap_slippage_exceeded`        | `slippage_bps` is missing/negative or exceeds `max_slippage_bps`.                      |
| `swap_deadline_expired`         | `deadline` is missing, malformed, or already past.                                     |

## What this contract does NOT cover

* Address checksum or on-chain consistency between `calldata` and
  `swap_target_contract`. Owned by the executor (epic #190+).
* Mainnet eligibility (`Bank.Chains.validate_mainnet_allowed/2`,
  workspace `mainnet_enabled` flag from #178).
* Canary cap (`Bank.Chains.CanaryCaps`, #181).
* Pause / kill switch (`Bank.Security.paused?/2`).
* Cumulative or per-day caps. Future enhancement requiring
  cross-broadcast persistent state.
* Provider-specific quote freshness windows. Owned by
  `Bank.Quotes.Preview.freshness_ttl_seconds`; the route deadline is
  the contract-level expiry.

## Non-goals (deferred)

* `#190` — execution-plan extension (persisted route shape).
* `#191` — dispatch safety gates that wire this validator into the
  intent submission / decision pipeline.
* Mainnet swap support. v0.1 is testnet-first.

## Cross-references

* Validator: `Bank.Intents.SwapRoute` — the source of truth for the
  contract.
* Tests: `test/bank/intents/swap_route_test.exs` — exhaustive unit
  pins for every failure mode.
* Pattern reference: `Bank.Chains.CanaryCaps` (#181) — same
  validator-with-config-overrides shape.
* Chain classification: `Bank.Chains.classify/1`.
