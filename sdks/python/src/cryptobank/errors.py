"""Typed exception hierarchy for CryptoBank API errors.

Every non-2xx ``/v1/*`` response is mapped to a typed ``APIError``
subclass keyed off the wire ``error.code``. The hierarchy mirrors the
table in ``docs/api/error-codes.md``.

Programmatic callers branch on ``error.code`` (the stable
fixed-allowlist string), not on ``error.message`` — message and hint
are operator copy and may be reworded across releases.
"""

from __future__ import annotations

from typing import Any, Mapping

__all__ = [
    # Base.
    "APIError",
    # 401 / 403.
    "AuthenticationError",
    "AuthorizationError",
    # 404.
    "NotFoundError",
    # 409.
    "ConflictError",
    "IdempotencyConflictError",
    "WrongStateError",
    # 422.
    "ValidationError",
    "SwapSafetyError",
    "MorphoSafetyError",
    # 429.
    "RateLimitError",
    # 502 / 503 / 504.
    "ServiceUnavailableError",
    "WorkspacePausedError",
    "ChainPausedError",
    "UpstreamError",
    # Helper.
    "from_envelope",
]


class APIError(Exception):
    """Base exception for every non-2xx response from `/v1/*`.

    All API errors carry the wire envelope fields (``code``,
    ``message``, ``hint``, ``retryable``, optional ``details``) plus
    the HTTP ``status`` and the ``Retry-After`` value the server may
    have advised.

    The string form NEVER includes the API key or any header value.
    """

    code: str
    message: str
    hint: str | None
    retryable: bool
    status: int
    details: Mapping[str, Any] | None
    retry_after_seconds: int | None

    def __init__(
        self,
        *,
        code: str,
        message: str,
        hint: str | None = None,
        retryable: bool = False,
        status: int = 0,
        details: Mapping[str, Any] | None = None,
        retry_after_seconds: int | None = None,
    ) -> None:
        self.code = code
        self.message = message
        self.hint = hint
        self.retryable = retryable
        self.status = status
        self.details = details
        self.retry_after_seconds = retry_after_seconds
        super().__init__(self._format())

    def _format(self) -> str:
        parts = [f"{self.status} {self.code}: {self.message}"]
        if self.hint:
            parts.append(f"(hint: {self.hint})")
        return " ".join(parts)

    def __repr__(self) -> str:  # pragma: no cover — trivial
        return (
            f"{type(self).__name__}(code={self.code!r}, status={self.status}, "
            f"retryable={self.retryable})"
        )


# --- 401 / 403 -----------------------------------------------------------


class AuthenticationError(APIError):
    """401 — credential problem.

    Fired for ``missing_authorization``, ``invalid_authorization_scheme``,
    ``invalid_credentials``, and the rare ``unauthenticated``
    config-bug surface. Never retryable from the client side; rotate
    the API key or restart with a valid one.
    """


class AuthorizationError(APIError):
    """403 — credential is valid but role / scope is insufficient.

    Fired for ``insufficient_role`` and ``forbidden``.
    """


# --- 404 -----------------------------------------------------------------


class NotFoundError(APIError):
    """404 — subject does not exist OR is in another workspace.

    The SDK never distinguishes these two cases; the server
    suppresses cross-workspace-existence leakage by collapsing both
    to ``not_found``.
    """


# --- 409 -----------------------------------------------------------------


class ConflictError(APIError):
    """409 — generic state conflict.

    Most callers will see ``IdempotencyConflictError`` or
    ``WrongStateError`` (subclasses) instead.
    """


class IdempotencyConflictError(ConflictError):
    """409 ``idempotency_conflict`` — same key, different body.

    The wire ``hint`` carries the prior intent id. Use a fresh
    ``Idempotency-Key`` for a new write, or resend the original body
    to replay the existing intent.
    """


class WrongStateError(ConflictError):
    """409 ``wrong_state`` / ``not_safe_to_abort``.

    The resource is not in a state that allows the requested
    transition (e.g. cancelling an ``:executing`` intent). Refetch
    the resource and reconsider.
    """


# --- 422 -----------------------------------------------------------------


class ValidationError(APIError):
    """422 — request body validation failed.

    Includes ``invalid_body``, ``validation_error``, ``invalid_amount``,
    ``invalid_target``, ``invalid_reason``, ``invalid_request``, plus
    workspace / chain capability codes (``unsupported_chain``,
    ``mainnet_disabled``, ``unsupported_asset``,
    ``morpho_chain_not_supported``) and smart-account-selector codes
    (``smart_account_chain_mismatch``, ``smart_account_required``).

    The ``details`` field, when present, carries a changeset-style
    field-by-field error map.
    """


class SwapSafetyError(ValidationError):
    """422 swap dispatch safety — every ``swap_*`` failure atom.

    See ``docs/api/error-codes.md`` for the full allowlist
    (``swap_chain_not_supported``, ``swap_amount_invalid``,
    ``swap_deadline_expired``, ``swap_native_value_disallowed``,
    etc.).
    """


class MorphoSafetyError(ValidationError):
    """422 Morpho dispatch safety — every ``morpho_*`` failure atom.

    Includes ``morpho_vault_not_allowlisted``,
    ``morpho_snapshot_missing``, ``morpho_snapshot_expired``,
    ``morpho_snapshot_drifted``, ``morpho_steps_missing``,
    ``morpho_asset_not_supported``,
    ``morpho_withdraw_invalid_amount``,
    ``morpho_withdraw_snapshot_invalid``, ``operator_role_required``.
    """


