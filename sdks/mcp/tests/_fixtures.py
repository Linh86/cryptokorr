"""Shared test fixtures.

The fake opener replaces ``urllib.request.urlopen`` so HttpClient can
be exercised without real network calls. Each opener records the
requests it received so tests can assert on the wire shape.
"""

from __future__ import annotations

import io
import json
import sys
import urllib.error
from dataclasses import dataclass, field
from email.message import Message
from typing import Any, Callable, Mapping
from urllib.request import Request

import os as _os

_PROJECT_ROOT = _os.path.dirname(_os.path.dirname(_os.path.abspath(__file__)))
_SRC = _os.path.join(_PROJECT_ROOT, "src")
if _SRC not in sys.path:
    sys.path.insert(0, _SRC)


@dataclass
class RecordedRequest:
    method: str
    url: str
    headers: dict[str, str]
    body: bytes | None


@dataclass
class CannedResponse:
    status: int
    body: Any = b""
    headers: dict[str, str] = field(default_factory=dict)


@dataclass
class FakeOpener:
    responder: Callable[[RecordedRequest], CannedResponse]
    recorded: list[RecordedRequest] = field(default_factory=list)

    def __call__(self, request: Request, timeout: float) -> Any:  # noqa: D401
        body = request.data if isinstance(request.data, (bytes, bytearray)) else None
        recorded = RecordedRequest(
            method=request.get_method(),
            url=request.full_url,
            headers={k: v for k, v in request.header_items()},
            body=bytes(body) if body is not None else None,
        )
        self.recorded.append(recorded)
        canned = self.responder(recorded)
        body_bytes = _encode_body(canned.body)
        return _FakeUrlopenResult(canned.status, body_bytes, canned.headers)


def _encode_body(body: Any) -> bytes:
    if isinstance(body, bytes):
        return body
    if isinstance(body, str):
        return body.encode("utf-8")
    return json.dumps(body).encode("utf-8")


class _FakeHeaders(Message):
    def __init__(self, headers: Mapping[str, str]) -> None:
        super().__init__()
        for k, v in headers.items():
            self[k] = v


class _FakeUrlopenResult:
    def __init__(self, status: int, body: bytes, headers: Mapping[str, str]) -> None:
        self.status = status
        self.code = status
        self._stream = io.BytesIO(body)
        self.headers = _FakeHeaders(headers)

    def read(self) -> bytes:
        return self._stream.read()

    def __enter__(self) -> "_FakeUrlopenResult":
        return self

    def __exit__(self, *args: Any) -> None:  # noqa: D401
        self._stream.close()


def http_error_responder(status: int, body: Any, headers: Mapping[str, str] | None = None) -> Callable[[RecordedRequest], CannedResponse]:
    def _respond(_request: RecordedRequest) -> CannedResponse:
        # urllib.error.HTTPError is what urlopen raises for non-2xx.
        # The HttpClient catches it and reads .read(); FakeOpener returns
        # a CannedResponse instead so HttpClient's normal-path code
        # exercises both branches deterministically.
        del status, body, headers
        raise AssertionError("use raise_http_error_responder for HTTPError")

    return _respond


def raise_http_error_responder(status: int, body: Any, headers: Mapping[str, str] | None = None) -> Callable[[RecordedRequest], CannedResponse]:
    body_bytes = _encode_body(body)

    def _respond(request: RecordedRequest) -> CannedResponse:
        raise urllib.error.HTTPError(
            url=request.url,
            code=status,
            msg="error",
            hdrs=_FakeHeaders(headers or {}),
            fp=io.BytesIO(body_bytes),
        )

    return _respond


def static_responder(status: int, body: Any, headers: Mapping[str, str] | None = None) -> Callable[[RecordedRequest], CannedResponse]:
    def _respond(_request: RecordedRequest) -> CannedResponse:
        return CannedResponse(status=status, body=body, headers=dict(headers or {}))

    return _respond


def routed_responder(routes: dict[tuple[str, str], CannedResponse]) -> Callable[[RecordedRequest], CannedResponse]:
    """Match (METHOD, path) → CannedResponse. Path matched ignoring query."""

    def _respond(request: RecordedRequest) -> CannedResponse:
        path = request.url.split("?", 1)[0]
        for (method, candidate), response in routes.items():
            if request.method != method:
                continue
            if path.endswith(candidate):
                return response
        raise AssertionError(f"unrouted request {request.method} {request.url}")

    return _respond
