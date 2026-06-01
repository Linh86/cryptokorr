# Sandbox demo dataset and reset flow

The alpha and every design-partner session run against a curated
dataset that represents the range of outcomes the runtime is designed
to produce: a fresh submitted intent, a decided-but-not-yet-executed
auto-exec, a trusted happy-path transfer, a sensitive approval loop
(both pending and post-approval), a held intent awaiting context, an
in-flight execution, a blocked unknown recipient, and a cancelled
intent. Keeping that dataset uniform across sessions means operators
always know what "baseline healthy" looks like before introducing
partner data.

Every seeded row is **visibly fake / test-only** — counterparty names
carry a `[Sandbox]` prefix, addresses use the obvious `0x111…1` test
pattern, and the smart-account, delegation, and agent identifiers
spell out their `*_demo_*` / `sandbox-demo-*` origin.

## Workspace placeholder (#155 forward-compat)

Until [#155 (Auth + Workspace Alpha Gate)](https://github.com/Linh86/cryptokorr/issues/155)
lands the `workspaces` / `memberships` tables, every seeded row is
implicitly scoped to a single demo workspace handle —
`Bank.Demo.workspace_slug/0`, currently `"sandbox-demo"`. Inside
`Bank.Demo` each `seed_*` / `upsert_*` helper has a `# TODO #155`
marker pointing at the exact line where the future `workspace_id:`
assignment will go on the changeset.

## What gets seeded

### Counterparties

| Name                              | Trust       | Purpose                                            |
| --------------------------------- | ----------- | -------------------------------------------------- |
| `[Sandbox] Payroll Provider`      | `trusted`   | Pre-approved recurring rails. Happy-path example.  |
| `[Sandbox] Treasury Ops`          | `trusted`   | Internal movement. In-flight + held examples.      |
| `[Sandbox] New Partner X`         | `sensitive` | Elevated review. Drives the approval queue demo.   |
| `[Sandbox] Unverified Recipient`  | `unknown`   | Raw-address case. Drives the blocked-intent demo.  |

Each counterparty gets one `base` chain address label with a
well-known test address (`0x111…1`, `0x222…2`, etc.). Counterparty
notes are prefixed with `[sandbox-demo]` plus a "Test-only — do not
transact against this record." disclaimer.

### Policy rules (all `:active`)

| Rule type         | Scope                                    | Params                                |
| ----------------- | ---------------------------------------- | ------------------------------------- |
| `amount_limit`    | `asset: USDC, chain: base`               | `max_amount: 10000`                   |
| `allowed_chain`   | —                                        | `chains: [base]`                      |
| `allowed_asset`   | —                                        | `assets: [USDC]`                      |
| `autonomy_tier`   | —                                        | `tier: guarded`                       |

### Delegation

One active delegation on `sa_demo_01` / `del_demo_01` / `base`.

### Intents (10)

Every intent uses agent id `sandbox-demo-agent` and an idempotency
key prefixed with `sandbox-`.

| Handle                          | Counterparty                     | Amount | State              | Decision outcome     | Plan         |
| ------------------------------- | -------------------------------- | ------ | ------------------ | -------------------- | ------------ |
| `submitted-fresh`               | `[Sandbox] Payroll Provider`     | 75     | `:submitted`       | — (no decision yet)  | —            |
| `decided-pending-exec`          | `[Sandbox] Payroll Provider`     | 125    | `:decided`         | `:auto_exec`         | —            |
| `payroll-confirmed`             | `[Sandbox] Payroll Provider`     | 250    | `:executed`        | `:auto_exec`         | confirmed    |
| `partner-x-pending-approval`    | `[Sandbox] New Partner X`        | 1500   | `:decided`         | `:approval_required` | —            |
| `partner-x-approved`            | `[Sandbox] New Partner X`        | 1000   | `:executed`        | `:approval_required` | confirmed    |
| `treasury-held`                 | `[Sandbox] Treasury Ops`         | 400    | `:decided`         | `:hold`              | —            |
| `treasury-executing`            | `[Sandbox] Treasury Ops`         | 100    | `:executing`       | `:auto_exec`         | broadcasting |
| `treasury-reverted`             | `[Sandbox] Treasury Ops`         | 200    | `:blocked`         | `:auto_exec`         | reverted     |
| `unknown-blocked`               | `[Sandbox] Unverified Recipient` | 500    | `:blocked`         | `:block`             | —            |
| `cancelled-pre-decision`        | `[Sandbox] Payroll Provider`     | 60     | `:cancelled`       | — (no decision)      | —            |

Each intent has at least an `intent.submitted` audit event;
scenarios with a decision also get a `decision.recorded` event;
`:planned` scenarios add an `execution.<status>` event; the cancelled
scenario gets a paired `intent.cancelled` event. That's enough for
the replay page to render a coherent timeline for every intent.

## Seeding

```sh
mix bank.demo.seed
```

Idempotent — runs cleanly against an already-seeded database. Upsert
keys:

- Counterparty: `name`.
- Address label: `(chain, address, counterparty_id)` where `retired_at` is null.
- Policy rule: `(rule_type, priority)` where `state == :active`.
- Delegation: `smart_account_id`.
- Intent: `(agent_id, idempotency_key)`.
- Decision: `(intent_id, current == true)`.
- Execution plan: `(decision_id, active == true)`.
- Audit event: `(correlation_id, subject_id, event_type)`.

## Resetting (scoped delete, not TRUNCATE)

`mix bank.demo.reset` deletes only the rows this module created —
matched by `[Sandbox]` counterparty names, `sandbox-demo-*` agent
ids, the `sa_demo_01` smart account, and the exact policy-rule
specs. Non-demo rows in the same tables (staging fixtures, partner
test data, operator-authored policies) are preserved.

The legacy unprefixed counterparty names and `demo-agent` agent id
are also cleaned up, so a workspace previously seeded with the older
shape is migrated by a single reset.

`audit_events` is intentionally untouched by reset. The table is
append-only at the DB layer (see `priv/repo/migrations/20260415170600_lock_audit_events.exs`)
and audit history is meant to be permanent. After a reset the
previous demo's audit rows become orphans (their `correlation_id`
points at intents that no longer exist), which is harmless — replay
queries the live `agent_intents` table and the next `seed/0`
re-creates audit rows for the fresh intent uuids.

Guarded behind:

1. **Env allowlist**: `:dev`, `:test`, `:staging` only. Refuses to
   run in `:prod`.
2. **Explicit `--confirm`**: without the flag, the task prints the
   list of tables it would touch and exits.

```sh
# Dry run — lists tables, does not touch the DB.
mix bank.demo.reset

# Actually delete demo rows + re-seed.
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
- If operator-authored rows have collided with the canonical demo
  identifiers (`[Sandbox]`-prefixed counterparty name, the
  `sandbox-demo-agent` id, the `sa_demo_01` smart account, or the
  exact demo policy-rule `(rule_type, priority, params)` triples).
  The scoped reset would remove those alongside the demo rows.
