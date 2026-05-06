# Design partner onboarding

This is the document we hand a partner on day one. Everything they
need to understand, try, and decide whether to keep using Bank.

It assumes zero prior familiarity with the product. It does not
assume zero familiarity with crypto — partners are builders and
treasury teams, not first-time wallet users.

## Contents

1. [What Bank is (and isn't)](#what-bank-is-and-isnt)
2. [Core concepts, briefly](#core-concepts-briefly)
3. [Before the first session](#before-the-first-session)
4. [The first session](#the-first-session)
5. [Operator quickstart](#operator-quickstart)
6. [Known limitations in alpha](#known-limitations-in-alpha)
7. [Getting help](#getting-help)

## What Bank is (and isn't)

**Bank is a control plane for AI-driven treasury actions.** An agent
sends an intent ("pay this counterparty 250 USDC on Base"); the
runtime decides whether to auto-execute, hold for approval, or block;
and — when it executes — it drives an ERC-4337 account abstraction
flow through a pinned bundler, returning a chain receipt.

**Bank is *not*:**

- A custody solution. The smart account is yours. Bank signs against
  a delegation you granted; you can revoke it in the control tower
  at any time.
- A replacement for your treasury team. Everything the runtime does
  lands in the audit log and — for non-trivial decisions — in the
  approval queue.
- A market maker, yield router, or DEX aggregator. The alpha
  supports transfers. Swaps come later.

## Core concepts, briefly

| Term              | What it means                                                                          |
| ----------------- | -------------------------------------------------------------------------------------- |
| **Smart account** | Your ERC-4337 account. Bank signs userops against it via a delegation.                 |
| **Delegation**    | An on-chain permission granting Bank the scope it needs to execute. Revocable.         |
| **Intent**        | A structured request from an agent ("transfer X to Y"). Input to the runtime.          |
| **Decision**      | The runtime's verdict: `auto_exec`, `approval_required`, `hold`, or `block`.            |
| **Execution plan**| The AA userop being built, signed, broadcast, and confirmed.                           |
| **Counterparty**  | A business-level recipient (not an address). Addresses attach to counterparties.        |
| **Trust level**   | `trusted`, `sensitive`, `unknown`, `conflicted`. Drives policy, not the other way.     |
| **Policy rule**   | A typed, versioned rule: amount limits, allowed chains/assets, autonomy tier, etc.     |
| **Audit event**   | The append-only record of every state change. Replay an intent end-to-end from this.    |
| **Control tower** | The LiveView console — dashboard, queue, counterparties, policies, audit, security.     |

See [docs/domain-model.md](domain-model.md) for the full data model
if you want to go deeper.

## Before the first session

We need three things from you before we can meaningfully co-pilot a
session:

1. **A funded smart account on Base Sepolia** (alpha runs against
   testnet unless we specifically agree otherwise). We will help you
   provision one if you don't have one; send us the account address.
2. **A shared Slack channel** so we can co-operate during the
   session. Invite the Bank team to the channel before session day.
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
- [docs/control-tower.md](control-tower.md) has the connection flow
  screenshots.

### 2. Policy walkthrough (15 min)

- We walk the default policy bundle:
    - `amount_limit`: 10000 USDC per transfer (tune down or up for
      your flow).
    - `allowed_chain: [base]`.
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

The shortest path to actually using Bank yourself after onboarding.

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
    "chain": "base",
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
3. **Revoke delegation** removes Bank's on-chain permission for the
   selected smart account. This is the nuclear option — do it any
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
| Base (mainnet + Sepolia) only — no multi-chain.       | Intentional for alpha.                          |
| Live swap is Base Sepolia + 0x router only (USDC ↔ USDT and USDC ↔ ETH, exact-input). No scheduled transfers. | Mainnet swap, 1inch / CCTP / Jupiter live execution, and arbitrary-token support stay post-MVP. See `docs/runbooks/swap-dispatch.md`. |
| Control tower does not yet have an intents page.      | Tracked as #44.                                 |
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
