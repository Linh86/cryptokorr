"""Tests for ``cryptokorr_mcp.errors``."""

from __future__ import annotations

import json
import unittest

from tests._fixtures import _PROJECT_ROOT  # noqa: F401  (sys.path side effect)

from cryptokorr_mcp.errors import (
    ToolError,
    map_http_error,
    map_transport_error,
)


class MapHttpErrorTests(unittest.TestCase):
    def test_envelope_passthrough(self) -> None:
        body = json.dumps({
            "error": {
                "code": "rate_limited",
                "message": "Too many requests.",
                "hint": "Honour Retry-After.",
                "retryable": True,
            }
        }).encode()
        err = map_http_error(429, body)
        self.assertEqual(err.code, "rate_limited")
        self.assertEqual(err.message, "Too many requests.")
        self.assertTrue(err.retryable)
        self.assertEqual(err.hint, "Honour Retry-After.")
        self.assertEqual(err.http_status, 429)

    def test_envelope_with_details(self) -> None:
        body = json.dumps({
            "error": {
                "code": "invalid_body",
                "message": "Validation failed.",
                "retryable": False,
                "details": {"amount": ["must be positive"]},
            }
        }).encode()
        err = map_http_error(422, body)
        self.assertEqual(err.code, "invalid_body")
        self.assertEqual(err.details, {"amount": ["must be positive"]})

    def test_no_envelope_falls_back_to_status(self) -> None:
        err = map_http_error(404, b"<html>not found</html>")
        self.assertEqual(err.code, "not_found")
        self.assertFalse(err.retryable)
        self.assertEqual(err.http_status, 404)

    def test_503_is_retryable_default(self) -> None:
        err = map_http_error(503, b"")
        self.assertEqual(err.code, "service_unavailable")
        self.assertTrue(err.retryable)

    def test_envelope_overrides_default_retryable(self) -> None:
        body = json.dumps({"error": {"code": "workspace_paused", "message": "paused", "retryable": True}}).encode()
        err = map_http_error(503, body)
        self.assertEqual(err.code, "workspace_paused")
        self.assertTrue(err.retryable)

    def test_invalid_json_falls_back(self) -> None:
        err = map_http_error(500, b"{not json")
        self.assertEqual(err.code, "service_unavailable")

    def test_to_payload_emits_stable_keys(self) -> None:
        err = ToolError(
            code="rate_limited",
            message="msg",
            retryable=True,
            hint="h",
            details={"a": 1},
            http_status=429,
        )
        payload = err.to_payload()
        self.assertEqual(payload["code"], "rate_limited")
        self.assertEqual(payload["message"], "msg")
        self.assertTrue(payload["retryable"])
        self.assertEqual(payload["hint"], "h")
        self.assertEqual(payload["details"], {"a": 1})
        self.assertEqual(payload["http_status"], 429)


class MapTransportErrorTests(unittest.TestCase):
    def test_timeout_is_retryable(self) -> None:
        class FakeTimeout(Exception):
            pass

        FakeTimeout.__name__ = "TimeoutError"
        err = map_transport_error(FakeTimeout("read timeout"))
        self.assertEqual(err.code, "upstream_timeout")
        self.assertTrue(err.retryable)

    def test_other_transport_is_service_unavailable(self) -> None:
        err = map_transport_error(ConnectionRefusedError("connection refused"))
        self.assertEqual(err.code, "service_unavailable")
        self.assertTrue(err.retryable)

    def test_secret_scrubbing_on_transport_text(self) -> None:
        err = map_transport_error(
            RuntimeError("authorization=cb_abcdefghijklmnop and a Bearer foo123456 too"),
        )
        # Full key body must never appear.
        self.assertNotIn("cb_abcdefghijklmnop", err.message)
        # Safe prefix is fine.
        self.assertIn("cb_abcdefgh", err.message)
        # Bearer token (with following body) gets scrubbed too.
        self.assertNotIn("foo123456", err.message)
        self.assertIn("Bearer", err.message)


if __name__ == "__main__":
    unittest.main()
