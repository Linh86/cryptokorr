# `/v1` error taxonomy

> Status: SDK / MCP foundation (#478).
> Source of truth: this document. Implementations (#479 Python SDK,
> #480 TypeScript SDK, #481 stdio MCP server) consume the table
> below and the OpenAPI artifact at
> [`priv/openapi/openapi.json`](../../priv/openapi/openapi.json).

Every `/v1/*` endpoint returns the same structured error envelope on
non-`2xx` responses. SDKs map these to typed exceptions; the MCP
server maps them to `error` tool results that the model can read
without parsing free-form prose.

## Error envelope

```jsonc
{
  "error": {
    "code": "<stable-string>",       // programmatic, fixed allowlist
    "message": "<human-readable>",   // operator-readable, no secrets
    "hint": "<remediation-string>",  // optional; how to recover
    "retryable": true | false,       // see "Retry semantics" below
    "details": {                     // optional; only on 422 with
      "<field>": ["<error1>", ...]   // changeset-style validation
    }
  }
}
```

Three rules SDK / MCP implementations rely on:

1. **`code` is stable.** It never changes meaning across releases. New
   codes may be added; existing codes are never repurposed.
2. **`code` is the only programmatic input.** `message` and `hint` are
   operator copy and may be reworded. SDK exception classes and MCP
   tool errors switch on `code`.
3. **`retryable` reflects safety, not preference.** `retryable: true`
   means a fresh request with the same `Idempotency-Key` is safe. It
   does not mean the caller *should* retry; it means they *may*.

## Retry semantics (table)

| Class                   | HTTP status | Retryable? | Backoff hint                            |
| ----------------------- | ----------- | ---------- | --------------------------------------- |
| Authentication / authz  | 401, 403    | **No**     | Fix credentials or scope; do not retry. |
| Validation              | 422         | **No**     | Fix the body; same key replays after.   |
| Idempotency conflict    | 409         | **No**     | Use a fresh `Idempotency-Key`.          |
| Wrong state             | 409         | **No**     | The resource changed under you; refetch.|
| Not found               | 404         | **No**     | The id is wrong or in another workspace.|
| Rate limit              | 429         | **Yes**    | Honour `Retry-After` header.            |
| Workspace paused        | 503         | **Yes**    | Long backoff; operator must resume.     |
| Upstream / provider 5xx | 502, 504    | **Yes**    | Exponential backoff; cap at ~30s.       |
| Service unavailable     | 503         | **Yes**    | Same as upstream; operator may pause.   |

The SDKs implement automatic retry only for explicit `retryable: true`
codes AND only when the caller passes `Idempotency-Key`. The MCP
server never retries automatically — it surfaces the error to the
agent so the agent can decide.

## Stable codes (allowlist)

Each row carries:

* **`code`** — what the SDK / MCP switches on.
* **HTTP** — the response status code.
* **Retryable** — what `retryable` is set to.
* **Returned by** — representative endpoints. Not exhaustive.
* **Action** — what an SDK or agent should do on receipt.

### Authentication & authorization

| `code`                          | HTTP | Retryable | Returned by                    | Action                                                                |
| ------------------------------- | ---- | --------- | ------------------------------ | --------------------------------------------------------------------- |
| `missing_authorization`         | 401  | No        | every authenticated `/v1/*`    | Send `Authorization: Bearer cb_<...>` header.                         |
| `invalid_authorization_scheme`  | 401  | No        | every authenticated `/v1/*`    | Send `Bearer ...` (not `Basic`, etc.).                                |
| `invalid_credentials`           | 401  | No        | every authenticated `/v1/*`    | Key is unknown / hash-mismatched / revoked / expired / workspace paused. Operator must rotate or unpause. |
| `unauthenticated`               | 401  | No        | role-gated routes              | Internal config bug (caller's `current_scope` missing). Report to operator. |
| `insufficient_role`             | 403  | No        | role-gated routes              | Caller's API key role is below the required threshold (`viewer < operator < admin`). Fix the key or use a higher-role key. |
| `forbidden`                     | 403  | No        | resource-scoped routes         | Caller's scope does not cover the subject. Cross-workspace ids surface as `404 not_found` instead — `403` is for genuine policy boundaries. |

### Resource lookup

| `code`            | HTTP | Retryable | Returned by                | Action                                    |
| ----------------- | ---- | --------- | -------------------------- | ----------------------------------------- |
| `not_found`       | 404  | No        | `GET /v1/{thing}/:id`      | Subject does not exist OR belongs to another workspace. SDKs do NOT distinguish — leakage of cross-workspace existence is intentionally suppressed. |

### Validation (request body)

| `code`              | HTTP | Retryable | Returned by                      | Action                                                                |
| ------------------- | ---- | --------- | -------------------------------- | --------------------------------------------------------------------- |
| `invalid_body`      | 422  | No        | every write endpoint             | A required field is missing or fails the changeset. `details` carries the field-by-field errors. |
| `validation_error`  | 422  | No        | every write endpoint             | Generic alias used by older endpoints; new endpoints prefer `invalid_body`. SDKs treat the two as equivalent. |
| `invalid_amount`    | 422  | No        | `POST /v1/intents`, `POST /v1/decisions/:id/execute` | `amount` must be a positive decimal string (e.g. `"10.5"`). |
| `invalid_target`    | 422  | No        | `POST /v1/intents`               | Intent target must be exactly one of `counterparty_id` (optionally with `address_label_id`) or `raw_address`; not both, not neither. |
| `invalid_reason`    | 422  | No        | `POST /v1/intents/:id/simulate`  | `reason` must be one of `pre_submit_dry_run`, `refresh`, `operator_inspection`. |
| `invalid_request`   | 422  | No        | `POST /v1/approvals/:id/approve` | Required fields (e.g. `actor_id`) missing. |

### Workspace / chain capability

| `code`                      | HTTP | Retryable | Returned by                | Action                                    |
| --------------------------- | ---- | --------- | -------------------------- | ----------------------------------------- |
| `unsupported_chain`         | 422  | No        | `POST /v1/intents`         | `chain` not in `["base", "base-sepolia"]`. |
| `mainnet_disabled`          | 422  | No        | `POST /v1/intents`, `POST /v1/decisions/:id/execute` | Workspace has not opted into Base mainnet. Switch to `base-sepolia` (MVP default) or have an admin enable mainnet. |
| `unsupported_asset`         | 422  | No        | `POST /v1/intents`         | `asset` not in the workspace's allowlist (currently `USDC`). |
| `morpho_chain_not_supported`| 422  | No        | `POST /v1/intents` (`kind: allocate_idle_capital`) | Morpho deposit only supports `base-sepolia` in MVP. |

### Smart-account selector (#184)

| `code`                              | HTTP | Retryable | Returned by         | Action                                            |
| ----------------------------------- | ---- | --------- | ------------------- | ------------------------------------------------- |
| `smart_account_not_found`           | 404  | No        | `POST /v1/intents`  | `smart_account_id` does not belong to the caller's workspace. Foreign-workspace ids surface as 404 with this code (no existence leak). |
| `smart_account_chain_mismatch`      | 422  | No        | `POST /v1/intents`  | The smart account's `chain` differs from the intent's `chain`.                                |
| `smart_account_required`            | 422  | No        | `POST /v1/intents`  | Workspace has 2+ non-revoked smart accounts; the caller must pick one explicitly via `smart_account_id`. |

### Swap dispatch safety (#191, #189 P2)

These fire at intent-submit (route shape) or at dispatch (workspace
gates). Every code maps to the structured `swap_*` failure
allowlist; the SDK exception class is `SwapSafetyError`.

| `code`                            | HTTP | Retryable | Action                                            |
| --------------------------------- | ---- | --------- | ------------------------------------------------- |
| `swap_chain_not_supported`        | 422  | No        | Use `chain: base-sepolia` in MVP.                |
| `swap_chain_id_mismatch`          | 422  | No        | Route's `chain_id` does not match its `chain` string. |
| `swap_asset_not_supported`        | 422  | No        | Source/destination asset must be `USDC` (MVP).   |
| `swap_route_field_missing`        | 422  | No        | A required #190 route field is absent or malformed. |
| `swap_amount_invalid`             | 422  | No        | Amount fields are non-positive or `min > expected`. |
| `swap_slippage_exceeded`          | 422  | No        | `slippage_bps > max_slippage_bps` (default 100). |
| `swap_deadline_expired`           | 422  | No        | Quote expired before validation ran. Refresh the quote. |
| `swap_type_not_supported`         | 422  | No        | Only exact-input is supported. Reject explicit `:exact_output` markers. |
| `swap_chain_mismatch_with_intent` | 422  | No        | Route's chain disagrees with the parent intent's chain. |
| `swap_amount_mismatch_with_intent`| 422  | No        | Route's `input_amount` disagrees with the intent's `amount`. |
| `swap_native_value_disallowed`    | 422  | No        | v0.1 swaps are ERC20→ERC20; native value must be zero. |

### Morpho dispatch safety (#206 / #208)

| `code`                          | HTTP | Retryable | Action                                            |
| ------------------------------- | ---- | --------- | ------------------------------------------------- |
| `morpho_vault_not_allowlisted`  | 422  | No        | Vault is not in the workspace's active Morpho allowlist. Operator must add a `:allowed_vault` rule. |
| `morpho_snapshot_missing`       | 422  | No        | Vault has no current snapshot. Refresh the snapshot before retry. |
| `morpho_snapshot_expired`       | 422  | No        | At least one freshness bucket is `:expired`. Refresh the snapshot. |
| `morpho_snapshot_drifted`       | 422  | No        | Current snapshot's `payload_hash` differs from the hash captured on the plan. Operator must reapprove. |
| `morpho_steps_missing`          | 422  | No        | Plan's `:steps` JSON does not have the `morpho_deposit` shape. Programming bug; report to operator. |
| `morpho_asset_not_supported`    | 422  | No        | MVP Morpho is USDC-only.                          |
| `morpho_withdraw_invalid_amount`| 422  | No        | `requested_assets` is non-positive.               |
| `morpho_withdraw_snapshot_invalid`| 422 | No        | Snapshot is missing or has zero shares.           |
| `operator_role_required`        | 403  | No        | The operation (e.g. Morpho withdraw) requires `actor_role: :operator`. SDKs do not expose this surface. |

### State machine

| `code`             | HTTP | Retryable | Returned by                                | Action                                    |
| ------------------ | ---- | --------- | ------------------------------------------ | ----------------------------------------- |
| `wrong_state`      | 409  | No        | `POST /v1/intents/:id/cancel`, `POST /v1/decisions/:id/execute`, etc. | The resource is not in a state that allows this transition (e.g. cancelling an `:executing` intent). Refetch state and reconsider. |
| `not_safe_to_abort`| 409  | No        | `POST /v1/security/abort_execution`        | The plan is not in `:prepared`. Use the normal cancel path. |

### Idempotency

| `code`                  | HTTP | Retryable | Returned by                  | Action                                              |
| ----------------------- | ---- | --------- | ---------------------------- | --------------------------------------------------- |
| `idempotency_conflict`  | 409  | No        | every write endpoint         | The same `Idempotency-Key` was reused with a different body. The response `hint` includes the prior intent id. Use a fresh key for a new intent, OR resend the original body to replay the existing intent. |

A duplicate `Idempotency-Key` with a *matching* body is **not an
error** — it returns the original resource with `idempotent_replay:
true` (or `idempotent: true` for cancel). SDKs surface this as a
non-exception result with the flag attached so callers can detect
deduped writes if they care.

### Rate limit

| `code`         | HTTP | Retryable | Returned by                | Action                                                                  |
| -------------- | ---- | --------- | -------------------------- | ----------------------------------------------------------------------- |
| `rate_limited` | 429  | **Yes**   | every `/v1/*` (per bucket) | Honour the `Retry-After` header. Three buckets exist: per-key (60/60s), per-workspace (600/60s), and a stricter chain-action cap (5/60s on `/v1/security/*`). The auth-failure bucket (10/300s on bad `Authorization`) returns the same code. |

### Liveness / availability

| `code`                  | HTTP | Retryable | Returned by                | Action                                            |
| ----------------------- | ---- | --------- | -------------------------- | ------------------------------------------------- |
| `workspace_paused`      | 503  | **Yes**   | every write endpoint       | The workspace is paused. Long backoff; an operator must call `POST /v1/security/resume` before writes flow. Reads are unaffected. |
| `chain_paused`          | 503  | **Yes**   | dispatch endpoints         | The workspace's chain is paused (#228). Reads still work; writes against that chain wait for resume. |
| `runtime_paused`        | 503  | **Yes**   | every write endpoint       | The global runtime is paused (operator escalation). Long backoff. |
| `service_unavailable`   | 503  | **Yes**   | any                        | Generic upstream unavailability.                  |
| `upstream_unavailable`  | 502  | **Yes**   | `POST /v1/intents/:id/simulate`, dispatch endpoints | Provider (quote / RPC / adapter) is failing. Honour `retryable`; the SDK's default backoff is exponential capped at ~30s. |
| `upstream_timeout`      | 504  | **Yes**   | `POST /v1/intents/:id/simulate`, dispatch endpoints | Provider request timed out. Same retry posture as `upstream_unavailable`. |
| `not_implemented`       | 501  | No        | scaffolded endpoints       | Endpoint exists in the router but the engine has not landed yet. Caller should not retry; report to operator if blocking. |

### Approval-required (decisions)

The decision pipeline returns approval-required as a successful
`200 / 202` response — **not** an error envelope. The SDK exposes it
as a typed result with `requires_approval: true` so an agent can
short-circuit instead of looping. See the SDK surface for the exact
shape.

For completeness: the decision envelope's `outcome` field is the
primary discriminator (`auto_exec | approval_required | hold |
block`). An agent that needs to wait for an operator to approve
should poll `GET /v1/decisions/:id` (or `/v1/intents/:id`, which
includes `current_decision_id`) and check `outcome` and
`approval_expires_at`. The SDK's `wait_for_decision/2` helper does
this with a default timeout. The MCP server's `wait_for_decision`
tool is the same with a fixed-cap timeout (no infinite loops).

## SDK / MCP exception classes

The Python and TypeScript SDKs expose one base exception per HTTP
class plus a typed subclass keyed off `error.code`:

```
APIError                        # base, all HTTP errors
├── AuthenticationError         # 401 + auth codes
├── AuthorizationError          # 403 + role codes
├── ValidationError             # 422 + validation codes
│   ├── SwapSafetyError         # swap_*
│   └── MorphoSafetyError       # morpho_*
├── NotFoundError               # 404
├── ConflictError               # 409
│   ├── IdempotencyConflictError
│   └── WrongStateError
├── RateLimitError              # 429
└── ServiceUnavailableError     # 502 / 503 / 504
    ├── WorkspacePausedError
    ├── ChainPausedError
    └── UpstreamError
```

The MCP server returns errors as standard MCP tool errors with the
same `code` field surfaced on `error.data.code`. See
[`mcp-tools.md`](mcp-tools.md) for the exact wire shape.

## Adding a new code

1. Add the code to the controller / context that emits it.
2. Update this document — table row + retryable verdict.
3. Update the SDK exception map (#479 / #480) — one new constant.
4. Update the MCP error decoder (#481) if the code maps to a typed
   tool error.
5. Run `mix openapi.gen` if the code is referenced in an
   `OpenApiSpex.Operation`'s `responses` map.
