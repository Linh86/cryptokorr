# CryptoBank MVP smoke test (Base Sepolia)

Operator runbook for re-running the cryptographic grant + revoke
flow that closed #58 / #31 under PR #132. Repeats the proven
dance against a live local stack in <5 minutes.

> **MVP onboarding lives in
> [`docs/wallet-quickstart.md`](wallet-quickstart.md).** That doc
> walks the browser-driven Connect → Bind → Install → Revoke flow
> partners use day-one. The curl form below is preserved as a
> **dev fallback** for adapter integration debugging and
> situations where the browser flow itself is the thing being
> investigated.

Pairs with:

- [`docs/wallet-quickstart.md`](wallet-quickstart.md) — MVP browser onboarding (use this first).
- [`docs/provisioning-kernel-v3.md`](provisioning-kernel-v3.md) — one-shot smart-account deploy.
- [`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md) — on-chain shape.
- [`docs/incident-runbook.md`](incident-runbook.md) — if a smoke fails in the field.
- [`priv/adapter/contract.md`](../priv/adapter/contract.md) — Phoenix ↔ adapter contract.

## Prereqs

- Adapter `.env` populated (see [`chain_adapter/.env.example`](../chain_adapter/.env.example)). Required at minimum: `BASE_RPC_URL`, `BUNDLER_RPC_URL`, `BASE_CHAIN_ID=84532`, `SMART_ACCOUNT_ADDRESS`, `DELEGATION_SIGNER_KEY`, `OPERATOR_PRIVATE_KEY`, `OPERATOR_ADDRESS`, `ADAPTER_DISPATCH_SECRET`, `ADAPTER_CALLBACK_SECRET`, `PHOENIX_BASE_URL`.
- Phoenix running on `:4000` (`mix phx.server`).
- Adapter running on `:4100` with logs captured: `npm run dev 2>&1 | tee /tmp/cryptobank-adapter.log` from `chain_adapter/`.
- Operator EOA funded on Base Sepolia (small testnet ETH for gas, smart account funded for UserOp prefund).
- Smart account already deployed under that operator EOA per [`docs/provisioning-kernel-v3.md`](provisioning-kernel-v3.md).

## 1. Health

```sh
curl -s http://localhost:4000/health
curl -s http://localhost:4100/health
```

Expected: 200 from both.
- Phoenix: `{"status":"ok","service":"bank","version":"…"}`.
- Adapter: includes `"contract_version":1` and `"supported_chains":["base"]`.

## 2. Grant

```sh
curl -X POST http://localhost:4000/v1/connect/smart_account \
  -H 'Content-Type: application/json' \
  -d '{
    "smart_account_id": "sa_smoke_01",
    "account": "0xYourOperatorEOA",
    "chain_id": 84532,
    "delegation_payload": null
  }'
```

Expected synchronous response: `202 accepted` with body
`{"status":"accepted","smart_account_id":"sa_smoke_01","note":"…"}`.

Wait ~15s. Inspect Phoenix DB:

```sh
mix run -e 'Bank.Delegations.get("sa_smoke_01") |> IO.inspect()'
```

Expected: a `%Bank.Delegations.Delegation{}` row with
`state: :active`, `permission_id` populated (4 bytes),
`validation_id` populated (21 bytes), `kernel_version: "0.3.1"`,
`session_signer_address` populated (0x + 40 hex), `install_tx_hash`
populated (0x + 64 hex), `installed_at_block` populated.

If `state: :active` but `permission_id` is nil, the cryptographic
grant FAILED and Phoenix accepted the synchronous receipt without
an artifact. Read `/tmp/cryptobank-adapter.log` for the
`grant_failed` callback `reason` code:

| `reason` | What to check |
| --- | --- |
| `operator_key_missing` | `OPERATOR_PRIVATE_KEY` / `OPERATOR_ADDRESS` not set, placeholder, or mismatched derivation. |
| `chain_id_mismatch` | Adapter `BASE_CHAIN_ID` differs from the dispatch's `chain_id`. |
| `permission_install_failed` | Bundler rejected the install UserOp. Check bundler URL, smart-account funding, kernel state. |
| `permission_serialization_failed` | `serializePermissionAccount(...)` threw. Check `@zerodev/permissions` package version + adapter logs. |

## 3. Revoke

```sh
curl -X POST http://localhost:4000/v1/security/revoke_delegation \
  -H 'Content-Type: application/json' \
  -d '{
    "smart_account_id": "sa_smoke_01",
    "reason": "smoke_test"
  }'
