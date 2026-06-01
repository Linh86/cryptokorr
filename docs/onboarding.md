# Design partner onboarding

This is the document we hand a partner on day one. Everything they
need to understand, try, and decide whether to keep using CryptoKorr.

It assumes zero prior familiarity with the product. It does not
assume zero familiarity with crypto — partners are builders and
treasury teams, not first-time wallet users.

## Contents

1. [What CryptoKorr is (and isn't)](#what-cryptokorr-is-and-isnt)
2. [Core concepts, briefly](#core-concepts-briefly)
3. [Before the first session](#before-the-first-session)
4. [The first session](#the-first-session)
5. [Operator quickstart](#operator-quickstart)
6. [Known limitations in alpha](#known-limitations-in-alpha)
7. [Getting help](#getting-help)

## What CryptoKorr is (and isn't)

**CryptoKorr is a control plane for AI-driven treasury actions.** An agent
sends an intent ("pay this counterparty 250 USDC on Base"); the
runtime decides whether to auto-execute, hold for approval, or block;
and — when it executes — it drives an ERC-4337 account abstraction
flow through a pinned bundler, returning a chain receipt.

**CryptoKorr is *not*:**

- A custody solution. The smart account is yours. CryptoKorr signs
  against a scoped delegation you granted; you can revoke it in the
  control tower at any time.
- A replacement for your treasury team. Everything the runtime does
  lands in the audit log and — for non-trivial decisions — in the
  approval queue.
- A market maker, broad yield router, or general DEX aggregator. The
  alpha supports narrow Base Sepolia transfer, 0x swap, and allowlisted
  Morpho deposit paths.

## Core concepts, briefly

| Term              | What it means                                                                          |
| ----------------- | -------------------------------------------------------------------------------------- |
| **Smart account** | Your ERC-4337 account. CryptoKorr signs userops against it via a delegation.           |
| **Delegation**    | An on-chain permission granting CryptoKorr the scope it needs to execute. Revocable.   |
| **Intent**        | A structured request from an agent ("transfer X to Y"). Input to the runtime.          |
| **Decision**      | The runtime's verdict: `auto_exec`, `approval_required`, `hold`, or `block`.            |
| **Execution plan**| The AA userop being built, signed, broadcast, and confirmed.                           |
| **Counterparty**  | A business-level recipient (not an address). Addresses attach to counterparties.        |
| **Trust level**   | `trusted`, `sensitive`, `unknown`, `conflicted`. Drives policy, not the other way.     |
| **Policy rule**   | A typed, versioned rule: amount limits, allowed chains/assets, autonomy tier, etc.     |
| **Audit event**   | The append-only record of every state change. Replay an intent end-to-end from this.    |
| **Control tower** | The LiveView console — dashboard, queue, counterparties, policies, audit, security.     |

See [docs/bank-v0.1-domain-model.md](bank-v0.1-domain-model.md) for
the full data model if you want to go deeper.

## Before the first session

We need three things from you before we can meaningfully co-pilot a
session:

1. **A funded smart account on Base Sepolia** (alpha runs against
   testnet unless we specifically agree otherwise). We will help you
   provision one if you don't have one; send us the account address.
2. **A shared Slack channel** so we can co-operate during the
   session. Invite the CryptoKorr team to the channel before session
   day.
3. **Two sample counterparties** representing payment flows you
   actually care about — one "trusted" (recurring, low-risk) and one
   "sensitive" (new, needs review). We'll seed them with you in
   Step 3 of the first session.

## The first session

Plan for 60 minutes. We run it together — one of us is on the call,
one of us is watching the logs.

### 1. Connection (10 min)

- You open the control tower (`/`) and connect your smart account.
- We verify the connection on our side: the delegation is active, the
  control tower dashboard shows the account as healthy, the adapter is
  reachable.
- The current operator walkthrough lives in
  [docs/runbooks/guided-sandbox.md](runbooks/guided-sandbox.md).

### 2. Policy walkthrough (15 min)

- We walk the default policy bundle:
    - `amount_limit`: 10000 USDC per transfer (tune down or up for
      your flow).
    - `allowed_chain: [base-sepolia]`.
    - `allowed_asset: [USDC]`.
    - `autonomy_tier: guarded` (default — most transfers auto-exec;
      first-touch partners hold for approval).
- You tell us what's wrong. We edit rules together in `/policies`.
  Every edit creates a new rule version; the old version is
  preserved for audit.

### 3. Counterparty seeding (10 min)

- Create the two sample counterparties you sent us ahead of the
  session (via `/counterparties` or the API).
- Attach a Base address to each.
- Set trust levels. You own this.

### 4. Scenario runs (15 min)

- We run the three canned scenarios from
  [docs/demo-scenarios.md](demo-scenarios.md) against your real
  setup:
    - A trusted-counterparty payment, auto-executed.
    - A sensitive-counterparty payment, approved in the queue.
    - An unknown-address payment, blocked, then promoted.
- You run the approve/block clicks yourself. We narrate.

### 5. Debrief + feedback (10 min)

- Open questions.
- Things that felt wrong or surprising — captured in
  [docs/alpha-feedback.md](alpha-feedback.md) (pilot issue #42).
- What to try next session.

## Operator quickstart

The shortest path to actually using CryptoKorr yourself after
onboarding.

### Connect

1. Open the control tower at your staging URL.
2. Click **Connect smart account**. Paste the smart account address.
3. Approve the delegation request in your wallet. The dashboard
   should flip the account's delegation chip to **active** within a
   few seconds. If not, see [docs/incident-runbook.md](incident-runbook.md).

### Submit an intent

From the API (most common):

```sh
curl -XPOST "$BANK_BASE_URL/v1/intents" \
  -H "authorization: Bearer $AGENT_TOKEN" \
  -H "content-type: application/json" \
  -H "idempotency-key: $(uuidgen)" \
  -d '{
    "kind": "transfer",
    "asset": "USDC",
    "chain": "base-sepolia",
    "amount": "250",
    "target": {
      "counterparty_id": "cp_abc...",
      "address_label_id": "lbl_abc..."
    },
    "notes": "payroll batch 2026-04"
  }'
```

From the control tower: `/queue` → **Submit intent** (coming soon —
currently API-only; tracked in #44).

### Approve / reject

1. Go to `/queue`.
2. Click the row with `:approval_required`.
3. **Approve** or **Reject** with a reason. Your approval is signed
   and recorded in audit.

### Pause / resume / revoke

1. Go to `/security`.
2. **Pause all** stops the runtime from dispatching any new work.
3. **Revoke delegation** removes CryptoKorr's on-chain permission for
   the selected smart account. This is the nuclear option — do it any
   time something feels wrong.

### Review

- `/audit` — every event, filter by intent, counterparty, actor, or
  date.
- `/audit/replay/:intent_id` — an intent's full lifecycle in one view.
- `/counterparties/:id` — a counterparty's history.

## Known limitations in alpha

We tell partners these up front. Most are tracked as explicit issues.

| Limitation                                            | Status                                          |
| ----------------------------------------------------- | ----------------------------------------------- |
| Public alpha execution is Base Sepolia only; operator-only Base mainnet preflight exists separately. | Intentional for alpha. |
| Live swap is Base Sepolia + 0x router only (USDC ↔ USDT and USDC ↔ ETH, exact-input). No scheduled transfers. | Mainnet swap, 1inch / CCTP / Jupiter live execution, and arbitrary-token support stay post-MVP. See `docs/runbooks/swap-dispatch.md`. |
| Control tower can inspect intents, but does not yet provide a full operator intent-creation form. | API submission remains the primary path. |
| No multi-account support in the operator UI.          | Tracked as #46.                                 |
| Audit pagination is coarse (no filter by date range). | Tracked as #45.                                 |
| Approvals UI is minimal.                              | Tracked as #47.                                 |
| Chain reconciliation is not automatic — a dropped    | We'll spot it in audit; manual recovery.        |
| callback needs operator intervention.                 |                                                 |
| Bundler / paymaster keys are ours, not yours.         | Alpha pilots use shared infra.                  |
| No on-chain rotation of the delegation scope yet.     | Revoke + re-grant is the current path.          |

None of these are subtle footguns. If a limitation bites you, we want
to hear about it — see [docs/alpha-feedback.md](alpha-feedback.md).

## Getting help

- **Slack**: use the shared channel we set up during onboarding for
  anything live.
- **Incidents**: we run incident triage against
  [docs/incident-runbook.md](incident-runbook.md). If something's
  on fire, tell us what you were trying to do and what you saw — we
  don't need a crafted bug report.
- **Async questions**: drop them in the Slack channel or email the
  address we gave you. 24-hour response during alpha.
