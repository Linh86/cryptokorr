# Status

Snapshot date: 2026-06-01
Reference commit: `bb83317`
Stage: **private-alpha / showcase MVP** on Base Sepolia. Not production.

## Works today (Base Sepolia, USDC)

| Capability | Status | Notes |
| --- | --- | --- |
| Invite-only access + workspace boundary | Works | Google OAuth, admin approval, role gates, workspace-scoped records |
| Browser wallet onboarding + delegation install | Works | Path A live on Base Sepolia: EOA connect, EIP-191 binding, browser-signed ZeroDev install confirmed on chain; no private-key paste |
| Multi-wallet picker (EIP-6963) | Works | MetaMask, Rabby, Frame; Coinbase Wallet + Phantom-EVM reported working, fixture pinning pending |
| Real on-chain USDC balance reader | Works | Wallet card reads live Base Sepolia balance via `Bank.Chains.BalanceReader` |
| Agent intent API (`/v1/intents`) | Works | `transfer`, `swap`, `scheduled_transfer`, `allocate_idle_capital`; idempotent; OpenAPI |
| Decision / approval / execution state machines | Works | `auto_exec` / `approval_required` / `hold` / `block`; fail-closed gates |
| USDC transfer execution | Works | ERC-4337 v0.7 UserOp; callback lifecycle + confirmation worker |
| 0x swap execution | Works (MVP) | 0x only, exact-input, USDC↔USDT and USDC↔ETH pairs; executable-vs-quote-only gate refuses 1inch/Odos calldata at dispatch |
| Morpho deposit | Works (MVP) | Single allowlisted vault; always requires operator approval |
| Morpho withdraw | Partial | Operator-only preview/planning; no on-chain withdraw broadcast yet |
| Mainnet fork-proof harness | Works (test) | Adapter swap UserOp proven against Base mainnet fork; production broadcast still gated by canary caps |
| Audit + replay | Works | Append-only events, supersession chains, replay LiveView + API |
| Operator console | Works (alpha) | Functional operator tooling: Test Intent flow, advanced policy editor + diff, permission-outdated gate, revoke fail-closed banner |
| SDKs / MCP / examples | Works | Python + TypeScript SDK, stdio MCP, Claude Desktop / LangGraph / Vercel examples |
| Notifications / Telegram | Works | Convenience/alert surface; signed callback tokens |
| Wallet screening infra | Works (MVP path) | OFAC, OpenSanctions, ScamSniffer, EtherScamDB, BTC Abuse, GraphSense, internal scoring |

## Out of scope / not real yet

| Item | Status |
| --- | --- |
| Mainnet broad launch | Out of scope (gated/canary posture only) |
| External security audit / bug bounty / insurance | None |
| HSM/KMS custody hardening | None |
| Paymaster / sponsored gas | Not wired |
| Multi-account UX / multi-tenant self-serve onboarding | Post-MVP |
| CCTP live bridge | Quote/planning only |
| 1inch live execution | Quote/planning only |
| Jupiter / Solana live execution | Quote/planning only |
| Autonomous Morpho withdraw | Not shipped |
| Borrowing / leverage / looping / arbitrary DeFi | Not supported |
| Arbitrary calldata from agents | Never allowed by design |
| On-chain anchoring of audit hashes | Not implemented |
| Browser-signed cryptographic revoke (user-rooted) | Post-MVP (v0.1 sentinel only) |
| Production support process | None |

## Provider execution posture

| Provider | Posture |
| --- | --- |
| 0x | Live MVP execution router (Base Sepolia) |
| 1inch | Quote/planning only |
| Circle CCTP | Quote/planning only |
| Jupiter | Quote/planning only |
| Deterministic stub | Local/test default; live mode is opt-in |
