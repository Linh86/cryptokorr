# Morpho Risk Explanation

Status: proposal
Owner: CryptoBank runtime / decisioning
Scope: Morpho Vault risk explanation, data ingestion, policy hooks, and UI copy

## Summary

Morpho should not be represented in CryptoBank as one trusted venue with one
global risk score. Morpho is better modeled as lending infrastructure plus a
curation layer:

- Morpho markets are isolated lending markets with their own loan asset,
  collateral asset, oracle, interest-rate model, LLTV, liquidity, and caps.
- Morpho Vaults are ERC-4626 vaults that accept one loan asset and allocate
  deposits across one or more Morpho markets.
- Curators and allocators manage market eligibility and allocation within
  vault constraints, but Morpho itself is not the asset manager.

CryptoBank should therefore display a CryptoBank-owned risk explanation:

> "This action is allowed, needs approval, or is blocked because of the
> specific vault, curator, underlying markets, liquidity, oracle setup, and our
> own exposure."

Morpho's API and on-chain data should be used as inputs. They should not be
treated as a final decision.

## Product Goal

When an agent proposes a DeFi yield action, the operator should immediately
understand:

- what protocol and vault are touched;
- who curates the vault;
- what the vault can allocate to;
- what the current allocation actually is;
- what could make withdrawals slow or partial;
- what CryptoBank policy limits are close to being breached;
- why the runtime chose `auto_exec`, `approval_required`, `hold`, or `block`.

The explanation should be readable by a human, deterministic enough for replay,
and structured enough to drive automated policy.

## Recommended First User Story

Use the most conservative Morpho workflow first:

> Agent asks to deposit USDC into a whitelisted Morpho Vault.

CryptoBank:

1. Resolves the vault from chain + address.
2. Fetches vault state and allocation facts.
3. Computes a `morpho_risk_explanation`.
4. Evaluates policy and internal exposure.
5. Writes a `DecisionEnvelope`.
6. Requires operator approval for the first versions.
7. Audits every fetched fact and decision reason.

Do not ship borrow, leverage, looping, recursive collateral, or arbitrary market
supply in the first version.

## What Morpho Provides

Morpho provides several high-value data surfaces we can use directly.

### GraphQL API

Official API endpoint:

```text
https://blue-api.morpho.org/graphql
```

Use this through `Req`, not a new HTTP client dependency.

Useful API fields from the Morpho docs:

- `vaults`: vault address, symbol, name, chain, deposit asset, listed status,
  state, APY, net APY, total assets, fee, timelock.
- `vaultByAddress`: specific vault detail by chain and address.
- `state.allocation`: underlying markets, supply caps, supplied assets, supplied
  USD, market LLTV, oracle address, IRM address, loan asset, collateral asset.
- `warnings`: potential vault warnings and warning levels.
- `pendingCaps`: pending market cap changes and `validAt`.
- `allocators`: allocator addresses for a vault.
- `publicAllocatorConfig`: flow caps and public allocator fee.
- `vaultReallocates`: historical allocation changes.
- `vaultPositions`: large positions in a vault.
- `userByAddress.vaultPositions`: the smart account's current vault exposure.
- `historicalState.apy` / `historicalState.netApy`: APY history.

Important implementation note: in a live API check on 2026-04-29, `whitelisted`
returned a deprecation warning and should be replaced by `listed`. The ingestion
adapter should tolerate field changes and store `source_schema_version` or
`source_warning` metadata when Morpho reports deprecations.

### On-Chain Vault Data

Use on-chain reads for facts that must be authoritative at execution time:

- ERC-4626 `asset`, `totalAssets`, `convertToAssets`, `maxDeposit`,
  `maxWithdraw`, `previewDeposit`, `previewRedeem`.
- Vault roles: owner, curator, guardian, allocators.
- Timelock and pending changes.
- Supply and withdraw queues.
- Market caps.
- Current allocation if API freshness is unknown.

