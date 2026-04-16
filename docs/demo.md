# Demo dataset and reset flow

The alpha and every design-partner session run against a curated
dataset that represents the range of outcomes the runtime is designed
to produce: a trusted happy-path transfer, a sensitive approval loop,
a blocked unknown recipient, and an in-flight execution. Keeping that
dataset uniform across sessions means operators always know what
"baseline healthy" looks like before introducing partner data.

## What gets seeded

### Counterparties

| Name                   | Trust       | Purpose                                            |
| ---------------------- | ----------- | -------------------------------------------------- |
| Payroll Provider       | `trusted`   | Pre-approved recurring rails. Happy-path example.  |
| Treasury Ops           | `trusted`   | Internal movement. In-flight execution example.    |
| New Partner X          | `sensitive` | Elevated review. Drives the approval queue demo.   |
| Unverified Recipient   | `unknown`   | Raw-address case. Drives the blocked-intent demo.  |

Each counterparty gets one `base` chain address label with a
well-known test address (`0x111…1`, `0x222…2`, etc.).

### Policy rules (all `:active`)

| Rule type         | Scope                                    | Params                                |
| ----------------- | ---------------------------------------- | ------------------------------------- |
| `amount_limit`    | `asset: USDC, chain: base`               | `max_amount: 10000`                   |
| `allowed_chain`   | —                                        | `chains: [base]`                      |
| `allowed_asset`   | —                                        | `assets: [USDC]`                      |
| `autonomy_tier`   | —                                        | `tier: guarded`                       |

### Delegation

One active delegation on `sa_demo_01` / `del_demo_01` / `base`.

### Intents (4)

| Handle                  | Counterparty        | Amount | Outcome             | Final status  |
| ----------------------- | ------------------- | ------ | ------------------- | ------------- |
| `payroll-confirmed`     | Payroll Provider    | 250    | `auto_exec`         | `:confirmed`  |
| `partner-x-approved`    | New Partner X       | 1000   | `approval_required` | `:confirmed`  |
| `unknown-blocked`       | Unverified Recipient| 500    | `block`             | —             |
| `treasury-executing`    | Treasury Ops        | 100    | `auto_exec`         | in-flight     |

Each intent has at least two audit events (`intent.submitted` and
`decision.recorded`); the two confirmed ones also have an
`execution.confirmed` event, giving the replay page something to
render.

## Seeding

```sh
mix bank.demo.seed
```

Idempotent — runs cleanly against an already-seeded database. Upsert
keys:

- Counterparty: `name`.
- Address label: `(chain, address, counterparty_id, retired_at is null)`.
- Policy rule: `(rule_type, priority, state == :active)`.
- Delegation: `smart_account_id`.
- Intent: `(agent_id, idempotency_key)`.
- Decision: `(intent_id, current == true)`.
- Execution plan: `(decision_id, active == true)`.
- Audit event: `(correlation_id, subject_id, event_type)`.

## Resetting

Destructive — truncates every demo-owned table and re-seeds. Guarded
behind:

1. **Env allowlist**: `:dev`, `:test`, `:staging` only. Refuses to
   run in `:prod`.
2. **Explicit `--confirm`**: without the flag, the task prints the
   list of tables it would truncate and exits.

```sh
# Dry run — lists tables, does not touch the DB.
mix bank.demo.reset

# Actually truncate + re-seed.
MIX_ENV=staging mix bank.demo.reset --confirm
```

Against a running release (no `mix` on the host), use the release
helper instead:

```sh
/app/bin/bank eval 'Bank.Demo.reset(env: :staging, confirm: true)'
```

## When to reset

- Between partner sessions, to wipe session-specific test records.
- After a smoke test left a transient plan in a non-terminal state
  that the safety-net poller has not yet aged out (see
  [docs/smoke-tests.md](smoke-tests.md#after-a-smoke-run)).
- Before a demo that needs a clean audit timeline.

## When not to reset

- In production. (Enforced by the env allowlist.)
- While a partner session is live. The reset is not transactional
  across concurrent writers; a partner submitting an intent during a
  reset would race.
- Against a database that contains real audit records you need to
  keep — even in staging. The truncate is total.
