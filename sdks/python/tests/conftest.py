"""Shared fixtures for the SDK test suite.

Tests are pure unit-level — no real network calls. We patch
``Transport._urlopen`` to inject mocked HTTP responses; that's the
single seam between the SDK and any HTTP server.
"""

from __future__ import annotations

import io
import json
import sys
from pathlib import Path
from typing import Any, Mapping

# Ensure the in-tree package is importable without an editable
# install. The package layout uses src/cryptobank/, so tests prepend
# the src/ directory to sys.path. This matches the contract that
# downstream `pip install -e .` would set up.
_SRC = Path(__file__).resolve().parent.parent / "src"
if str(_SRC) not in sys.path:
    sys.path.insert(0, str(_SRC))


class FakeResponse(io.BytesIO):
    """Stand-in for the object returned by ``urllib.request.urlopen``.

    Mimics the response contract the SDK transport reads:

      * iterable / readable bytes payload,
      * ``status`` int,
      * ``headers`` mapping with ``items()``.

    Acts as a context manager so ``with self._urlopen(req) as resp``
    works unchanged.
    """

    def __init__(
        self,
        *,
        status: int = 200,
        body: Mapping[str, Any] | list[Any] | None = None,
        raw: bytes | None = None,
        headers: Mapping[str, str] | None = None,
    ) -> None:
        if raw is None and body is not None:
            raw = json.dumps(body).encode("utf-8")
        super().__init__(raw or b"")
        self.status = status

        class _Headers:
            def __init__(self, hdrs: Mapping[str, str]) -> None:
                self._hdrs = dict(hdrs or {})

            def items(self) -> list[tuple[str, str]]:
                return list(self._hdrs.items())

            def get(self, key: str, default: Any = None) -> Any:
                return self._hdrs.get(key.lower(), default)

        merged = {"content-type": "application/json"}
        merged.update({k.lower(): v for k, v in (headers or {}).items()})
        self.headers = _Headers(merged)

    def __enter__(self) -> "FakeResponse":
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()


class CallRecorder:
    """Capture a single HTTP request for later assertions.

    Usage:

        recorder = CallRecorder([FakeResponse(body=...)])
        client = make_client(recorder)
        client.submit_transfer(...)
        assert recorder.calls[0].method == "POST"
    """

    def __init__(self, responses: list[Any]):
        self.responses = list(responses)
        self.calls: list[_Call] = []

    def __call__(self, request: Any, *, timeout: float | None = None) -> Any:
        if not self.responses:
            raise AssertionError("CallRecorder out of mocked responses")
        # `request` is a urllib.request.Request — pull just the
        # safe fields the tests assert on.
        body = request.data.decode("utf-8") if request.data else None
        headers = {k.lower(): v for k, v in request.header_items()}
        self.calls.append(
            _Call(
                method=request.get_method(),
                url=request.full_url,
                headers=headers,
                body=body,
                timeout=timeout,
            )
        )
        nxt = self.responses.pop(0)
        if isinstance(nxt, BaseException):
            raise nxt
        return nxt


class _Call:
    def __init__(
        self,
        *,
        method: str,
        url: str,
        headers: Mapping[str, str],
        body: str | None,
        timeout: float | None,
    ) -> None:
        self.method = method
        self.url = url
        self.headers = dict(headers)
        self.body = body
        self.json_body = json.loads(body) if body else None
        self.timeout = timeout

    @property
    def path(self) -> str:
        # Strip scheme + host so tests match against `/v1/...`.
        from urllib.parse import urlsplit

        parts = urlsplit(self.url)
        return parts.path + (("?" + parts.query) if parts.query else "")
