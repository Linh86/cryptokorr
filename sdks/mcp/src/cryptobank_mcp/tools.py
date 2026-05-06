"""Tool registry — definitions, validation, and dispatch.

Each tool is a ``ToolSpec`` whose handler receives a parsed argument
dict and a ``ToolContext`` (the HTTP client + the resolved config) and
returns either a plain dict (success) or a ``ToolError``.

Tier semantics:

- ``read``: always advertised.
- ``read_operator``: hidden when role < operator OR ``readonly``.
- ``write``: hidden when ``readonly``. Wire requires operator role; an
  agent without operator gets a typed ``insufficient_role`` at call
  time.
- ``operator``: hidden when role < operator OR ``readonly``.
"""

from __future__ import annotations

import hashlib
import json
import time
import uuid
from dataclasses import dataclass
from enum import Enum
from typing import Any, Callable, Iterable, Mapping

from cryptobank_mcp import schemas
from cryptobank_mcp.client import HttpClient, HttpResponse
from cryptobank_mcp.config import Config
from cryptobank_mcp.errors import ToolError, map_http_error, map_transport_error


class Role(Enum):
    UNKNOWN = "unknown"
    VIEWER = "viewer"
    OPERATOR = "operator"
    ADMIN = "admin"

    def at_least_operator(self) -> bool:
        return self in (Role.OPERATOR, Role.ADMIN)


class Tier(Enum):
    READ = "read"
    READ_OPERATOR = "read_operator"
    WRITE = "write"
    OPERATOR = "operator"


@dataclass
class ToolContext:
    config: Config
    client: HttpClient
    role: Role
    sleep: Callable[[float], None] = time.sleep
    monotonic: Callable[[], float] = time.monotonic

    def now_for_idempotency(self) -> str:
        return uuid.uuid4().hex


@dataclass(frozen=True)
class ToolSpec:
    name: str
    description: str
    input_schema: Mapping[str, Any]
    tier: Tier
    handler: Callable[[Mapping[str, Any], ToolContext], dict[str, Any] | ToolError]


_FORBIDDEN_TOOLS = frozenset({
    "revoke_delegation",
    "create_policy",
    "revise_policy",
    "archive_policy",
    "create_counterparty",
    "create_address_label",
    "patch_counterparty",
    "create_evidence",
    "create_trust_assertion",
    "create_api_key",
    "rotate_api_key",
    "delete_api_key",
    "pause_chain",
    "resume_chain",
    "pause_agent_keys",
    "resume_agent_keys",
    "abort_execution",
    "connect_smart_account",
})


def forbidden_tool_names() -> frozenset[str]:
    return _FORBIDDEN_TOOLS


# ---------------------------------------------------------------------
# Read handlers
# ---------------------------------------------------------------------

def _handle_get_intent(args: Mapping[str, Any], ctx: ToolContext) -> dict[str, Any] | ToolError:
    return _request(ctx, "GET", f"/v1/intents/{args['intent_id']}")


def _handle_get_decision(args: Mapping[str, Any], ctx: ToolContext) -> dict[str, Any] | ToolError:
    return _request(ctx, "GET", f"/v1/decisions/{args['decision_id']}")


def _handle_get_audit_trail(args: Mapping[str, Any], ctx: ToolContext) -> dict[str, Any] | ToolError:
    return _request(ctx, "GET", f"/v1/intents/{args['intent_id']}/replay")


def _handle_list_counterparties(args: Mapping[str, Any], ctx: ToolContext) -> dict[str, Any] | ToolError:
    params = {}
    if "limit" in args:
        params["limit"] = args["limit"]
    return _request(ctx, "GET", "/v1/counterparties", params=params or None)


def _handle_get_runtime_status(args: Mapping[str, Any], ctx: ToolContext) -> dict[str, Any] | ToolError:
    return _request(ctx, "GET", "/v1/health/deep")


