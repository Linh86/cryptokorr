"""Sync ``CryptoKorr`` client.

The SDK is currently sync-only. An ``AsyncCryptoKorr`` mirror is
deferred to a follow-up; the method names below are the canonical
contract for both forms.
"""

from __future__ import annotations

import os
import time
from typing import Any, Mapping

from . import errors
from ._http import Transport, _redact_key
from ._version import __version__
from .models import (
    AuditTrail,
    Counterparty,
    Decision,
    DecisionWaitResult,
    Intent,
    IntentCancelResult,
    IntentSimulationResult,
    IntentSubmitResult,
    OperatorActionResult,
    Policy,
    RuntimeStatus,
    SecurityState,
    SimulateReason,
    TransferTarget,
)

__all__ = ["CryptoKorr", "OperatorClient"]


_DEFAULT_BASE_URL = "http://localhost:4000"
_DEFAULT_TIMEOUT_MS = 15_000
_USER_AGENT = f"cryptokorr-py/{__version__}"


class CryptoKorr:
    """The CryptoKorr Python client.

    Construction:

        client = CryptoKorr(api_key="cb_...", base_url="https://api...")

    Or from environment:

        client = CryptoKorr.from_env()
        # Reads CRYPTOKORR_API_KEY (required), CRYPTOKORR_BASE_URL
        # (default http://localhost:4000), CRYPTOKORR_TIMEOUT_MS
        # (default 15_000).

    The API key is **never** echoed in ``repr()`` and **never**
    appears in any log line, error message, or test fixture
    formatted by the SDK.
    """

    def __init__(
        self,
        *,
        api_key: str,
        base_url: str = _DEFAULT_BASE_URL,
        timeout_ms: int = _DEFAULT_TIMEOUT_MS,
        user_agent: str | None = None,
    ) -> None:
        if not api_key or not isinstance(api_key, str):
            raise ValueError("api_key is required and must be a non-empty string")
        if not base_url or not isinstance(base_url, str):
            raise ValueError("base_url is required and must be a non-empty string")
        if timeout_ms <= 0:
            raise ValueError("timeout_ms must be > 0")

        self._api_key = api_key
        self._base_url = base_url.rstrip("/")
        self._transport = Transport(
            api_key=api_key,
            base_url=self._base_url,
            timeout_seconds=timeout_ms / 1000.0,
            user_agent=user_agent or _USER_AGENT,
        )
        self.operator = OperatorClient(self._transport)

    # -- Construction helpers --------------------------------------------

    @classmethod
    def from_env(cls) -> "CryptoKorr":
        """Build a client from environment variables.

        Reads:

          * ``CRYPTOKORR_API_KEY`` — required.
          * ``CRYPTOKORR_BASE_URL`` — defaults to
            ``http://localhost:4000``.
          * ``CRYPTOKORR_TIMEOUT_MS`` — defaults to ``15_000``.
        """
        api_key = os.environ.get("CRYPTOKORR_API_KEY")
        if not api_key:
            raise ValueError(
                "CRYPTOKORR_API_KEY env var is required for CryptoKorr.from_env()"
            )
        base_url = os.environ.get("CRYPTOKORR_BASE_URL", _DEFAULT_BASE_URL)
        timeout_ms_str = os.environ.get("CRYPTOKORR_TIMEOUT_MS")
        try:
            timeout_ms = int(timeout_ms_str) if timeout_ms_str else _DEFAULT_TIMEOUT_MS
        except ValueError as exc:
            raise ValueError(
                "CRYPTOKORR_TIMEOUT_MS must be an integer (milliseconds)"
            ) from exc
        return cls(api_key=api_key, base_url=base_url, timeout_ms=timeout_ms)

    # -- Hygiene ----------------------------------------------------------

    def __repr__(self) -> str:
        return (
            f"CryptoKorr(base_url={self._base_url!r}, "
            f"api_key={_redact_key(self._api_key)!r})"
        )

    # -- Intents ----------------------------------------------------------

    def submit_transfer(
        self,
        *,
        agent_id: str,
        asset: str,
        chain: str,
        amount: str,
        target: TransferTarget,
        notes: str | None = None,
        smart_account_id: str | None = None,
        source: str = "agent",
        idempotency_key: str | None = None,
    ) -> IntentSubmitResult:
        """Submit a transfer intent (`POST /v1/intents`).

        See ``docs/api/sdk-surface.md#submit_transfer-submitTransfer``
        for the full contract. Errors map to typed
        ``cryptokorr.APIError`` subclasses.
        """
        body: dict[str, Any] = {
            "idempotency_key": idempotency_key or self._transport._generate_idempotency_key(),
            "source": source,
            "agent_id": agent_id,
            "kind": "transfer",
            "asset": asset,
            "chain": chain,
            "amount": amount,
            "target": _normalise_target(target),
        }
        _put_optional(body, "notes", notes)
        _put_optional(body, "smart_account_id", smart_account_id)

        response = self._transport.request(
            "POST",
            "/v1/intents",
            json_body=body,
            idempotency_key=body["idempotency_key"],
        )
        return _ensure_dict(response.body)

    def submit_swap(
        self,
        *,
        agent_id: str,
        chain: str,
        source_asset: str,
        destination_asset: str,
        amount: str,
        smart_account_id: str | None = None,
        notes: str | None = None,
        source: str = "agent",
        idempotency_key: str | None = None,
    ) -> IntentSubmitResult:
        """Submit a swap intent (`POST /v1/intents` with ``kind: swap``).

        Phoenix's quote provider fills in route, calldata, slippage,
        and deadline; agents express *intent* (input + output asset
        + amount), not execution mechanics.
        """
        body: dict[str, Any] = {
            "idempotency_key": idempotency_key or self._transport._generate_idempotency_key(),
            "source": source,
            "agent_id": agent_id,
            "kind": "swap",
            # The /v1 contract reuses `asset` for the source asset
            # and uses the route's `destination_asset` server-side.
            "asset": source_asset,
            "chain": chain,
            "amount": amount,
            "destination_asset": destination_asset,
            # Swap intents have no caller-supplied target — the
            # smart account is the receiver.
            "target": {"smart_account": True},
        }
        _put_optional(body, "notes", notes)
        _put_optional(body, "smart_account_id", smart_account_id)

        response = self._transport.request(
            "POST",
            "/v1/intents",
            json_body=body,
            idempotency_key=body["idempotency_key"],
        )
        return _ensure_dict(response.body)

    def submit_allocate_idle_capital(
        self,
        *,
        agent_id: str,
        amount: str,
        vault_address: str,
        asset: str = "USDC",
        chain: str = "base-sepolia",
        smart_account_id: str | None = None,
        notes: str | None = None,
        source: str = "agent",
        idempotency_key: str | None = None,
    ) -> IntentSubmitResult:
        """Submit a Morpho ERC-4626 deposit intent.

        MVP Morpho is Sepolia-only and USDC-only. The vault address
        must be in the workspace's active Morpho allowlist (server
        verifies). Withdraw / redeem is operator-only; the SDK does
        not expose it.
        """
        # The public wire enum is `allocate_idle_capital` (per
        # `IntentSubmissionRequest.kind` in
        # `priv/openapi/openapi.json`). The Phoenix runtime maps
        # this string to the internal `:defi_yield_deposit` atom in
        # `Bank.Intents.normalize/1`; submitting the internal name
        # is rejected with `{:invalid, :kind}`. SDK callers always
        # see the public name on responses too — see
        # `docs/runbooks/morpho-deposits.md`.
        body: dict[str, Any] = {
            "idempotency_key": idempotency_key or self._transport._generate_idempotency_key(),
            "source": source,
            "agent_id": agent_id,
            "kind": "allocate_idle_capital",
            "asset": asset,
            "chain": chain,
            "amount": amount,
            "target": {"raw_address": vault_address},
        }
        _put_optional(body, "notes", notes)
        _put_optional(body, "smart_account_id", smart_account_id)

        response = self._transport.request(
            "POST",
            "/v1/intents",
            json_body=body,
            idempotency_key=body["idempotency_key"],
        )
        return _ensure_dict(response.body)

    def get_intent(self, intent_id: str) -> Intent:
        response = self._transport.request("GET", f"/v1/intents/{intent_id}")
        body = _ensure_dict(response.body)
        # The /v1 show response wraps the intent in an envelope.
        intent_payload = body.get("intent")
        if isinstance(intent_payload, Mapping):
            return dict(intent_payload)  # type: ignore[return-value]
        return body  # type: ignore[return-value]

    def simulate_intent(
        self,
        intent_id: str,
        *,
        reason: SimulateReason = "refresh",
        idempotency_key: str | None = None,
    ) -> IntentSimulationResult:
        body = {"reason": reason}
        response = self._transport.request(
            "POST",
            f"/v1/intents/{intent_id}/simulate",
            json_body=body,
            idempotency_key=idempotency_key,
        )
        return _ensure_dict(response.body)

    def cancel_intent(
        self,
        intent_id: str,
        *,
        reason: str,
        idempotency_key: str | None = None,
    ) -> IntentCancelResult:
        body = {"reason": reason}
        response = self._transport.request(
            "POST",
            f"/v1/intents/{intent_id}/cancel",
            json_body=body,
            idempotency_key=idempotency_key,
        )
        return _ensure_dict(response.body)

    def get_audit_trail(self, intent_id: str) -> AuditTrail:
        response = self._transport.request("GET", f"/v1/intents/{intent_id}/replay")
        return _ensure_dict(response.body)

    # -- Decisions --------------------------------------------------------

    def get_decision(self, decision_id: str) -> Decision:
        response = self._transport.request("GET", f"/v1/decisions/{decision_id}")
        body = _ensure_dict(response.body)
        decision_payload = body.get("decision") or body
        return _ensure_dict(decision_payload)

    def wait_for_decision(
        self,
        intent_id: str,
        *,
        timeout_seconds: float = 60.0,
        poll_interval_ms: int = 500,
    ) -> DecisionWaitResult:
        """Poll until an intent leaves ``:evaluating`` or the timeout fires.

        Approval-required is a **successful** result, not an
        exception: the returned ``DecisionWaitResult`` carries
        ``requires_approval=True`` and the latest ``Decision``.
        Agents should treat that as "waiting on a human" and not
        loop further.

        Raises ``cryptokorr.NotFoundError`` if the intent id is
        invalid; otherwise propagates whatever error the underlying
        polls raise (rate-limit, etc.).
        """
        if timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be > 0")
        if poll_interval_ms <= 0:
            raise ValueError("poll_interval_ms must be > 0")

        deadline = time.monotonic() + timeout_seconds
        intent: Intent = self.get_intent(intent_id)
        decision: Decision | None = None

        while True:
            state = intent.get("state")
            if state and state != "evaluating":
                decision_id = intent.get("current_decision_id")
                if isinstance(decision_id, str) and decision_id:
                    decision = self.get_decision(decision_id)
                requires_approval = bool(
                    decision and decision.get("outcome") == "approval_required"
                )
                return DecisionWaitResult(
                    intent=intent,
                    decision=decision,
                    timed_out=False,
                    requires_approval=requires_approval,
                )

            if time.monotonic() >= deadline:
                # Best-effort: still try to surface any decision that
                # exists, even if the intent is still :evaluating.
                decision_id = intent.get("current_decision_id")
                if isinstance(decision_id, str) and decision_id:
                    try:
                        decision = self.get_decision(decision_id)
                    except errors.NotFoundError:
                        decision = None
                return DecisionWaitResult(
                    intent=intent,
                    decision=decision,
                    timed_out=True,
                    requires_approval=False,
                )

            time.sleep(poll_interval_ms / 1000.0)
            intent = self.get_intent(intent_id)

    # -- Counterparties / runtime / policy --------------------------------

    def list_counterparties(self) -> list[Counterparty]:
        response = self._transport.request("GET", "/v1/counterparties")
        body = _ensure_dict(response.body)
        items = body.get("counterparties") or body.get("items") or []
        if not isinstance(items, list):
            return []
        return list(items)  # type: ignore[return-value]

    def get_runtime_status(self) -> RuntimeStatus:
        # /v1/health/deep is unauthenticated but the SDK still sends
        # the bearer for telemetry attribution. The server tolerates
        # it.
        response = self._transport.request("GET", "/v1/health/deep")
        return _ensure_dict(response.body)

    def get_policy(self, policy_id: str | None = None) -> Policy | list[Policy]:
        if policy_id:
            response = self._transport.request("GET", f"/v1/policies/{policy_id}")
            body = _ensure_dict(response.body)
            policy = body.get("policy") or body
            return _ensure_dict(policy)

        response = self._transport.request("GET", "/v1/policies")
        body = _ensure_dict(response.body)
        items = body.get("policies") or body.get("items") or []
        if not isinstance(items, list):
            return []
        return list(items)  # type: ignore[return-value]


