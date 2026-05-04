# Guided sandbox runbook

> **Status: interim.** This runbook is the working version that goes
> with [#242](https://github.com/Linh86/cryptobank/issues/242) — it is
> NOT the final closeout. Two upstream slices in epic
> [#214](https://github.com/Linh86/cryptobank/issues/214) are still
> open and feed back into this page once they land:
>
> - **[#240](https://github.com/Linh86/cryptobank/issues/240)** —
>   automated Level 1 sandbox smoke command. Shipped as
>   `mix bank.sandbox.smoke` (see "Run the automated smoke" below
>   and the per-environment table). The manual `/sandbox` walk
>   stays useful for human review; the Mix task is the
>   non-interactive smoke for CI / runbook self-checks.
> - **[#241](https://github.com/Linh86/cryptobank/issues/241)** —
>   safe sandbox reset and fixture hygiene. The "Reset between takes"
>   section below describes `mix bank.demo.reset` as it ships **today**;
>   when #241 hardens reset / fixture handling, that section needs to
>   cite the final reset surface, not the current shape.
>
> #242 will be re-closed once #240 and #241 merge AND this runbook is
> updated to cite their shipped surfaces.

A fresh reviewer should be able to follow this page top-to-bottom, starting from an empty database, and finish with the `/sandbox` checklist green — without configuring any secrets, without `.env` files, and without ever broadcasting to a real chain.

This is the *interim* closeout doc for [#242](https://github.com/Linh86/cryptobank/issues/242). It sits next to the dataset reference in [`docs/demo.md`](../demo.md), the demo dataset scenarios in [`docs/demo-scenarios.md`](../demo-scenarios.md), and the alpha-staging smoke in [`docs/mvp-smoke-runbook.md`](../mvp-smoke-runbook.md). What is new here is the *single guided path*: setup → seed → walk → reset, with explicit boundaries against staging / testnet / mainnet.

## What this runbook is — and is not

**Is.** A local-only walkthrough that proves the runtime's review surfaces (intents → simulation → decision → approval / replay / held / blocked) work end-to-end on canned data, with no chain calls.

**Is not.** Not a real chain execution guide. Not a production incident playbook. Not a legal or compliance attestation. Not a tutorial for wallet private keys, RPC URLs, or provider credentials.

If you need the testnet-broadcast smoke (`mix bank.smoke.transfer` / `mix bank.smoke.revoke`), that lives in [`docs/base-sepolia-execution-day.md`](../base-sepolia-execution-day.md) and [`docs/deploy.md`](../deploy.md) and requires `ADAPTER_DISPATCH_SECRET`, `ADAPTER_CALLBACK_SECRET`, `SMART_ACCOUNT_ID`, and `DELEGATION_ID`. The guided sandbox does **not** require any of those.

## Prerequisites

- Elixir / OTP per [`README.md`](../../README.md) (the toolchain pinned in `.tool-versions` if you use `asdf`).
- A local Postgres reachable on the `:dev` configuration in `config/dev.exs` (defaults to `localhost:5432`, no password). Postgres is the only external dependency.
- Node / npm if you plan to render the LiveView in a browser tab (`mix assets.setup` builds esbuild + tailwind for you).

What you do **not** need:

- No `.env` file. The sandbox runs entirely off `config/dev.exs` defaults.
- No `ADAPTER_BASE_URL`, `ADAPTER_DISPATCH_SECRET`, or `ADAPTER_CALLBACK_SECRET`. The adapter does not need to be running for the guided sandbox; the deep-health probe will report `adapter` as `not_configured` and that is fine (#253 made `not_configured` benign at the overall level).
- No `RPC_URL`, `CHAIN_RPC_URL`, or any provider tokens. The sandbox seeds canned `:executed` rows with synthetic `tx_refs`; nothing is broadcast.
- No real wallet private keys. The seed uses obvious test addresses (`0x111…1`, `0x222…2`).
- No OAuth provider configuration beyond what is checked in. The dev environment auto-installs a sandbox user and workspace via the seed step below.

## Setup

From a fresh checkout:

```sh
mix deps.get
mix assets.setup
mix ecto.setup        # create + migrate from empty
```

`mix ecto.setup` runs `ecto.create`, `ecto.migrate`, and the `priv/repo/seeds.exs` you have on `:dev`. If you already have a populated DB you can skip this step or run `mix ecto.reset` instead (`drop` + `setup`).

## Seed the sandbox dataset

```sh
mix bank.demo.seed
```

The full dataset is documented in [`docs/demo.md`](../demo.md): four `[Sandbox]`-prefixed counterparties, four active policy rules, one delegation on `sa_demo_01`, and nine intents covering submitted / decided-pending / executed / approval-required / held / executing / blocked / cancelled. Every row is visibly fake (`[Sandbox]` name, `0x111…1`-style addresses, `sandbox-demo-agent` agent id) and the seed is idempotent — re-running it does not duplicate rows.

`mix bank.demo.seed` does **not** make any HTTP call, does **not** talk to the chain adapter, and does **not** require any environment variables.

## Start the server

```sh
mix phx.server
```

Open <http://localhost:4000>. You will land on the dashboard for the seeded `sandbox-demo` workspace.

## Walk the guided checklist at `/sandbox`

Open <http://localhost:4000/sandbox>. You will see a one-page guided checklist (`#sandbox-guide`) with a progress badge (`#sandbox-progress`) and eight steps. Each step is keyed by a stable element id (`#sandbox-step-<id>`) with a navigation link (`#sandbox-step-link-<id>`) to the operator page where the corresponding action lives. The checklist itself is **read-only** — no buttons, no form submissions, no chain calls; each step's `complete?` flag is a bounded `LIMIT 1` workspace-scoped DB read.

Walk the eight steps in order:

| # | Step id | Goal |
|---|---|---|
| 1 | `workspace` | Confirm the workspace mounted; the seed ensures this. Click through to `/dashboard` to see the runtime card. |
| 2 | `policies` | At least one active policy rule (the seed installs four). Click through to `/policies` to inspect the amount / asset / chain / autonomy rules. |
| 3 | `counterparty` | At least one counterparty has a non-`:unknown` trust assertion (the seed marks two `trusted` and one `sensitive`). Click through to `/counterparties`. |
| 4 | `intent` | At least one intent in this workspace (the seed creates nine). Click through to `/intents` to see the mix of submitted / decided / executed / blocked / cancelled rows. |
| 5 | `simulate` | At least one simulation report has been recorded for an intent in this workspace. Click through to `/intents` and open the `payroll-confirmed` intent to see the simulation snapshot. |
| 6 | `approval` | At least one decision has surfaced as `:approval_required`. The seed creates `partner-x-pending-approval` and `partner-x-approved`. Click through to `/queue#pending-approvals-section`. |
| 7 | `replay` | At least one decision envelope exists for replay inspection. Click through to `/audit` and open one of the seeded decisions. |
| 8 | `held-blocked` | At least one decision was held or blocked by the trust engine. The seed includes `treasury-held` and `unknown-blocked`. Click through to `/queue#held-actions-section`. |

The progress badge updates on the next mount or on the `refresh` event. After a fresh seed, all eight steps render as complete.

A reviewer who is *new* to the runtime should also exercise the no-action path: open `/security` to see the empty `#chain-pauses-card`, the `#adapter-health-card` showing `not_configured` (because no adapter is running locally), and the `#incident-readiness-card` rolled up to `data-level="steady"`. None of these surfaces require credentials.

## Run the automated smoke

For a non-interactive pass/fail signal, run:

```sh
mix bank.sandbox.smoke
```

The task exercises the same Level 1 review-flow surfaces as the `/sandbox` checklist plus a deep-health snapshot, and prints a per-check report. It is **read-only by construction**: the database is the only external dependency, no secrets / `.env` are read, no HTTP is made to the adapter, no chain RPC, no broadcast, no signing, no Oban jobs, no audit rows are written. Exits 0 on PASS and 1 on FAIL so a CI step can pick up the outcome without parsing stdout.

The checks (in order) and what makes them fail:

1. `health` — `Bank.Ops.Health.snapshot/0` overall status. `:not_configured` for the adapter is benign; `:degraded` / `:down` / `:unknown` for any check fails.
2. `workspace` — `sandbox-demo` workspace exists. Run `mix bank.demo.seed` if missing.
3. `policies` — at least one active `PolicyRule` in the workspace.
4. `counterparty` — at least one counterparty with a non-`:unknown` trust assertion.
5. `intent` — `Bank.Intents.list/1` and the workspace-scoped `get_in_workspace/2` round-trip return the same row (catches stub regressions where list returns rows but the get path is stubbed to `nil`).
6. `simulate` — at least one `SimulationReport` is recorded for an intent in this workspace.
7. `approval` — at least one `DecisionEnvelope` with outcome `:approval_required`.
8. `held_or_blocked` — at least one decision with outcome `:hold` or `:block` — proves the safety rails fired.
9. `cancel` — at least one `:cancelled` intent with a matching `intent.cancelled` audit event.
10. `replay` — `Bank.Audit.replay/1` for a recent decision returns a non-empty audit slice.

If the demo workspace has not been seeded yet the task short-circuits with a single `seed` failure check pointing to `mix bank.demo.seed`, so the first-run experience tells the operator exactly what to do next.

## Reset between takes

> **Interim — final reset behavior is tracked by [#241](https://github.com/Linh86/cryptobank/issues/241).**
> The instructions below describe `mix bank.demo.reset` as it ships
> on `main` *today*. #241 is hardening reset / fixture hygiene; when
> it lands, this section must be updated to cite the final reset
> surface (command shape, allowlist, and any new safety guards) and
> any superseded behavior must be removed before #242 re-closes.

```sh
mix bank.demo.reset
```

By default this is a **dry run**: it lists the tables it would touch and exits. To actually delete the demo rows, pass `--confirm`:

```sh
mix bank.demo.reset --confirm
```

`mix bank.demo.reset` is a *scoped* delete — only the rows the seed created are removed (matched by `[Sandbox]` counterparty names, `sandbox-demo-*` agent ids, `sa_demo_01` smart account, and the exact policy-rule specs). Operator-authored rows in the same tables are preserved. `audit_events` is intentionally left untouched (the table is append-only at the DB layer); after a reset the previous demo's audit rows become harmless orphans, and the next `seed` re-creates fresh rows for the new intent uuids.

The reset is guarded behind an env allowlist — `:dev`, `:test`, `:staging` only — and refuses to run in `:prod`.

## How sandbox differs from staging / testnet / mainnet

| Environment | Chain calls | Secrets / `.env` | Broadcast posture | Smoke command |
|---|---|---|---|---|
| **Local sandbox** (this runbook) | None. The seed inserts canned `:executed` rows with synthetic `tx_refs`. | None required. | No HTTP to the adapter; deep-health reports `adapter: not_configured`. | `mix bank.sandbox.smoke` (read-only Level 1 smoke; manual `/sandbox` checklist for human review). |
| **Staging** | Real adapter, but Base Sepolia by default. | Requires `ADAPTER_BASE_URL`, `ADAPTER_DISPATCH_SECRET`, `ADAPTER_CALLBACK_SECRET`. | Broadcasts to Base Sepolia bundler. | `mix bank.smoke.transfer`, `mix bank.smoke.revoke`. |
| **Testnet (Base Sepolia)** | Real chain. | Same staging secrets plus a funded smart account and an active delegation. | Broadcasts; on-chain calls land. | See [`docs/base-sepolia-execution-day.md`](../base-sepolia-execution-day.md). |
| **Mainnet** | Real chain. | Production-tier secrets, controlled by deploy. | Broadcasts; real value moves. | See [`docs/deploy.md`](../deploy.md). |

If you find yourself reaching for `.env`, `ADAPTER_*`, or anything that looks like a production secret while running this runbook, stop — you are no longer in the guided sandbox.

## Limitations and non-goals

- **Read-only checklist.** `/sandbox` does not mutate runtime state. Step completions are derived from existing workspace data; clicking a step's link takes you to the operator page where the underlying action happens.
- **No real chain execution.** The `:executed` rows in the seed are pre-fabricated to give the replay / safety-timeline pages something to render. Confirming a transfer on a block explorer requires a real testnet/mainnet flow, not the sandbox.
- **No legal / compliance attestation.** This runbook proves the runtime renders the documented review surfaces. It does not certify policy correctness, regulatory posture, or partner KYC.
- **No production incident handling.** For pause / resume / abort / revoke during a real incident, see [`docs/incident-runbook.md`](../incident-runbook.md).
- **No private-key handling.** Wallets, private keys, and provider credentials are out of scope. The sandbox uses obvious test addresses and the seed never reads or writes a key.
- **Scoped to one workspace.** The seed creates the `sandbox-demo` workspace and a single membership. Cross-workspace isolation is exercised by other test suites, not by this runbook.

## Verification (what `mix precommit` covers)

The shipped surfaces this runbook walks are pinned by:

- `test/bank/demo_test.exs` — seed idempotency and reset scoping.
- `test/bank_web/live/sandbox_live_test.exs` — `/sandbox` rendering and per-step `complete?` predicates against fixture state.
- `test/bank/sandbox/smoke_test.exs` — `mix bank.sandbox.smoke` runner: happy-path PASS on a freshly seeded workspace, no-side-effect contract (no Oban / no audit writes), and regression detection when a check's underlying rows go missing.
- `test/bank_web/controllers/health_controller_test.exs` — `not_configured` adapter does not falsely fail the local readiness probe.

Run them as part of the pre-merge gate:

```sh
mix precommit
```

A green `mix precommit` plus a green `/sandbox` page on a fresh seed is the success signal for this runbook.

## Troubleshooting

- **A step is unexpectedly red.** Click the step's `#sandbox-step-link-<id>` to the operator page and confirm the underlying row exists. If the seed is incomplete, run `mix bank.demo.reset --confirm` followed by `mix bank.demo.seed` to rebuild from the canonical dataset.
- **`/sandbox` redirects to login.** The dev seed installs a default `sandbox-demo` user; if your dev DB pre-dates that, run `mix ecto.reset` to start clean.
- **`/v1/health/deep` returns 503 in dev.** Inspect the response body: `adapter: { status: "not_configured", detail: "adapter_base_url_not_configured" }` rolls up to overall `"ok"` (200), so a 503 means a different check failed. Most often it is `database` — verify Postgres is running and `mix ecto.migrate` has succeeded.
- **`mix phx.server` cannot bind port 4000.** Another process holds it. `lsof -i :4000` will name it. The sandbox port is configurable via `PORT` but every link in this runbook assumes the default.
