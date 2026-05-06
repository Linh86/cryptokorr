# `@cryptobank/sdk` — TypeScript SDK for CryptoBank

The official TypeScript SDK for the CryptoBank `/v1` control-plane
API. Submit intents, poll decisions, drive operator approvals, and
read audit trails from a Node-server-side application — without
ever pasting a private key into your code.

The SDK matches the contract pinned in
[`docs/api/sdk-surface.md`](../../docs/api/sdk-surface.md) and the
error taxonomy in
[`docs/api/error-codes.md`](../../docs/api/error-codes.md). The
Python SDK ([`@cryptobank/sdk-py`](../python)) ships alongside it
with the same method names.

## Install

```sh
npm install @cryptobank/sdk
```

The SDK targets **Node 18+**. It uses native `fetch` + `globalThis.crypto`;
no transitive runtime dependencies.

## MVP scope

- **Base Sepolia (`chain: "base-sepolia"`) only.** Base mainnet
  (`chain: "base"`) is gated by a workspace flag and surfaces as a
  typed `mainnet_disabled` error until the operator opts the
  workspace in.
- **USDC** is the only supported asset in the MVP.
- **Single active delegation** per workspace.
- **No paymaster / sponsored gas** — the smart account pays.

## Quickstart (Node, server-side)

```ts
import { Cryptobank } from "@cryptobank/sdk";

// Reads CRYPTOBANK_API_KEY (required) + CRYPTOBANK_BASE_URL +
// CRYPTOBANK_TIMEOUT_MS from process.env.
const client = Cryptobank.fromEnv();

// 1. Submit a transfer intent.
const result = await client.submitTransfer({
  agentId: "agent-alice",
  asset: "USDC",
  chain: "base-sepolia",
  amount: "10.50",
  target: { counterpartyId: "b6a10f53-8c6e-4d79-9bb9-3e1e5b1f1a11" },
  notes: "MVP demo transfer",
});

console.log("intent:", result.intentId, "state:", result.state);

// 2. Wait for the decision pipeline to make a call.
const decision = await client.waitForDecision(result.intentId, {
  timeoutSeconds: 30,
});

switch (decision.outcome) {
  case "auto_exec":
    console.log("Auto-dispatched.");
    break;
  case "approval_required":
    // approval_required is a SUCCESSFUL response, not an error.
    // The agent should hand off to an operator instead of looping.
    console.log("Operator approval required.");
    break;
  case "hold":
    console.log("Held — runtime needs more data:", decision.reasons);
    break;
  case "block":
    console.log("Refused:", decision.reasons);
    break;
}
```

Run it (with a valid CryptoBank workspace API key):

```sh
export CRYPTOBANK_API_KEY="cb_..."
export CRYPTOBANK_BASE_URL="http://localhost:4000"  # optional
node ./demo.mjs
```

## ⚠️ Browser usage

**Do not embed your workspace API key in browser / client-side
code.** Workspace API keys are operator credentials. They're
designed for server-to-server use; exposing one in a browser bundle
or a client-side environment variable lets anyone with view of your
site act as your workspace.

The supported pattern is:

1. Run this SDK on **your own backend** (Node service, edge
   function, serverless handler).
2. Have the browser call **your backend**.
3. Your backend authenticates the end user, then submits the
   intent through the SDK on their behalf.

The browser-driven non-custodial onboarding flow (wallet connect →
session permission install) is a different surface; see
[`docs/wallet-quickstart.md`](../../docs/wallet-quickstart.md) for
that path. It does not use this SDK.

## Configuration

| Setting       | Constructor key | Env var                 | Default                  |
| ------------- | --------------- | ----------------------- | ------------------------ |
| API key       | `apiKey`        | `CRYPTOBANK_API_KEY`    | (required, no default)   |
| Base URL      | `baseUrl`       | `CRYPTOBANK_BASE_URL`   | `http://localhost:4000`  |
| Timeout (ms)  | `timeoutMs`     | `CRYPTOBANK_TIMEOUT_MS` | `15000`                  |
| User-Agent    | `userAgent`     | n/a                     | `cryptobank-js/<v>`      |
| `fetch`       | `fetch`         | n/a                     | `globalThis.fetch`       |

```ts
const client = new Cryptobank({
  apiKey: process.env.CRYPTOBANK_API_KEY!,
  baseUrl: "https://api.example.com",
  timeoutMs: 30_000,
});
```

The `apiKey` is **never** logged, **never** included in error
message text, **never** echoed in `toString()` or object inspection.
Any string the SDK surfaces to the caller passes through a
`cb_<...>` redactor first; tests pin this guarantee.

## Method surface

### Intents