def _handle_get_policy(args: Mapping[str, Any], ctx: ToolContext) -> dict[str, Any] | ToolError:
    pid = args.get("policy_id")
    if pid:
        return _request(ctx, "GET", f"/v1/policies/{pid}")
    return _request(ctx, "GET", "/v1/policies")


def _handle_list_pending_approvals(args: Mapping[str, Any], ctx: ToolContext) -> dict[str, Any] | ToolError:
    return _request(ctx, "GET", "/v1/approvals")


def _handle_wait_for_decision(args: Mapping[str, Any], ctx: ToolContext) -> dict[str, Any] | ToolError:
    intent_id = args["intent_id"]
    timeout_seconds = min(int(args.get("timeout_seconds", 30)), 60)
    poll_interval_ms = max(100, min(int(args.get("poll_interval_ms", 500)), 5_000))
    deadline = ctx.monotonic() + timeout_seconds

    last_decision: dict[str, Any] | None = None
    while True:
        intent = _request(ctx, "GET", f"/v1/intents/{intent_id}")
        if isinstance(intent, ToolError):
            return intent
        decision_id = _read_field(intent, ["current_decision_id", "currentDecisionId"])
        if decision_id:
            decision = _request(ctx, "GET", f"/v1/decisions/{decision_id}")
            if isinstance(decision, ToolError):
                return decision
            outcome = _read_field(decision, ["outcome"])
            if outcome and outcome != "evaluating":
                return decision
            last_decision = decision

        if ctx.monotonic() >= deadline:
            return _still_evaluating_payload(intent_id, last_decision)

        sleep_for = poll_interval_ms / 1000.0
        remaining = deadline - ctx.monotonic()
        ctx.sleep(min(sleep_for, max(0.0, remaining)))


def _still_evaluating_payload(
    intent_id: str, last_decision: dict[str, Any] | None
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "intent_id": intent_id,
        "outcome": "still_evaluating",
        "synthetic": True,
        "hint": (
            "Decision did not resolve before the timeout. The MCP tool "
            "caps timeout at 60 seconds; call wait_for_decision again "
            "to keep waiting."
        ),
    }
    if last_decision is not None:
        payload["last_decision"] = last_decision
    return payload


# ---------------------------------------------------------------------
# Write handlers
# ---------------------------------------------------------------------

def _handle_submit_transfer(args: Mapping[str, Any], ctx: ToolContext) -> dict[str, Any] | ToolError:
    body = _build_intent_body(args, kind="transfer", ctx=ctx)
    if isinstance(body, ToolError):
        return body
    return _request(ctx, "POST", "/v1/intents", body=body, idempotency_key=body["idempotency_key"])


def _handle_submit_swap(args: Mapping[str, Any], ctx: ToolContext) -> dict[str, Any] | ToolError:
    extras = {
        "source_asset": args["source_asset"],
        "destination_asset": args["destination_asset"],
    }
    body = _build_intent_body(
        args,
        kind="swap",
        asset=args["source_asset"],
        ctx=ctx,
        extras=extras,
        target={"raw_address": "0x0000000000000000000000000000000000000000"},
    )
    if isinstance(body, ToolError):
        return body
    return _request(ctx, "POST", "/v1/intents", body=body, idempotency_key=body["idempotency_key"])


def _handle_submit_allocate_idle_capital(
    args: Mapping[str, Any], ctx: ToolContext
) -> dict[str, Any] | ToolError:
    extras = {"vault_address": args["vault_address"]}
    body = _build_intent_body(
        args,
        kind="allocate_idle_capital",
        asset=args.get("asset", "USDC"),
        chain=args.get("chain", "base-sepolia"),
        ctx=ctx,
        extras=extras,
        target={"raw_address": args["vault_address"]},
    )
    if isinstance(body, ToolError):
        return body
    return _request(ctx, "POST", "/v1/intents", body=body, idempotency_key=body["idempotency_key"])


def _handle_approve_decision(args: Mapping[str, Any], ctx: ToolContext) -> dict[str, Any] | ToolError:
    body = _approval_body(args)
    return _request(
        ctx,
        "POST",
        f"/v1/approvals/{args['decision_id']}/approve",
        body=body,
        idempotency_key=args.get("idempotency_key") or _content_hash(body),
    )