The API is useful for fast UI and analytics. On-chain reads are the stronger
source when deciding whether an execution is still valid.

### Morpho Warnings

Morpho API warnings should be shown, but not blindly mapped to final severity.
Examples from the API docs include:

- `unrecognized_deposit_asset`
- `unrecognized_vault_curator`
- `not_whitelisted`

A live response also returned warnings such as:

- `short_timelock`
- `deposit_disabled`
- `not_whitelisted`

CryptoBank should preserve the raw warning type and level in audit evidence.
Policy can then map warning types to `approval_required`, `hold`, or `block`.

## What Morpho Does Not Give Us

Morpho does not give us a complete CryptoBank decision.

Do not rely on:

- APY as a safety signal.
- A curator brand as proof that the vault is acceptable for this user.
- A single `listed` or warning field as a complete risk model.
- API data without freshness metadata.
- Vault-level TVL without checking underlying market concentration.
- Current allocation without checking pending cap changes and timelock.
- Protocol-level audits as proof that a specific vault strategy is safe.

Morpho explains the shape of the risk. CryptoBank decides whether that risk fits
the user's configured boundaries.

## Risk Explanation Model

Add a derived explanation object to the decision rationale and audit event.
This can be persisted later as a first-class table if needed, but a structured
map is enough for the first version.

```elixir
%{
  "kind" => "morpho_vault_risk",
  "venue" => "morpho",
  "chain_id" => 1,
  "vault_address" => "0x...",
  "vault_name" => "Steakhouse USDC",
  "loan_asset" => "USDC",
  "risk_tier" => "moderate",
  "decision" => "approval_required",
  "summary" => "Approved venue, but deposit would raise exposure near cap.",
  "primary_reasons" => [
    %{
      "code" => "exposure_near_cap",
      "severity" => "approval",
      "message" => "Exposure after deposit reaches 82% of configured cap."
    }
  ],
  "checks" => [
    %{
      "code" => "vault_listed",
      "status" => "pass",
      "label" => "Vault is listed by Morpho API",
      "source" => "morpho_api"
    },
    %{
      "code" => "max_market_lltv",
      "status" => "warn",
      "label" => "Highest underlying LLTV is 86%",
      "source" => "morpho_api"
    }
  ],
  "market_allocations" => [
    %{
      "market_id" => "0x...",
      "loan_asset" => "USDC",
      "collateral_asset" => "wstETH",
      "lltv" => "0.86",
      "oracle_address" => "0x...",
      "irm_address" => "0x...",
      "supply_cap" => "10000000",
      "supply_assets" => "4200000",
      "supply_assets_usd" => "4200000",
      "allocation_pct" => "42.0",
      "severity" => "moderate"
    }
  ],
  "source_refs" => [
    %{
      "source" => "morpho_api",
      "fetched_at" => "2026-04-29T10:00:00Z",
      "freshness_seconds" => 60
    }
  ]
}
```

## Risk Dimensions

Compute each dimension independently, then aggregate. The UI should show the
dimensions, not just the aggregate result.

### 1. Protocol Risk

Question:

> Are the underlying protocol contracts and vault standard acceptable?

Signals:

- Morpho Vaults are ERC-4626 vaults.
- Contracts are immutable and open source.
- Morpho documents audits, formal verification, and bug bounties.
- Still non-zero smart contract risk.

Recommended display:

```text
Protocol: Morpho Vaults
Status: Known protocol
Risk: Low / Moderate
Reason: Protocol is established, but this is still DeFi smart-contract risk.
```

Policy:

- Unknown protocol: block.
- Known protocol but new integration path: approval required.
- Mature integration with guardrails: eligible for lower tier.

### 2. Vault Identity Risk

Question:

> Are we interacting with the exact vault we intended to support?

Signals:

- Chain ID.
- Vault address.
- Deposit asset address and decimals.
- ERC-4626 `asset`.
- Morpho API `listed`.
- Morpho warnings.
- Internal whitelist.

