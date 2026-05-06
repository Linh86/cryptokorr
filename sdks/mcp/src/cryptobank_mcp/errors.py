"""Map Phoenix HTTP errors to MCP tool errors.

The wire shape mirrors ``docs/api/error-codes.md``: stable ``code``,
operator-readable ``message``, optional ``hint``, ``retryable`` boolean.
This module never reads the API key out of any structure it processes,
so it cannot leak secrets in formatted output.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Mapping


@dataclass(frozen=True)
class ToolError:
    code: str
    message: str
    retryable: bool
    hint: str | None = None
    details: Mapping[str, Any] | None = None
    http_status: int | None = None

    def to_payload(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "code": self.code,
            "message": self.message,
            "retryable": self.retryable,
        }
        if self.hint:
            payload["hint"] = self.hint
        if self.details:
            payload["details"] = dict(self.details)
        if self.http_status is not None:
            payload["http_status"] = self.http_status
        return payload


_RETRYABLE_HTTP = frozenset({429, 502, 503, 504})

_FALLBACK_MESSAGES = {
    400: "Malformed request.",
    401: "Authentication failed.",
    403: "Caller is not allowed to perform this action.",
    404: "Resource not found.",
    409: "Conflict with current resource state.",
    422: "Validation failed.",
    429: "Rate-limited.",
    500: "Server error.",
    501: "Not implemented.",
    502: "Upstream provider failure.",
    503: "Service unavailable.",
    504: "Upstream timeout.",
}

_FALLBACK_CODES = {
    400: "invalid_body",
    401: "missing_authorization",
    403: "forbidden",
    404: "not_found",
    409: "wrong_state",
    422: "invalid_body",
    429: "rate_limited",
    500: "service_unavailable",
    501: "not_implemented",
    502: "upstream_unavailable",
    503: "service_unavailable",
    504: "upstream_timeout",
}


def map_http_error(status: int, body: bytes | str | None) -> ToolError:
    """Decode a non-2xx Phoenix response into a ``ToolError``.

    Phoenix always returns the ``ErrorEnvelope`` shape on non-2xx, but
    some upstream proxies (or 502/504 from a load balancer) may return
    plain text. Fall back to status-derived defaults in that case.
    """
    parsed = _parse_envelope(body)
    fallback_code = _FALLBACK_CODES.get(status, "service_unavailable")
    fallback_message = _FALLBACK_MESSAGES.get(status, "Unexpected error.")
    fallback_retryable = status in _RETRYABLE_HTTP

    if parsed is None:
        return ToolError(
            code=fallback_code,
            message=fallback_message,
            retryable=fallback_retryable,
            http_status=status,
        )

    code = parsed.get("code") or fallback_code
    message = parsed.get("message") or fallback_message
    hint = parsed.get("hint") or None
    details = parsed.get("details") or None
    retryable = parsed.get("retryable")
    if not isinstance(retryable, bool):
        retryable = fallback_retryable

    return ToolError(
        code=str(code),
        message=str(message),
        retryable=bool(retryable),
        hint=str(hint) if hint else None,
        details=details if isinstance(details, Mapping) else None,
        http_status=status,
    )


def map_transport_error(exc: BaseException) -> ToolError:
    """Map a transport-layer exception (DNS, connect, timeout) to ToolError.

    These never carry an HTTP status. We classify timeouts as retryable
    and everything else as a transport-unreachable error.
    """
    name = type(exc).__name__
    text = str(exc) or name
    safe = _strip_secret_like(text)
    if "timeout" in name.lower() or "timeout" in text.lower():
        return ToolError(
            code="upstream_timeout",
            message=f"Request to CryptoBank API timed out: {safe}",
            retryable=True,
        )
    return ToolError(
        code="service_unavailable",
        message=f"Could not reach CryptoBank API: {safe}",
        retryable=True,
    )


def _parse_envelope(body: bytes | str | None) -> dict[str, Any] | None:
    if body is None:
        return None
    if isinstance(body, bytes):
        try:
            text = body.decode("utf-8")
        except UnicodeDecodeError:
            return None
    else:
        text = body
    text = text.strip()
    if not text:
        return None
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError:
        return None
    if not isinstance(parsed, dict):
        return None
    error = parsed.get("error")
    if isinstance(error, dict):
        return error
    return None


import re as _re

_CB_KEY_RE = _re.compile(r"cb_[A-Za-z0-9]{8,}")
_BEARER_RE = _re.compile(r"(?i)bearer[\s=:]+[A-Za-z0-9._-]+")


def _strip_secret_like(text: str) -> str:
    """Best-effort scrub of substrings that look like API keys.

    Two passes: replace any ``cb_<8+ alphanumerics>`` with the safe
    8-char prefix + ellipsis, and any ``Bearer <token>`` sequence with
    the bare word ``Bearer``. Catches both whitespace-separated tokens
    and substrings embedded in ``key=value`` style strings.
    """
    scrubbed = _CB_KEY_RE.sub(lambda m: m.group(0)[:11] + "…", text)
    scrubbed = _BEARER_RE.sub("Bearer", scrubbed)
    return scrubbed