def _handle_reject_decision(args: Mapping[str, Any], ctx: ToolContext) -> dict[str, Any] | ToolError:
    body = _approval_body(args)
    return _request(
        ctx,
        "POST",
        f"/v1/approvals/{args['decision_id']}/reject",
        body=body,
        idempotency_key=args.get("idempotency_key") or _content_hash(body),
    )


def _handle_pause_runtime(args: Mapping[str, Any], ctx: ToolContext) -> dict[str, Any] | ToolError:
    return _request(ctx, "POST", "/v1/security/pause", body={})


def _handle_resume_runtime(args: Mapping[str, Any], ctx: ToolContext) -> dict[str, Any] | ToolError:
    return _request(ctx, "POST", "/v1/security/resume", body={})


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

def _build_intent_body(
    args: Mapping[str, Any],
    *,
    kind: str,
    ctx: ToolContext,
    asset: str | None = None,
    chain: str | None = None,
    extras: Mapping[str, Any] | None = None,
    target: Mapping[str, Any] | None = None,
) -> dict[str, Any] | ToolError:
    agent_id = args.get("agent_id") or ctx.config.agent_id
    if not agent_id:
        return ToolError(
            code="invalid_body",
            message=(
                "agent_id is required. Pass it as a tool argument or set "
                "CRYPTOBANK_AGENT_ID in the MCP server env."
            ),
            retryable=False,
            hint="Add agent_id to the tool call, or set CRYPTOBANK_AGENT_ID.",
        )

    resolved_target = args.get("target") or target
    if not resolved_target:
        return ToolError(
            code="invalid_target",
            message="target is required.",
            retryable=False,
        )

    body: dict[str, Any] = {
        "kind": kind,
        "agent_id": agent_id,
        "asset": asset or args.get("asset") or "USDC",
        "chain": chain or args.get("chain") or "base-sepolia",
        "amount": args["amount"],
        "target": dict(resolved_target),
        "source": args.get("source") or "agent",
    }
    if "notes" in args and args["notes"]:
        body["notes"] = args["notes"]
    if "smart_account_id" in args and args["smart_account_id"]:
        body["smart_account_id"] = args["smart_account_id"]
    if extras:
        for k, v in extras.items():
            body[k] = v

    body["idempotency_key"] = (
        args.get("idempotency_key") or _content_hash(body)
    )
    return body


def _approval_body(args: Mapping[str, Any]) -> dict[str, Any]:
    body: dict[str, Any] = {"actor_id": args["actor_id"]}
    if args.get("reason"):
        body["reason"] = args["reason"]
    return body


def _content_hash(payload: Mapping[str, Any]) -> str:
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    digest = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    return f"mcp-{digest[:32]}"


def _request(
    ctx: ToolContext,
    method: str,
    path: str,
    *,
    body: Mapping[str, Any] | None = None,
    params: Mapping[str, Any] | None = None,
    idempotency_key: str | None = None,
) -> dict[str, Any] | ToolError:
    try:
        if method == "GET":
            response = ctx.client.get(path, params=params)
        elif method == "POST":
            response = ctx.client.post(path, body=body, idempotency_key=idempotency_key)
        else:  # pragma: no cover - we only ever call GET/POST today
            return ToolError(
                code="invalid_body",
                message=f"Unsupported HTTP method {method}.",
                retryable=False,
            )
    except Exception as exc:  # noqa: BLE001 - transport failures are arbitrary
        return map_transport_error(exc)

    return _parse(response)


def _parse(response: HttpResponse) -> dict[str, Any] | ToolError:
    if 200 <= response.status < 300:
        if not response.body:
            return {}
        try:
            value = response.json()
        except json.JSONDecodeError:
            return ToolError(
                code="service_unavailable",
                message="API returned non-JSON success body.",
                retryable=False,
                http_status=response.status,
            )
        if isinstance(value, dict):
            return value
        return {"data": value}
    return map_http_error(response.status, response.body)


