# Changelog — `cryptobank-mcp` (stdio MCP server)

All notable changes to the stdio MCP server ship in this file.
Versioning follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

The server is pinned against the tool surface in
[`docs/api/mcp-tools.md`](../../docs/api/mcp-tools.md). Renaming or
removing a tool, or shrinking a tool's input schema, is a breaking
change.

## [Unreleased]

## [0.1.0] — initial MVP foundation

First publishable revision of the stdio MCP server. Implements the
full tool surface pinned in
[`docs/api/mcp-tools.md`](../../docs/api/mcp-tools.md), backed by an
internal `urllib`-based HTTP client to Phoenix `/v1/*`.

### Added

- JSON-RPC 2.0 stdio loop over `stdin`/`stdout`. Handles `initialize`,
  `notifications/initialized`, `ping`, `tools/list`, `tools/call`,
  `shutdown`.
- Read tier (always advertised): `get_intent`, `get_decision`,
  `wait_for_decision`, `get_audit_trail`, `list_counterparties`,
  `get_runtime_status`, `get_policy`.
- Read-operator tier (hidden when role < operator OR readonly):
  `list_pending_approvals`.
- Write tier (hidden when `CRYPTOBANK_READONLY=true`):
  `submit_transfer`, `submit_swap`, `submit_allocate_idle_capital`.
  Wire `kind` is `allocate_idle_capital` for Morpho ERC-4626 deposit.
- Operator tier (hidden when readonly OR role < operator):
  `approve_decision`, `reject_decision`, `pause_runtime`,
  `resume_runtime`.
- Forbidden surfaces enforced by an explicit allowlist in
  `cryptobank_mcp.tools` and tested per tier × role × readonly:
  delegation revoke, policy edits, trust mutation, API-key management,
  chain/agent pause-resume, abort_execution, browser-wallet flows.
- `wait_for_decision` caps timeout at 60 seconds, returns synthetic
  `outcome: still_evaluating` if the decision doesn't resolve in time.
- 256 KB result-size cap with synthetic `truncated: true` payload that
  preserves surface keys (`id`, `intent_id`, `decision_id`, `state`,
  `outcome`, `kind`).
- Structured tool errors with `error.code`, `retryable`, `hint`, and
  `http_status` from Phoenix's `ErrorEnvelope`.
- Configuration: `CRYPTOBANK_API_KEY` (required), `CRYPTOBANK_BASE_URL`,
  `CRYPTOBANK_READONLY`, `CRYPTOBANK_AGENT_ID`, `CRYPTOBANK_TIMEOUT_MS`,
  `CRYPTOBANK_ROLE`, `CRYPTOBANK_LOG_LEVEL`.
- Role probing at startup hits `GET /v1/approvals?limit=1` to detect
  viewer vs operator+; `CRYPTOBANK_ROLE` overrides the probe.
- Console script `cryptobank-mcp` (Hatchling-built wheel + sdist).

### Notes

- MVP scope: Base Sepolia (`chain: "base-sepolia"`) and USDC.
- Zero runtime dependencies — stdlib `urllib` only. Python 3.10+.
- Logs key prefix (`cb_<first8>`) only — never the full key, never
  tool arguments. Result sizes are logged.

### Known limitations

- Mainnet writes (`chain: "base"`) surface as `mainnet_disabled` until
  the workspace flag is set — the server does not pre-filter the chain
  enum.
- Live Claude Desktop / Cursor smoke is documented but not wired to
  CI; the subprocess smoke tests prove the wire protocol end-to-end.

[0.1.0]: https://github.com/Linh86/cryptobank/releases/tag/cryptobank-mcp-0.1.0
[Unreleased]: https://github.com/Linh86/cryptobank/compare/cryptobank-mcp-0.1.0...HEAD
