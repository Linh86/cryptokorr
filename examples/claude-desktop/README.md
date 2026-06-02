# `examples/claude-desktop/` — MCP walkthrough (`cryptokorr-mcp`)

A copy-pastable walkthrough that wires the **CryptoKorr stdio MCP
server** (`cryptokorr-mcp`) into Claude Desktop and submits a
first intent on Base Sepolia. Includes a Claude-Desktop-style
config snippet (`config.example.json`), a tested first prompt, and
a side-by-side mapping from MCP tool names to the SDK methods.

The MCP server is the **read-mostly** surface in the
`@cryptokorr` toolkit: it exposes the same wire contract as the
SDKs, but every write tool requires `CRYPTOKORR_READONLY=false`
(default `false`, but worth saying out loud) and the operator
tools require an operator-role API key.

## Scope

- **Base Sepolia only** (`chain: "base-sepolia"`). Mainnet
  (`base`) is post-MVP and surfaces as a typed
  `mainnet_disabled` error in the tool result.
- **Server-side only.** The MCP server runs on your machine
  (Claude Desktop spawns it as a stdio child process). The
  workspace API key (`cb_<...>`) lives in Claude Desktop's
  config; never put it in a shared chat or a remote MCP host.
- **Single allowlisted Morpho USDC vault.** The first-prompt
  walkthrough takes the vault from the workspace policy; the
  operator must add a `:allowed_vault` rule before a deposit is
  accepted.
- **`approval_required` is a successful tool response**, not a
  tool error. Claude reads `decision.outcome` and tells the user
  what's happening; it does not loop on the call.
- **No paymaster / sponsored gas, no multi-account selector, no
  arbitrary calldata.**

## Prerequisites

- Claude Desktop **with MCP support**. Anthropic publishes
  install instructions for macOS, Windows, and Linux at
  https://claude.ai/download.
