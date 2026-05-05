# Base mainnet rehearsal — no-broadcast operator runbook

Issue [#180](https://github.com/Linh86/cryptobank/issues/180) (epic
[#166](https://github.com/Linh86/cryptobank/issues/166)).

> **Audience.** Operator preparing to flip a workspace into Base
> mainnet for the first time, or rehearsing a fresh deployment
> before the first mainnet UserOp leaves the box.
>
> **Posture.** Every step in this runbook is **read-only**. There
> is no signing, no `eth_sendRawTransaction`, no UserOp submission,
> and no `Bank.AdapterClient` dispatch. A successful rehearsal
> produces **no transaction hash** because nothing is broadcast.

## Why this rehearsal exists

Base mainnet broadcast is irreversible. Two independent gates ride
together before the first mainnet UserOp can leave the runtime:

1. The **workspace mainnet flag** (#178) — `mainnet_enabled`
   controls whether a workspace may run mainnet at all. Defaults
   `false` in every env.
2. The **deployment preflight** (#179) — verifies the deployment
   is actually configured to talk to Base mainnet (right RPC, right
   chain id, right ERC-4337 EntryPoint).

Both must clear before an admin flips
`Bank.Workspaces.set_mainnet_enabled(workspace, true)`. This
runbook is the operator-facing rehearsal that proves both gates
clear **without touching chain state**.

## What "no broadcast" means here

The rehearsal must satisfy every one of these properties — they
are pinned by automated tests and listed here so an operator can
audit the posture from the runbook alone:

- **No `Bank.AdapterClient` HTTP call leaves the rehearsal
  process.** Pinned by
  [`test/bank/mainnet_gate_test.exs`][gate-test] — the dispatch
  worker test installs a `Req.Test.stub` on `Bank.AdapterClient`
  and asserts `refute_receive :adapter_was_called` when the
  workspace flag flips off.
- **No `eth_sendRawTransaction`, `eth_sendUserOperation`, or other
  write-side JSON-RPC method is ever called.** Pinned by
  [`test/bank/chains/mainnet_preflight_test.exs`][preflight-test]
  "no broadcast posture" — the preflight only issues
  `eth_chainId`, `eth_getCode`, and `eth_getBalance`; any other
  method `flunk`s the test.
- **No bundler RPC round-trip.** `BUNDLER_RPC_URL` is shape-checked
  but the bundler is not contacted.
- **No `.env` is sourced.** The rehearsal is run against the
  deployment env (or an explicit one-off shell prefix); the test
  and CI processes never `source .env`. The
  [`mix bank.observability.smoke`][obs-smoke] task documents the
  same posture.
- **No signing.** No private-key material is loaded; no UserOp is
  signed.
- **No transaction hash is produced.** A successful rehearsal log
  contains zero `0x[64 hex chars]` tx hashes — see § Failure
  modes if one appears.

[gate-test]: ../../test/bank/mainnet_gate_test.exs
[preflight-test]: ../../test/bank/chains/mainnet_preflight_test.exs
[obs-smoke]: ../../lib/mix/tasks/bank.observability.smoke.ex

## Pre-rehearsal checklist

**Deployment env** (set in the host's environment, **not** sourced
from a checked-in `.env`):

| Var | Required value | Why |
| --- | --- | --- |
| `BASE_RPC_URL` | a Base mainnet RPC URL | preflight `eth_chainId` round-trip |
| `BUNDLER_RPC_URL` | a Base mainnet bundler URL | shape check only |
| `BASE_CHAIN_ID` | `8453` | preflight gates on this exact value |
| `SMART_ACCOUNT_ADDRESS` | 20-byte `0x` address | preflight reads `eth_getCode`/`eth_getBalance` at this address |

**Workspace state**:

- The workspace exists.
- `Bank.Workspaces.Workspace.mainnet_enabled` is **`false`** — the
  rehearsal is run against the safe default. Flipping the flag
  is the *post-rehearsal* step, after every check below clears.

**Process posture**:

- `Bank.Security.paused?(:global)` is `false` (or, if it is
  `true`, the operator is deliberately rehearsing the paused
  posture — see § Step 4).

## The rehearsal

### Step 1 — Static config + read-only RPC preflight

```sh
mix bank.chain.mainnet.preflight
```

Runs eight checks against the deployment env. Pass criteria:

- every line is `PASS`, **or**
- the only non-`PASS` line is `WARN smart_account_code
  (smart_account_not_deployed)` — that's informational; the
  ZeroDev kernel install is a separate provisioning step
  (#171) and is not a hard fail.

Expected stdout shape (from
`Mix.Tasks.Bank.Chain.Mainnet.Preflight` moduledoc):

```text
[bank.chain.mainnet.preflight] running 8 checks
[bank.chain.mainnet.preflight] PASS config_present
[bank.chain.mainnet.preflight] PASS chain_id_declared
[bank.chain.mainnet.preflight] PASS smart_account_address_shape
[bank.chain.mainnet.preflight] PASS bundler_url_shape
[bank.chain.mainnet.preflight] PASS chain_id_rpc
[bank.chain.mainnet.preflight] PASS entrypoint_code
[bank.chain.mainnet.preflight] PASS smart_account_code
[bank.chain.mainnet.preflight] PASS smart_account_balance
[bank.chain.mainnet.preflight] 8 / 8 PASS
```

What this proves:

- `BASE_CHAIN_ID == 8453` (declared chain id matches Base mainnet);
- the RPC at `BASE_RPC_URL` answers `eth_chainId` with `0x2105`
  (the load-bearing check that catches "operator pasted a Sepolia
  RPC URL into a mainnet deployment");
- the canonical ERC-4337 v0.7 EntryPoint
  (`0x0000000071727De22E5E9d8BAf0edAc6f37da032`) has bytecode on
  this RPC;
- `SMART_ACCOUNT_ADDRESS` is a 20-byte `0x` address;
- the bundler URL has an `http(s)` shape.

What this does NOT do:

- no broadcast, no signing, no UserOp, no bundler RPC, no
  `Bank.AdapterClient`. The Mix task's moduledoc spells this out
  as "Mirrors the safety posture of `mix bank.observability.smoke`".

Exit code: `0` on `:ok` or `:not_configured`; non-zero (via
`Mix.raise`) on `:down` or `:degraded`.

### Step 2 — Runtime observability smoke

```sh
mix bank.observability.smoke
```

Confirms the runtime's health surface compiles and behaves
correctly: DB reachability, adapter health classification,
stuck-plan shape, the `/v1/health` and `/v1/health/deep` HTTP
routes, and the typed `Bank.Ops.Alerts.emit/1` surface. Adapter
calls in this task are stubbed via `Req.Test`; no real chain HTTP
leaves the process. See
[`docs/runbooks/production-observability.md`](production-observability.md)
§ Local smoke for the authoritative scope list.

### Step 3 — Mainnet gate posture

Confirm the workspace gate is in the safe default:

```elixir
ws = Bank.Workspaces.get_workspace!(workspace_id)
ws.mainnet_enabled  # → false
```

The fail-closed gates are pinned by
[`test/bank/mainnet_gate_test.exs`][gate-test], which exercises
five layers — intent submit, decision pipeline (execute), dispatch
worker, synchronous revoke, revoke worker — and asserts that each
returns `{:error, :mainnet_disabled}` or
`{:cancel, :mainnet_disabled}` without ever calling
`Bank.AdapterClient`. The dispatch worker test in particular
installs a `Req.Test` stub and asserts
`refute_receive :adapter_was_called`, so a regression that
re-enabled chain HTTP under a flipped-off flag would fail there
in CI long before any rehearsal noticed it.

### Step 4 — Pause / kill-switch posture

Before any first mainnet UserOp, confirm:

```elixir
Bank.Security.paused?(:global)
# → false (or, deliberately, true if rehearsing the paused
#    posture)

Bank.Security.paused?(workspace_id, {:chain, "base"})
# → false
```

The pause registry lives in `Bank.Security.PauseState` and is
consulted by the decision pipeline's
`Bank.Decisions.validate_not_paused/2`. Any plan whose chain
matches a paused scope is held with
`:runtime_paused`, never broadcast.

If either pause check is `true`, **do not flip
`mainnet_enabled`**. Resolve the underlying incident first per
[`docs/incident-runbook.md` § Emergency pause](../incident-runbook.md#emergency-pause).
Resuming pause to unblock a rehearsal is never the right move:
the pause is a kill switch, not a yellow light.

The rehearsal's job is to **observe** the pause posture, not
exercise the resume path. The pause/resume audit cadence is
covered separately by `docs/runbooks/notifications.md`.

### Step 5 — No-broadcast acceptance check

After running Step 1 and Step 2, the operator audits the
following surfaces and confirms none of them shows broadcast
activity:

- **stdout / log capture from the rehearsal**: zero strings
  matching `0x[0-9a-fA-F]{64}` (a full 32-byte tx hash);
- **`oban_jobs` table**: no rows for
  `Bank.Runtime.Workers.RunExecution` were inserted by the
  rehearsal;
- **audit events**: no events of kind `adapter.dispatch.*`
  attributable to the rehearsal correlation id;
- **adapter telemetry**: no
  `[:bank, :adapter, :dispatch, :start | :stop]` events emitted
  during the rehearsal window.

If any of these surfaces shows broadcast activity, see § Failure
modes — the rehearsal posture has been violated and must be
treated as an incident, not a soft warning.

## Expected artifacts and logs

| Surface | Expected during rehearsal | Why |
| --- | --- | --- |
| `mix bank.chain.mainnet.preflight` stdout | `8 / 8 PASS` (or `7 / 8 PASS` with `WARN smart_account_code`) | static + read-only RPC verification |
| `mix bank.observability.smoke` stdout | every check `PASS` | health surface compiles; degraded-adapter case is deliberately stubbed and recovered |
| `oban_jobs` rows | none for `Bank.Runtime.Workers.RunExecution` attributable to the rehearsal | no dispatch was enqueued |
| audit events | none of kind `adapter.dispatch.*` or `intent.broadcast.*` | no broadcast occurred |
| transaction hash | **never** | rehearsal does not broadcast |
| `bank.adapter.dispatch.*` telemetry | none emitted | adapter not called |
| `Bank.Notifications` rows | only the typed `ops.*` kinds in the Phase 1 allowlist | alert emission is read-only by construction (#256) |

## Failure modes and next operator action

Every preflight error `detail` is drawn from a fixed allowlist —
see `Bank.Chains.MainnetPreflight` moduledoc. The runbook
enumerates every documented detail and the next operator action.

| Failure | Symptom | Next action |
| --- | --- | --- |
| `config_missing:<KEY>` | preflight `:not_configured` for the named env var | populate the named env var in the deployment env (not `.env`) and rerun. Do not proceed |
| `chain_id_declared_mismatch` | preflight `FAIL chain_id_declared` — `BASE_CHAIN_ID` is not `8453` | set `BASE_CHAIN_ID=8453` in deployment env. Reject any other value (incl. `84532` Sepolia) |
| `chain_id_rpc_mismatch` | preflight `FAIL chain_id_rpc` — RPC reports a non-mainnet chain id (often `0x14a34` = Sepolia) | the RPC URL points at the wrong chain. Replace `BASE_RPC_URL` with a Base mainnet RPC. Do not proceed under any circumstances |
| `entrypoint_missing` | preflight `FAIL entrypoint_code` — EntryPoint v0.7 has empty bytecode at the canonical address | the RPC is not Base mainnet (or is a fork without ERC-4337). Replace `BASE_RPC_URL`. Do not proceed |
| `smart_account_address_invalid` | preflight `FAIL smart_account_address_shape` — `SMART_ACCOUNT_ADDRESS` is not a 20-byte `0x` hex address | fix the env var. Do not proceed |
| `smart_account_not_deployed` | preflight `WARN smart_account_code` — informational | continue rehearsal; complete `#171` ZeroDev kernel onboarding before flipping `mainnet_enabled: true` |
| `bundler_url_invalid` | preflight `FAIL bundler_url_shape` — `BUNDLER_RPC_URL` is not `http(s)` | fix `BUNDLER_RPC_URL` |
| `transport_error` | preflight `FAIL` on any RPC check — the RPC is unreachable | verify the URL/credentials/network egress and retry. If persistent, escalate to the RPC provider per `docs/incident-runbook.md` § Adapter outage |
| `http_5xx` | preflight `FAIL` — RPC returned a 5xx | provider-side outage. Wait or escalate per `docs/incident-runbook.md` § Adapter outage |
| `http_4xx` | preflight `FAIL` — RPC returned a 4xx | usually credential / quota related. Verify the RPC URL has correct auth |
| `rpc_error` | preflight `FAIL` — JSON-RPC `error` body | the RPC method or payload was rejected by the provider. Check provider docs; retry. The provider's error message is **not** surfaced (secret hygiene) |
| `invalid_response` | preflight `FAIL` — non-numeric or wrong-shape response | RPC provider regression; switch to a different mainnet RPC and retry |
| `rpc_check_raised` / `rpc_check_timeout` | preflight `:unknown` rollup is `:degraded` | transient. Retry once. If persistent, treat as `transport_error` |
| **unexpected transaction hash** in any rehearsal log | `0x[64 hex chars]` appears in stdout, audit events, or telemetry | **STOP.** The rehearsal posture has been violated. Pause the runtime via `Bank.Security.pause(:global, "rehearsal-broadcast", actor: :operator, actor_id: <id>)` and follow `docs/incident-runbook.md` § Adapter outage and § Stuck executions. Do not flip `mainnet_enabled` |
| **unexpected `Bank.AdapterClient` call** | network log or `bank.adapter.dispatch.*` telemetry shows a call attributable to the rehearsal | **STOP.** Same pause-and-investigate response as above. The dispatch-gate test in `test/bank/mainnet_gate_test.exs` should have caught this in CI; if it didn't, the regression is the gate, not the rehearsal |
| pause is on (unexpected) | `Bank.Security.paused?(:global)` is `true` and the operator did not deliberately pause | resolve the underlying incident per `docs/incident-runbook.md` § Emergency pause; do **not** silently resume to unblock the rehearsal |
| workspace `mainnet_enabled` already `true` | `ws.mainnet_enabled == true` before rehearsal starts | rehearsal posture is wrong. Flip the flag back to `false` (`Bank.Workspaces.set_mainnet_enabled(ws, false)`), audit who flipped it (audit event `workspace.mainnet_enabled.set`), and only then rehearse |

## After the rehearsal

If — and only if — every check in Steps 1-5 cleared:

1. Confirm the per-workspace `mainnet_eligibility` badge on
   `/ops` reads "disabled" (the safe default). The badge has
   `data-mainnet-enabled="false"` until the flip.
2. The admin runs
   `Bank.Workspaces.set_mainnet_enabled(workspace, true)`. This
   emits a `workspace.mainnet_enabled.set` audit event with actor,
   subject, and workspace id.
3. The first real mainnet UserOp is now allowed to proceed
   through the runtime, gated still by every other safety
   surface (pause/kill switch, dispatch-worker defense in depth,
   policy version snapshot, etc.).

Until step 2 happens, the runtime continues to refuse mainnet
operation at every layer with `:mainnet_disabled` — see the
"Where the gate fires" table in
[`docs/runbooks/production-observability.md`](production-observability.md#where-the-gate-fires).

## Cross-links

- [`docs/runbooks/production-observability.md`](production-observability.md)
  — daily operator triage; § Base mainnet feature gate (#178) and
  § Base mainnet preflight (#179).
- [`docs/incident-runbook.md`](../incident-runbook.md) —
  § Emergency pause, § Adapter outage, § Stuck executions.
- [`docs/operator-secrets-checklist.md`](../operator-secrets-checklist.md)
  — env var / secret provisioning checklist.
- `Bank.Chains.MainnetPreflight` moduledoc.
- `Mix.Tasks.Bank.Chain.Mainnet.Preflight` moduledoc.
- [`test/bank/chains/mainnet_preflight_test.exs`][preflight-test]
  — pinned no-broadcast posture (only read-only RPC methods).
- [`test/bank/mainnet_gate_test.exs`][gate-test] — pinned
  fail-closed mainnet gate at every chain-touching boundary.

## Related issues

- [#166](https://github.com/Linh86/cryptobank/issues/166) — epic.
- [#178](https://github.com/Linh86/cryptobank/issues/178) —
  workspace `mainnet_enabled` flag.
- [#179](https://github.com/Linh86/cryptobank/issues/179) —
  read-only mainnet preflight.
- [#180](https://github.com/Linh86/cryptobank/issues/180) — this
  runbook.
