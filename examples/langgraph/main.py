"""LangGraph-style agent — monitor a condition and submit
``allocate_idle_capital`` through the CryptoKorr Python SDK.

Runs against **Base Sepolia only** (`chain: "base-sepolia"`); the
runtime rejects mainnet writes unless the workspace flag is on. The
example never asks for a private key — the agent only emits intent;
the CryptoKorr runtime decides whether to dispatch.

If the ``langgraph`` package is on ``sys.path`` the example uses
``StateGraph`` so the wiring is recognisable to LangGraph users. If
not, it falls back to a tiny in-process state machine with the same
node names — the fallback is the CI-friendly path that needs no
external install.

Env vars (see ``README.md`` for the full table):

    CRYPTOKORR_API_KEY       (required)  cb_<...>
    CRYPTOKORR_BASE_URL      (optional)  http://localhost:4000
    CRYPTOKORR_AGENT_ID      (optional)  agent-langgraph-example
    MORPHO_VAULT_ADDRESS     (required)  Allowlisted Morpho USDC vault
    IDLE_BALANCE_USDC        (optional)  Synthetic balance      (default 100)
    IDLE_THRESHOLD_USDC      (optional)  Trigger threshold      (default 50)
    DEPLOY_AMOUNT_USDC       (optional)  Deposit amount         (default 10)
    CRYPTOKORR_DRY_RUN       (optional)  "1" to skip SDK calls and print only
"""

from __future__ import annotations

import os
import sys
from dataclasses import dataclass, field
from decimal import Decimal
from typing import Any, Callable

# --- Optional LangGraph -------------------------------------------------

try:  # pragma: no cover — exercised only when LangGraph is installed.
    from langgraph.graph import END, StateGraph  # type: ignore[import]

    HAS_LANGGRAPH = True
except Exception:
    HAS_LANGGRAPH = False
    END = "__end__"


# --- State --------------------------------------------------------------


@dataclass
class AgentState:
    agent_id: str
    asset: str
    chain: str
    vault_address: str
    idle_balance: Decimal
    threshold: Decimal
    deploy_amount: Decimal
    dry_run: bool
    monitor_log: list[str] = field(default_factory=list)
    trigger_fired: bool = False
    intent: dict[str, Any] | None = None
    decision: dict[str, Any] | None = None
    final_outcome: str = "noop"


# --- Nodes --------------------------------------------------------------


def monitor_node(state: AgentState) -> AgentState:
    """Synthetic monitor — would normally read on-chain balance or an
    indexer. The example simulates the read so the smoke is offline.
    """
    excess = state.idle_balance - state.threshold
    line = (
        f"[monitor]   idle balance: {state.idle_balance} {state.asset} "
        f"(threshold {state.threshold} {state.asset})"
    )
    state.monitor_log.append(line)
    print(line)
    if excess > 0:
        state.trigger_fired = True
        msg = f"[monitor]   trigger fired — over-threshold by {excess} {state.asset}"
        state.monitor_log.append(msg)
        print(msg)
    else:
        msg = "[monitor]   no trigger — under threshold; agent stops"
        state.monitor_log.append(msg)
        print(msg)
    return state


def deposit_node(state: AgentState) -> AgentState:
    """Submit ``allocate_idle_capital`` through the Python SDK."""
    intent_shape = {
        "agent_id": state.agent_id,
        "asset": state.asset,
        "chain": state.chain,
        "amount": str(state.deploy_amount),
        "vault_address": state.vault_address,
    }
    print("[deposit]   submitting allocate_idle_capital")
    print(f"            agent_id   = {state.agent_id}")
    print(f"            asset      = {state.asset}")
    print(f"            chain      = {state.chain}")
    print(f"            amount     = {state.deploy_amount}")
    print(f"            vault      = {state.vault_address} (Base Sepolia)")

    if state.dry_run:
        print("[deposit]   dry-run mode — skipping SDK call")
        state.intent = {"id": "int_dry_run", "state": "submitted", **intent_shape}
        state.final_outcome = "dry_run"
        return state

    try:
        from cryptokorr import CryptoKorr
    except ImportError as exc:  # pragma: no cover — covered via dry_run path
        raise RuntimeError(
            "The cryptokorr Python SDK is not installed. Run "
            "`pip install -e ../../sdks/python` from this directory or "
            "set CRYPTOKORR_DRY_RUN=1 to skip the network call."
        ) from exc

    client = CryptoKorr.from_env()
    result = client.submit_allocate_idle_capital(
        agent_id=state.agent_id,
        asset=state.asset,
        chain=state.chain,
        amount=str(state.deploy_amount),
        vault_address=state.vault_address,
    )
    state.intent = {
        "id": result["intent_id"],
        "state": result["state"],
    }
    print(f"[deposit]   intent submitted: {result['intent_id']}")
    print(f"            state      = {result['state']}")

    print("[wait]      polling decision (timeout 30s)")
    decision = client.wait_for_decision(result["intent_id"], timeout_seconds=30)
    state.decision = {
        "id": decision["id"],
        "outcome": decision["outcome"],
    }
    print(f"[wait]      decision: {decision['id']}")
    print(f"            outcome    = {decision['outcome']}")
    state.final_outcome = decision["outcome"]
    return state


