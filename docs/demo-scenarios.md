# Alpha demo scenarios

Three short, repeatable walk-throughs that showcase what the Bank
runtime actually does, in the order we tell the product story:

1. [Happy-path payment](#1-happy-path-payment) — auto-executed, signed
   on chain, confirmed. "It just works, with receipts."
2. [Approval-required transfer](#2-approval-required-transfer) — an
   elevated-risk intent parked for human approval, approved, and
   executed. "The operator stays in the loop for the ones that matter."
3. [Blocked intent + replay](#3-blocked-intent--audit-replay) — an
   unknown recipient refused by policy, then the replay timeline shown
   end-to-end. "Every decision is auditable."

All three reuse the curated dataset from
[docs/demo.md](demo.md). Seed it with `mix bank.demo.seed`; reset
between takes with `mix bank.demo.reset --confirm` (staging only).

Each scenario includes:

- **Prep**: what must be true before you begin.
- **Script**: what you say.
- **Clicks**: the UI path. The control tower is the operator console
  at `/` (connection dashboard), `/queue`, `/audit`, etc.
- **Watch for**: the specific thing the audience should notice.
- **Fallback**: what to do if something misbehaves live.

## Preflight (always)

Run through this once before a session:

1. Reset the demo dataset: `mix bank.demo.reset --confirm`.
2. Run smoke tests: `mix bank.smoke.transfer` + `mix bank.smoke.revoke`.
   Both must PASS.
3. Open the control tower at `/` and confirm:
    - `sa_demo_01` shows an **active** delegation.
    - `/v1/health/deep` returns `status: "ok"`.
    - The queue at `/queue` shows the blocked intent
      (`unknown-blocked`) waiting, and the executing one
      (`treasury-executing`) in flight.
4. Have two browser windows ready: one on `/queue`, one on `/audit`.
   You will flip between them.

If anything is off, fall back to the pre-recorded demo (captured
screenshots in `priv/demo-screenshots/`, to be produced once we have
live staging visuals). Never debug live.

---

## 1. Happy-path payment

### Narrative

> The agent saw an invoice from a vetted payroll provider, decided the
> amount and recipient were within policy, signed a ERC-4337 userop
> against our smart account, and got a chain confirmation back. Zero
> operator intervention. Every step is on the audit timeline.

### Prep

- Dataset seeded.
- Payroll Provider counterparty is `trusted`.
- The `payroll-confirmed` intent already exists in the seed with
  `final_status: :confirmed`.

### Script

> I'll show you a transfer the runtime executed on its own. This is
> what the alpha promise looks like when everything is in policy.

### Clicks

1. Open `/audit`.
2. Filter by counterparty **Payroll Provider**, or click the latest
   `execution.confirmed` row.
3. Click into the replay page for that intent
   (`/audit/replay/:intent_id`).
4. Walk the four events top-to-bottom:
    - `intent.submitted` — agent gave us the transfer.
    - `decision.recorded` — runtime decided `auto_exec` at
      `risk_tier: :low`.
    - `execution.confirmed` — adapter reported chain inclusion.
    - (Trust / policy context is visible in the decision envelope.)

### Watch for

- The **reasons list** on the decision envelope — concrete rule
  references, not vibes.
- The **tx_ref** on the execution plan — clickable, proves real chain
  landing.
- The **actor** column — runtime decided, adapter confirmed, no human
  touched it.

### Fallback

If the replay doesn't render (DB slow, callback dropped), switch to
the counterparty detail page at
`/counterparties/<payroll-provider-id>` and walk the recent-history
tab instead — it draws from the same audit source but is rendered
more tolerantly.

---

## 2. Approval-required transfer

### Narrative

> Same agent, same runtime. This time the recipient is a new partner
> we onboarded recently — so policy bumped the risk tier to elevated
> and the runtime held the transfer for human approval instead of
> auto-executing. The operator approves, and execution proceeds.

### Prep

- Dataset seeded.
- The `partner-x-approved` intent exists with
  `outcome: :approval_required` and `final_status: :confirmed`.
- If running live (not pre-baked), create a fresh intent with New
  Partner X as the counterparty *before* starting so you have an
  unresolved row in the queue.

### Script

> Not every transfer is low-risk. When the runtime sees something that
> needs a human eye — a new partner, an unusually large amount — it
> parks the decision and asks the operator. Here's the queue.

### Clicks

1. Open `/queue`.
2. Point out the row for **New Partner X**. Show:
    - Risk tier `:elevated`.
    - Approval clock ticking down (`approval_expires_at`).
    - Reasons explaining why it paused.
3. Click **Approve**. Optionally call out the signature / actor
   attribution.
4. Flip to `/audit` and show the new events appended in real time:
    - `decision.superseded` (prior `approval_required` → new
      `auto_exec`).
    - `execution.broadcast`.
    - `execution.confirmed` (after a few seconds).

### Watch for

- The **expires_at clock**. Emphasise that unapproved intents auto-
  block instead of silently succeeding — the default is safe.
- The **operator's identity** captured on the approval event. The
  audit chain tells you *who* approved, not just *that it was
  approved*.

### Fallback

If execution doesn't land inside 30 seconds, note the adapter's
callback timing and keep talking — the replay page renders every
state transition, so you can demo the audit surface even while the
confirm event is still in flight.

---

## 3. Blocked intent + audit replay

### Narrative

> Policy isn't just a knob on auto-execution — it can refuse a
> transfer outright. Here's an intent aimed at an address we've never
> seen before, with no counterparty, no prior trust. The runtime
> blocks it on first touch.

### Prep

- Dataset seeded.
- The `unknown-blocked` intent exists with a raw-address target of
  `0x4444...4` and `outcome: :block`.

### Script

> The runtime doesn't learn about addresses by osmosis. Unknown ones
> stay unknown until a trusted actor says otherwise.

### Clicks

1. Open `/queue`.
2. Show the blocked row. Callouts:
    - `:block` outcome.
    - Reason list: "address not on any counterparty," "target_raw_address."
3. Click the intent to open its detail.
4. Scroll to the trust assessment: unknown with evidence links.
5. Flip to `/audit/replay/:intent_id` and walk:
    - `intent.submitted`.
    - `decision.recorded` with `outcome: :block`.
6. Demonstrate *promotion*: go to `/counterparties`, create a new
   counterparty for this address, attach the address as a label,
   mark trust level `:sensitive`, and resubmit the intent — it now
   lands in approval_required instead of block.

### Watch for

- The **policy snapshot ref** on the decision envelope. Point out
  that the decision is tied to the exact rule versions in effect at
  decision time, so replay is deterministic even after policy edits.
- The **promotion path**: block is never a dead end. Tied to the
  operator's explicit action, with its own audit trail.

### Fallback

If the resubmit pipeline misbehaves live, skip the promotion segment
and stay with the replay. The block → audit story alone is enough.

---

## Emergency pause (anytime)

If a demo goes sideways or the audience asks "what if it does
something bad?", pivot to this:

1. Open `/security`.
2. Click **Pause all**. Point at the confirmation state.
3. Show the audit entry written for the pause.
4. Click **Resume** to restore normal operation.

This is the shortest demo we have and always lands — good insurance
when the primary flow stalls.

## Debrief script

Close every session with the same three-sentence summary so the
audience leaves remembering the right thing:

> Every transfer the runtime touched, it either executed with a
> receipt or explained why it didn't. The operator is always in the
> loop on the ones that matter, and never on the ones that don't.
> Every decision is reproducible from the audit log.

## Iteration log

Record what worked and what didn't from each session in
[docs/alpha-feedback.md](alpha-feedback.md) (issue #42). Keep
iterating on this file — it's the cheapest product-quality surface we
have.