Recommended rules:

- Vault address not internally allowlisted: block.
- Chain or asset mismatch: block.
- Morpho warning level `RED`: approval required or block by warning type.
- Morpho warning level `YELLOW`: approval required unless explicitly waived.

### 3. Curator And Role Risk

Question:

> Who controls the vault's risk bounds and who can change allocation?

Signals:

- Owner address.
- Curator address.
- Guardian address.
- Allocator addresses.
- Whether curator is recognized by internal allowlist.
- Whether roles changed recently.
- Timelock duration.
- Pending changes.

Recommended rules:

- Unknown curator: approval required.
- Unrecognized curator plus high APY or long-tail collateral: block.
- Short timelock: approval required.
- Recent role change: hold until reviewed.
- Guardian absent: approval required for larger amounts.

Recommended UI copy:

```text
Curator: Recognized
Guardian: Present
Timelock: 24h
Role changes: none observed in current snapshot
```

### 4. Underlying Market Risk

Question:

> What markets can this vault put our money into, and what market risks do
> depositors inherit?

Signals from `state.allocation`:

- Market unique key.
- Loan asset.
- Collateral asset.
- LLTV.
- Oracle address.
- IRM address.
- Supply cap.
- Current supplied assets.
- Allocation percentage.

Recommended rules:

- Unknown collateral asset: approval required or block.
- Unsupported collateral category: block.
- LLTV above policy max: block.
- LLTV near policy max: approval required.
- Unknown oracle: approval required.
- Custom oracle without allowlist: block.
- Market allocation above concentration cap: approval required or block.

Suggested thresholds for first policy draft:

| Dimension | Low | Moderate | Elevated | Severe |
| --- | --- | --- | --- | --- |
| Max LLTV | <= 80% | <= 86% | <= 91.5% | > 91.5% |
| Unknown collateral | no | no | yes | yes + high allocation |
| Unknown oracle | no | no | yes | yes + high LLTV |
| Single-market allocation | <= 40% | <= 65% | <= 85% | > 85% |

These defaults should be configurable per asset and curator.

### 5. Oracle Risk

Question:

> Could bad or stale pricing cause bad debt or liquidation failures?

Signals:

- Oracle address.
- Internal oracle allowlist.
- Collateral type.
- LLTV.
- External oracle health source if available.
- Curator documentation.

Recommended rules:

- Oracle not allowlisted: approval required.
- Oracle not allowlisted and LLTV high: block.
- RWA or custom NAV oracle: approval required by default.
- Oracle changed recently: hold.

### 6. Liquidity And Withdrawal Risk

Question:

> If the user wants to exit, how much can the vault actually return now?

Signals:

- ERC-4626 `maxWithdraw`.
- Idle funds.
- Withdraw queue.
- Underlying market liquidity.
- Markets at end of withdraw queue.
- Morpho docs note that a broken or forever illiquid market can be moved to the
  end of the withdraw queue.

Recommended rules:

- `maxWithdraw` below requested withdrawal: block withdrawal plan or partial
  withdrawal only.
- Low withdrawable liquidity for a deposit action: approval required.
- Underlying illiquidity concentrated in one market: approval required.
- Unknown liquidity data: hold.

Recommended UI copy:

```text
Withdrawable liquidity: healthy
Largest illiquid market: 12% of vault assets
Exit expectation: normal, subject to borrower utilization
```

### 7. Concentration Risk

Question:

> Are we overexposed to one vault, curator, collateral, oracle, or market?

Signals:

- Current CryptoBank position in this vault.
- Total exposure per curator.
- Total exposure per collateral category.
- Total exposure per oracle.
- Total exposure per Morpho market.
- Proposed post-trade exposure.

Recommended rules:

- Any post-trade exposure above cap: block.
- Above 80% of cap: approval required.
- Above 50% of cap: show warning.
- Correlated collateral groups should share caps, e.g. ETH LSTs.