```

Expected synchronous response: `202` with body
`{"status":"revoke_enqueued","smart_account_id":"sa_smoke_01"}`.

Wait ~15s. Inspect Phoenix DB:

```sh
mix run -e '
import Ecto.Query
Bank.Repo.one(from d in Bank.Delegations.Delegation,
  where: d.smart_account_id == "sa_smoke_01",
  order_by: [desc: d.inserted_at], limit: 1)
|> IO.inspect()'
```

(`Bank.Delegations.get/1` returns `nil` for terminal rows, so the
direct query is what surfaces `:revoked`.)

Expected: row `state: :revoked`, `last_tx_hash` populated. The
adapter log shows the revoke UserOp hash, the kernel's
`uninstallValidation` userOp, and the receipt.

If `state: :revoke_failed`, read the callback `reason` code:

| `reason` | What to check |
| --- | --- |
| `operator_key_missing` | Same as grant — operator key absent or invalid. |
| `validation_id_mismatch` | `validation_id` does not equal `0x02 ‖ rightPad(permission_id, 20)`. Database corruption or schema drift. |
| `package_version_mismatch` | Adapter's pinned `@zerodev/permissions` version differs from the one persisted with the grant. |
| `session_signer_missing` | `session_signer_address` absent on the row (keyless blob requires it). |
| `unaccepted_signer_module` | Blob references a signer module outside `KERNEL_PERMISSION_PIN.acceptedSignerContracts`. |
| `unaccepted_policy_module` | Blob references a policy module outside `KERNEL_PERMISSION_PIN.acceptedPolicyContracts` (or empty list). |
| `permission_deserialization_failed` | `deserializePermissionAccount(...)` threw. Likely persisted-blob / SDK-version mismatch. |
| `deinit_computation_failed` | `getEnableData(...)` threw. Verify the stub signer + policy chain. |
| `uninstall_validation_reverted` | UserOp made it on chain but reverted. Check the receipt + kernel state. |

## 4. Public proof

The currently-pinned smoke proof (PR #132):

- smart account: `0xacb3390BF0E13eB0755317Fbb2C73Ed185F4142C`
- permission id: `0xbb2f68d9`
- validation id: `0x02bb2f68d900000000000000000000000000000000`
- install tx: `0xbbb3a2e8ae78e6c7c4ce6fb5c69f735baaf3af346ffd5b2ff7954724db39891a`
- revoke userOp: `0x478ec3b1e9fc76f5aa1d523024ce0e7d10922125fdc8da750d40cca004e069e7`
- revoke tx: `0xf81c969dafc25eccd0dccad0379317ec64b66916a45cdb9fae8c38e31d795ceb`
- revoke block: `40820243`

A successful smoke produces NEW tx hashes; record them in the
deployment journal alongside the operator EOA, smart-account
address, kernel version, and timestamp.

## 5. Failure triage

| Phoenix state | Likely adapter callback `reason` | What to check |
| --- | --- | --- |
| `:pending` (no transition after 30s) | (no callback yet) | Adapter not running, dispatch route bearer mismatch, or worker stuck. Check `/tmp/cryptobank-adapter.log`. |
| `:active`, `permission_id` nil | `grant_failed` reasons (Step 2 table) | Cryptographic grant did not produce artifacts; review the `grant_failed` callback. |
| `:revoking` (stuck) | (no terminal callback) | Adapter accepted dispatch but never confirmed. Check bundler health + adapter log. |
| `:revoke_failed` | Step 3 table | Match the callback `reason` to the table; remediate, then re-issue `POST /v1/security/revoke_delegation`. |
| `:revoked`, `last_tx_hash` set | n/a | Success — record the new tx hashes. |

If the cryptographic path fails closed and you need to clear the
delegation regardless, the operator escape hatch is to rotate the
smart account's owner off chain (see
[`docs/incident-runbook.md`](incident-runbook.md)) — the adapter
does NOT silently downgrade to the legacy sentinel revoke when a
`permission` block is present and the cryptographic path refuses.

## 6. Intent lifecycle

Smoke for the agent-facing intent path that landed in epic #134
(PRs #142–#148). All five `/v1/intents` actions are live: submit,
show, simulate, cancel, replay; `/v1/approvals` is live for the
operator review loop. No chain calls are needed for these recipes —
the runtime uses the deterministic in-process
`Bank.Quotes.StubProvider` when no provider is configured.

> The runtime resolves `smart_account_id` for auto-dispatch via
> `Bank.Decisions.resolve_executable_account/0` — single-active-
> delegation fallback. If you want a positive `dispatched` outcome
> in step 6.3 below, run §2 first so exactly one delegation is
> active. Otherwise the runtime emits `intent.auto_exec_held` with
> `held_reason: "no_executable_account"` and the curl response
> shows `dispatch: "held"`. That's the documented v0.1 behavior.

### 6.1 Submit an intent

```sh
curl -X POST http://localhost:4000/v1/intents \
  -H 'Content-Type: application/json' \
  -d '{
    "idempotency_key": "smoke-001",
    "source": "agent",
    "agent_id": "smoke-agent",
    "kind": "transfer",
    "asset": "USDC",
    "chain": "base",
    "amount": "10.00",
    "target": { "raw_address": "0xabababababababababababababababababababab" }
  }'
