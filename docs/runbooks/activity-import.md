# Activity import — operator runbook

This runbook is the operator-facing reference for the read-only **activity import** surfaces (issues #243–#246). It tells a fresh reviewer what activity import is, what it is **not**, and how to verify the surfaces locally without secrets, without `.env`, and without any chain broadcast.

> **Audience.** Operators, alpha reviewers, and anyone wiring CSV / chain activity into a workspace. The activity ledger is a passive read-only record — *not* an accounting system, *not* a tax record, *not* a substitute for bank reconciliation.

## What activity import is

Activity import is a workspace-scoped, append-only ledger of **observed money movement** — both off-chain (CSV uploads from a bank or wallet) and on-chain (RPC-derived ERC-20 transfers and adapter callbacks). It feeds the reconciliation surface (was this transfer driven by a runtime decision?) and the exposure-by-asset aggregator (what is the workspace's net position in confirmed activity?).

The ledger is composed of four read-only modules — none of which write outside the `imported_activities` table:

1. **[`Bank.Activity.CsvImport`](../../lib/bank/activity/csv_import.ex)** — parses, previews, and commits CSV uploads (#244). Workspace-scoped via `current_scope.workspace.id`; the CSV body cannot supply a `workspace_id` (the parser's forbidden-columns guard rejects the upload outright).
2. **[`Bank.Activity.ChainSync`](../../lib/bank/activity/chain_sync.ex)** — pulls ERC-20 transfers from a real RPC endpoint (`base-sepolia`) and projects adapter callbacks into the same ledger (#245). Wallet-chain syncs accept a test-friendly `:rpc_fn` injection.
3. **[`Bank.Activity.Reconciliation`](../../lib/bank/activity/reconciliation.ex)** — links an `ExecutionPlan`'s `tx_refs` to imported activity rows on the same chain + workspace, so an operator can tell "this was a CryptoKorr-driven transfer" apart from "this was external counterparty activity" (#246).
4. **[`Bank.Activity.Exposure`](../../lib/bank/activity/exposure.ex)** — aggregates confirmed inbound / outbound activity per asset for a workspace, opt-in via `include_imported_activity: true` (#246).

Every row carries a deterministic `dedupe_key`, so re-running an import is idempotent — the same CSV row, the same on-chain transfer, the same adapter callback all collapse to a single ledger row.

## What activity import is **not**

- **Not bank-grade accounting.** The ledger does not balance, does not enforce double-entry, and does not produce statutory reports. It is a passive *observation* of activity, classified by source (`:csv`, `:wallet_chain`, `:smart_account_chain`).
- **Not tax software.** Activity rows carry no jurisdiction, no realised-gain calculation, no tax-lot identification, and no reporting-currency conversion. Operators preparing tax filings must use a dedicated tool.
- **Not a chain ingestion daemon.** Chain sync runs on demand (operator-triggered or scheduled), not as a continuous block subscription. Ledger rows can lag head-of-chain by an arbitrary amount.
- **Not a substitute for the decision pipeline.** Activity rows do not produce `DecisionEnvelope`s, do not enqueue `Oban` jobs, and do not call the chain adapter. They are *historical*.

## Prerequisites

- Elixir / OTP per [`README.md`](../../README.md).
- A local Postgres reachable on the `:dev` configuration in `config/dev.exs` (defaults to `localhost:5432`, no password).
- A seeded sandbox demo workspace (one-shot, idempotent):

```sh
mix bank.demo.seed
```

What you do **not** need:

- No `.env` file. The activity import surfaces run entirely off `config/dev.exs` defaults.
- No `ADAPTER_BASE_URL`, `ADAPTER_DISPATCH_SECRET`, or `ADAPTER_CALLBACK_SECRET`. The activity ledger does not call the adapter.
- No `RPC_URL`, `CHAIN_RPC_URL`, or any provider tokens. The chain-sync smoke uses an injected `:rpc_fn` stub that returns deterministic canned logs; nothing is fetched from a real RPC endpoint.
- No real wallet private keys. The smoke uses obvious test addresses (`0xaaa…`, `0xbbb…`) and a sandbox literal `tx_hash` (`0xsmoke7…`).

## CSV walkthrough

The CSV body uses a small, fixed header set:

```csv
occurred_at,asset,chain,amount,direction,memo
2026-04-01T12:00:00Z,USDC,base,100.50,inbound,payroll
2026-04-02T12:00:00Z,USDC,base,25.00,outbound,vendor
```

- **Required headers.** `occurred_at`, `asset`, `amount`, `direction`. Anything else (`chain`, `memo`, free-form columns) is preserved in the row's `metadata` map, with secret-bearing keys (`Authorization`, `private_key`, etc.) redacted at the persist boundary.
- **Forbidden headers.** `workspace_id`, `dedupe_key`, `id`, `source_type`. The parser rejects the upload outright with a `{:forbidden_column, name}` error if any of these appear in the header row — the CSV body must not be able to set workspace boundaries or hijack identity columns.
- **Limits.** Max body size is 5 MB. The LiveView upload (`/activity/import`) enforces this at the boundary.

Every committed row gets a deterministic `dedupe_key` derived from `(source_type, source_hash, occurred_at, asset, direction, amount)`. Re-uploading the same body is idempotent — the second commit reports every row as `:duplicate`.

## Chain-sync runbook

Chain sync is workspace-scoped and read-only. Two source types:

| Source type | Address shape | Fetched by |
|---|---|---|
| `:wallet_chain` | 0x-prefixed 20-byte hex address | `eth_blockNumber` + `eth_getLogs` + `eth_getBlockByNumber` against the configured RPC, projected from ERC-20 `Transfer(address,address,uint256)` events |
| `:smart_account_chain` | Adapter `smart_account_id` | Direct read of `Bank.Delegations.Delegation` and `Bank.Decisions.ExecutionPlan` rows (no RPC call) |

For local development and CI the wallet path accepts a `:rpc_fn` keyword option — a 1-arity function that takes `%{method: ..., params: ...}` and returns `{:ok, body} | {:error, label}`. The smoke task uses this to drive the chain-sync read path with canned fixture data; nothing leaves the BEAM process.

A single sync invocation on `base-sepolia` against a watched address looks like this in IEx:

```elixir
rpc_fn = fn
  %{method: "eth_blockNumber"} -> {:ok, "0x3e8"}                 # head 1000
  %{method: "eth_getLogs", params: [_]} -> {:ok, []}             # no transfers
  %{method: "eth_getBlockByNumber", params: [_, false]} ->
    {:ok, %{"timestamp" => "0x6553f100"}}                        # synthetic ts
end

Bank.Activity.ChainSync.sync_address(
  Bank.Demo.demo_workspace_id(),
  "base-sepolia",
  "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  asset_address: "0x036cbd53842c5426634e7929541ec2318f3dcf7e",
  rpc_fn: rpc_fn
)
# => {:ok, %{inserted: 0, duplicates: 0, last_block: 988}}
```

The cursor (`Bank.Activity.ChainSyncCursor`) advances on every successful sync, so a re-invocation against the same RPC stub returns no new rows — that is the durable record of "we've already seen everything up to block N".

## Reconciliation example

Reconciliation links a workspace's `ExecutionPlan` rows to imported activity rows on the same chain. The match condition is exact `tx_refs` overlap.

`Bank.Activity.Reconciliation.classify_activity/2` returns one of:

- `:cryptobank_execution` — at least one `ExecutionPlan` in this workspace has a `tx_ref` that equals this activity's `tx_hash`.
- `:external` — no plan match; this activity was driven by something other than CryptoKorr's runtime.

In an alpha-staging review the typical operator flow is:

1. Run a chain sync to land newly observed transfers in the ledger.
2. Group the workspace's recent `ExecutionPlan` rows.
3. Pass them to `Bank.Activity.Reconciliation.match_for_plans/1` to fold each plan's `tx_refs` against the ledger.
4. For un-reconciled activity rows, classify each via `Bank.Activity.Reconciliation.classify_activity(row, [])` — `:external` is the expected label for counterparty-driven movement that the runtime did not produce.

## Run the automated smoke

For a non-interactive pass/fail signal that the whole activity-import pipe is wired correctly, run:

```sh
mix bank.activity.smoke
```

The task exercises the CSV preview / commit / idempotency / mixed-row / forbidden-header paths plus a stubbed chain-sync invocation and a reconciliation classification against the freshly imported chain row. It is **read-only with respect to the world outside the sandbox-demo workspace**:

- The database is the only external dependency.
- No `.env` / no environment variables are read.
- No HTTP is made to the chain adapter.
- No real RPC call is made — the chain-sync check uses an injected `:rpc_fn` stub returning deterministic canned logs.
- No Oban jobs are enqueued; no audit rows are written; the read path does not mutate intents, decisions, or plans.

Within the demo workspace the smoke writes a small set of canned `[Sandbox]`-shaped activity rows (the sample CSV plus one stubbed chain transfer). The CSV is committed with idempotent dedupe keys, so re-running the smoke is a no-op on rows that already exist — that idempotency is itself one of the checks.

The seven checks (in order) and what makes them fail:

1. `csv_preview` — `Bank.Activity.CsvImport.preview/2` returns `{:ok, %{summary: ...}}` for a valid CSV with `summary.invalid == 0`.
2. `csv_commit` — same CSV via `commit/2` lands rows in `imported_activities` with `summary.invalid == 0`.
3. `csv_idempotent` — re-committing the same body returns `inserted=0, duplicate=2`. A regression that breaks dedupe keys would fail here.
4. `csv_mixed` — a CSV with one valid + one invalid row lands the valid row only and reports `invalid: 1`.
5. `csv_forbidden_header` — `preview/2` of a CSV containing `workspace_id` in the header returns `{:error, {:forbidden_column, _}}`. A regression that silently accepts the column would fail here.
6. `chain_sync_stub` — `Bank.Activity.ChainSync.sync_address/4` against a canned RPC stub completes with at least one `:wallet_chain` row in the ledger after the run.
7. `reconciliation` — `Bank.Activity.Reconciliation.classify_activity/2` returns `:external` (or `:cryptobank_execution`) for the chain-imported row — never raises, never returns a stub `nil`.

If the demo workspace has not been seeded yet the runner short-circuits with a single `seed` failure check pointing the operator at `mix bank.demo.seed`, so the first-run experience tells the operator exactly what to do next.

Exits 0 on PASS and 1 on FAIL so a CI step can pick up the outcome without parsing stdout.

## Limitations and provenance

- Every activity row carries a `provenance` field naming where it came from (`csv:upload`, `chain_rpc`, `adapter_callback`). Reviewers reading the ledger should treat `csv:upload` rows as operator-supplied (correctness depends on the source spreadsheet) and `chain_rpc` / `adapter_callback` rows as runtime-observed.
- Chain sync runs on demand; the ledger lags head-of-chain by an arbitrary amount. The cursor row records the most recent confirmed block per `(workspace_id, chain, source_type, address)`.
- Confidence is a coarse marker: `:high` for chain-derived rows, default for CSV (operator marks higher confidence at the upload boundary if appropriate). Exposure aggregation defaults to `:high`-only so an unreviewed CSV upload cannot silently shift the workspace's reported net position.
- Status defaults to `:imported` for CSV and chain rows. Exposure-by-asset filters to `:confirmed` rows, so a freshly imported row does not flow into the aggregator until an operator (or an automated reconciliation step) flips its status.
- The activity ledger never auto-creates `DecisionEnvelope`s or `ExecutionPlan`s. It is a passive record of money movement — not an entry point into the decision pipeline.

## Verification (what `mix precommit` covers)

The shipped surfaces this runbook walks are pinned by:

- `test/bank/activity/csv_import_test.exs` — CSV parser / preview / commit semantics, dedupe-key shape, forbidden-column guard, secret redaction.
- `test/bank/activity/chain_sync_test.exs` — `sync_address/4` happy path and cursor advancement against canned `:rpc_fn` stubs.
- `test/bank/activity/reconciliation_test.exs` and `exposure_test.exs` — read-path classification and the `include_imported_activity` opt-in gate.
- `test/bank/activity/smoke_test.exs` — `mix bank.activity.smoke` runner happy path and side-effect contract (no Oban, idempotent on re-run).

Run them as part of the pre-merge gate:

```sh
mix precommit
```

A green `mix precommit` plus a green `mix bank.activity.smoke` on a fresh seed is the success signal for this runbook.