### 8. APY And Yield Anomaly Risk

Question:

> Is yield abnormally high, rapidly changing, or compensation for risk?

Signals:

- Current APY and net APY.
- Historical APY.
- Difference from peer vaults with same asset.
- Sudden APY jumps.
- Rewards dependence if available.

Recommended rules:

- APY should never reduce risk.
- APY significantly above peer median: approval required.
- APY spike with allocation change: hold.
- Missing APY history: informational only, not a block by itself.

Recommended UI copy:

```text
Net APY: 8.2%
APY signal: elevated versus peer USDC vaults
Risk note: high yield is not treated as a safety signal
```

### 9. Change Velocity Risk

Question:

> Did the vault risk profile recently change?

Signals:

- `pendingCaps`.
- `vaultReallocates`.
- Role changes from on-chain reads or event indexing.
- Timelock duration and pending `validAt`.
- New markets recently enabled.

Recommended rules:

- Pending cap increase: approval required.
- New market enabled inside review window: approval required.
- Curator/owner change inside review window: hold.
- Timelock shorter than internal minimum: approval required or block.

### 10. Incident And External Context Risk

Question:

> Is there an active incident affecting the vault, curator, asset, oracle, bridge,
> or underlying market?

Signals:

- Internal incident flags.
- Morpho warnings.
- Curator announcements.
- Governance forum / official channels.
- Security advisories.
- Internal execution or withdrawal failures.

Recommended rules:

- Active incident on vault or underlying market: hold or block.
- Incident on shared oracle/collateral: approval required.
- Unknown status after stale data: hold.

## Aggregation Policy

Use a conservative aggregation model:

- Any `block` reason makes the decision `block`.
- Any missing critical data makes the decision `hold`.
- Any `approval` reason makes the decision `approval_required`.
- Only actions with no block, hold, or approval reasons are eligible for
  `auto_exec`.

For the first Morpho version, all deposits should be `approval_required` even if
the computed risk tier is `low`. Auto-exec can be enabled later per vault,
asset, amount, and smart-account guardrail.

Risk tier mapping:

| Inputs | Risk tier | Decision |
| --- | --- | --- |
| Allowlisted vault, recognized curator, low LLTV, low concentration | low | approval_required in MVP |
| Known vault, moderate LLTV or near exposure cap | moderate | approval_required |
| Unknown curator, custom oracle, high LLTV, low liquidity | elevated | approval_required or hold |
| Unknown vault, asset mismatch, cap breach, severe warning, active incident | severe | block |

## Operator UI Recommendation

### Approval Queue Card

```text
Deposit 1,000 USDC into Steakhouse USDC Vault

Decision: Approval required
Risk: Moderate

Main reason:
This is a DeFi yield allocation. The vault is approved, but post-deposit
exposure reaches 82% of the configured cap.

Checks:
[pass] Vault address is internally allowlisted
[pass] Deposit asset is native USDC
[pass] Curator is recognized
[pass] No active incident flag
! Highest underlying LLTV is 86%
! Exposure after deposit reaches 82% of cap
```

### Detail View

Show four sections:

1. Intent summary.
2. Decision summary.
3. Risk dimensions.
4. Source evidence.

Market table:

| Market | Collateral | LLTV | Oracle | Allocation | Cap Usage | Risk |
| --- | --- | --- | --- | --- | --- | --- |
| USDC / wstETH | wstETH | 86% | Chainlink | 52% | 74% | Moderate |
| USDC / cbETH | cbETH | 84% | Chainlink | 28% | 42% | Moderate |
| USDC / RWA token | RWA | 75% | Custom NAV | 20% | 61% | Elevated |

Source panel:

```text
Morpho API fetched: 2026-04-29 10:00:00 UTC
On-chain vault read: block 22400000
Internal exposure snapshot: decision-time snapshot
Policy snapshot: rule ids [...]
```

## Suggested Policy Types