class OperatorClient:
    """Operator-only writes.

    Exposed under ``client.operator``. Calling these with an
    ``agent``-role API key surfaces ``insufficient_role`` from the
    server; the SDK's separate namespace is the loud-defaults design
    so accidental misuse from an agent context is obvious.
    """

    def __init__(self, transport: Transport) -> None:
        self._transport = transport

    def list_pending_approvals(self) -> list[Decision]:
        response = self._transport.request("GET", "/v1/approvals")
        body = _ensure_dict(response.body)
        items = body.get("pending") or body.get("items") or []
        if not isinstance(items, list):
            return []
        return list(items)  # type: ignore[return-value]

    def approve_decision(
        self,
        decision_id: str,
        *,
        actor_id: str,
        reason: str | None = None,
        idempotency_key: str | None = None,
    ) -> OperatorActionResult:
        body: dict[str, Any] = {"actor_id": actor_id}
        _put_optional(body, "reason", reason)
        response = self._transport.request(
            "POST",
            f"/v1/approvals/{decision_id}/approve",
            json_body=body,
            idempotency_key=idempotency_key,
        )
        return _ensure_dict(response.body)

    def reject_decision(
        self,
        decision_id: str,
        *,
        actor_id: str,
        reason: str | None = None,
        idempotency_key: str | None = None,
    ) -> OperatorActionResult:
        body: dict[str, Any] = {"actor_id": actor_id}
        _put_optional(body, "reason", reason)
        response = self._transport.request(
            "POST",
            f"/v1/approvals/{decision_id}/reject",
            json_body=body,
            idempotency_key=idempotency_key,
        )
        return _ensure_dict(response.body)

    def pause_runtime(
        self,
        *,
        idempotency_key: str | None = None,
    ) -> SecurityState:
        # /v1/security/* is on the stricter chain-action cap (5/60s)
        # and must NOT be auto-retried. Transport handles that.
        response = self._transport.request(
            "POST",
            "/v1/security/pause",
            json_body={},
            idempotency_key=idempotency_key,
        )
        return _ensure_dict(response.body)

    def resume_runtime(
        self,
        *,
        idempotency_key: str | None = None,
    ) -> SecurityState:
        response = self._transport.request(
            "POST",
            "/v1/security/resume",
            json_body={},
            idempotency_key=idempotency_key,
        )
        return _ensure_dict(response.body)


# --- helpers -------------------------------------------------------------


def _put_optional(body: dict[str, Any], key: str, value: Any) -> None:
    if value is not None:
        body[key] = value


def _normalise_target(target: TransferTarget) -> Mapping[str, Any]:
    """Pass-through normaliser for transfer targets.

    Accepts the same tagged-union shape ``IntentTarget`` defines on
    the wire: ``{counterparty_id, address_label_id?}`` or
    ``{raw_address}``. The server validates the exclusivity; the SDK
    only forwards the dict.
    """
    if not isinstance(target, Mapping):
        raise TypeError(
            "target must be a mapping with `counterparty_id` (and optional "
            "`address_label_id`) or `raw_address`"
        )
    return dict(target)


def _ensure_dict(value: Any) -> dict[str, Any]:
    if isinstance(value, Mapping):
        return dict(value)
    return {}
