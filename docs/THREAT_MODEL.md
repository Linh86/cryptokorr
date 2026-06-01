# Threat Model

Snapshot date: 2026-06-01
Reference commit: `bb83317`

## Scope

This threat model covers CryptoKorr v0.1 (alpha) deployed on Base Sepolia.
It does not cover mainnet deployment, which has additional requirements
(external audit, HSM/KMS custody, paymaster planning, incident runbooks,
insurance, and legal review — none of which exist yet).

The system is a non-custodial control plane: AI agents submit structured
intents, Phoenix decides (`auto_exec`, `approval_required`, `hold`,
`block`), and a TypeScript adapter executes only approved plans through a
scoped, revocable ZeroDev/Kernel session permission. The user owns the
EOA / smart account; CryptoKorr never holds keys or funds.

## Threat Actors

- Compromised AI agent (prompt injection, jailbreak, credential leak)
- Malicious counterparty (sanctioned or scam address)
- Compromised API key
- Compromised operator account
- Buggy or malicious smart contract (Morpho vault, 0x router)
- Network-level attacker (MITM, DNS, replay)
- Insider (operator going rogue)

## Threats and Mitigations

### Compromised AI Agent

**Threat:** Agent receives prompt injection or is jailbroken and tries to
move funds outside intended boundaries.
**Mitigation:** Agent submits structured intents (`transfer`, `swap`,
`scheduled_transfer`, `allocate_idle_capital`), never raw calldata — swap
and Morpho calldata are built by trusted runtime/adapter code only after
policy validation. Every intent passes the policy gate, trust evaluation,
and wallet screening. Sensitive actions route to the approval queue.
Pause and revoke are available at any time. The agent cannot withdraw,
redeem, borrow, leverage, or supply arbitrary calldata.

### Malicious Counterparty

**Threat:** Agent is directed at a sanctioned or scam/phishing address.
**Mitigation:** Wallet/address screening runs before execution. Sanctions
matches (OFAC, OpenSanctions) hard-block. Scam/phishing signals
(ScamSniffer, EtherScamDB, BTC Abuse) challenge or route to manual
review. Attribution sources (GraphSense) add context. Trust vocabulary
(`trusted`/`sensitive`/`unknown`/`conflicted`) gates automation: unknown
or conflicted targets do not auto-execute without override.

### Compromised API Key

**Threat:** A leaked workspace API key is used to submit hostile intents.
**Mitigation:** API keys are workspace-scoped with role gates across
`/v1`. A stolen key still cannot bypass policy, approval, pause, or
delegation gates — it can only submit intents that are then independently
evaluated. Cross-workspace isolation prevents a key from reaching another
tenant's resources. Keys are redacted in SDK/MCP error surfaces.
Idempotency limits replay of submission requests.
**Residual risk:** A compromised key can submit intents that fall inside
auto-exec policy bounds. Tight policy limits and rolling spend caps are
the operator's responsibility.

### Compromised Operator Account

**Threat:** An attacker takes over an operator/admin session and approves
malicious actions, mutates policy, or revokes safety controls.
**Mitigation:** Operator surfaces sit behind Google OAuth + session,
admin approval to enter a workspace, and role hierarchy. All approvals,
policy changes, pause/resume, and revoke actions are written to the
append-only audit trail with attribution. Replay reconstructs every
decision.
**Residual risk:** A fully compromised operator account is high-impact —
they can approve queued actions and edit policy within their role. This
is a known limitation; MFA/hardware-key enforcement is post-MVP.

### Buggy or Malicious Smart Contract

**Threat:** A Morpho vault or 0x router behaves maliciously or is exploited.
**Mitigation:** Morpho is treated as a risk-explained venue, not a
trusted protocol — single allowlisted vault only, deposits always require
operator approval, deterministic risk explanation surfaced in the queue.
Swaps are 0x-only, exact-input, on a bounded MVP pair set, with bounded
token approvals (not infinite). Simulation/quote preview runs before
signing; provider failure widens caution.
**Trust assumption:** The vault and router contracts themselves are
trusted (see Out of Scope).

### Network-Level Attacker

**Threat:** MITM, DNS hijack, or replay against API/provider/chain traffic.
**Mitigation:** Idempotency keys prevent duplicate intent execution.
Adapter callbacks update execution state with a confirmation worker that
reconciles missed terminal callbacks. Telegram approval callbacks use
signed, short-lived tokens. Stale routes/simulations hold or block.
**Residual risk:** Standard TLS/transport hardening and provider
endpoint integrity are assumed; no on-chain anchoring of audit hashes yet.

### Insider (Operator Going Rogue)

**Threat:** A legitimate operator abuses their authority.
**Mitigation:** Append-only audit with per-actor attribution (users,
agents, Telegram, adapter callbacks, runtime workers) makes actions
reconstructable but not preventable. Non-custodial design limits blast
radius: the operator cannot extract the user's keys, and the user can
revoke delegation.
**Residual risk:** An insider within role bounds can approve harmful-but-
in-policy actions. Separation of duties and multi-approver flows are
post-MVP.

## Out of Scope (Trust Assumptions)

- We trust the underlying Ethereum / Base consensus.
- We trust the ZeroDev / Kernel v3.1 smart-account implementation and its audit.
- We trust the allowlisted Morpho vault contracts.
- We trust the 0x router contracts.
- We do not protect against a compromised user EOA private key — if the
  user's own key is stolen, the attacker can act as the user directly,
  outside CryptoKorr's control plane.
- We assume the ERC-4337 bundler and quote providers are reachable and
  honest at the transport layer.

## Known Limitations

- v0.1 sentinel revoke for user-rooted (browser-signed) delegations;
  browser-signed cryptographic revoke is post-MVP. Only legacy
  operator-rooted delegations have cryptographic revoke today.
- `OPERATOR_PRIVATE_KEY` remains in the system for legacy operator-rooted
  delegations and some revoke paths.
- On-chain permission encoding is not yet the full policy engine — policy
  is enforced by Phoenix, not entirely on-chain.
- Audit payload hashes are not anchored on chain.
- One active delegation resolver is the only MVP dispatch path;
  multiple executable delegations hold rather than choose.
- No external security audit, bug bounty, insurance, or HSM/KMS migration.
- No paymaster / sponsored gas.
- Broader wallet screening beyond the configured MVP path is post-MVP.