The existing `PolicyRule` model can be extended with DeFi-specific rule types.

Recommended additions:

- `allowed_defi_venue`
- `allowed_vault`
- `allowed_curator`
- `allowed_collateral_asset`
- `allowed_oracle`
- `max_vault_exposure`
- `max_curator_exposure`
- `max_market_exposure`
- `max_collateral_exposure`
- `max_oracle_exposure`
- `max_market_lltv`
- `min_vault_liquidity`
- `min_timelock_seconds`
- `deny_morpho_warning`
- `incident_hold`
- `yield_anomaly_approval`

Example policy params:

```json
{
  "rule_type": "max_market_lltv",
  "scope": {"venue": "morpho", "asset": "USDC"},
  "params": {
    "max_lltv_bps": 8600,
    "approval_over_bps": 8000
  }
}
```

```json
{
  "rule_type": "allowed_vault",
  "scope": {"venue": "morpho", "chain_id": 1},
  "params": {
    "vault_addresses": [
      "0x..."
    ],
    "default_decision": "approval_required"
  }
}
```

## Suggested New Contexts

### `Bank.DefiVenues`

Owns venue metadata, normalized identifiers, and common risk vocabulary.

Possible schemas:

- `DefiVenue`
- `DefiVault`
- `DefiMarket`
- `DefiRiskSnapshot`
- `DefiPositionSnapshot`

### `Bank.DefiVenues.Morpho`

Owns Morpho-specific ingestion and normalization.

Modules:

- `Bank.DefiVenues.Morpho.Client`
- `Bank.DefiVenues.Morpho.GraphQL`
- `Bank.DefiVenues.Morpho.VaultSnapshot`
- `Bank.DefiVenues.Morpho.RiskExplanation`
- `Bank.DefiVenues.Morpho.PolicyInput`

The client should use `Req`.

### `Bank.Runtime.Workers.RefreshMorphoVault`

Fetches and stores a vault snapshot periodically or on demand.

Recommended behavior:

- Store raw source payload hash.
- Store normalized fields.
- Store fetch timestamp and block number when available.
- Record API warnings and deprecations.
- Fail closed when freshness exceeds threshold.

## GraphQL Query Drafts

### Vault State

```graphql
query MorphoVaultState($address: String!, $chainId: Int!) {
  vaultByAddress(address: $address, chainId: $chainId) {
    address
    name
    symbol
    listed
    asset {
      address
      symbol
      decimals
    }
    chain {
      id
      network
    }
    state {
      apy
      netApy
      totalAssets
      totalAssetsUsd
      fee
      timelock
      allocation {
        supplyCap
        supplyAssets
        supplyAssetsUsd
        market {
          uniqueKey
          loanAsset {
            symbol
            address
          }
          collateralAsset {
            symbol
            address
          }
          oracleAddress
          irmAddress
          lltv
        }
      }
    }
    warnings {
      type
      level
    }
    pendingCaps {
      validAt
      supplyCap
      market {
        uniqueKey
      }
    }
    allocators {
      address
    }
  }
}
```

### Historical APY

```graphql
query MorphoVaultApys($address: String!, $options: TimeseriesOptions) {
  vaultByAddress(address: $address) {
    address
    historicalState {
      apy(options: $options) {
        x
        y
      }
      netApy(options: $options) {
        x
        y
      }
    }
  }
}
```

### Public Allocator Config

```graphql
query MorphoPublicAllocator($address: String!, $chainId: Int!) {
  vaultByAddress(address: $address, chainId: $chainId) {
    address
    publicAllocatorConfig {
      fee
      flowCaps {
        maxIn
        maxOut
        market {
          uniqueKey
        }
      }
    }
  }
}
```

## API Freshness And Fallbacks

Recommended freshness model:

