"""Internal HTTP transport for the SDK.

Zero runtime dependencies — uses ``urllib.request`` from the stdlib so
``pip install -e sdks/python`` is trivial and free of dependency
resolution. The only externally-visible class is ``Transport``,
constructed by ``Cryptobank.__init__``; tests patch
``Transport._urlopen`` to inject mocked HTTP responses.

Posture (see ``docs/api/sdk-surface.md``):

  * Bearer auth via ``Authorization: Bearer <api_key>``.
  * Auto-generated ``Idempotency-Key`` for write methods when the
    caller does not supply one.
  * Retries only when the server marks the error ``retryable: true``;
    honours ``Retry-After``; exponential backoff capped at 30s; total
    wall-clock bounded at ``timeout * 4``.
  * The stricter chain-action cap on ``/v1/security/*`` is NOT
    auto-retried — the caller wants the error surface, not silent
    waiting.
  * The API key NEVER appears in any log line, error message, or
    ``repr`` output.
"""

from __future__ import annotations

import json
import logging
import secrets
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Mapping
from urllib.parse import urljoin

from . import errors
from ._version import __version__

__all__ = ["Transport", "Response"]


_LOG = logging.getLogger("cryptobank")


def _redact_key(key: str) -> str:
    """Render a short non-secret prefix for logs.

    Always shows at most 4 characters of the key body (after the
    ``cb_`` prefix) so a full key is never echoed, regardless of
    length. Keys too short to truncate safely render as
    ``<redacted>``.
    """
    if not key:
        return "<empty>"
    # The key body is everything after the canonical "cb_" prefix.
    # We want to expose at most 4 body characters in repr / logs so
    # operators can correlate which key the SDK is using without
    # ever echoing the full secret.
    if key.startswith("cb_") and len(key) >= 12:
        return key[:7] + "…"
    if len(key) >= 12:
        return key[:6] + "…"
    return "<redacted>"


@dataclass
class Response:
    """Parsed response envelope returned by ``Transport.request``."""

    status: int
    body: Any  # Parsed JSON or None for empty 204 responses.
    headers: Mapping[str, str] = field(default_factory=dict)


