# cryptokorr-mcp

Stdio MCP server that exposes a curated subset of CryptoKorr's `/v1`
agent surface to MCP-aware hosts (Claude Desktop, Cursor, Codex, etc.).

> Status: MVP. Targets **Base Sepolia** and **USDC** by default.
> Mainnet writes (`chain: "base"`) require a workspace flag and surface
> `mainnet_disabled` until enabled.

## What it does

The server speaks the standard MCP wire protocol (JSON-RPC 2.0 over
stdio). It advertises a subset of CryptoKorr's REST endpoints as tools
with stable names, JSON Schemas, and structured error codes that an
agent can branch on without reading docs.

The full tool contract is pinned in
[`docs/api/mcp-tools.md`](../../docs/api/mcp-tools.md). The error
taxonomy is in [`docs/api/error-codes.md`](../../docs/api/error-codes.md).

## Install

The package is published as `cryptokorr-mcp`. Until that lands on
PyPI you can install from the repo:

```bash
pip install ./sdks/mcp
# or, from outside the repo:
pip install "cryptokorr-mcp @ git+https://github.com/Linh86/cryptokorr.git#subdirectory=sdks/mcp"
```

The console script `cryptokorr-mcp` is the stdio entrypoint.

```bash
CRYPTOKORR_API_KEY="cb_..." cryptokorr-mcp
```

The server reads JSON-RPC requests from stdin and writes responses to
stdout. Logs go to stderr (key prefix only — never the full key, never
tool arguments, only result sizes).

## Configuration

| Env var                  | Required | Default                   | Purpose                                                     |
| ------------------------ | -------- | ------------------------- | ----------------------------------------------------------- |
| `CRYPTOKORR_API_KEY`     | yes      | (none)                    | Workspace API key. Must start with `cb_`.                   |
| `CRYPTOKORR_BASE_URL`    | no       | `http://localhost:4000`   | Tenant URL. No trailing slash.                              |
| `CRYPTOKORR_READONLY`    | no       | `false`                   | When `true`, write + operator tools are absent from `tools/list`. The model cannot invoke a tool that was not advertised. |
| `CRYPTOKORR_AGENT_ID`    | no       | (none)                    | Default `agent_id` injected into write tools when the caller doesn't supply one. |
| `CRYPTOKORR_TIMEOUT_MS`  | no       | `15000`                   | Per-request HTTP timeout (1000–120000).                     |
| `CRYPTOKORR_ROLE`        | no       | (probed)                  | Override role probing — `viewer` / `operator` / `admin`. The server otherwise probes `GET /v1/approvals`. |
| `CRYPTOKORR_LOG_LEVEL`   | no       | `INFO`                    | Standard Python log level.                                  |

The API key is **never** logged, **never** included in tool errors,
and **never** echoed in tool results. The server logs the first 8
characters of the key (e.g. `cb_a1b2c3d4`) for telemetry correlation.

## Claude Desktop config

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`
(macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "cryptokorr": {
      "command": "cryptokorr-mcp",
      "env": {
        "CRYPTOKORR_API_KEY": "cb_your_key_here",
        "CRYPTOKORR_BASE_URL": "https://api.your-tenant.example.com",
        "CRYPTOKORR_READONLY": "false"
      }
    }
  }
}
```

Restart Claude Desktop. The CryptoKorr tools appear in the tool
picker.

## Cursor config

Add to `~/.cursor/mcp.json` (project-scoped configs go in
`.cursor/mcp.json` next to your repo root):

```json
{
  "mcpServers": {
    "cryptokorr": {
      "command": "cryptokorr-mcp",
      "env": {
        "CRYPTOKORR_API_KEY": "cb_your_key_here",
        "CRYPTOKORR_BASE_URL": "https://api.your-tenant.example.com"
      }
    }
  }
}
```

## Readonly example

For audit / read-only sessions (e.g. a chatbot that should never
submit intents), set `CRYPTOKORR_READONLY=true`:

```json
{
  "mcpServers": {
    "cryptokorr-readonly": {
      "command": "cryptokorr-mcp",
      "env": {
        "CRYPTOKORR_API_KEY": "cb_your_key_here",
        "CRYPTOKORR_READONLY": "true"
      }
    }
  }
}
```

In readonly mode the model only sees:

- `get_intent`
- `get_decision`
- `wait_for_decision`
- `get_audit_trail`
- `list_counterparties`
- `get_runtime_status`
- `get_policy`

`submit_*`, `approve_decision`, `reject_decision`, `pause_runtime`,
`resume_runtime`, and `list_pending_approvals` are **omitted from
the advertised tool list**, so the model cannot invoke them at all.

## First intent example

A typical agent flow:

```jsonc
// 1. Submit
{
  "jsonrpc": "2.0", "id": 1, "method": "tools/call",
  "params": {
    "name": "submit_transfer",
    "arguments": {
      "agent_id": "agent-alice",
      "asset": "USDC",
      "chain": "base-sepolia",
      "amount": "10.50",
      "target": { "counterparty_id": "b6a10f53-8c6e-4d79-9bb9-3e1e5b1f1a11" }
    }
  }
}
// → success: content[0].text is JSON with intent_id + state.

// 2. Wait for the decision (capped at 60 seconds)
{
  "jsonrpc": "2.0", "id": 2, "method": "tools/call",
  "params": {
    "name": "wait_for_decision",
    "arguments": { "intent_id": "...", "timeout_seconds": 30 }
  }
}
```

### Approval-required is not an error

A decision with `outcome: "approval_required"` is a **successful**
tool result, not an error. The agent sees:

```json
{
  "content": [{
    "type": "text",
    "text": "{\"id\":\"...\",\"outcome\":\"approval_required\",\"approval_expires_at\":\"...\"}"
  }],
  "isError": false
}
```

The model should treat this as "waiting on a human" — not as a failure
to retry, and not as a signal to call `approve_decision` itself
(those operator tools are hidden from non-operator keys).

## Error shape

Tool failures return the standard MCP error result shape with the
wire `error.code` surfaced verbatim:

```json
{
  "content": [{ "type": "text", "text": "rate_limited: Too many requests." }],
  "isError": true,
  "error": {
    "code": "rate_limited",
    "message": "Too many requests.",
    "hint": "Honour the Retry-After header.",
    "retryable": true,
    "http_status": 429
  }
}
```

The full code allowlist is in
[`docs/api/error-codes.md`](../../docs/api/error-codes.md). The MCP
server **never automatically retries** — it surfaces the error and
lets the agent decide.

## Non-goals — what this server will never expose

The following surfaces are **never** advertised, even with an admin
key and `readonly=false`:

- Delegation revoke (`POST /v1/security/revoke_delegation`)
- Policy edits (create / revise / archive)
- Trust mutation (counterparty create/patch, address attach, evidence,
  trust assertions)
- API key management (create / rotate / delete)
- Workspace pause/resume scoped to chain or agent keys, abort
  execution
- Browser-wallet flows (`/v1/connect/smart_account`, browser-session
  endpoints)

These are operator-console surfaces. If a future feature warrants MCP
exposure, it goes through a written design note + a follow-up issue.

## Local development

```bash
# Run unit tests (stdlib unittest, no external deps)
cd sdks/mcp
python3 -m unittest discover -s tests -v

# Run the server locally against a Phoenix dev instance
CRYPTOKORR_API_KEY="cb_test_..." \
CRYPTOKORR_BASE_URL="http://localhost:4000" \
python3 -m cryptokorr_mcp
```

The package has zero runtime dependencies (stdlib `urllib` only) so a
fresh Python 3.10+ install can run it without `pip install` of any
transitive packages.
