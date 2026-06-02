# SDKs and stdio MCP server

Three packages, one wire contract — the
[`/v1/*` API](../priv/openapi/openapi.json) and the docs in
[`docs/api/`](../docs/api/README.md).

| Package                                 | Path                            | Install (after publish)                    | Audience                                  |
| --------------------------------------- | ------------------------------- | ------------------------------------------ | ----------------------------------------- |
| [`cryptokorr`](python/README.md)        | [`sdks/python/`](python/)       | `pip install cryptokorr`                   | Python services and agent runtimes        |
| [`@cryptokorr/sdk`](typescript/README.md) | [`sdks/typescript/`](typescript/) | `npm install @cryptokorr/sdk`              | Node 18+ services and edge functions      |
| [`cryptokorr-mcp`](mcp/README.md)       | [`sdks/mcp/`](mcp/)             | `pip install cryptokorr-mcp`               | stdio MCP hosts (Claude Desktop, Cursor)  |

All three packages target the same MVP posture:

- **Base Sepolia (`chain: "base-sepolia"`)** for examples; mainnet is
  workspace-flag-gated and surfaces as `mainnet_disabled`.
- **USDC** is the only supported asset.
- **`approval_required` is a successful response**, not an error —
  agents short-circuit and hand off to a human instead of looping.
- **API key** is read from `CRYPTOKORR_API_KEY`; never hardcode.
- **Idempotency keys** are auto-generated for every write.
- **Structured errors** carry the wire `error.code` from
  [`docs/api/error-codes.md`](../docs/api/error-codes.md).

## Cross-cutting docs

- [`PUBLISHING.md`](PUBLISHING.md) — build/dry-run commands per
  package, publish commands (do not run without explicit
  authorization), versioning policy, MCP community-directory
  submission checklist, license discrepancy resolution.
- Each package has its own `CHANGELOG.md`.
- The contract docs in [`docs/api/`](../docs/api/README.md) are
  authoritative — `sdk-surface.md`, `error-codes.md`, `mcp-tools.md`.

## Test status

| Package           | Local check                                    |
| ----------------- | ---------------------------------------------- |
| `cryptokorr`      | `cd sdks/python && pytest`                     |
| `@cryptokorr/sdk` | `cd sdks/typescript && npm test`               |
| `cryptokorr-mcp`  | `cd sdks/mcp && python -m unittest discover -s tests -t .` |

CI gates all three on every PR to `main`.