| Data | Preferred source | Max age | Fallback |
| --- | --- | --- | --- |
| Vault identity | on-chain + API | 24h | block if mismatch |
| Allocation | API | 5m | on-chain read or hold |
| Warnings | API | 5m | hold if stale |
| APY | API | 1h | informational only |
| User position | on-chain + API | 5m | on-chain read |
| Internal exposure | Postgres | decision-time | required |
| Incident flags | Postgres/manual | decision-time | required |

For execution, refresh critical fields immediately before creating the
`ExecutionPlan`. If the pre-execution snapshot differs materially from the
decision snapshot, write a successor decision or require re-approval.

## Audit Requirements

Every Morpho decision should emit enough evidence for replay:

- intent payload;
- vault address and chain;
- normalized vault snapshot;
- raw API payload hash;
- API fetched timestamp;
- API deprecation/warning metadata;
- on-chain block number for critical reads;
- policy rule IDs;
- internal exposure snapshot;
- final risk explanation object;
- operator approval record if applicable.

This should be visible in `/audit/replay/:intent_id`.

## Execution Guardrails

Before enabling execution, require:

- vault address allowlist at the smart-account or adapter layer;
- exact deposit asset allowlist;
- per-vault amount cap;
- per-day or rolling exposure cap;
- deadline/max slippage equivalent for share mint expectations;
- post-decision preflight refresh;
- adapter support only for ERC-4626 deposit/withdraw, not arbitrary calldata;
- emergency pause blocks all new DeFi deposits.

Do not allow the agent to provide vault calldata directly.

## Implementation Plan

### Phase 1: Read-Only Risk Explanation

- Add Morpho API client using `Req`.
- Add normalized snapshot structs.
- Add `Morpho.RiskExplanation.build/2`.
- Add tests using recorded/static API payloads.
- Add a demo page or internal function output; no execution.

### Phase 2: Policy Integration

- Add DeFi policy rule types.
- Convert Morpho snapshots to `PolicyInput`.
- Store explanation in decision rationale.
- Route all Morpho deposit intents to `approval_required`.

### Phase 3: Operator UI

- Add risk explanation panel to approval queue / decision detail.
- Add underlying market allocation table.
- Add source freshness and audit links.
- Show Morpho warnings and internal caps in plain language.

### Phase 4: Execution Adapter

- Add a narrow `/dispatch/erc4626_deposit` adapter path.
- Support only allowlisted vaults and assets.
- Refresh vault snapshot before execution.
- Emit execution callbacks like existing transfer path.

### Phase 5: Autonomy Unlock

- Allow auto-exec only for:
  - whitelisted vault;
  - recognized curator;
  - no active warnings;
  - low internal exposure;
  - low or moderate market risk;
  - recent snapshot;
  - smart-account guardrails active.

## Open Questions

- Which chain do we support first for Morpho: Ethereum mainnet, Base, or both?
- Do we want Morpho snapshots stored persistently from day one, or computed
  on demand for the first spike?
- What is the initial internal curator allowlist?
- Which oracle addresses are acceptable by default?
- Are RWA collateral markets blocked in MVP or approval-only?
- Should APY anomalies use peer comparison across Morpho only, or all DeFi
  yield venues?
- How should we map Morpho `RED` warnings: always block, or warning-specific?

## References

- Morpho API docs: https://legacy.docs.morpho.org/morpho/tutorials/api/
- Morpho Vaults API examples: https://legacy.docs.morpho.org/apis/morpho-vaults/
- Morpho Vaults overview: https://legacy.docs.morpho.org/morpho-vaults/concepts/overview/
- Morpho Vault roles: https://legacy.docs.morpho.org/morpho-vaults/concepts/roles/
- Morpho Vault role capabilities: https://legacy.docs.morpho.org/morpho-vaults/tutorials/role-and-capabilities/
- Morpho Vault risk documentation: https://legacy.docs.morpho.org/morpho-vaults/concepts/risk-documentation/
- Morpho Vault contracts overview: https://legacy.docs.morpho.org/morpho-vaults/contracts/overview/