def _read_field(payload: Mapping[str, Any], keys: Iterable[str]) -> Any:
    for key in keys:
        if key in payload:
            return payload[key]
    data = payload.get("data") if isinstance(payload, Mapping) else None
    if isinstance(data, Mapping):
        for key in keys:
            if key in data:
                return data[key]
    return None


# ---------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------

ALL_TOOLS: tuple[ToolSpec, ...] = (
    ToolSpec(
        name="get_intent",
        description=(
            "Look up a CryptoBank intent by id. Returns the full Intent "
            "record including its current state, decision id, and "
            "execution plan id."
        ),
        input_schema=schemas.GET_INTENT,
        tier=Tier.READ,
        handler=_handle_get_intent,
    ),
    ToolSpec(
        name="get_decision",
        description=(
            "Fetch a decision envelope by id. Branch on decision.outcome: "
            "auto_exec | approval_required | hold | block."
        ),
        input_schema=schemas.GET_DECISION,
        tier=Tier.READ,
        handler=_handle_get_decision,
    ),
    ToolSpec(
        name="wait_for_decision",
        description=(
            "Poll an intent's current decision until it leaves "
            "evaluating or the timeout elapses. Capped at 60s. If the "
            "decision is still evaluating after the timeout, returns "
            "outcome: still_evaluating so the caller can move on."
        ),
        input_schema=schemas.WAIT_FOR_DECISION,
        tier=Tier.READ,
        handler=_handle_wait_for_decision,
    ),
    ToolSpec(
        name="get_audit_trail",
        description=(
            "Fetch the full replay bundle for an intent: policy snapshot, "
            "trust assessments, simulations, decisions, plans, audit "
            "events, route evidence."
        ),
        input_schema=schemas.GET_AUDIT_TRAIL,
        tier=Tier.READ,
        handler=_handle_get_audit_trail,
    ),
    ToolSpec(
        name="list_counterparties",
        description="List counterparties in the caller's workspace.",
        input_schema=schemas.LIST_COUNTERPARTIES,
        tier=Tier.READ,
        handler=_handle_list_counterparties,
    ),
    ToolSpec(
        name="get_runtime_status",
        description=(
            "Fetch the deep health status: database connectivity, adapter "
            "reachability, quote-provider health, stuck-plan counts, "
            "overall status (ok | degraded | failing)."
        ),
        input_schema=schemas.GET_RUNTIME_STATUS,
        tier=Tier.READ,
        handler=_handle_get_runtime_status,
    ),
    ToolSpec(
        name="get_policy",
        description=(
            "Fetch a single policy by id, or list all policies in the "
            "workspace when no id is given."
        ),
        input_schema=schemas.GET_POLICY,
        tier=Tier.READ,
        handler=_handle_get_policy,
    ),
    ToolSpec(
        name="list_pending_approvals",
        description=(
            "List decisions waiting on operator approval. Operator-tier; "
            "hidden when CRYPTOBANK_READONLY=true or the API key is below "
            "operator role."
        ),
        input_schema=schemas.LIST_PENDING_APPROVALS,
        tier=Tier.READ_OPERATOR,
        handler=_handle_list_pending_approvals,
    ),
    ToolSpec(
        name="submit_transfer",
        description=(
            "Submit a transfer intent. Returns the IntentSubmitResult with "
            "the intent id, state, and idempotent_replay flag. Approval-"
            "required is success — call wait_for_decision to follow up."
        ),
        input_schema=schemas.SUBMIT_TRANSFER,
        tier=Tier.WRITE,
        handler=_handle_submit_transfer,
    ),
    ToolSpec(
        name="submit_swap",
        description=(
            "Submit a swap intent (exact-input only; v0.1 is Sepolia). "
            "Phoenix's quote provider fills in slippage / deadline / "
            "calldata. Approval-required is success — call wait_for_"
            "decision to follow up."
        ),
        input_schema=schemas.SUBMIT_SWAP,
        tier=Tier.WRITE,
        handler=_handle_submit_swap,
    ),
    ToolSpec(
        name="submit_allocate_idle_capital",
        description=(
            "Submit a Morpho ERC-4626 USDC deposit intent (Sepolia, "
            "approval-required by construction). vault_address must be on "
            "the workspace's Morpho allowlist. Approval-required is "
            "success — call wait_for_decision to follow up."
        ),
        input_schema=schemas.SUBMIT_ALLOCATE_IDLE_CAPITAL,
        tier=Tier.WRITE,
        handler=_handle_submit_allocate_idle_capital,
    ),
    ToolSpec(
        name="approve_decision",
        description=(
            "Operator approve. Resolves a decision in approval_required "
            "state and dispatches its execution plan."
        ),
        input_schema=schemas.APPROVAL_ACTION,
        tier=Tier.OPERATOR,
        handler=_handle_approve_decision,
    ),
    ToolSpec(
        name="reject_decision",
        description=(
            "Operator reject. Resolves a decision in approval_required "
            "state with no execution."
        ),
        input_schema=schemas.APPROVAL_ACTION,
        tier=Tier.OPERATOR,
        handler=_handle_reject_decision,
    ),
    ToolSpec(
        name="pause_runtime",
        description=(
            "Globally pause the runtime — every write endpoint refuses "
            "with runtime_paused. Subject to a 5/60s chain-action cap."
        ),
        input_schema=schemas.PAUSE_RESUME,
        tier=Tier.OPERATOR,
        handler=_handle_pause_runtime,
    ),
    ToolSpec(
        name="resume_runtime",
        description=(
            "Globally resume the runtime. Subject to a 5/60s chain-"
            "action cap."
        ),
        input_schema=schemas.PAUSE_RESUME,
        tier=Tier.OPERATOR,
        handler=_handle_resume_runtime,
    ),
)