def report_node(state: AgentState) -> AgentState:
    """Branch on `decision.outcome`. `approval_required` is a
    SUCCESSFUL response — the agent hands off to the operator
    instead of looping.
    """
    outcome = state.final_outcome
    if outcome == "auto_exec":
        print("[result]    AUTO-DISPATCHED")
        print("            The runtime auto-executed; the deposit is on-chain.")
    elif outcome == "approval_required":
        print("[result]    APPROVAL REQUIRED")
        print(
            "            The runtime accepted the intent but is waiting for an operator\n"
            "            to approve the deposit. Approval is a successful response — the\n"
            "            agent should hand off to a human, not loop on the call."
        )
    elif outcome == "hold":
        print("[result]    HOLD")
        print(
            "            The runtime is waiting for missing data (often a stale Morpho\n"
            "            snapshot). Refresh and retry; the agent does not loop here."
        )
    elif outcome == "block":
        print("[result]    BLOCKED")
        print("            The runtime refused the intent. The decision's reasons explain why.")
    elif outcome == "dry_run":
        print("[result]    DRY RUN — no SDK call was made")
    else:
        print(f"[result]    no-op ({outcome})")
    return state


# --- Graph wiring -------------------------------------------------------


def _route_after_monitor(state: AgentState) -> str:
    return "deposit" if state.trigger_fired else "report"


def run_with_langgraph(state: AgentState) -> AgentState:  # pragma: no cover — optional
    graph: Any = StateGraph(AgentState)  # type: ignore[arg-type]
    graph.add_node("monitor", monitor_node)
    graph.add_node("deposit", deposit_node)
    graph.add_node("report", report_node)
    graph.set_entry_point("monitor")
    graph.add_conditional_edges(
        "monitor", _route_after_monitor, {"deposit": "deposit", "report": "report"}
    )
    graph.add_edge("deposit", "report")
    graph.add_edge("report", END)
    runner = graph.compile()
    final: AgentState = runner.invoke(state)  # type: ignore[assignment]
    return final


def run_inline(state: AgentState) -> AgentState:
    """No-LangGraph fallback — same node sequence, no external install."""
    nodes: dict[str, Callable[[AgentState], AgentState]] = {
        "monitor": monitor_node,
        "deposit": deposit_node,
        "report": report_node,
    }
    state = nodes["monitor"](state)
    if state.trigger_fired:
        state = nodes["deposit"](state)
    state = nodes["report"](state)
    return state


# --- Entry point --------------------------------------------------------


def _decimal_env(name: str, default: str) -> Decimal:
    raw = os.environ.get(name, default)
    try:
        return Decimal(raw)
    except Exception as exc:
        raise SystemExit(f"{name} must be a decimal number, got {raw!r}") from exc


def build_state() -> AgentState:
    vault = os.environ.get("MORPHO_VAULT_ADDRESS")
    if not vault and not os.environ.get("CRYPTOKORR_DRY_RUN"):
        raise SystemExit(
            "MORPHO_VAULT_ADDRESS is required. Set it to the workspace's "
            "allowlisted Morpho USDC vault on Base Sepolia, or export "
            "CRYPTOKORR_DRY_RUN=1 to print the intent shape without calling "
            "the SDK."
        )
    return AgentState(
        agent_id=os.environ.get("CRYPTOKORR_AGENT_ID", "agent-langgraph-example"),
        asset="USDC",
        chain="base-sepolia",
        vault_address=vault or "0x0000000000000000000000000000000000000000",
        idle_balance=_decimal_env("IDLE_BALANCE_USDC", "100"),
        threshold=_decimal_env("IDLE_THRESHOLD_USDC", "50"),
        deploy_amount=_decimal_env("DEPLOY_AMOUNT_USDC", "10"),
        dry_run=os.environ.get("CRYPTOKORR_DRY_RUN") == "1",
    )


def main() -> int:
    state = build_state()
    final = (
        run_with_langgraph(state)
        if HAS_LANGGRAPH and not state.dry_run
        else run_inline(state)
    )
    return 0 if final.final_outcome != "block" else 1


if __name__ == "__main__":
    sys.exit(main())
