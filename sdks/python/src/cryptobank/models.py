"""Result types returned by the SDK.

The SDK uses ``TypedDict`` rather than dataclasses because the wire
JSON the server returns is the source of truth — every field on the
result types matches a field name in ``priv/openapi/openapi.json``.
This keeps the surface stable across server-side additive changes
(new fields appear automatically; the SDK never strips them).

Where the SDK adds a synthetic field for caller ergonomics
(e.g. ``requires_approval`` on a decision result), it is documented
inline.

All types are PEP 655-style ``TypedDict``s with ``total=False``
where the server may omit fields. Future versions may switch to
``pydantic`` if the optional dep set grows; the type names here are
the public contract regardless.
"""

from __future__ import annotations

from typing import Any, List, Literal, Mapping, TypedDict

__all__ = [
    "TransferTarget",
    "Intent",
    "IntentSubmitResult",
    "IntentSimulationResult",
    "IntentCancelResult",
    "Decision",
    "DecisionWaitResult",
    "AuditTrail",
    "AuditEvent",
    "Counterparty",
    "RuntimeStatus",
    "Policy",
    "OperatorActionResult",
    "SecurityState",
]

IntentState = Literal[
    "submitted",
    "evaluating",
    "decided",
    "executing",
    "executed",
    "blocked",
    "cancelled",
    "expired",
]

DecisionOutcome = Literal[
    "auto_exec",
    "approval_required",
    "hold",
    "block",
]

RiskTier = Literal["low", "moderate", "elevated", "severe"]

SimulateReason = Literal["pre_submit_dry_run", "refresh", "operator_inspection"]


# --- Targets --------------------------------------------------------------


class _TransferTargetCounterparty(TypedDict, total=False):
    counterparty_id: str
    address_label_id: str


class _TransferTargetRaw(TypedDict, total=False):
    raw_address: str


# Tagged-union via TypedDict — callers pass either form. Python
# does not have a built-in tagged union for TypedDict, so the
# public alias is `Mapping[str, str]` for ergonomics.
TransferTarget = Mapping[str, str]


# --- Intent ---------------------------------------------------------------


class Intent(TypedDict, total=False):
    id: str
    agent_id: str
    source: Literal["agent", "user", "runtime"]
    kind: Literal["transfer", "swap", "scheduled_transfer", "defi_yield_deposit"]
    asset: str
    chain: str
    amount: str
    target: Mapping[str, Any]
    notes: str | None
    state: IntentState
    smart_account_id: str | None
    submitted_at: str
    payload_hash: str
    schema_version: str
    current_decision_id: str | None
    current_simulation_id: str | None
    current_trust_assessment_id: str | None
    current_execution_plan_id: str | None


class _Links(TypedDict, total=False):
    self: str
    replay: str


class IntentSubmitResult(TypedDict, total=False):
    intent_id: str
    state: IntentState
    idempotent_replay: bool
    intent: Intent
    links: _Links


class IntentSimulationResult(TypedDict, total=False):
    intent_id: str
    state: IntentState
    reason: SimulateReason
    refreshed: bool
    intent: Intent
    simulation: Mapping[str, Any]
    links: _Links


class IntentCancelResult(TypedDict, total=False):
    intent_id: str
    state: IntentState
    idempotent: bool
    reason: str
    intent: Intent
    links: _Links


# --- Decision -------------------------------------------------------------


class Decision(TypedDict, total=False):
    id: str
    intent_id: str
    outcome: DecisionOutcome
    risk_tier: RiskTier
    reasons: Mapping[str, Any]
    state: str
    current: bool
    decided_at: str
    decided_by: str
    approval_expires_at: str | None
    supersedes_id: str | None
    policy_snapshot_ref: Mapping[str, Any]


class DecisionWaitResult(TypedDict, total=False):
    """Return shape of ``wait_for_decision`` / ``waitForDecision``.

    ``decision`` is the latest decision envelope (``None`` if the
    intent's current decision id was missing). ``timed_out`` is
    ``True`` when the poll loop exited without the intent leaving
    ``:evaluating``.
    """

    intent: Intent
    decision: Decision | None
    timed_out: bool
    requires_approval: bool


# --- Audit / replay -------------------------------------------------------


class AuditEvent(TypedDict, total=False):
    id: str
    event_type: str
    actor: str
    actor_id: str | None
    subject_type: str
    subject_id: str
    correlation_id: str | None
    workspace_id: str | None
    ts: str
    before_ref: Mapping[str, Any]
    after_ref: Mapping[str, Any]


class AuditTrail(TypedDict, total=False):
    """Replay bundle returned by ``get_audit_trail``.

    Mirrors the bundle that ``Bank.Audit.replay/1`` produces and that
    the LiveView replay page renders. Permissive ``Mapping``s for
    each child collection — the SDK never strips fields.
    """

    intent: Intent
    policy_snapshot: List[Mapping[str, Any]]
    trust_assessments: List[Mapping[str, Any]]
    simulations: List[Mapping[str, Any]]
    decisions: List[Decision]
    plans: List[Mapping[str, Any]]
    audit: List[AuditEvent]
    screening_evidence: List[Mapping[str, Any]]
    stablecoin_route_evidence: List[Mapping[str, Any]]
    morpho_evidence: List[Mapping[str, Any]]
    swap_route_evidence: List[Mapping[str, Any]]
    matched_activities: List[Mapping[str, Any]]


# --- Counterparty / runtime / policy --------------------------------------


class Counterparty(TypedDict, total=False):
    id: str
    name: str
    trust_level: str
    addresses: List[Mapping[str, Any]]
    evidence: List[Mapping[str, Any]]
    created_at: str


class RuntimeStatus(TypedDict, total=False):
    status: str
    service: str
    version: str
    checks: Mapping[str, Any]


class Policy(TypedDict, total=False):
    id: str
    version: int
    status: str
    rules: List[Mapping[str, Any]]
    created_at: str


# --- Operator -------------------------------------------------------------


class OperatorActionResult(TypedDict, total=False):
    intent_id: str
    decision_id: str
    state: str
    reason: str | None


class SecurityState(TypedDict, total=False):
    paused: bool
    paused_at: str | None
    resumed_at: str | None
    actor_id: str | None