# --- 429 -----------------------------------------------------------------


class RateLimitError(APIError):
    """429 ``rate_limited`` — the request was throttled.

    Honour ``retry_after_seconds`` (mirrors the wire ``Retry-After``
    header). Three buckets exist: per-key (60/60s), per-workspace
    (600/60s), and the chain-action cap (5/60s on
    ``/v1/security/*``). The auth-failure bucket (10/300s on bad
    ``Authorization``) returns the same code with a longer
    ``Retry-After``.
    """


# --- 502 / 503 / 504 -----------------------------------------------------


class ServiceUnavailableError(APIError):
    """503 — service-level unavailability.

    Subclasses cover the specific reasons.
    """


class WorkspacePausedError(ServiceUnavailableError):
    """503 ``workspace_paused`` / ``runtime_paused`` / ``chain_paused``.

    Long backoff; an operator must call ``/v1/security/resume``
    (or the relevant per-chain / per-agent-key resume endpoint)
    before writes flow.
    """


class ChainPausedError(ServiceUnavailableError):
    """503 ``chain_paused`` — workspace's chain is paused (#228)."""


class UpstreamError(ServiceUnavailableError):
    """502 / 504 — provider (quote / RPC / adapter) failed or timed out.

    Fired for ``upstream_unavailable``, ``upstream_timeout``,
    ``service_unavailable``. The default retry posture is
    exponential backoff capped at ~30s.
    """


# --- Mapping -------------------------------------------------------------

# Mapping rules:
#   1. The wire `error.code` is the primary discriminator.
#   2. When `code` is unrecognised, fall back to the HTTP status class.
#   3. The mapping is intentionally exhaustive across the documented
#      taxonomy in `docs/api/error-codes.md` so a future code that
#      lands without an SDK update still surfaces as the right
#      base class.

_CODE_CLASSES: dict[str, type[APIError]] = {
    # 401.
    "missing_authorization": AuthenticationError,
    "invalid_authorization_scheme": AuthenticationError,
    "invalid_credentials": AuthenticationError,
    "unauthenticated": AuthenticationError,
    # 403.
    "insufficient_role": AuthorizationError,
    "forbidden": AuthorizationError,
    "operator_role_required": MorphoSafetyError,
    # 404.
    "not_found": NotFoundError,
    "smart_account_not_found": NotFoundError,
    # 409.
    "idempotency_conflict": IdempotencyConflictError,
    "wrong_state": WrongStateError,
    "not_safe_to_abort": WrongStateError,
    # 422 — generic validation.
    "invalid_body": ValidationError,
    "validation_error": ValidationError,
    "invalid_amount": ValidationError,
    "invalid_target": ValidationError,
    "invalid_reason": ValidationError,
    "invalid_request": ValidationError,
    # 422 — workspace / chain capability.
    "unsupported_chain": ValidationError,
    "mainnet_disabled": ValidationError,
    "unsupported_asset": ValidationError,
    "morpho_chain_not_supported": ValidationError,
    # 422 — smart-account selector.
    "smart_account_chain_mismatch": ValidationError,
    "smart_account_required": ValidationError,
    # 429.
    "rate_limited": RateLimitError,
    # 503 — pause family.
    "workspace_paused": WorkspacePausedError,
    "chain_paused": ChainPausedError,
    "runtime_paused": WorkspacePausedError,
    "service_unavailable": ServiceUnavailableError,
    # 502 / 504.
    "upstream_unavailable": UpstreamError,
    "upstream_timeout": UpstreamError,
    # 501.
    "not_implemented": APIError,
}


def _swap_class(code: str) -> type[APIError] | None:
    if code.startswith("swap_"):
        return SwapSafetyError
    return None


def _morpho_class(code: str) -> type[APIError] | None:
    if code.startswith("morpho_"):
        return MorphoSafetyError
    return None


def _status_fallback(status: int) -> type[APIError]:
    if status == 401:
        return AuthenticationError
    if status == 403:
        return AuthorizationError
    if status == 404:
        return NotFoundError
    if status == 409:
        return ConflictError
    if status == 422:
        return ValidationError
    if status == 429:
        return RateLimitError
    if status in (502, 504):
        return UpstreamError
    if status == 503:
        return ServiceUnavailableError
    return APIError


def from_envelope(
    *,
    status: int,
    envelope: Mapping[str, Any],
    retry_after_seconds: int | None = None,
) -> APIError:
    """Build the typed ``APIError`` for a wire error envelope.

    ``envelope`` is the parsed ``error`` object from the wire body,
    e.g. ``{"code": "rate_limited", "message": "...", "retryable":
    True}``. Missing fields are tolerated — ``code`` defaults to a
    derived ``http_<status>`` and ``message`` to the empty string —
    so a malformed adapter response cannot crash the caller's
    error path.
    """
    code = str(envelope.get("code") or f"http_{status}")
    message = str(envelope.get("message") or "")
    hint_value = envelope.get("hint")
    hint = str(hint_value) if hint_value is not None else None
    retryable = bool(envelope.get("retryable", False))
    details_value = envelope.get("details")
    details: Mapping[str, Any] | None
    if isinstance(details_value, Mapping):
        details = details_value
    else:
        details = None

    cls = (
        _swap_class(code)
        or _morpho_class(code)
        or _CODE_CLASSES.get(code)
        or _status_fallback(status)
    )

    return cls(
        code=code,
        message=message,
        hint=hint,
        retryable=retryable,
        status=status,
        details=details,
        retry_after_seconds=retry_after_seconds,
    )