```

> `source` is the enum `"agent" | "user" | "runtime"` (see
> `Bank.Intents.normalize/1`); free-form strings return `422
> invalid_body`. Use `"agent"` for agent-submitted smokes,
> `"user"` for operator-driven ones.

Expected `202 Accepted`:

```json
{
  "intent_id": "<uuid>",
  "state": "submitted",
  "idempotent_replay": false,
  "links": {
    "self": "/v1/intents/<uuid>",
    "replay": "/v1/intents/<uuid>/replay"
  },
  "intent": { ... }
}
```

`EvaluateIntent` runs in milliseconds; the intent transitions to
`:decided` (or `:blocked`). For a 10 USDC raw-address payment, the
v0.1 autonomy router returns `:approval_required` (under the
unknown-trust ceiling).

### 6.2 Inspect the intent

```sh
curl http://localhost:4000/v1/intents/<intent_id>
```

Expected `200 OK` with `state: "decided"` and the cached
`current_decision_id` / `current_simulation_id` /
`current_trust_assessment_id` populated.

### 6.3 Approve an `:approval_required` intent

If §6.1 produced an `:approval_required` decision, it shows up in
the queue:

```sh
curl http://localhost:4000/v1/approvals
```

Approve it:

```sh
curl -X POST http://localhost:4000/v1/approvals/<decision_id>/approve \
  -H 'Content-Type: application/json' \
  -d '{ "actor_id": "op-smoke" }'
```

Expected `200 OK`. The `dispatch` field tells you what happened
next:

| `dispatch` | meaning |
| --- | --- |
| `"dispatched"` | One executable delegation; `execution_plan` is in the response and `RunExecution` is enqueued. |
| `"held"` | Successor envelope recorded, dispatch withheld. `held_reason` is one of: `no_executable_account`, `ambiguous_executable_account`, `runtime_paused`, `delegation_not_active`, `active_plan_exists`, `stablecoin_adapter_not_wired`. `next_step` points at `POST /v1/decisions/{id}/execute`. |
| `"no_dispatch"` | Reject path (not used for approve). |

For the held case, resolve the gate (e.g., grant a delegation via
§2) and dispatch manually:

```sh
curl -X POST http://localhost:4000/v1/decisions/<successor_id>/execute \
  -H 'Content-Type: application/json' \
  -d '{ "smart_account_id": "<sa_id>" }'
```

### 6.4 Reject an approval

```sh
curl -X POST http://localhost:4000/v1/approvals/<decision_id>/reject \
  -H 'Content-Type: application/json' \
  -d '{ "actor_id": "op-smoke", "reason": "duplicate" }'
```

Expected `200 OK` with `dispatch: "no_dispatch"`. The intent moves
to `:blocked`. Reject never dispatches even when a delegation is
present.

### 6.5 Cancel a pre-execution intent

```sh
curl -X POST http://localhost:4000/v1/intents/<intent_id>/cancel \
  -H 'Content-Type: application/json' \
  -d '{ "reason": "operator_withdrew" }'