class ToolRegistry:
    def __init__(self, *, config: Config, role: Role, tools: Iterable[ToolSpec] | None = None) -> None:
        if config.readonly and role.at_least_operator():
            self._role = Role.VIEWER
        else:
            self._role = role
        self._config = config
        self._all = tuple(tools or ALL_TOOLS)
        self._visible = tuple(self._filter(self._all))
        self._by_name = {t.name: t for t in self._visible}

    @property
    def visible_tools(self) -> tuple[ToolSpec, ...]:
        return self._visible

    @property
    def all_tools(self) -> tuple[ToolSpec, ...]:
        return self._all

    def get(self, name: str) -> ToolSpec | None:
        return self._by_name.get(name)

    def visible_names(self) -> list[str]:
        return [t.name for t in self._visible]

    def _filter(self, tools: Iterable[ToolSpec]) -> Iterable[ToolSpec]:
        readonly = self._config.readonly
        operator_or_above = self._role.at_least_operator()
        for tool in tools:
            if tool.name in _FORBIDDEN_TOOLS:
                continue
            if tool.tier == Tier.READ:
                yield tool
                continue
            if readonly:
                continue
            if tool.tier in (Tier.READ_OPERATOR, Tier.OPERATOR, Tier.WRITE):
                if not operator_or_above and tool.tier != Tier.WRITE:
                    continue
                yield tool


def probe_role(client: HttpClient, *, override: str | None = None) -> Role:
    """Resolve the API key's role, preferring the explicit override.

    Without an override, hits ``GET /v1/approvals?limit=1``: 200 means
    operator+, 403 means viewer. Anything else (transport errors, 5xx)
    is treated as operator+ optimistically — failing closed at startup
    would block the entire MCP session.
    """
    if override:
        try:
            return Role(override.lower())
        except ValueError:
            return Role.OPERATOR
    try:
        resp = client.get("/v1/approvals", params={"limit": 1})
    except Exception:  # noqa: BLE001 - probe must not crash startup
        return Role.OPERATOR
    if resp.status == 403:
        return Role.VIEWER
    if 200 <= resp.status < 300:
        return Role.OPERATOR
    return Role.OPERATOR
