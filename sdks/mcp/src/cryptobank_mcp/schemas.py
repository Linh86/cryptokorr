"""JSON Schemas for tool inputs.

These mirror the schemas pinned in ``docs/api/mcp-tools.md``. They are
the contract the model sees when it lists tools; the server validates
arguments against them before dispatching to a handler.
"""

from __future__ import annotations

from typing import Any

UUID = {"type": "string", "format": "uuid"}
AMOUNT = {"type": "string", "pattern": r"^[0-9]+(\.[0-9]+)?$"}
EVM_ADDRESS = {"type": "string", "pattern": r"^0x[a-fA-F0-9]{40}$"}

CHAIN_ENUM = ["base-sepolia", "base"]
SWAP_CHAIN_ENUM = ["base-sepolia"]
USDC_ENUM = ["USDC"]
SWAP_DST_ENUM = ["USDC", "USDT", "ETH"]


def _empty() -> dict[str, Any]:
    return {"type": "object", "properties": {}, "additionalProperties": False}


GET_INTENT: dict[str, Any] = {
    "type": "object",
    "required": ["intent_id"],
    "properties": {"intent_id": dict(UUID)},
    "additionalProperties": False,
}

GET_DECISION: dict[str, Any] = {
    "type": "object",
    "required": ["decision_id"],
    "properties": {"decision_id": dict(UUID)},
    "additionalProperties": False,
}

WAIT_FOR_DECISION: dict[str, Any] = {
    "type": "object",
    "required": ["intent_id"],
    "properties": {
        "intent_id": dict(UUID),
        "timeout_seconds": {
            "type": "integer",
            "minimum": 1,
            "maximum": 60,
            "default": 30,
        },
        "poll_interval_ms": {
            "type": "integer",
            "minimum": 100,
            "maximum": 5_000,
            "default": 500,
        },
    },
    "additionalProperties": False,
}

GET_AUDIT_TRAIL: dict[str, Any] = {
    "type": "object",
    "required": ["intent_id"],
    "properties": {"intent_id": dict(UUID)},
    "additionalProperties": False,
}

LIST_COUNTERPARTIES: dict[str, Any] = {
    "type": "object",
    "properties": {
        "limit": {"type": "integer", "minimum": 1, "maximum": 100, "default": 50},
    },
    "additionalProperties": False,
}

GET_RUNTIME_STATUS: dict[str, Any] = _empty()

GET_POLICY: dict[str, Any] = {
    "type": "object",
    "properties": {"policy_id": dict(UUID)},
    "additionalProperties": False,
}

LIST_PENDING_APPROVALS: dict[str, Any] = _empty()

_TRANSFER_TARGET = {
    "type": "object",
    "properties": {
        "counterparty_id": dict(UUID),
        "address_label_id": dict(UUID),
        "raw_address": dict(EVM_ADDRESS),
    },
    "additionalProperties": False,
}

SUBMIT_TRANSFER: dict[str, Any] = {
    "type": "object",
    "required": ["asset", "chain", "amount", "target"],
    "properties": {
        "agent_id": {"type": "string"},
        "asset": {"type": "string", "enum": USDC_ENUM},
        "chain": {"type": "string", "enum": CHAIN_ENUM},
        "amount": dict(AMOUNT),
        "target": _TRANSFER_TARGET,
        "notes": {"type": "string"},
        "smart_account_id": dict(UUID),
        "idempotency_key": {"type": "string"},
    },
    "additionalProperties": False,
}

SUBMIT_SWAP: dict[str, Any] = {
    "type": "object",
    "required": ["chain", "source_asset", "destination_asset", "amount"],
    "properties": {
        "agent_id": {"type": "string"},
        "chain": {"type": "string", "enum": SWAP_CHAIN_ENUM},
        "source_asset": {"type": "string", "enum": USDC_ENUM},
        "destination_asset": {"type": "string", "enum": SWAP_DST_ENUM},
        "amount": dict(AMOUNT),
        "smart_account_id": dict(UUID),
        "notes": {"type": "string"},
        "idempotency_key": {"type": "string"},
    },
    "additionalProperties": False,
}

SUBMIT_ALLOCATE_IDLE_CAPITAL: dict[str, Any] = {
    "type": "object",
    "required": ["amount", "vault_address"],
    "properties": {
        "agent_id": {"type": "string"},
        "asset": {"type": "string", "enum": USDC_ENUM},
        "chain": {"type": "string", "enum": SWAP_CHAIN_ENUM},
        "amount": dict(AMOUNT),
        "vault_address": dict(EVM_ADDRESS),
        "smart_account_id": dict(UUID),
        "notes": {"type": "string"},
        "idempotency_key": {"type": "string"},
    },
    "additionalProperties": False,
}

APPROVAL_ACTION: dict[str, Any] = {
    "type": "object",
    "required": ["decision_id", "actor_id"],
    "properties": {
        "decision_id": dict(UUID),
        "actor_id": {"type": "string", "minLength": 1},
        "reason": {"type": "string", "maxLength": 280},
        "idempotency_key": {"type": "string"},
    },
    "additionalProperties": False,
}

PAUSE_RESUME: dict[str, Any] = _empty()
