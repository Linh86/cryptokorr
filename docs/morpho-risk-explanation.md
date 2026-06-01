# Morpho Risk Explanation

This is the design reference for how CryptoKorr explains Morpho
ERC-4626 vault risk to operators. It mirrors the implementation in
[`Bank.DefiVenues.Morpho.RiskExplanation`](../lib/bank/defi_venues/morpho/risk_explanation.ex)
and the operational runbook in
[`docs/runbooks/morpho-deposits.md`](runbooks/morpho-deposits.md).

## Current Scope

The public-alpha Morpho path is deliberately narrow:

- Base Sepolia only.
- USDC deposits only.
- Allowlisted ERC-4626 vaults only.
- Agent-initiated deposits only through the `allocate_idle_capital`
  public intent kind.
- Withdraw, redeem, borrow, leverage, and looping remain
  operator-only or out of scope.

The risk explanation is decision support, not an investment
recommendation. It gives Phoenix structured reasons to approve, hold,
or block a proposed deposit; it does not certify that a vault is safe.

## Model

CryptoKorr does not treat "Morpho" as one globally trusted venue.
The runtime models three layers separately:

- **Protocol:** Morpho infrastructure and contract family.
- **Vault:** an ERC-4626 wrapper with a loan asset, curator, allocator
  set, caps, and allocation targets.
- **Markets:** isolated lending markets under the vault, each with its
  own collateral, oracle, LLTV, liquidity, and utilization profile.

Morpho API and on-chain data are inputs to CryptoKorr's policy engine.
Final routing remains owned by Phoenix policy, trust, approval, pause,
and audit gates.

## Risk Dimensions

`Bank.DefiVenues.Morpho.RiskExplanation.explain/3` evaluates ten
dimensions in a fixed order:

| # | Dimension | Typical checks |
|---|---|---|
| 1 | Protocol | Known protocol, MVP deposit floor. |
| 2 | Vault identity | Vault listed, allowlisted, asset matches. |
| 3 | Curator / roles | Curator and role allowlists. |
| 4 | Underlying markets | LLTV and collateral allowlists. |
| 5 | Oracle | Oracle allowlist and missing-data handling. |
| 6 | Liquidity / withdrawal | Pending caps and future allocation freshness. |
| 7 | Concentration | Exposure caps. |
| 8 | APY anomaly | APY is informational, never a safety signal. |
| 9 | Change velocity | Pending caps and stale data. |
| 10 | Incident context | Known incident flags and external context. |

Each check returns `pass`, `warn`, `fail`, or `missing` plus one or
more reason codes. Reasons carry one of these severities:

| Severity | Meaning |
|---|---|
| `info` | Informational; does not raise the outcome. |
| `warn` | Operator-visible caution. |
| `approval` | Requires explicit operator approval. |
| `hold` | Hold until data or policy is refreshed. |
| `block` | Refuse the intent. |

## Outcome Aggregation

The current MVP has an approval floor for every Morpho deposit. Even
when all risk dimensions are clean, the outcome is
`:approval_required`, not `:auto_exec`.

Aggregation rules:

- Any `block` reason => `:block`.
- Otherwise any `hold` reason => `:hold`.
- Otherwise any `approval` reason => `:approval_required`.
- Otherwise the MVP floor still returns `:approval_required`.

The public API uses `kind: "allocate_idle_capital"`. Internally this
maps to `:defi_yield_deposit`; the internal atom is not part of the
public vocabulary.

## Audit And Replay

Morpho explanations are persisted into the audit stream so reviewers
can replay a decision without re-querying Morpho:

- `morpho.risk_explained` records the explanation, snapshot summary,
  policy rule ids, and proposed amount.
- `morpho.snapshot_stale` records stale or expired snapshot fields.
- `morpho.policy_blocked` records block reasons when policy refuses
  the proposed vault action.

The replay bundle exposes these rows through `morpho_evidence`. The
snapshot payload is allowlisted: it excludes upstream URLs, provider
headers, source warnings, secrets, and raw API responses.

## Execution Boundary

Read-only risk explanation and decision routing are separate from
chain execution. A live Base Sepolia deposit smoke exists behind
`mix bank.morpho.deposit_smoke --confirm`; it requires an operator-run
adapter, configured Base Sepolia RPC/bundler values, and explicit
confirmation before any UserOperation is broadcast.

Mainnet Morpho deposits, broad vault discovery, arbitrary routing,
agent-initiated withdraws, and sponsored gas are post-MVP.
