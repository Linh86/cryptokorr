# SDK surface — Python and TypeScript

> Status: SDK / MCP foundation (#478).
> Implementation tracks: Python (#479), TypeScript (#480). MCP
> server (#481) sits on top of the same wire contract.
> OpenAPI artifact: [`priv/openapi/openapi.json`](../../priv/openapi/openapi.json).
> Error taxonomy: [`error-codes.md`](error-codes.md).

This document pins the SDK method names, signatures, and behavioral
contracts so #479 (Python) and #480 (TypeScript) can land in
parallel without divergence. Implementations consume the OpenAPI
artifact; this document is the human-readable contract that
constrains the parts the artifact does not pin (method naming,
exception classes, retry posture, return shapes that flatten the
JSON envelope).

## Posture

* **Workspace-scoped.** Every method operates within the workspace
  the API key belongs to. There is no cross-workspace surface.
* **MVP.** Examples show Base Sepolia (`chain: "base-sepolia"`) and
  USDC. Mainnet (`chain: "base"`) is gated by a workspace flag and
  is not the default.
* **Idempotent writes.** Every write method accepts an
  `idempotency_key` parameter. The SDK auto-generates one if the
  caller does not supply one; passing the same key twice with the
  same body is a safe replay.
* **Typed errors.** Non-2xx responses raise / throw a typed
  exception keyed off the `error.code` from the wire (see
  [`error-codes.md`](error-codes.md)).
* **Approval-required is not an error.** A decision with
  `outcome: "approval_required"` is a successful 202; the SDK
  surfaces it as a typed result with `requires_approval: True` so
  agents can short-circuit instead of looping.

## Configuration

Both SDKs read configuration in this priority order:

1. Constructor argument.
2. Environment variable.
3. `~/.cryptobank/config.toml` (planned, post-MVP).

| Setting       | Env var                | Default                       | Notes                                             |
| ------------- | ---------------------- | ----------------------------- | ------------------------------------------------- |
| `api_key`     | `CRYPTOBANK_API_KEY`   | (required, no default)        | `Authorization: Bearer cb_<...>`. Must be a valid `cb_` prefixed key.                          |
| `base_url`    | `CRYPTOBANK_BASE_URL`  | `http://localhost:4000`       | Production deployments override with their tenant URL. No trailing slash.                      |
| `timeout`     | `CRYPTOBANK_TIMEOUT_MS`| `15_000` (ms)                 | Per-request HTTP timeout. SDK retry budget is on top of this.                                  |
| `user_agent`  | (n/a)                  | `cryptobank-py/<v>` / `cryptobank-js/<v>` | Sent on every request for telemetry / log correlation.                  |

`api_key` is **never** logged, **never** included in error message
text, and **never** echoed in repr/inspect output. Both SDKs strip it
from formatted exceptions.

## Auth + retry

```python
# Python
client = Cryptobank(api_key="cb_...", base_url="https://api.example.com")
client = Cryptobank.from_env()  # reads CRYPTOBANK_API_KEY + CRYPTOBANK_BASE_URL
```

```typescript
// TypeScript
const client = new Cryptobank({ apiKey: "cb_...", baseUrl: "https://api.example.com" });
const client = Cryptobank.fromEnv();  // reads CRYPTOBANK_API_KEY + CRYPTOBANK_BASE_URL
```

Both clients add `Authorization: Bearer <api_key>` to every request,
generate a `Idempotency-Key` for writes when the caller does not pass
one, and retry only on `error.retryable === true` codes (rate-limit,
upstream 5xx, paused). Retry honours `Retry-After`, uses exponential
backoff capped at 30s, and bounds total wall-clock at the
configured `timeout * 4` budget.

The chain-action cap on `/v1/security/*` (5 / 60s) is **not**
auto-retried — operator-cap throttling means the caller wants the
error surface, not silent waiting.

## Method surface

Each method is listed with:

* a short purpose,
* HTTP details (method + path),
* required role,
* Python signature,
* TypeScript signature,
* return shape highlights,
* error codes that can fire (full list in
  [`error-codes.md`](error-codes.md)).

All methods are async in TypeScript (`Promise<T>`). The Python SDK
ships sync (`Cryptobank`) and async (`AsyncCryptobank`) clients with
identical method names; the signatures below show the sync form.

### Intents

#### `submit_transfer` / `submitTransfer`

Submit a transfer intent. The agent flow's primary write.

* `POST /v1/intents`
* Role: `operator`
* Errors: `idempotency_conflict`, `unsupported_chain`,
  `unsupported_asset`, `mainnet_disabled`, `invalid_amount`,
  `invalid_target`, `invalid_body`, `smart_account_required`,
  `smart_account_not_found`, `smart_account_chain_mismatch`,
  `rate_limited`, `workspace_paused`.

```python
def submit_transfer(
    self,
    *,
    agent_id: str,
    asset: str,                     # "USDC"
    chain: str,                     # "base-sepolia" | "base"
    amount: str,                    # decimal string, e.g. "10.5"
    target: TransferTarget,         # see below
    notes: str | None = None,
    smart_account_id: str | None = None,
    source: str = "agent",
    idempotency_key: str | None = None,
) -> IntentSubmitResult: ...
```

```typescript
async submitTransfer(args: {
  agentId: string;
  asset: string;
  chain: string;
  amount: string;
  target: TransferTarget;
  notes?: string;
  smartAccountId?: string;
  source?: string;
  idempotencyKey?: string;
}): Promise<IntentSubmitResult>;
```

`TransferTarget` is a tagged union:

```typescript
type TransferTarget =
  | { counterpartyId: string; addressLabelId?: string }
  | { rawAddress: string };
```

Returns:

```typescript
type IntentSubmitResult = {
  intentId: string;
  state: IntentState;        // "submitted" | "evaluating" | "decided" | ...
  idempotentReplay: boolean; // true when this is a key-replay
  intent: Intent;
  links: { self: string; replay: string };
};
```

#### `submit_swap` / `submitSwap`

Submit a swap intent (exact-input only; MVP uses 0x on Base Sepolia).

* `POST /v1/intents` with `kind: "swap"`
* Role: `operator`
* Errors: every `submit_transfer` error plus
  `swap_chain_not_supported`, `swap_asset_not_supported`,
  `swap_route_field_missing`, `swap_amount_invalid`,
  `swap_slippage_exceeded`, `swap_deadline_expired`,
  `swap_type_not_supported`, `swap_native_value_disallowed`.

```python
def submit_swap(
    self,
    *,
    agent_id: str,
    chain: str,                     # "base-sepolia"
    source_asset: str,              # "USDC"
    destination_asset: str,         # "USDC", "USDT", "ETH"
    amount: str,                    # input amount, decimal string
    smart_account_id: str | None = None,
    notes: str | None = None,
    source: str = "agent",
    idempotency_key: str | None = None,
) -> IntentSubmitResult: ...
```

```typescript
async submitSwap(args: {
  agentId: string;
  chain: string;
  sourceAsset: string;
  destinationAsset: string;
  amount: string;
  smartAccountId?: string;
  notes?: string;
  source?: string;
  idempotencyKey?: string;
}): Promise<IntentSubmitResult>;
```

The SDK does **not** accept raw calldata, slippage, deadline, or
target contract — Phoenix's quote provider fills those in via the
#190 route artifacts. Agents express *intent* (input + output asset
+ amount); Phoenix decides *execution*.

#### `submit_allocate_idle_capital` / `submitAllocateIdleCapital`

Submit a Morpho ERC-4626 deposit intent.

* `POST /v1/intents` with `kind: "allocate_idle_capital"` (the
  public wire enum; the persisted Elixir atom is internally
  `:defi_yield_deposit` but submitting that internal name is
  rejected with `{:invalid, :kind}`).
* Role: `operator`
* Errors: `morpho_chain_not_supported`,
  `morpho_vault_not_allowlisted`, `morpho_snapshot_missing`,
  `morpho_snapshot_expired`, `morpho_snapshot_drifted`,
  `idempotency_conflict`, `rate_limited`, `workspace_paused`.

```python
def submit_allocate_idle_capital(
    self,
    *,
    agent_id: str,
    asset: str,                     # "USDC"
    chain: str = "base-sepolia",    # MVP: Morpho is Sepolia-only
    amount: str,
    vault_address: str,             # workspace allowlist verified server-side
    smart_account_id: str | None = None,
    notes: str | None = None,
    source: str = "agent",
    idempotency_key: str | None = None,
) -> IntentSubmitResult: ...
```

```typescript
async submitAllocateIdleCapital(args: {
  agentId: string;
  asset: string;
  chain?: string;
  amount: string;
  vaultAddress: string;
  smartAccountId?: string;
  notes?: string;
  source?: string;
  idempotencyKey?: string;
}): Promise<IntentSubmitResult>;
```

Withdraw / redeem is **not** in the SDK. Morpho withdraw is
operator-only (see `OperatorWithdraw` module, gated on
`actor_role: :operator`).

#### `get_intent` / `getIntent`

Fetch the current state of an intent.

* `GET /v1/intents/:id`
* Role: `viewer`
* Errors: `not_found`, `rate_limited`.

```python
def get_intent(self, intent_id: str) -> Intent: ...
```

```typescript
async getIntent(intentId: string): Promise<Intent>;
```

#### `simulate_intent` / `simulateIntent`

Re-run simulation for an intent.

* `POST /v1/intents/:id/simulate`
* Role: `operator`
* Errors: `not_found`, `wrong_state`, `invalid_reason`,
  `upstream_unavailable`, `upstream_timeout`, `rate_limited`.

```python
def simulate_intent(
    self,
    intent_id: str,
    *,
    reason: Literal["pre_submit_dry_run", "refresh", "operator_inspection"] = "refresh",
) -> SimulationResult: ...
```

```typescript
async simulateIntent(intentId: string, args?: {
  reason?: "pre_submit_dry_run" | "refresh" | "operator_inspection";
}): Promise<SimulationResult>;
```

#### `cancel_intent` / `cancelIntent`

Operator pre-execution cancel.

* `POST /v1/intents/:id/cancel`
* Role: `operator`
* Errors: `not_found`, `wrong_state`, `rate_limited`.

```python
def cancel_intent(self, intent_id: str, *, reason: str) -> IntentCancelResult: ...
```

```typescript
async cancelIntent(intentId: string, args: { reason: string }): Promise<IntentCancelResult>;
```

#### `get_audit_trail` / `getAuditTrail`

Get the replay bundle for an intent — full history of decisions,
simulations, plans, and audit events.

* `GET /v1/intents/:id/replay`
* Role: `viewer`
* Errors: `not_found`, `rate_limited`.

```python
def get_audit_trail(self, intent_id: str) -> AuditTrail: ...
```

```typescript
async getAuditTrail(intentId: string): Promise<AuditTrail>;
```

The `AuditTrail` is the full replay bundle shape that powers the
LiveView replay page: intent, policy snapshot, trust assessments,
simulations, decisions, plans, audit events,
`stablecoin_route_evidence`, `morpho_evidence`, `swap_route_evidence`,
matched activities. SDK consumers can render their own audit UI from
this shape.

### Decisions

#### `get_decision` / `getDecision`

Fetch a decision envelope.

* `GET /v1/decisions/:id`
* Role: `viewer`
* Errors: `not_found`, `rate_limited`.

```python
def get_decision(self, decision_id: str) -> Decision: ...
```

```typescript
async getDecision(decisionId: string): Promise<Decision>;
```

The `Decision.outcome` field is the primary thing agents switch on:
`"auto_exec"` (already dispatched), `"approval_required"` (waiting
for operator), `"hold"` (waiting on missing data; e.g. snapshot
stale), `"block"` (terminal refusal).

#### `wait_for_decision` / `waitForDecision`

Poll an intent's current decision until it leaves `:evaluating`.
Helper, not a separate endpoint.

```python
def wait_for_decision(
    self,
    intent_id: str,
    *,
    timeout_seconds: int = 60,
    poll_interval_ms: int = 500,
) -> Decision: ...
```

```typescript
async waitForDecision(intentId: string, args?: {
  timeoutSeconds?: number;
  pollIntervalMs?: number;
}): Promise<Decision>;
```

The SDK polls `GET /v1/intents/:id`, reads `current_decision_id`,
then polls `GET /v1/decisions/:id`. Bounded by the timeout. Returns
the decision regardless of `outcome` — the caller decides what to do
with `approval_required` / `hold` / `block`.

### Approvals (operator-scoped)

These are operator surfaces. Agents calling them with an
`agent`-role key get `403 insufficient_role`. SDKs expose them under
a separate `client.operator` namespace so accidental misuse from an
agent context is loud:

```python
client.operator.list_pending_approvals()
client.operator.approve_decision(decision_id, actor_id="me", reason="ok")
client.operator.reject_decision(decision_id, actor_id="me", reason="too risky")
```

```typescript
client.operator.listPendingApprovals();
client.operator.approveDecision(decisionId, { actorId: "me", reason: "ok" });
client.operator.rejectDecision(decisionId, { actorId: "me", reason: "too risky" });
```

* `GET /v1/approvals` (operator)
* `POST /v1/approvals/:decision_id/approve` (operator)
* `POST /v1/approvals/:decision_id/reject` (operator)
* Errors: `not_found`, `wrong_state`, `invalid_request`,
  `insufficient_role`, `rate_limited`.

### Counterparties

```python
client.list_counterparties()                           # GET /v1/counterparties
client.get_counterparty(counterparty_id)               # not in MVP; reserved
```

```typescript
client.listCounterparties();
client.getCounterparty(counterpartyId);  // reserved
```

* `GET /v1/counterparties`
* Role: `viewer`
* Errors: `rate_limited`.

Mutating counterparties (create, attach address, add evidence) is
operator-only and exposed under `client.operator.counterparties.*`.
Agents should not be creating counterparties; they reference
existing ones by id.

### Audit

```python
client.list_audit_events(filter: AuditFilter | None = None) -> Page[AuditEvent]
```

```typescript
client.listAuditEvents(filter?: AuditFilter): Promise<Page<AuditEvent>>;
```

* `GET /v1/audit`
* Role: `operator`
* Errors: `insufficient_role` (if called with `agent` role),
  `rate_limited`.

`AuditFilter` supports event-type prefix, subject id, time range,
and pagination cursor. Read-only.

### Runtime status

```python
client.get_runtime_status() -> RuntimeStatus
```

```typescript
client.getRuntimeStatus(): Promise<RuntimeStatus>;
```

* `GET /v1/health/deep`
* Auth: **none required** (the deep health endpoint is on the bare
  `:api` pipeline so external monitors can hit it without a key).
* Errors: `service_unavailable` (very rare; database down).

`RuntimeStatus` includes Postgres connectivity, adapter reachability,
quote-provider health (#176), stuck-plan counts (#230), and the
overall `status` ("ok" | "degraded" | "failing").

### Policies

```python
client.get_policy(policy_id: str) -> Policy
client.list_policies() -> list[Policy]
```

```typescript
client.getPolicy(policyId: string): Promise<Policy>;
client.listPolicies(): Promise<Policy[]>;
```

* `GET /v1/policies` (viewer), `GET /v1/policies/:id` (viewer)
* Errors: `not_found`, `rate_limited`.

Mutating policies (create, revise, archive) is **admin-only** and
**not** exposed in the SDK. Agents must not edit policy. Operators
needing programmatic access call `/v1/policies` directly.

### Smart accounts

The smart-account picker (#184) is part of intent submission, not a
separate surface — `smart_account_id` is an optional argument on
every write. The SDK does not provide a `list_smart_accounts`
helper in MVP because the intent path returns
`smart_account_required` with the workspace's account ids in the
hint when ambiguity occurs; operators discover accounts through the
operator UI or via the OpenAPI spec for the connect endpoint.

## Type definitions (cross-SDK)

Both SDKs ship a single shared model module generated from the
OpenAPI artifact. Field-level details live there; the high-level
shapes:

```typescript
type IntentState =
  | "submitted" | "evaluating" | "decided" | "executing"
  | "executed" | "blocked" | "cancelled" | "expired";

type DecisionOutcome =
  | "auto_exec" | "approval_required" | "hold" | "block";

type Intent = {
  id: string;
  agentId: string;
  source: "agent" | "user" | "runtime";
  kind: "transfer" | "swap" | "scheduled_transfer" | "allocate_idle_capital";
  asset: string;
  chain: string;
  amount: string;
  target: { counterpartyId?: string; addressLabelId?: string; rawAddress?: string };
  state: IntentState;
  smartAccountId: string | null;
  submittedAt: string;
  currentDecisionId: string | null;
  currentSimulationId: string | null;
  currentExecutionPlanId: string | null;
  // ... see OpenAPI artifact for the full field list
};

type Decision = {
  id: string;
  intentId: string;
  outcome: DecisionOutcome;
  riskTier: "low" | "moderate" | "elevated" | "severe";
  reasons: { items: ReasonItem[] };
  approvalExpiresAt: string | null;
  // ...
};
```

## Examples

### Submit a transfer (Python)

```python
from cryptobank import Cryptobank
client = Cryptobank.from_env()  # CRYPTOBANK_API_KEY + CRYPTOBANK_BASE_URL

result = client.submit_transfer(
    agent_id="agent-alice",
    asset="USDC",
    chain="base-sepolia",
    amount="10.50",
    target={"counterparty_id": "b6a10f53-8c6e-4d79-9bb9-3e1e5b1f1a11"},
    notes="MVP demo transfer",
)
print(result.intent_id, result.state)

decision = client.wait_for_decision(result.intent_id, timeout_seconds=30)
if decision.outcome == "approval_required":
    print("Waiting for operator approval; not auto-executing.")
elif decision.outcome == "auto_exec":
    print("Dispatched.")
elif decision.outcome in ("hold", "block"):
    print("Refused:", decision.reasons)
```

### Submit a swap (TypeScript)

```typescript
import { Cryptobank } from "@cryptobank/sdk";

const client = Cryptobank.fromEnv();

const result = await client.submitSwap({
  agentId: "agent-alice",
  chain: "base-sepolia",
  sourceAsset: "USDC",
  destinationAsset: "USDC",
  amount: "10",
});

const decision = await client.waitForDecision(result.intentId, { timeoutSeconds: 30 });
if (decision.outcome === "approval_required") {
  console.log("Operator approval required.");
}
```

### Handle a typed error (Python)

```python
from cryptobank import (
    Cryptobank,
    SwapSafetyError,
    IdempotencyConflictError,
    RateLimitError,
)

try:
    client.submit_swap(
        agent_id="agent-alice",
        chain="base-sepolia",
        source_asset="USDC",
        destination_asset="USDC",
        amount="0",  # invalid
    )
except SwapSafetyError as e:
    if e.code == "swap_amount_invalid":
        print("Fix the amount and resubmit with a fresh idempotency_key.")
except IdempotencyConflictError as e:
    print("Reused key with mismatched body. Prior intent:", e.hint)
except RateLimitError as e:
    print("Rate-limited. Retry after:", e.retry_after_seconds)
```

## Non-goals (deferred)

The following are explicitly **not** in the SDK foundation:

* Mainnet writes (`chain: "base"`). The wire endpoint exists; the
  SDK will surface `mainnet_disabled` as a typed error until the
  workspace flag is on. Examples and docstrings always use
  `base-sepolia` in MVP.
* Streaming / websocket subscription. Polling-only in MVP.
* Workspace-management writes (create workspace, edit workspace
  settings, manage memberships).
* API-key management surface. Admin-only and exposed only through
  the operator console; SDK callers do not rotate their own keys.
* Session-permission / browser-wallet flows. Browser-only.
* Trust-assertion writes. Operator-only via `client.operator` in a
  future issue; not part of the SDK / MCP launch surface.

## Versioning

The SDKs version against the OpenAPI artifact's `info.version`
(currently pinned at the `/v1` major version). Breaking changes
require a major SDK bump and a written upgrade note. Additive
changes (new endpoints, new optional fields) are minor.