- The CryptoKorr MCP server (`cryptokorr-mcp`) installed on your
  machine. From the repo root:

  ```sh
  cd sdks/mcp
  pip install -e .                 # local development install
  cryptokorr-mcp --help             # confirm the binary resolves
  ```

  Or if you publish later (out of scope here under #483):

  ```sh
  pipx install cryptokorr-mcp
  ```

- A workspace API key (`cb_<...>`).
- A running CryptoKorr backend (default `http://localhost:4000`).

## Configure Claude Desktop

Claude Desktop reads MCP servers from `claude_desktop_config.json`
in its application support directory:

| OS      | Path                                                                        |
| ------- | --------------------------------------------------------------------------- |
| macOS   | `~/Library/Application Support/Claude/claude_desktop_config.json`           |
| Windows | `%APPDATA%\Claude\claude_desktop_config.json`                              |
| Linux   | `~/.config/Claude/claude_desktop_config.json`                              |

Merge the snippet from [`config.example.json`](./config.example.json)
into your `mcpServers` block. The shape:

```json
{
  "mcpServers": {
    "cryptokorr": {
      "command": "cryptokorr-mcp",
      "args": [],
      "env": {
        "CRYPTOKORR_API_KEY": "cb_REPLACE_ME_DO_NOT_COMMIT",
        "CRYPTOKORR_BASE_URL": "http://localhost:4000",
        "CRYPTOKORR_AGENT_ID": "agent-claude-desktop-example",
        "CRYPTOKORR_READONLY": "false"
      }
    }
  }
}
```

> **Substitute your real API key locally — never commit one.** The
> example file ships with `cb_REPLACE_ME_DO_NOT_COMMIT` so a
> grep-for-keys CI check stays clean. The smoke under
> `examples/test/` refuses any value matching
> `cb_[A-Za-z0-9_-]{16,}` in the example config.

After editing the config, fully quit and re-launch Claude Desktop.
The CryptoKorr tools appear in the model's tool list when a
session starts.

## Environment variables

| Variable                  | Required | Purpose                                                                 |
| ------------------------- | -------- | ----------------------------------------------------------------------- |
| `CRYPTOKORR_API_KEY`      | yes      | Workspace API key (`cb_<...>`). Never log or commit this.               |
| `CRYPTOKORR_BASE_URL`     | no       | Defaults to `http://localhost:4000`.                                   |
| `CRYPTOKORR_AGENT_ID`     | no       | Default `agent_id` for write tools. Recommended for multi-app setups.   |
| `CRYPTOKORR_READONLY`     | no       | `"true"` hides every write tool. Default `"false"`.                    |
| `CRYPTOKORR_TIMEOUT_MS`   | no       | Per-request timeout. Defaults to `15000`.                              |
| `CRYPTOKORR_LOG_LEVEL`    | no       | Defaults to `INFO`.                                                    |

## Tool-name → SDK-method map

| MCP tool                   | SDK method (Python / TS)               | Tier      |
| -------------------------- | -------------------------------------- | --------- |
| `submit_transfer`          | `submitTransfer`                       | write     |
| `submit_swap`              | `submitSwap`                           | write     |
| `submit_allocate_idle_capital` | `submitAllocateIdleCapital`        | write     |
| `get_intent`               | `getIntent`                            | read      |
| `get_decision`             | `getDecision`                          | read      |
| `wait_for_decision`        | `waitForDecision`                      | read      |
| `get_audit_trail`          | `getAuditTrail`                        | read      |
| `list_counterparties`      | `listCounterparties`                   | read      |
| `get_runtime_status`       | `getRuntimeStatus`                     | read      |
| `get_policy`               | `getPolicy`                            | read      |
| `list_pending_approvals`   | `operator.listPendingApprovals`        | operator  |
| `approve_decision`         | `operator.approveDecision`             | operator  |
| `reject_decision`          | `operator.rejectDecision`              | operator  |
| `pause_runtime`            | `operator.pauseRuntime`                | operator  |
| `resume_runtime`           | `operator.resumeRuntime`               | operator  |

The MCP server gates operator tools on the API key's role —
agent-tier keys see only the read + write tiers; operator-tier
keys see all of them.

## First prompt — submit a Base Sepolia transfer

Open a fresh Claude Desktop session and paste:

> Use the cryptokorr tools to submit a USDC transfer of 5.0 to
> counterparty `b6a10f53-8c6e-4d79-9bb9-3e1e5b1f1a11` on Base
> Sepolia. Then call `get_decision` with the returned
> `currentDecisionId` and tell me the outcome plainly. If the
> outcome is `approval_required`, do not loop — that is a
> successful response that means an operator must approve.

Claude picks `submit_transfer`, fills in the args, and calls the
MCP server. The expected high-level flow:

1. `submit_transfer` returns `intent_id` + `state: "submitted"`.
2. Claude calls `get_decision` (or `wait_for_decision` for a
   bounded poll).
3. The decision response carries `outcome: "auto_exec" |
   "approval_required" | "hold" | "block"`.
4. Claude tells you which one.

## Expected output (Claude's reply)

```
I submitted the transfer through the CryptoKorr MCP. Result:

  intent id        : int_xxxxxxxx
  decision id      : dec_yyyyyyyy
  decision.outcome : approval_required
  approval expires : 2026-…

approval_required is a successful response — the runtime accepted
the intent but a workspace operator must approve before it
dispatches. The MCP server returned this as a normal tool result
(isError: false). I will not loop; please approve from the
CryptoKorr dashboard or have an operator call the
`approve_decision` tool.
```

The exact wording depends on the model; the *structure* is what
this example pins (intent id, decision id, `approval_required` as
a successful result).

## Approval-required handling

Over MCP, the decision result is a **successful tool response**
with `isError: false`. The decision payload carries
`outcome: "approval_required"` as a normal field; there is no
separate `requires_approval` flag (the SDK and the MCP server
agree that `decision.outcome` is the discriminator).

Claude — or any LLM driving the MCP server — should branch on the
outcome:

| `decision.outcome`     | What it means                                | What Claude should say                            |
| ---------------------- | -------------------------------------------- | ------------------------------------------------- |
| `auto_exec`            | Runtime auto-dispatched on Base Sepolia.     | "Done — dispatched on Base Sepolia."              |
| `approval_required`    | **Successful**, waiting for operator.        | "Submitted; waiting for operator approval."       |
| `hold`                 | Runtime needs more data.                     | "Held; the operator is refreshing."               |
| `block`                | Terminal refusal.                            | "Refused: …" (surface `decision.reasons`).        |

## Safety notes

- **Workspace API keys are operator credentials.** The Claude
  Desktop config is local to your machine; if you share your
  config or sync it through a cloud service, the key syncs too.
  Treat the config like any other secrets file — chmod / vault /
  whatever your standard is.
- **Base Sepolia (`84532`) only.** The runtime rejects mainnet
  writes with `mainnet_disabled` unless the workspace flag is on.
  The example pins `chain: "base-sepolia"` everywhere.
- **Read-only mode.** Set `CRYPTOKORR_READONLY=true` for
  exploration sessions where you don't want Claude to be able to
  emit writes. The MCP server hides every write + operator tool
  in that mode.
- **No browser-side use.** This is the desktop MCP path. The
  browser-driven non-custodial onboarding flow lives in
  `docs/wallet-quickstart.md`; the MCP server is not in that
  loop.

## Smoke

The static smoke under `examples/test/` parses this README's env
var table, refuses any banned mainnet / paymaster /
unlimited-token claim, and verifies `config.example.json` carries
the placeholder API key (`cb_REPLACE_ME_DO_NOT_COMMIT`) — a real
`cb_<...>` value would fail the test.

Run from the repo root:

```sh
python3 -m unittest discover -s examples/test
```