```

Allowed states: `:submitted`, `:evaluating`, `:decided`. Other
terminal / in-flight states return `409 wrong_state`. Re-cancelling
an already-`:cancelled` intent returns `200` with `idempotent: true`.

### 6.6 Simulate

```sh
curl -X POST http://localhost:4000/v1/intents/<intent_id>/simulate \
  -H 'Content-Type: application/json' \
  -d '{ "reason": "refresh" }'
```

Three reasons:

| `reason` | `simulation.current` | intent pointer | use case |
| --- | --- | --- | --- |
| `pre_submit_dry_run` | `false` | unchanged | preview before submit |
| `refresh` | `true` | advances | reset the active report |
| `operator_inspection` | `false` | unchanged | history-only audit trail |

`200 OK` returns the produced `SimulationReport` inline.

### 6.7 Replay

```sh
curl http://localhost:4000/v1/intents/<intent_id>/replay
```

Returns the deterministic bundle: intent record, policy snapshot,
trust assessment chain, simulation chain, decision envelope chain,
execution plan chain, audit events, screening evidence, and
stablecoin route evidence. The audit chain for an end-to-end
auto-dispatched intent looks like:

```
intent.submitted
  → trust.assessed
  → simulation.produced
  → decision.decided          (outcome: auto_exec)
  → execution.auto_dispatched (decision-driven dispatch)
  → execution.broadcast       (adapter signs + bundles)
  → execution.confirmed       (chain inclusion)
  → intent.state_changed      (decided → executing → executed)
```

For a held auto_exec — whether the held state was produced by the
evaluation pipeline (no executable account at evaluation time) or
by the operator approval path (no/ambiguous/paused/missing-
delegation gate at approve time) — replay surfaces an
`intent.auto_exec_held` row in place of the
`execution.auto_dispatched` row, with the held reason in
`after_ref.held_reason`. Both paths emit the same audit shape.

For an approval-required path the chain is:
```
intent.submitted → trust.assessed → simulation.produced →
decision.decided (outcome: approval_required) →
intent.state_changed → approval.granted →
decision.decided (outcome: auto_exec, successor) →
intent.state_changed
```
followed by either `execution.auto_dispatched` (when a delegation
is executable at approve time) OR `intent.auto_exec_held` (when a
gate held the dispatch — the synchronous HTTP response also sets
`dispatch: "held"` with a `held_reason`).

For simulate calls, a `simulation.requested` row carries the
`reason`; `refresh` additionally writes a `simulation.produced`
row for the new current report.

### 6.8 Audit event vocabulary (intent-correlated)

| event_type | when | actor (default) |
| --- | --- | --- |
| `intent.submitted` | `Bank.Intents.submit/2` accepted the body | `:agent` |
| `intent.cancelled` | `Bank.Intents.cancel/2` ran successfully | `:user` |
| `intent.state_changed` | Intent state transition (e.g., `:decided` → `:executing`) | `:runtime` |
| `intent.auto_exec_held` | Auto-exec dispatch was withheld by a safety gate | `:runtime` |
| `trust.assessed` | New current `TrustAssessment` written | `:runtime` |
| `simulation.produced` | New current `SimulationReport` written | `:runtime` |
| `simulation.requested` | `/v1/intents/:id/simulate` called (any reason) | `:agent` |
| `decision.decided` | New current `DecisionEnvelope` written | `:runtime` |
| `approval.granted` | Operator approved an envelope | `:user` |
| `approval.rejected` | Operator rejected an envelope | `:user` |
| `execution.auto_dispatched` | Runtime auto-dispatched an `:auto_exec` envelope | `:runtime` |
| `execution.manually_requested` | Operator-triggered manual execution | `:user` |
| `execution.<status>` | Execution-plan status transition (`prepared → broadcasting → confirmed | reverted | aborted`) | `:adapter` |
| `delegation.connect_requested` / `delegation.state_changed` | Connect / grant / revoke lifecycle | `:user` / `:adapter` |
| `security.paused` / `security.resumed` | Operator pause / resume | `:user` |
