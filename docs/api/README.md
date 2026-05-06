# API foundation for SDKs and MCP

> Status: SDK / MCP foundation (#478, parent epic #477).
> The shared contract that #479 (Python SDK), #480 (TypeScript SDK),
> and #481 (stdio MCP server) implement against.

## What's here

* [`error-codes.md`](error-codes.md) — stable, programmatic error
  taxonomy with retry semantics. SDKs map these to typed
  exceptions; the MCP server surfaces them on
  `error.data.code`.
* [`sdk-surface.md`](sdk-surface.md) — aligned Python and TypeScript
  method names, signatures, and behavioral contracts. Implementers
  consume this plus the OpenAPI artifact.
* [`mcp-tools.md`](mcp-tools.md) — stdio MCP tool list, JSON
  schemas, readonly mode, role gating, and the explicit non-goal
  list (no policy edits, no delegation revoke, no trust mutation,
  no API-key management).

## Source-of-truth chain

```
docs/bank-v0.1-runtime-flow-and-api.md   (product contract)
            │
            ▼
lib/bank_web/api_spec.ex                 (code-first OpenAPI spec)
            │ mix openapi.gen
            ▼
priv/openapi/openapi.json                (machine-readable artifact)
            │
            ├──▶ docs/api/error-codes.md       (this directory)
            ├──▶ docs/api/sdk-surface.md       (this directory)
            └──▶ docs/api/mcp-tools.md         (this directory)
                        │
                        ├──▶ #479 Python SDK
                        ├──▶ #480 TypeScript SDK
                        └──▶ #481 stdio MCP server
```

The OpenAPI artifact pins the wire shape (paths, params, request
and response schemas). The three docs in this directory pin the
contracts the artifact does not cover: stable error code names and
their retry posture, SDK method naming and exception classes, and
the MCP tool tier system.

## Posture

* Workspace-scoped. Every API key belongs to one workspace; the SDK
  and MCP server inherit that scope. No cross-workspace surface.
* MVP. Examples target Base Sepolia (`chain: "base-sepolia"`) and
  USDC. Mainnet (`chain: "base"`) is gated behind a workspace flag
  and surfaces as `mainnet_disabled` until enabled.
* Idempotent writes. Every write endpoint accepts an
  `Idempotency-Key` header; SDKs auto-generate one when the caller
  doesn't.
* Approval-required is a successful response, not an error. SDKs
  and MCP tools surface `outcome: "approval_required"` so agents
  can short-circuit instead of looping.

## Boundaries

The MCP non-goal list is the most explicit security boundary.
Three classes of API actions are **never** exposed as MCP tools:

1. **Trust authorship** — counterparties, address labels, trust
   assertions, evidence. Trust is the human boundary.
2. **Policy authorship** — create / revise / archive policy rules.
   Agents read policies; they do not edit them.
3. **Hard-state escalations** — delegation revoke, API-key
   creation / rotation, browser-wallet flows.

Operators access these via the operator console; the MCP server
deliberately does not.

## Implementation rules

* The OpenAPI artifact is the source of wire types; SDK type
  modules are generated from it.
* Every code in `error-codes.md` either appears in
  `BankWeb.OpenApi.Schemas.ErrorEnvelope` enum or is added there in
  the same PR that emits the new code.
* Adding a new method to either SDK requires:
  1. The endpoint exists in the OpenAPI artifact.
  2. The aligned Python and TypeScript signatures land together
     in [`sdk-surface.md`](sdk-surface.md).
  3. If the method should be MCP-callable, a tool definition
     lands in [`mcp-tools.md`](mcp-tools.md).
* `mix openapi.check` runs in CI; do not bypass drift. If the SDK
  or MCP doc references a schema that doesn't exist in the
  artifact, the doc is wrong.

## See also

* [`docs/openapi.md`](../openapi.md) — how the OpenAPI artifact is
  generated and consumed.
* [`docs/bank-v0.1-runtime-flow-and-api.md`](../bank-v0.1-runtime-flow-and-api.md)
  — product-level contract that the OpenAPI document implements
  against.
* [`docs/security.md`](../security.md) — auth posture, operator
  boundary, secret hygiene.
