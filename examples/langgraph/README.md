# `examples/langgraph/` — monitor + Morpho deposit (Python SDK)

A minimal LangGraph-style agent that monitors a condition and, when
the condition fires, submits an `allocate_idle_capital` intent
through the **Python SDK** (`@cryptobank/sdk-py` — package
`cryptobank` on PyPI). The agent then waits for the decision
pipeline and prints the outcome (`auto_exec`, `approval_required`,
`hold`, or `block`).

This example **never** asks for a private key. The CryptoBank
runtime decides whether to dispatch; the agent just emits intent.

## Scope

- **Base Sepolia only** (`chain: "base-sepolia"`). Mainnet
  (`base`) is post-MVP and surfaces as a typed
  `mainnet_disabled` error.
- **USDC** is the only supported asset.
- **Single allowlisted Morpho USDC vault.** The example takes the
  vault address from `MORPHO_VAULT_ADDRESS`; your operator must
  add a `:allowed_vault` policy rule before the runtime accepts
  the intent.
- **No paymaster / sponsored gas.** The smart account pays.
- **`approval_required` is a successful response**, not an error.
  The agent surfaces it explicitly so the operator can take over.

## Prerequisites

- Python **3.10+**.
- The CryptoBank Python SDK (`cryptobank>=0.1.0`).
- A workspace API key (`cb_<...>`) — operator-level, **not**
  embedded in the code; loaded from the environment.
- A running CryptoBank backend (default `http://localhost:4000`).

LangGraph itself is **optional** for this example. The graph shape
is small enough that it runs cleanly with or without the
`langgraph` package installed:

- If `langgraph` is on `sys.path`, the example wires through
  `langgraph.graph.StateGraph` so the structure is recognizable
  to LangGraph users.
- If `langgraph` is not installed, the example falls back to a
  tiny in-process state machine with the same node names and
  transitions. The fallback is the default for CI smoke; no
  network or SDK install is required to run the static smoke.

## Install

```sh
cd examples/langgraph
python3 -m venv .venv
source .venv/bin/activate
pip install -e ../../sdks/python  # local development install
# Optional, only if you want the real LangGraph runtime:
# pip install langgraph
```

## Environment variables

| Variable                  | Required | Purpose                                                            |
| ------------------------- | -------- | ------------------------------------------------------------------ |
| `CRYPTOBANK_API_KEY`      | yes      | Workspace API key (`cb_<...>`). Never log or commit this.          |
| `CRYPTOBANK_BASE_URL`     | no       | Defaults to `http://localhost:4000`.                              |
| `CRYPTOBANK_AGENT_ID`     | no       | Defaults to `agent-langgraph-example`.                            |
| `MORPHO_VAULT_ADDRESS`    | yes      | Allowlisted Morpho USDC vault address (Base Sepolia).             |
| `IDLE_BALANCE_USDC`       | no       | Synthetic balance the monitor reports. Defaults to `"100"`.       |
| `IDLE_THRESHOLD_USDC`     | no       | Trigger threshold. Defaults to `"50"`.                            |
| `DEPLOY_AMOUNT_USDC`      | no       | Amount to deposit when the trigger fires. Defaults to `"10"`.     |
| `CRYPTOBANK_DRY_RUN`      | no       | Set to `1` to skip the SDK call and print the intent shape only.  |

## Run

```sh
export CRYPTOBANK_API_KEY="cb_..."
export MORPHO_VAULT_ADDRESS="0x..."   # operator-supplied, allowlisted
python3 main.py
```

## Expected output

```
[monitor]   idle balance: 100 USDC (threshold 50 USDC)
[monitor]   trigger fired — over-threshold by 50 USDC
[deposit]   submitting allocate_idle_capital
            agent_id   = agent-langgraph-example
            asset      = USDC
            chain      = base-sepolia
            amount     = 10
            vault      = 0x... (Base Sepolia)
[deposit]   intent submitted: int_xxxx
            state      = submitted
[wait]      polling decision (timeout 30s)
[wait]      decision: dec_yyyy
            outcome    = approval_required
[result]    APPROVAL REQUIRED
            The runtime accepted the intent but is waiting for an operator
            to approve the deposit. Approval is a successful response — the
            agent should hand off to a human, not loop on the call.
```

When the operator approves the decision via the dashboard or
`client.operator.approve_decision(decision_id, ...)`, the runtime
dispatches the deposit through the existing Morpho path. The
agent's job ends at "approval requested"; it does not poll the
operator queue.

## Approval-required handling

The example switches on `decision.outcome`:

```python
match decision.outcome:
    case "auto_exec":
        # Runtime auto-dispatched. Nothing else for the agent to do.
    case "approval_required":
        # Successful response — operator must approve.
    case "hold":
        # Runtime is waiting for missing data (e.g. stale snapshot).
    case "block":
        # Terminal refusal; surface the reasons.
```

`approval_required` is **not** an error. It comes back on the same
successful HTTP status as `auto_exec`; the agent reads
`decision.outcome` to branch.

## Safety notes

- **Never paste your API key into the code.** Always load it from
  the environment.
- **Never deploy this example with `chain: "base"`.** The runtime
  rejects mainnet writes unless the workspace flag is on; this
  example pins `base-sepolia`.
- **Never bypass the policy gate.** The runtime decides whether
  to dispatch; the agent only emits intent.
- **The Morpho vault must be in the workspace's
  `:allowed_vault` policy rule** before the deposit will be
  accepted; otherwise the runtime returns `morpho_vault_not_allowlisted`
  (typed `MorphoSafetyError` in the SDK).
- **No private keys, no signed payloads.** Only the Bearer API
  key crosses the wire from the agent's process.

## Smoke

The static smoke under `examples/test/` parses this README's env
var table, confirms the example file imports the SDK from the
documented path, and refuses any banned mainnet / paymaster /
unlimited-token claim. Run from the repo root:

```sh
python3 -m unittest discover -s examples/test
```

The smoke does **not** require LangGraph, the SDK, or a running
backend.
