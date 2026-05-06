# `cryptobank` — Python SDK

> Status: MVP foundation (#479) on top of the SDK contract pinned in
> [`docs/api/sdk-surface.md`](../../docs/api/sdk-surface.md), error
> taxonomy in [`docs/api/error-codes.md`](../../docs/api/error-codes.md),
> and the OpenAPI artifact at
> [`priv/openapi/openapi.json`](../../priv/openapi/openapi.json).

A typed Python client for CryptoBank `/v1`. Submit and inspect
intents, follow decisions to approval / dispatch, and read the
audit / replay bundle without hand-writing HTTP glue.

## Posture

* **Workspace-scoped.** The API key binds the SDK to one workspace.
* **MVP testnet.** Examples target Base Sepolia
  (`chain="base-sepolia"`). Mainnet is gated behind the workspace
  flag and surfaces as `mainnet_disabled` until enabled.
* **Approval-required is a successful response.** A decision with
  `outcome="approval_required"` does not raise — the SDK returns a
  result with `requires_approval=True` so agents can short-circuit
  instead of looping.
* **Idempotent writes.** Every write method auto-generates an
  `Idempotency-Key` if the caller does not supply one; passing the
  same key twice with the same body is a safe replay.
* **Typed errors.** Non-2xx responses raise a typed exception keyed
  off the wire `error.code`. See
  [`docs/api/error-codes.md`](../../docs/api/error-codes.md).
* **Zero runtime dependencies.** The SDK uses stdlib `urllib.request`
  for HTTP. `pip install -e sdks/python` is fast and free of
  resolution conflicts.

## Install

```bash
pip install -e sdks/python
```

(Wheels and a published distribution land in a follow-up.)

## Configuration

The SDK reads configuration in this priority order:

1. Constructor argument.
2. Environment variable.

| Setting    | Env var                | Default                       |
| ---------- | ---------------------- | ----------------------------- |
| `api_key`  | `CRYPTOBANK_API_KEY`   | (required, no default)        |
| `base_url` | `CRYPTOBANK_BASE_URL`  | `http://localhost:4000`       |
| `timeout`  | `CRYPTOBANK_TIMEOUT_MS`| `15_000` (ms)                 |

Set the API key via env var before running the quickstart:

```bash
export CRYPTOBANK_API_KEY="cb_your_key_here"
export CRYPTOBANK_BASE_URL="https://api.example.com"  # optional
```

The API key is **never** logged, **never** included in error
messages, and **never** echoed by `repr(client)`.

## Quickstart

```python
from cryptobank import Cryptobank, IdempotencyConflictError, RateLimitError

client = Cryptobank.from_env()

# 1. Submit a transfer intent.
result = client.submit_transfer(
    agent_id="agent-alice",
    asset="USDC",
    chain="base-sepolia",         # MVP: Base Sepolia only
    amount="10.50",
    target={"counterparty_id": "b6a10f53-8c6e-4d79-9bb9-3e1e5b1f1a11"},
    notes="quickstart demo",
)

print("intent id:", result["intent_id"], "state:", result["state"])

# 2. Wait for the decision (approval-required is a successful result).
wait = client.wait_for_decision(result["intent_id"], timeout_seconds=30)

if wait["timed_out"]:
    print("Still evaluating; poll again later.")
elif wait["requires_approval"]:
    print("Operator approval required — the agent should not loop.")
elif wait["decision"]["outcome"] == "auto_exec":
    print("Decision auto-approved; dispatch in flight.")
else:
    print("Refused:", wait["decision"]["outcome"], wait["decision"]["reasons"])
```

### Submit a swap

```python
result = client.submit_swap(
    agent_id="agent-alice",
    chain="base-sepolia",
    source_asset="USDC",
    destination_asset="USDC",  # MVP: USDC → USDC, USDT, ETH
    amount="10",
)
```

The SDK does not accept raw calldata, slippage, deadline, or target
contract — those flow from the live quote provider into the route
artifacts server-side. Agents express *intent* (input + output asset
+ amount); Phoenix decides *execution*.

### Allocate idle capital to a Morpho vault

```python
result = client.submit_allocate_idle_capital(
    agent_id="agent-alice",
    amount="100",
    vault_address="0x...",  # workspace allowlist verified server-side
)
```

Withdraw / redeem is **not** in the SDK. Morpho withdraw is
operator-only.

### Inspect history

```python
intent = client.get_intent(result["intent_id"])
trail = client.get_audit_trail(result["intent_id"])
runtime = client.get_runtime_status()  # /v1/health/deep, no auth required
```

## Typed errors

```python
from cryptobank import (
    Cryptobank,
    IdempotencyConflictError,
    RateLimitError,
    SwapSafetyError,
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

The full exception hierarchy is documented in
[`docs/api/error-codes.md`](../../docs/api/error-codes.md). All
errors are subclasses of `cryptobank.APIError`; their `code`
attribute is the stable wire identifier.

## Operator namespace

Operator-only writes live under `client.operator.*`. Agents calling
them with an `agent`-role API key get `403 insufficient_role`.

```python
client.operator.list_pending_approvals()
client.operator.approve_decision(decision_id, actor_id="me", reason="ok")
client.operator.reject_decision(decision_id, actor_id="me", reason="too risky")
client.operator.pause_runtime()    # /v1/security/pause (admin role)
client.operator.resume_runtime()
```

The chain-action cap (5 / 60s on `/v1/security/*`) is **not**
auto-retried — the operator-cap throttling is meant to surface, not
to silently wait.

## Retry posture

The SDK retries automatically only when:

1. The wire envelope says `retryable: true` (rate-limit, upstream
   5xx, paused), AND
2. The path is not `/v1/security/*` (those surface immediately), AND
3. The operation is idempotent (every write either has a
   caller-supplied `Idempotency-Key` or one the SDK generates).

Retry honours the `Retry-After` header, uses exponential backoff
capped at 30s, and bounds total wall-clock at `timeout × 4`. Errors
without `retryable: true` (validation, idempotency conflict, wrong
state, not-found, auth) raise on the first response.

## Approval-required is a normal result

The SDK never raises an exception for `outcome="approval_required"`.
`wait_for_decision` returns a `DecisionWaitResult` with
`requires_approval=True` and the latest `Decision` so an agent can
log it and stop. This matches the contract documented in
[`docs/api/sdk-surface.md`](../../docs/api/sdk-surface.md).

## Tests

```bash
cd sdks/python
python -m venv .venv
source .venv/bin/activate
pip install -e .[dev]
pytest
```

The suite is mocked-HTTP only — no real network calls. Tests patch
the single `Transport._urlopen` seam to inject canned responses.

## Non-goals (deferred)

* `AsyncCryptobank` — sync-only in MVP; async client follows in a
  separate PR.
* Streaming / websocket subscription — polling only in MVP.
* Workspace-management writes, API-key management, browser-wallet
  flows — operator console only.
* Mainnet examples — every example uses `base-sepolia`.
* `client.operator.list_smart_accounts` — discover accounts via
  the operator UI in MVP.

See [`docs/api/sdk-surface.md`](../../docs/api/sdk-surface.md) for
the full contract.