@dataclass
class Transport:
    """HTTP transport bound to a single ``Cryptobank`` client."""

    api_key: str
    base_url: str
    timeout_seconds: float
    user_agent: str
    max_retries: int = 4

    # Methods that need an `Idempotency-Key` when the caller does
    # not supply one. Mirrors the wire convention in
    # `docs/api/error-codes.md`.
    _IDEMPOTENT_METHODS = frozenset({"POST", "PATCH", "PUT", "DELETE"})

    # Paths where automatic retry on 429 must NOT happen — the
    # operator-cap throttling means the caller wants the error
    # surface immediately, not silent waiting. See sdk-surface.md.
    _NO_AUTO_RETRY_PATH_PREFIXES = ("/v1/security/",)

    def request(
        self,
        method: str,
        path: str,
        *,
        json_body: Mapping[str, Any] | None = None,
        idempotency_key: str | None = None,
        query: Mapping[str, str] | None = None,
        retryable: bool = True,
    ) -> Response:
        """Issue an HTTP request and return the parsed response.

        Raises ``cryptobank.APIError`` (or a subclass) on non-2xx
        responses. Retries on ``retryable=True`` codes when
        ``retryable`` is True (the call-site default); the chain-
        action path family is excluded automatically.
        """
        method = method.upper()
        url = self._build_url(path, query)
        body_bytes = self._encode_body(json_body)

        headers = self._base_headers()
        headers["Authorization"] = f"Bearer {self.api_key}"
        if body_bytes is not None:
            headers["Content-Type"] = "application/json"
        if method in self._IDEMPOTENT_METHODS and body_bytes is not None:
            headers["Idempotency-Key"] = idempotency_key or self._generate_idempotency_key()

        retries_allowed = retryable and not any(
            path.startswith(prefix) for prefix in self._NO_AUTO_RETRY_PATH_PREFIXES
        )

        attempt = 0
        deadline = time.monotonic() + self.timeout_seconds * (self.max_retries + 1)
        while True:
            attempt += 1
            try:
                response = self._send(method, url, headers, body_bytes)
            except (urllib.error.URLError, ConnectionError, TimeoutError) as exc:
                # Transport-level failures map to UpstreamError so
                # callers can branch on the typed exception.
                if retries_allowed and attempt <= self.max_retries and time.monotonic() < deadline:
                    self._sleep_for_retry(attempt, retry_after=None)
                    continue
                raise errors.UpstreamError(
                    code="upstream_unavailable",
                    message=f"network failure: {self._safe_reason(exc)}",
                    retryable=True,
                    status=0,
                ) from exc

            if 200 <= response.status < 300:
                return response

            # Non-2xx → typed exception.
            api_error = self._build_error(response)
            should_retry = (
                retries_allowed
                and api_error.retryable
                and attempt <= self.max_retries
                and time.monotonic() < deadline
            )
            if not should_retry:
                raise api_error

            self._sleep_for_retry(attempt, retry_after=api_error.retry_after_seconds)
            continue

    # --- internals -------------------------------------------------------

    def _build_url(self, path: str, query: Mapping[str, str] | None) -> str:
        if not path.startswith("/"):
            path = "/" + path
        url = urljoin(self.base_url + "/", path.lstrip("/"))
        if query:
            from urllib.parse import urlencode

            sep = "&" if "?" in url else "?"
            url = f"{url}{sep}{urlencode(query)}"
        return url

    def _encode_body(self, json_body: Mapping[str, Any] | None) -> bytes | None:
        if json_body is None:
            return None
        return json.dumps(json_body, separators=(",", ":"), sort_keys=True).encode("utf-8")

    def _base_headers(self) -> dict[str, str]:
        return {
            "Accept": "application/json",
            "User-Agent": self.user_agent,
        }

    def _generate_idempotency_key(self) -> str:
        # 32 hex chars — equivalent to a UUID v4 in randomness terms
        # without the hyphen formatting.
        return secrets.token_hex(16)

    def _send(
        self, method: str, url: str, headers: Mapping[str, str], body: bytes | None
    ) -> Response:
        # Method override on `urllib.request.Request` is set via
        # `method=` kwarg; setting it on the constructor is the
        # recommended pattern for non-GET/POST verbs.
        req = urllib.request.Request(url=url, data=body, headers=dict(headers), method=method)

        # The urlopen call is the integration point tests patch.
        try:
            with self._urlopen(req, timeout=self.timeout_seconds) as resp:
                raw = resp.read() or b""
                # `resp.headers` is an email.message.Message; flatten
                # to a plain dict so the SDK never leaks an internal
                # type at the public boundary.
                hdrs = {k.lower(): v for k, v in resp.headers.items()}
                return Response(
                    status=resp.status,
                    body=self._parse_body(raw, hdrs.get("content-type", "")),
                    headers=hdrs,
                )
        except urllib.error.HTTPError as exc:
            # Non-2xx responses raise HTTPError with a body we still
            # need to parse. Re-emit as a synthetic Response so the
            # main loop's error path is uniform.
            raw = exc.read() or b""
            hdrs = {k.lower(): v for k, v in (exc.headers or {}).items()}
            return Response(
                status=exc.code,
                body=self._parse_body(raw, hdrs.get("content-type", "")),
                headers=hdrs,
            )

    def _urlopen(self, request: urllib.request.Request, *, timeout: float) -> Any:
        """Thin wrapper around ``urllib.request.urlopen`` so tests can patch it."""
        return urllib.request.urlopen(request, timeout=timeout)

    def _parse_body(self, raw: bytes, content_type: str) -> Any:
        if not raw:
            return None
        if "application/json" in content_type or raw.startswith(b"{") or raw.startswith(b"["):
            try:
                return json.loads(raw.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                return None
        try:
            return raw.decode("utf-8")
        except UnicodeDecodeError:
            return None

    def _build_error(self, response: Response) -> errors.APIError:
        envelope: Mapping[str, Any]
        if isinstance(response.body, Mapping) and isinstance(response.body.get("error"), Mapping):
            envelope = response.body["error"]
        else:
            envelope = {}

        retry_after = self._parse_retry_after(response.headers.get("retry-after"))
        return errors.from_envelope(
            status=response.status,
            envelope=envelope,
            retry_after_seconds=retry_after,
        )

    def _parse_retry_after(self, value: str | None) -> int | None:
        if not value:
            return None
        try:
            return max(int(value), 0)
        except (ValueError, TypeError):
            return None

    def _sleep_for_retry(self, attempt: int, *, retry_after: int | None) -> None:
        if retry_after is not None:
            delay = max(retry_after, 0)
        else:
            # Exponential backoff with a 30s cap. Attempt 1 → 0.5s,
            # 2 → 1s, 3 → 2s, 4 → 4s, …
            delay = min(0.25 * (2**attempt), 30.0)
        time.sleep(delay)

    @staticmethod
    def _safe_reason(exc: BaseException) -> str:
        """Return the exception's ``reason`` or its class name.

        Defensive against ``URLError`` reasons that contain socket
        addresses or other non-secret-but-noisy text. We surface the
        category, never the full struct.
        """
        reason = getattr(exc, "reason", None)
        if isinstance(reason, BaseException):
            return type(reason).__name__
        if isinstance(reason, str):
            return reason
        return type(exc).__name__