```ts
await client.submitTransfer({...});                // POST /v1/intents kind=transfer
await client.submitSwap({...});                    // POST /v1/intents kind=swap
await client.submitAllocateIdleCapital({...});     // POST /v1/intents kind=allocate_idle_capital
await client.getIntent(intentId);                  // GET  /v1/intents/:id
await client.simulateIntent(intentId, {reason});   // POST /v1/intents/:id/simulate
await client.cancelIntent(intentId, {reason});     // POST /v1/intents/:id/cancel
await client.getAuditTrail(intentId);              // GET  /v1/intents/:id/replay
```

### Decisions

```ts
await client.getDecision(decisionId);              // GET /v1/decisions/:id
await client.waitForDecision(intentId, {           // polling helper
  timeoutSeconds: 60,
  pollIntervalMs: 500,
});
```

### Counterparties / runtime / policy

```ts
await client.listCounterparties({q, active});      // GET /v1/counterparties
await client.getRuntimeStatus();                   // GET /v1/health/deep (no auth)
await client.getPolicy(policyId);                  // GET /v1/policies/:id
```

### Operator-only

These return `403 insufficient_role` when called with an
agent-role API key. They live under `client.operator.*` so misuse
from an agent context is loud:

```ts
await client.operator.listPendingApprovals();
await client.operator.approveDecision(decisionId, {actorId, reason});
await client.operator.rejectDecision(decisionId, {actorId, reason});
await client.operator.pauseRuntime({reason});
await client.operator.resumeRuntime();
```

## Idempotency

Every write method accepts an `idempotencyKey`. The SDK
auto-generates a UUID v4 if you don't supply one. Passing the same
key twice with the same body is a safe replay; the response carries
`idempotentReplay: true` (or `idempotent: true` on cancel) so you
can detect dedupes if you care.

```ts
await client.submitTransfer({ ...args, idempotencyKey: "my-stable-key" });
```

A duplicate key with a *mismatched body* surfaces as
`IdempotencyConflictError`. Use a fresh key for a new intent.

## Errors

Non-2xx responses raise a typed exception keyed off the wire
`error.code`. The class hierarchy mirrors
[`docs/api/error-codes.md`](../../docs/api/error-codes.md):

```
APIError
├── AuthenticationError       (401)
├── AuthorizationError        (403)
├── ValidationError           (422)
│   ├── SwapSafetyError       (swap_*)
│   └── MorphoSafetyError     (morpho_*)
├── NotFoundError             (404)
├── ConflictError             (409)
│   ├── IdempotencyConflictError
│   └── WrongStateError
├── RateLimitError            (429)
└── ServiceUnavailableError   (502 / 503 / 504)
    ├── WorkspacePausedError
    ├── ChainPausedError
    └── UpstreamError
```

```ts
import {
  Cryptobank,
  SwapSafetyError,
  IdempotencyConflictError,
  RateLimitError,
} from "@cryptobank/sdk";

try {
  await client.submitSwap({
    agentId: "agent-alice",
    chain: "base-sepolia",
    sourceAsset: "USDC",
    destinationAsset: "USDC",
    amount: "0", // invalid
  });
} catch (err) {
  if (err instanceof SwapSafetyError && err.code === "swap_amount_invalid") {
    console.log("Fix the amount and resubmit with a fresh idempotencyKey.");
  } else if (err instanceof IdempotencyConflictError) {
    console.log("Reused key with mismatched body. Hint:", err.hint);
  } else if (err instanceof RateLimitError) {
    console.log("Retry-After:", err.retryAfterSeconds);
  } else {
    throw err;
  }
}
```

## Retry posture

The SDK retries **only** when:

1. The wire response sets `error.retryable: true`.
2. The request carried an `Idempotency-Key` (auto or
   caller-supplied).

Retry uses exponential backoff (250ms → 500ms → 1s → 2s …) capped
at 30 seconds, honours the `Retry-After` header, and bounds the
total wall-clock budget at `timeoutMs * 4` (default 60s).

The chain-action cap on `/v1/security/*` (5 / 60s) is **not**
auto-retried — the operator wants to see the error, not silent
waiting.

## Approval-required is a successful response

A decision with `outcome: "approval_required"` is **not** an error.
The runtime returned a successful HTTP status with that decision;
the SDK surfaces it as `Decision.outcome === "approval_required"`
so an agent can short-circuit instead of looping. See
[`docs/api/error-codes.md`](../../docs/api/error-codes.md#approval-required-decisions)
for the full statement.

## Versioning

The SDK version tracks the `/v1` API's major version. Breaking
changes require a major SDK bump and a written upgrade note;
additive changes (new endpoints, new optional fields) are minor.

## Development

```sh
npm install
npm run typecheck      # tsc --noEmit
npm test               # vitest run
npm run build          # tsc -p tsconfig.build.json → dist/
```

Tests are mocked — no real network calls.
