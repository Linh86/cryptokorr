# Decision reports — semantics, examples, and local smoke

This runbook is the operator-facing reference for the human-readable
**decision report** artifact (issues #248–#252). It tells a fresh
reviewer what the report is, what it is **not**, and how to generate
one locally without secrets, without `.env`, and without any chain
broadcast.

> **Audience.** Operators, alpha reviewers, and anyone preparing an
> incident replay. The report is a runtime artifact, not a legal
> document.

## What the report is

A decision report is a deterministic, secret-redacted Markdown
projection of the runtime evidence captured for a single agent
intent.

It is built by composing three modules — none of which read,
broadcast, or persist anything new:

1. **[`Bank.Audit.replay/1`](../../lib/bank/audit.ex)** — collects
   the existing rows tied to an intent: trust assessments,
   simulation reports, screening evidence, the policy snapshot the
   decision used, decision envelopes, execution plans, matched
   activities, and the audit timeline. Read-only.
2. **[`Bank.Decisions.Report.from_bundle/1`](../../lib/bank/decisions/report.ex)** —
   shapes that bundle into a typed struct. Pure function on its
   input; missing evidence is **labelled** (`available: false`) so a
   reader can tell "no simulation recorded" apart from "the report
   builder forgot the field".
3. **[`Bank.Decisions.ReportExport.build/1`](../../lib/bank/decisions/report_export.ex)** —
   wraps the rendered Markdown with a stable filename, a metadata
   header (schema version, intent / workspace ids, body SHA-256),
   and the `text/markdown; charset=utf-8` content type.

The report's body is byte-stable for the same input bundle — same
intent, same DB rows ⇒ same Markdown body, same `body_sha256`
hash. The metadata block changes only with `generated_at`.

## What the report is **not**

- **Not a legal attestation.** The report is the runtime's record of
  evidence; it is not a sworn statement, audit certification, or
  compliance attestation. Do not present it as such to regulators,
  external auditors, or counterparties.
- **Not a compliance certification.** The fields it carries (trust
  level, simulation status, decision outcome, execution status) are
  internal runtime concepts. They are useful inputs for a
  compliance review, not a substitute for one.
- **Not proof of safe execution.** A `confirmed` execution plan
  proves only that the runtime saw a confirmation event — it does
  not prove the on-chain transaction did what the operator
  intended, only that it did not revert at the address recorded in
  `tx_refs`.
- **Not a forensic snapshot.** The report mirrors the *current*
  state of the rows on disk. If a row is later corrected (e.g. a
  decision is superseded), the next report build will reflect the
  new state. Use the audit-event log (`audit_events` table) for the
  immutable historical record.

The report is best understood as an **evidence-based runtime report**: a faithful summary of what the runtime recorded, with
secret material excluded by construction.

## Local generation — three paths

All three paths are **no-secret, no-broadcast, no-`.env`**. They
read existing DB rows and render a Markdown document.

### Path A — browser (operator console)

The fastest path for a reviewer who already has the dev server
running and a browser-session login.

```sh
mix bank.demo.seed   # idempotent; safe to run repeatedly
mix phx.server
```

Then open the operator console, log in, and either:

- visit `/queue` and click **Download report** on any pending row,
  or
- visit `/audit/replay/<intent_id>` and click **Download report**
  inside the **Decision report** panel.

Both anchors point at:

```
GET /audit/replay/:intent_id/report
```

This is the **browser-session-authenticated** route added by
[#251](https://github.com/Linh86/cryptobank/pull/384). It uses the
session cookie set by `BankWeb.Plugs.FetchCurrentUser`, enforces a
`viewer+` role, and scopes the lookup with
`Bank.Intents.get_in_workspace/2`. No `Authorization: Bearer`
header is required — it is **rejected** if you accidentally pass
one against this route, because this is not the API surface.

### Path B — API (SDK / cURL with an API key)

For agents, SDK clients, or scripted reviewers.

```sh
mix bank.demo.seed
mix phx.server
```

Then with a workspace-scoped API key (see
[`docs/runbooks/api-key-auth-smoke.md`](api-key-auth-smoke.md) for
local issuance):

```sh
curl -i \
  -H "Authorization: Bearer cb_..." \
  http://localhost:4000/v1/intents/<intent_id>/report
```

The route is `/v1/intents/:id/report` in router terms.

This is the API-key-gated route added by
[#250](https://github.com/Linh86/cryptobank/pull/360). The
response body, content type, and `x-decision-report-*` headers are
**byte-identical** to the browser route — the only difference is
the auth surface.

### Path C — Mix smoke task (no server, no auth)

For CI, headless replay testing, or a fresh reviewer who just
wants to see all six outcome shapes at once.

```sh
mix bank.decision_report.smoke --seed
```

The `--seed` flag runs `Bank.Demo.seed/0` first, so a fresh
database is fine. The task:

1. Locates the seeded intents that cover the six outcome examples
   below.
2. For each, builds the export artifact via
   `Bank.Audit.replay/1 → Report.from_bundle/1 → ReportExport.build/1`
   — exactly the pipeline the HTTP routes use.
3. Validates the report body is non-empty, declares the expected
   outcome marker, and is free of secret-shaped strings (no
   `Authorization: Bearer`, `sk_live_`, PEM markers, tokenized
   `https://user:pass@host` URLs, or 32-byte hex literals).
4. Prints one `PASS <example>` line per example and a final
   `N / N PASS` summary. Exits non-zero on any failure.

It does **not** call `Bank.AdapterClient`, **not** make any HTTP
request, **not** sign anything, **not** dispatch anything, and
**not** read any environment variable.

## The six outcome examples

Each row maps a #252-required example to a deterministic seed
intent. The smoke task pins these mappings; if a future seed
change drops one of them, the smoke fails loudly rather than
silently dropping coverage.

| Example outcome      | Seed intent handle             | Decision outcome     | Execution plan     | Intent state |
| -------------------- | ------------------------------ | -------------------- | ------------------ | ------------ |
| `auto_exec`          | `decided-pending-exec`         | `:auto_exec`         | — (no plan yet)    | `:decided`   |
| `approval_required`  | `partner-x-pending-approval`   | `:approval_required` | — (awaiting human) | `:decided`   |
| `held`               | `treasury-held`                | `:hold`              | — (held)           | `:decided`   |
| `blocked`            | `unknown-blocked`              | `:block`             | — (no plan)        | `:blocked`   |
| `executed`           | `payroll-confirmed`            | `:auto_exec`         | `:confirmed`       | `:executed`  |
| `failed`             | `treasury-reverted`            | `:auto_exec`         | `:reverted`        | `:blocked`   |

Notes on shape differences a reviewer should recognize:

- **`blocked` vs `failed`.** Both end with `intent.state = :blocked`,
  but the `blocked` example has **no execution plan** at all (the
  decision was `:block`); the `failed` example has a plan with
  `final_outcome = :reverted`. The report's `:execution_plan`
  section is the cleanest way to tell them apart.
- **`held` vs `approval_required`.** Both leave a decision in flight
  with no execution. The report's `:approval` section labels them as
  `kind: "hold"` and `kind: "approval_required_pending"`
  respectively.
- **`auto_exec` (pending exec) vs `executed`.** Both carry an
  `:auto_exec` decision. The pending one has no plan yet; the
  executed one has a plan in `final_outcome = :confirmed`.

## What the report carries — and what it deliberately doesn't

**Carried:** intent kind / asset / chain / amount / state / target
shape; trust assessment derived level + confidence + counts;
simulation provider + status + gas / output / slippage summary;
screening winning record summary; policy rule ids + types +
priorities + sorted param **keys** (not values); decision outcome,
risk tier, decided_by, reasons summary; execution plan chain /
asset / smart-account / status / final outcome / `tx_refs`; matched
activities (chain-public hash + amount + status); flags
(mainnet?/testnet?, live?/stub?); audit timeline (event_type,
actor, ts, subject — **no payload refs**).

**Deliberately excluded:**

- `signing_requirements` (key reference material)
- audit `before_ref` / `after_ref` payloads
- raw policy rule `params` *values* (only the keys are exposed)
- raw simulation `predicted_balance_changes` /
  `routing_path` / `failure_conditions` items
- operator-supplied free-text approval / rejection messages
  (the `:reasons` section drops `message` / `details` and emits
  a `redacted: true` marker so a reader knows free text existed)

`tx_refs` and `provider_trace_ref` **are** included — both are
publicly observable via chain explorers / provider dashboards and
are required for incident replay.

## Operating posture

- **Local-only.** All three paths above run against the local
  Postgres instance and the seeded sandbox dataset.
- **No secrets.** None of the three paths reads `.env`, requires
  `ADAPTER_*` / `RPC_URL` / signer keys, or accepts an
  `Authorization: Bearer` header that is later logged.
- **No chain broadcast.** No path issues a `Bank.AdapterClient`
  call, no path signs a UserOperation, no path opens a WebSocket
  to a bundler.
- **Idempotent.** `mix bank.demo.seed` is safe to re-run.
  `mix bank.decision_report.smoke` is read-only.
- **CI-safe.** The Mix smoke is the dependency-free path: it
  requires only `app.start` (which boots the Repo against the
  test DB) and runs entirely in-process.

## Related documents

- [`docs/demo.md`](../demo.md) — the seeded dataset reference, including the
  10-row intent matrix the smoke task indexes into.
- [`docs/runbooks/guided-sandbox.md`](guided-sandbox.md) — the
  end-to-end sandbox checklist that covers report download
  alongside the rest of the operator surface.
- [`docs/runbooks/api-key-auth-smoke.md`](api-key-auth-smoke.md) —
  how to issue a workspace-scoped API key locally for Path B.
- `Bank.Decisions.Report` / `Bank.Decisions.ReportMarkdown` /
  `Bank.Decisions.ReportExport` moduledocs — the determinism and
  redaction contracts in code.
