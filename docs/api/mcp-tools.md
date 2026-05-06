# MCP tool surface — stdio MCP server for agent builders

> Status: SDK / MCP foundation (#478).
> Implementation: stdio MCP server (#481), built on top of the
> Python SDK (#479). Examples follow-up: #482; package/docs
> follow-up: #483.
> Wire contract: [`error-codes.md`](error-codes.md),
> [`sdk-surface.md`](sdk-surface.md), and the OpenAPI artifact
> at [`priv/openapi/openapi.json`](../../priv/openapi/openapi.json).

This document pins the tool list, JSON schemas, readonly behaviour,
and explicit non-goals for the stdio MCP server. The intent is that
an agent host (Claude Desktop, Cursor, Codex, etc.) can discover
the tools via standard MCP tool listing and use them safely without
the host needing to understand CryptoBank semantics.

## Configuration

The MCP server reads configuration from environment variables only.
There is **no per-call auth** — the agent host launches the server
with the operator's credentials baked in, and every tool call
inherits them. This matches the stdio MCP convention.

| Env var                    | Required | Purpose                                                          |
| -------------------------- | -------- | ---------------------------------------------------------------- |
| `CRYPTOBANK_API_KEY`       | yes      | The `cb_<...>` API key. Maps directly to the workspace and role this MCP session can act as. |
| `CRYPTOBANK_BASE_URL`      | no       | Defaults to `http://localhost:4000`. Production deployments override.                        |
| `CRYPTOBANK_READONLY`      | no       | When set to `"true"`, write tools are **omitted from the tool list**. The server does not surface them at all — the model cannot invoke a write tool that wasn't advertised. Defaults to `"false"`. |
| `CRYPTOBANK_AGENT_ID`      | no       | Optional default `agent_id` injected into write-tool requests when the caller doesn't supply one. Useful when one MCP session represents one agent. |
| `CRYPTOBANK_TIMEOUT_MS`    | no       | Per-tool-call HTTP timeout. Defaults to `15_000`.                |

The MCP server **never** logs the API key, **never** echoes it in
tool error data, and **never** surfaces it via a tool result.

## Tool tiers

Tools are partitioned into three tiers. The server advertises a
different subset depending on the API key's role and
`CRYPTOBANK_READONLY`:

| Tier        | Always advertised? | Hidden when…                                       |
| ----------- | ------------------ | -------------------------------------------------- |
| **read**    | yes                | (never hidden)                                     |
| **write**   | conditional        | `CRYPTOBANK_READONLY=true`                         |
| **operator**| conditional        | API key role is below `operator` (server probes the `/v1/health/deep` headers / a probe call to determine role at startup) OR `CRYPTOBANK_READONLY=true` |

If a tool is hidden, the model cannot invoke it. If the API key's
role can't reach a tool's required role even when advertised (e.g.,
operator API key tries to call an admin-only tool), the tool call
returns a typed error with `code: insufficient_role` that the agent
sees and can react to.

## Tool list

### Read tools (always advertised)

#### `get_intent`

Look up an intent by id.

* Backed by `GET /v1/intents/:id` (viewer).
* Input schema:
  ```json
  {
    "type": "object",
    "required": ["intent_id"],
    "properties": {
      "intent_id": { "type": "string", "format": "uuid" }
    },
    "additionalProperties": false
  }
  ```
* Output: the full `Intent` record (see SDK surface).
* Errors: `not_found`, `rate_limited`.

#### `get_decision`

Look up a decision envelope by id.

* Backed by `GET /v1/decisions/:id` (viewer).
* Input schema: `{ "decision_id": "uuid" }` (required).
* Output: the `Decision` record. The model branches on
  `decision.outcome`.
* Errors: `not_found`, `rate_limited`.

#### `wait_for_decision`

Block until an intent leaves `:evaluating` (or timeout).

* No new endpoint — wraps `get_intent` + `get_decision`.
* Input schema:
  ```json
  {
    "type": "object",
    "required": ["intent_id"],
    "properties": {
      "intent_id":  { "type": "string", "format": "uuid" },
      "timeout_seconds": { "type": "integer", "minimum": 1, "maximum": 60, "default": 30 }
    },
    "additionalProperties": false
  }
  ```
* Output: the resulting `Decision`. The MCP tool **caps timeout at
  60 seconds** so an agent cannot accidentally loop. If the
  decision is still `:evaluating` after the timeout, the tool
  returns a synthetic result with `outcome: "still_evaluating"` so
  the model can decide to call again or move on.
* Errors: `not_found`, `rate_limited`.

#### `get_audit_trail`

Fetch the replay bundle for an intent.

* Backed by `GET /v1/intents/:id/replay` (viewer).
* Input schema: `{ "intent_id": "uuid" }` (required).
* Output: the full `AuditTrail` (intent, policy snapshot, trust
  assessments, simulations, decisions, plans, audit events,
  `swap_route_evidence`, `morpho_evidence`, `stablecoin_route_evidence`).
* Errors: `not_found`, `rate_limited`.

#### `list_counterparties`

List counterparties in the caller's workspace.

* Backed by `GET /v1/counterparties` (viewer).
* Input schema:
  ```json
  {
    "type": "object",
    "properties": {
      "limit": { "type": "integer", "minimum": 1, "maximum": 100, "default": 50 }
    },
    "additionalProperties": false
  }
  ```
* Output: `{ "counterparties": [CounterpartySummary] }`.
* Errors: `rate_limited`.

#### `get_runtime_status`

Fetch the runtime / health status.

* Backed by `GET /v1/health/deep` (no auth required, but the MCP
  server still sends the API key for telemetry attribution).
* Input schema: `{}` (no arguments).
* Output: `RuntimeStatus` (status string, per-component checks,
  quote-provider health, stuck-plan counts).
* Errors: `service_unavailable` (rare).

#### `get_policy`

Fetch a policy or list policies.

* Backed by `GET /v1/policies` and (planned) `GET /v1/policies/:id`
  (viewer).
* Input schema: `{ "policy_id": "uuid" }` (optional; lists when
  absent).
* Output: a single `Policy` or `{ "policies": [Policy] }`.
* Errors: `not_found`, `rate_limited`.

#### `list_pending_approvals` *(operator-tier)*

List decisions waiting on operator approval.

* Backed by `GET /v1/approvals` (operator).
* Hidden when the API key role is below `operator` OR
  `CRYPTOBANK_READONLY=true` (because the typical follow-up is an
  approve/reject write).
* Input schema: `{}`.
* Output: `{ "pending": [Decision] }`.
* Errors: `insufficient_role`, `rate_limited`.

### Write tools (hidden when `CRYPTOBANK_READONLY=true`)

#### `submit_transfer`

Submit a transfer intent.

* Backed by `POST /v1/intents` (operator).
* Input schema (truncated for readability; full schema is generated
  from `IntentSubmissionRequest` in the OpenAPI artifact):
  ```json
  {
    "type": "object",
    "required": ["asset", "chain", "amount", "target"],
    "properties": {
      "agent_id":          { "type": "string" },
      "asset":             { "type": "string", "enum": ["USDC"] },
      "chain":             { "type": "string", "enum": ["base-sepolia", "base"] },
      "amount":            { "type": "string", "pattern": "^[0-9]+(\\.[0-9]+)?$" },
      "target":            { "$ref": "#/definitions/TransferTarget" },
      "notes":             { "type": "string" },
      "smart_account_id":  { "type": "string", "format": "uuid" },
      "idempotency_key":   { "type": "string" }
    },
    "additionalProperties": false
  }
  ```
* Output: the full `IntentSubmitResult` (intent + state +
  `idempotent_replay`).
* Errors: every `submit_transfer` SDK error (see
  [`error-codes.md`](error-codes.md)).

The MCP server auto-generates `idempotency_key` if the agent
doesn't supply one; the generator is content-derived (hash of the
request body) so an agent retrying the same call produces a
deduped write rather than a fresh intent.

#### `submit_swap`

Submit a swap intent.

* Backed by `POST /v1/intents` with `kind: "swap"` (operator).
* Input schema:
  ```json
  {
    "type": "object",
    "required": ["chain", "source_asset", "destination_asset", "amount"],
    "properties": {
      "agent_id":           { "type": "string" },
      "chain":              { "type": "string", "enum": ["base-sepolia"] },
      "source_asset":       { "type": "string", "enum": ["USDC"] },
      "destination_asset":  { "type": "string", "enum": ["USDC", "USDT", "ETH"] },
      "amount":             { "type": "string", "pattern": "^[0-9]+(\\.[0-9]+)?$" },
      "smart_account_id":   { "type": "string", "format": "uuid" },
      "notes":              { "type": "string" },
      "idempotency_key":    { "type": "string" }
    },
    "additionalProperties": false
  }
  ```
* Output: `IntentSubmitResult`.
* Errors: every `submit_swap` SDK error including `swap_*` codes.

The MCP swap tool intentionally **does not accept** raw calldata,
slippage, deadline, or target contract. Phoenix's quote provider
fills those in. An agent expressing a swap describes intent (input,
output, amount); execution mechanics are decided server-side.

#### `submit_allocate_idle_capital`

Submit a Morpho ERC-4626 deposit intent.

* Backed by `POST /v1/intents` with `kind: "allocate_idle_capital"`
  (the public wire enum; the persisted Elixir atom is internally
  `:defi_yield_deposit` but submitting that internal name is
  rejected with `{:invalid, :kind}`). Operator role required.
* Input schema:
  ```json
  {
    "type": "object",
    "required": ["amount", "vault_address"],
    "properties": {
      "agent_id":         { "type": "string" },
      "asset":            { "type": "string", "enum": ["USDC"] },
      "chain":            { "type": "string", "enum": ["base-sepolia"] },
      "amount":           { "type": "string", "pattern": "^[0-9]+(\\.[0-9]+)?$" },
      "vault_address":    { "type": "string", "pattern": "^0x[a-fA-F0-9]{40}$" },
      "smart_account_id": { "type": "string", "format": "uuid" },
      "notes":            { "type": "string" },
      "idempotency_key":  { "type": "string" }
    },
    "additionalProperties": false
  }
  ```
* Output: `IntentSubmitResult`.
* Errors: every `submit_allocate_idle_capital` SDK error including
  `morpho_*` codes.

Withdraw / redeem is **not** an MCP tool. Morpho withdraw is
operator-only and is invoked through `OperatorWithdraw` (server
side, gated on `actor_role: :operator`).

#### `cancel_intent`

Operator pre-execution cancel.

* Backed by `POST /v1/intents/:id/cancel` (operator).
* Input schema:
  ```json
  {
    "type": "object",
    "required": ["intent_id", "reason"],
    "properties": {
      "intent_id": { "type": "string", "format": "uuid" },
      "reason":    { "type": "string", "minLength": 1, "maxLength": 280 }
    },
    "additionalProperties": false
  }
  ```
* Output: `IntentCancelResult`.
* Errors: `not_found`, `wrong_state`, `rate_limited`.

### Operator tools (hidden when role < `operator` or `CRYPTOBANK_READONLY=true`)

These are the operator-only mutating surfaces. They share
`CRYPTOBANK_READONLY=true` hiding semantics with the write tier.

#### `approve_decision`

Approve a decision in the queue.

* Backed by `POST /v1/approvals/:decision_id/approve` (operator).
* Input schema:
  ```json
  {
    "type": "object",
    "required": ["decision_id", "actor_id"],
    "properties": {
      "decision_id":     { "type": "string", "format": "uuid" },
      "actor_id":        { "type": "string", "minLength": 1 },
      "reason":          { "type": "string", "maxLength": 280 },
      "idempotency_key": { "type": "string" }
    },
    "additionalProperties": false
  }
  ```
* Output: `ApprovalActionResponse` (successor envelope + dispatch
  status).
* Errors: `not_found`, `wrong_state`, `invalid_request`,
  `insufficient_role`, `rate_limited`.

#### `reject_decision`

Reject a decision in the queue.

* Backed by `POST /v1/approvals/:decision_id/reject` (operator).
* Input schema: same as `approve_decision`.
* Output: `ApprovalActionResponse`.
* Errors: same as `approve_decision`.

#### `pause_runtime`

Globally pause the runtime (writes refuse with `runtime_paused`).

* Backed by `POST /v1/security/pause` (admin + chain-action cap).
* Input schema: `{}`.
* Output: `SecurityStateResponse`.
* Errors: `insufficient_role`, `rate_limited` (chain-action bucket
  is stricter — 5 / 60s on `/v1/security/*`).

#### `resume_runtime`

Globally resume the runtime.

* Backed by `POST /v1/security/resume` (admin + chain-action cap).
* Input schema: `{}`.
* Output: `SecurityStateResponse`.
* Errors: same as `pause_runtime`.

## Explicit non-goals — never an MCP tool

The MCP server **does not** expose the following surfaces, even
when the API key is admin and `CRYPTOBANK_READONLY=false`:

* **Delegation revoke** (`POST /v1/security/revoke_delegation`).
  Delegation revocation is a hard-state-change with on-chain
  consequences; an agent should never invoke it directly. Operators
  use the operator console.
* **Policy edits** (`POST /v1/policies`, `POST /v1/policies/:id/revise`,
  `POST /v1/policies/:id/archive`). Trust + policy is the human
  boundary. Agents read policies (via `get_policy`) but never edit
  them.
* **Trust mutation** (`POST /v1/trust_assertions`,
  `PATCH /v1/counterparties/:id`, `POST /v1/counterparties/:id/evidence`,
  `POST /v1/counterparties/:id/addresses`). Trust authorship is an
  operator decision. Agents read counterparty trust through
  `list_counterparties`; they do not write it.
* **API key management** (`POST /v1/api_keys`, rotate, delete).
  An agent must not spawn keys.
* **Workspace / scope management** (chain pause/resume, agent-key
  pause/resume, abort-execution). These are operator escalation
  surfaces; the operator console is the right place. Specifically,
  `pause_chain` / `resume_chain` / `pause_agent_keys` /
  `resume_agent_keys` / `abort_execution` are **not** MCP tools.
* **Browser-wallet flows.** `POST /v1/connect/smart_account` and
  the `/audit/replay/:id/report` browser-session endpoints are
  designed for a session-bound browser. The MCP server has no
  session affinity and cannot drive them safely.

If a future feature genuinely warrants MCP exposure, it goes through
a written design note + a follow-up issue. The non-goal list is
the security boundary.

## Wire shapes

### Tool list response

The standard MCP `tools/list` response. The server omits hidden
tools entirely; an agent that never sees `submit_swap` cannot call
it.

### Tool call response — success

```json
{
  "content": [
    {
      "type": "text",
      "text": "<JSON-stringified result>"
    }
  ]
}
```

The result body is JSON-stringified (per the MCP convention) and
matches the SDK return shape exactly. Agents can `JSON.parse` it.

### Tool call response — error

```json
{
  "content": [
    {
      "type": "text",
      "text": "<one-line human-readable summary>"
    }
  ],
  "isError": true,
  "error": {
    "code": "<API error.code>",
    "message": "<error.message>",
    "hint": "<error.hint or null>",
    "retryable": true | false
  }
}
```

The MCP error data carries the wire `code` exactly so an agent that
understands the CryptoBank error taxonomy can branch on it. The
human-readable summary in `content[0].text` is the same prose an
operator would see.

The MCP server **never automatically retries**. It surfaces the
error with `retryable` so the agent can decide. The SDK's automatic
retry posture is stripped at the MCP boundary because retries inside
a model loop are usually wrong (the model can re-issue the call
explicitly with a fresh idempotency key if it wants).

## Approval-required handling

A decision with `outcome: "approval_required"` is **not** an error
at the MCP layer. The `submit_*` tool returns success with the
intent + decision; the agent can then call `wait_for_decision` to
check status. If the decision is still `:approval_required` at the
caller's poll, the model should treat it as "waiting on a human"
and not invoke approve/reject itself (those tools are hidden unless
the API key has operator role).

This is documented inside every write tool's description text so
the agent host's tool-discovery surfaces it without the agent
needing to read this doc.

## Examples

### Tool listing (readonly mode)

```bash
CRYPTOBANK_API_KEY="cb_..." CRYPTOBANK_READONLY=true cryptobank-mcp
```

Visible tools:

* `get_intent`
* `get_decision`
* `wait_for_decision`
* `get_audit_trail`
* `list_counterparties`
* `get_runtime_status`
* `get_policy`

(Write and operator tiers are completely absent.)

### Tool listing (operator key, readonly off)

```bash
CRYPTOBANK_API_KEY="cb_op_..." cryptobank-mcp
```

Visible tools (additive over readonly):

* (read tier above)
* `submit_transfer`
* `submit_swap`
* `submit_allocate_idle_capital`
* `cancel_intent`
* `list_pending_approvals`
* `approve_decision`
* `reject_decision`

(`pause_runtime` / `resume_runtime` require admin role; if the key
is operator only, those two are still hidden.)

### Tool call (submit a swap)

Inbound MCP call:

```json
{
  "method": "tools/call",
  "params": {
    "name": "submit_swap",
    "arguments": {
      "chain": "base-sepolia",
      "source_asset": "USDC",
      "destination_asset": "USDC",
      "amount": "10"
    }
  }
}
```

Server response:

```json
{
  "content": [{
    "type": "text",
    "text": "{\"intent_id\":\"...\",\"state\":\"submitted\",\"idempotent_replay\":false,...}"
  }]
}
```

### Tool call (approval-required swap)

Same as above; result includes the intent. Then:

```json
{
  "method": "tools/call",
  "params": {
    "name": "wait_for_decision",
    "arguments": {
      "intent_id": "<id>",
      "timeout_seconds": 30
    }
  }
}
```

Response:

```json
{
  "content": [{
    "type": "text",
    "text": "{\"id\":\"...\",\"intent_id\":\"...\",\"outcome\":\"approval_required\",\"approval_expires_at\":\"...\"}"
  }]
}
```

The agent now knows a human has to approve and should not loop.

## Implementation notes for #481

* The MCP server is Python-first (built on the Python SDK from
  #479). TypeScript MCP support is post-MVP.
* Role / readonly probing happens at server startup. Once
  established, the server caches the role for the lifetime of the
  process; key rotation requires a server restart.
* All HTTP error responses from `/v1/*` flow through the SDK's
  exception mapper, then the MCP exception → tool-error mapper.
  The mapping is mechanical: SDK `<X>Error` → MCP error with the
  `error.code` from the wire.
* The server emits structured logs (one log line per tool call)
  with the API key prefix (`cb_<first8>`) but never the full key.
  Tool arguments are NOT logged; result sizes are.
* Tool results that exceed a configurable size cap (default 256 KB
  per call) are truncated with a synthetic `truncated: true` field
  + a hint to fetch the full record via the SDK directly. Replay
  bundles can grow large.
