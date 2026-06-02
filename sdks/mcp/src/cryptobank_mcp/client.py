"""Internal HTTP client to the Phoenix ``/v1`` API.

This is intentionally tiny — it exists so the MCP server can ship
without depending on the (unmerged) Python SDK from #479. Once that
SDK lands, this module can be replaced with the SDK's transport.

Stdlib-only (``urllib``) so the package has zero install dependencies.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Callable, Mapping
from urllib.parse import urlencode

from cryptokorr_mcp import __version__ as _VERSION

_USER_AGENT = f"cryptokorr-mcp/{_VERSION}"


@dataclass(frozen=True)
class HttpResponse:
    status: int
    body: bytes
    headers: Mapping[str, str]

    def json(self) -> Any:
        if not self.body:
            return None
        return json.loads(self.body.decode("utf-8"))


Opener = Callable[[urllib.request.Request, float], "urllib.request.addinfourl"]


class HttpClient:
    """Minimal Phoenix client — used by tool handlers.

    Auth header is added on every request. The api key is stored as a
    string but never logged or echoed in any of this class's methods.
    """

    def __init__(
        self,
        *,
        api_key: str,
        base_url: str,
        timeout_seconds: float,
        opener: Opener | None = None,
    ) -> None:
        self._api_key = api_key
        self._base_url = base_url.rstrip("/")
        self._timeout = timeout_seconds
        self._opener = opener or _default_opener

    def get(
        self,
        path: str,
        *,
        params: Mapping[str, Any] | None = None,
    ) -> HttpResponse:
        url = self._url(path, params)
        request = urllib.request.Request(url, method="GET")
        return self._send(request)

    def post(
        self,
        path: str,
        *,
        body: Mapping[str, Any] | None = None,
        idempotency_key: str | None = None,
    ) -> HttpResponse:
        url = self._url(path, None)
        payload = b"" if body is None else json.dumps(body).encode("utf-8")
        request = urllib.request.Request(url, data=payload, method="POST")
        request.add_header("Content-Type", "application/json")
        if idempotency_key:
            request.add_header("Idempotency-Key", idempotency_key)
        return self._send(request)

    def _url(self, path: str, params: Mapping[str, Any] | None) -> str:
        if not path.startswith("/"):
            path = "/" + path
        url = f"{self._base_url}{path}"
        if params:
            cleaned = {k: v for k, v in params.items() if v is not None}
            if cleaned:
                url = f"{url}?{urlencode(cleaned, doseq=True)}"
        return url

    def _send(self, request: urllib.request.Request) -> HttpResponse:
        request.add_header("Authorization", f"Bearer {self._api_key}")
        request.add_header("Accept", "application/json")
        request.add_header("User-Agent", _USER_AGENT)
        try:
            with self._opener(request, self._timeout) as resp:
                body = resp.read()
                return HttpResponse(
                    status=resp.status,
                    body=body,
                    headers={k: v for k, v in resp.headers.items()},
                )
        except urllib.error.HTTPError as exc:
            try:
                body = exc.read() if exc.fp is not None else b""
                headers = (
                    {k: v for k, v in exc.headers.items()} if exc.headers else {}
                )
            finally:
                exc.close()
            return HttpResponse(status=exc.code, body=body, headers=headers)


def _default_opener(
    request: urllib.request.Request,
    timeout: float,
) -> "urllib.request.addinfourl":
    return urllib.request.urlopen(request, timeout=timeout)
