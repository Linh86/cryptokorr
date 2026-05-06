"""Tests for tool handlers — exercises HTTP wire shape with mocked client."""

from __future__ import annotations

import json
import unittest

from tests._fixtures import (  # noqa: F401  (sys.path side effect)
    CannedResponse,
    FakeOpener,
    _PROJECT_ROOT,
    raise_http_error_responder,
    routed_responder,
    static_responder,
)

from cryptobank_mcp.client import HttpClient
from cryptobank_mcp.config import Config
from cryptobank_mcp.errors import ToolError
from cryptobank_mcp.tools import (
    Role,
    ToolContext,
    ToolRegistry,
)


def _config(*, readonly: bool = False, agent_id: str | None = None) -> Config:
    return Config(
        api_key="cb_secretkey00000000",
        base_url="http://localhost:4000",
        readonly=readonly,
        agent_id=agent_id,
        timeout_ms=15_000,
    )


def _ctx(opener: FakeOpener, *, readonly: bool = False, agent_id: str | None = None) -> ToolContext:
    config = _config(readonly=readonly, agent_id=agent_id)
    client = HttpClient(
        api_key=config.api_key,
        base_url=config.base_url,
        timeout_seconds=config.timeout_seconds,
        opener=opener,
    )
    return ToolContext(
        config=config,
        client=client,
        role=Role.OPERATOR,
        sleep=lambda _: None,
        monotonic=lambda: 0.0,
    )


def _registry(readonly: bool = False) -> ToolRegistry:
    return ToolRegistry(config=_config(readonly=readonly), role=Role.OPERATOR)


def _header(headers: dict[str, str], name: str) -> str | None:
    """urllib normalizes header capitalization (Title-case → Title-case)."""
    target = name.lower()
    for key, value in headers.items():
        if key.lower() == target:
            return value
    return None


class ReadHandlerTests(unittest.TestCase):
    def test_get_intent_success(self) -> None:
        opener = FakeOpener(static_responder(200, {"id": "abc", "state": "submitted"}))
        registry = _registry()
        result = registry.get("get_intent").handler(  # type: ignore[union-attr]
            {"intent_id": "abc"}, _ctx(opener)
        )
        self.assertEqual(result, {"id": "abc", "state": "submitted"})
        self.assertEqual(opener.recorded[0].method, "GET")
        self.assertTrue(opener.recorded[0].url.endswith("/v1/intents/abc"))

    def test_authorization_header_sent(self) -> None:
        opener = FakeOpener(static_responder(200, {"id": "abc"}))
        registry = _registry()
        registry.get("get_intent").handler({"intent_id": "abc"}, _ctx(opener))  # type: ignore[union-attr]
        auth = _header(opener.recorded[0].headers, "Authorization")
        self.assertIsNotNone(auth)
        self.assertTrue(auth.startswith("Bearer "))

    def test_get_intent_not_found_maps_to_tool_error(self) -> None:
        opener = FakeOpener(raise_http_error_responder(
            404,
            {"error": {"code": "not_found", "message": "Intent not found.", "retryable": False}},
        ))
        registry = _registry()
        result = registry.get("get_intent").handler(  # type: ignore[union-attr]
            {"intent_id": "abc"}, _ctx(opener)
        )
        self.assertIsInstance(result, ToolError)
        self.assertEqual(result.code, "not_found")  # type: ignore[union-attr]
        self.assertFalse(result.retryable)  # type: ignore[union-attr]

    def test_list_counterparties_passes_limit(self) -> None:
        opener = FakeOpener(static_responder(200, {"counterparties": []}))
        registry = _registry()
        registry.get("list_counterparties").handler({"limit": 25}, _ctx(opener))  # type: ignore[union-attr]
        self.assertIn("limit=25", opener.recorded[0].url)

    def test_get_runtime_status_no_args(self) -> None:
        opener = FakeOpener(static_responder(200, {"status": "ok"}))
        registry = _registry()
        result = registry.get("get_runtime_status").handler({}, _ctx(opener))  # type: ignore[union-attr]
        self.assertEqual(result, {"status": "ok"})

    def test_get_policy_with_id(self) -> None:
        opener = FakeOpener(static_responder(200, {"id": "p-1"}))
        registry = _registry()
        registry.get("get_policy").handler({"policy_id": "p-1"}, _ctx(opener))  # type: ignore[union-attr]
        self.assertTrue(opener.recorded[0].url.endswith("/v1/policies/p-1"))

    def test_get_policy_without_id_lists(self) -> None:
        opener = FakeOpener(static_responder(200, {"policies": []}))
        registry = _registry()
        registry.get("get_policy").handler({}, _ctx(opener))  # type: ignore[union-attr]
        self.assertTrue(opener.recorded[0].url.endswith("/v1/policies"))

    def test_get_audit_trail_path(self) -> None:
        opener = FakeOpener(static_responder(200, {"intent": {}}))
        registry = _registry()
        registry.get("get_audit_trail").handler({"intent_id": "x"}, _ctx(opener))  # type: ignore[union-attr]
        self.assertTrue(opener.recorded[0].url.endswith("/v1/intents/x/replay"))


class WriteHandlerTests(unittest.TestCase):
    def test_submit_transfer_request_shape(self) -> None:
        opener = FakeOpener(static_responder(202, {"intent_id": "i-1", "state": "submitted"}))
        registry = _registry()
        result = registry.get("submit_transfer").handler(  # type: ignore[union-attr]
            {
                "agent_id": "agent-alice",
                "asset": "USDC",
                "chain": "base-sepolia",
                "amount": "10.5",
                "target": {"counterparty_id": "cp-1"},
            },
            _ctx(opener),
        )
        self.assertEqual(result, {"intent_id": "i-1", "state": "submitted"})
        request = opener.recorded[0]
        self.assertEqual(request.method, "POST")
        body = json.loads(request.body)
        self.assertEqual(body["kind"], "transfer")
        self.assertEqual(body["agent_id"], "agent-alice")
        self.assertEqual(body["asset"], "USDC")
        self.assertEqual(body["chain"], "base-sepolia")
        self.assertEqual(body["amount"], "10.5")
        self.assertEqual(body["target"], {"counterparty_id": "cp-1"})
        self.assertEqual(body["source"], "agent")
        self.assertIn("idempotency_key", body)
        idem = _header(request.headers, "Idempotency-Key")
        self.assertEqual(idem, body["idempotency_key"])

    def test_submit_transfer_uses_default_agent_id_from_config(self) -> None:
        opener = FakeOpener(static_responder(202, {"intent_id": "i-1"}))
        registry = ToolRegistry(
            config=_config(agent_id="default-agent"),
            role=Role.OPERATOR,
        )
        result = registry.get("submit_transfer").handler(  # type: ignore[union-attr]
            {
                "asset": "USDC",
                "chain": "base-sepolia",
                "amount": "1",
                "target": {"raw_address": "0x" + "a" * 40},
            },
            _ctx(opener, agent_id="default-agent"),
        )
        self.assertNotIsInstance(result, ToolError)
        body = json.loads(opener.recorded[0].body)
        self.assertEqual(body["agent_id"], "default-agent")

    def test_submit_transfer_missing_agent_id_returns_invalid_body(self) -> None:
        opener = FakeOpener(static_responder(500, b""))
        registry = _registry()
        result = registry.get("submit_transfer").handler(  # type: ignore[union-attr]
            {
                "asset": "USDC",
                "chain": "base-sepolia",
                "amount": "1",
                "target": {"raw_address": "0x" + "b" * 40},
            },
            _ctx(opener),
        )
        self.assertIsInstance(result, ToolError)
        self.assertEqual(result.code, "invalid_body")  # type: ignore[union-attr]
        self.assertEqual(opener.recorded, [])  # short-circuited before HTTP

    def test_submit_swap_request_shape(self) -> None:
        opener = FakeOpener(static_responder(202, {"intent_id": "i-2"}))
        registry = _registry()
        registry.get("submit_swap").handler(  # type: ignore[union-attr]
            {
                "agent_id": "agent-1",
                "chain": "base-sepolia",
                "source_asset": "USDC",
                "destination_asset": "USDT",
                "amount": "5",
            },
            _ctx(opener),
        )
        body = json.loads(opener.recorded[0].body)
        self.assertEqual(body["kind"], "swap")
        self.assertEqual(body["source_asset"], "USDC")
        self.assertEqual(body["destination_asset"], "USDT")
        self.assertEqual(body["asset"], "USDC")  # mirrors source for the wire schema

    def test_submit_allocate_idle_capital_request_shape(self) -> None:
        opener = FakeOpener(static_responder(202, {"intent_id": "i-3"}))
        registry = _registry()
        vault = "0x" + "c" * 40
        registry.get("submit_allocate_idle_capital").handler(  # type: ignore[union-attr]
            {
                "agent_id": "agent-1",
                "amount": "100",
                "vault_address": vault,
            },
            _ctx(opener),
        )
        body = json.loads(opener.recorded[0].body)
        self.assertEqual(body["kind"], "allocate_idle_capital")
        self.assertEqual(body["chain"], "base-sepolia")
        self.assertEqual(body["asset"], "USDC")
        self.assertEqual(body["vault_address"], vault)
        self.assertEqual(body["target"], {"raw_address": vault})

    def test_idempotency_key_deterministic_per_body(self) -> None:
        opener = FakeOpener(static_responder(202, {"intent_id": "i-x"}))
        registry = _registry()
        args = {
            "agent_id": "a",
            "asset": "USDC",
            "chain": "base-sepolia",
            "amount": "1",
            "target": {"raw_address": "0x" + "d" * 40},
        }
        registry.get("submit_transfer").handler(args, _ctx(opener))  # type: ignore[union-attr]
        registry.get("submit_transfer").handler(args, _ctx(opener))  # type: ignore[union-attr]
        body0 = json.loads(opener.recorded[0].body)
        body1 = json.loads(opener.recorded[1].body)
        self.assertEqual(body0["idempotency_key"], body1["idempotency_key"])

    def test_idempotency_key_caller_supplied_wins(self) -> None:
        opener = FakeOpener(static_responder(202, {"intent_id": "i-x"}))
        registry = _registry()
        registry.get("submit_transfer").handler(  # type: ignore[union-attr]
            {
                "agent_id": "a",
                "asset": "USDC",
                "chain": "base-sepolia",
                "amount": "1",
                "target": {"raw_address": "0x" + "e" * 40},
                "idempotency_key": "caller-key",
            },
            _ctx(opener),
        )
        body = json.loads(opener.recorded[0].body)
        self.assertEqual(body["idempotency_key"], "caller-key")
        idem = _header(opener.recorded[0].headers, "Idempotency-Key")
        self.assertEqual(idem, "caller-key")


class OperatorHandlerTests(unittest.TestCase):
    def test_approve_decision_path_and_body(self) -> None:
        opener = FakeOpener(static_responder(200, {"ok": True}))
        registry = _registry()
        registry.get("approve_decision").handler(  # type: ignore[union-attr]
            {"decision_id": "d-1", "actor_id": "op@example.com", "reason": "ok"},
            _ctx(opener),
        )
        request = opener.recorded[0]
        self.assertTrue(request.url.endswith("/v1/approvals/d-1/approve"))
        body = json.loads(request.body)
        self.assertEqual(body, {"actor_id": "op@example.com", "reason": "ok"})

    def test_reject_decision_path(self) -> None:
        opener = FakeOpener(static_responder(200, {"ok": True}))
        registry = _registry()
        registry.get("reject_decision").handler(  # type: ignore[union-attr]
            {"decision_id": "d-2", "actor_id": "op@example.com"},
            _ctx(opener),
        )
        self.assertTrue(opener.recorded[0].url.endswith("/v1/approvals/d-2/reject"))

    def test_pause_runtime_path(self) -> None:
        opener = FakeOpener(static_responder(200, {"paused": True}))
        registry = _registry()
        registry.get("pause_runtime").handler({}, _ctx(opener))  # type: ignore[union-attr]
        self.assertTrue(opener.recorded[0].url.endswith("/v1/security/pause"))

    def test_resume_runtime_path(self) -> None:
        opener = FakeOpener(static_responder(200, {"paused": False}))
        registry = _registry()
        registry.get("resume_runtime").handler({}, _ctx(opener))  # type: ignore[union-attr]
        self.assertTrue(opener.recorded[0].url.endswith("/v1/security/resume"))

    def test_pause_returns_chain_action_rate_limit(self) -> None:
        opener = FakeOpener(raise_http_error_responder(
            429,
            {"error": {"code": "rate_limited", "message": "Too many.", "retryable": True}},
        ))
        registry = _registry()
        result = registry.get("pause_runtime").handler({}, _ctx(opener))  # type: ignore[union-attr]
        self.assertIsInstance(result, ToolError)
        self.assertEqual(result.code, "rate_limited")  # type: ignore[union-attr]
        self.assertTrue(result.retryable)  # type: ignore[union-attr]


class WaitForDecisionTests(unittest.TestCase):
    def test_returns_decision_when_outcome_resolved(self) -> None:
        responder = routed_responder({
            ("GET", "/v1/intents/i-1"): CannedResponse(200, {"current_decision_id": "d-1"}),
            ("GET", "/v1/decisions/d-1"): CannedResponse(200, {"id": "d-1", "outcome": "auto_exec"}),
        })
        opener = FakeOpener(responder)
        registry = _registry()
        result = registry.get("wait_for_decision").handler(  # type: ignore[union-attr]
            {"intent_id": "i-1", "timeout_seconds": 5}, _ctx(opener)
        )
        self.assertEqual(result, {"id": "d-1", "outcome": "auto_exec"})

    def test_returns_synthetic_still_evaluating_after_timeout(self) -> None:
        responder = routed_responder({
            ("GET", "/v1/intents/i-1"): CannedResponse(200, {"current_decision_id": "d-1"}),
            ("GET", "/v1/decisions/d-1"): CannedResponse(200, {"id": "d-1", "outcome": "evaluating"}),
        })
        opener = FakeOpener(responder)
        config = _config()
        client = HttpClient(
            api_key=config.api_key,
            base_url=config.base_url,
            timeout_seconds=config.timeout_seconds,
            opener=opener,
        )
        time_holder = {"t": 0.0}

        def monotonic() -> float:
            return time_holder["t"]

        def sleep(_: float) -> None:
            time_holder["t"] += 1.0

        ctx = ToolContext(
            config=config,
            client=client,
            role=Role.OPERATOR,
            sleep=sleep,
            monotonic=monotonic,
        )
        registry = _registry()
        result = registry.get("wait_for_decision").handler(  # type: ignore[union-attr]
            {"intent_id": "i-1", "timeout_seconds": 2}, ctx
        )
        assert isinstance(result, dict)
        self.assertEqual(result["outcome"], "still_evaluating")
        self.assertTrue(result["synthetic"])
        self.assertIn("hint", result)

    def test_caps_timeout_at_60_seconds(self) -> None:
        responder = routed_responder({
            ("GET", "/v1/intents/i-1"): CannedResponse(200, {"current_decision_id": "d-1"}),
            ("GET", "/v1/decisions/d-1"): CannedResponse(200, {"id": "d-1", "outcome": "evaluating"}),
        })
        opener = FakeOpener(responder)
        config = _config()
        client = HttpClient(
            api_key=config.api_key,
            base_url=config.base_url,
            timeout_seconds=config.timeout_seconds,
            opener=opener,
        )
        time_holder = {"t": 0.0}

        def monotonic() -> float:
            return time_holder["t"]

        def sleep(_: float) -> None:
            time_holder["t"] += 100.0

        ctx = ToolContext(
            config=config,
            client=client,
            role=Role.OPERATOR,
            sleep=sleep,
            monotonic=monotonic,
        )
        registry = _registry()
        # Even though caller asks for 1000 seconds, the cap is 60.
        result = registry.get("wait_for_decision").handler(  # type: ignore[union-attr]
            {"intent_id": "i-1", "timeout_seconds": 1000}, ctx
        )
        assert isinstance(result, dict)
        self.assertEqual(result["outcome"], "still_evaluating")
        self.assertLess(time_holder["t"], 200.0)  # never blew past the cap


class TransportFailureTests(unittest.TestCase):
    def test_connection_refused_maps_to_service_unavailable(self) -> None:
        def raiser(_: object) -> object:
            raise ConnectionRefusedError("refused")

        opener = FakeOpener(raiser)
        registry = _registry()
        result = registry.get("get_intent").handler({"intent_id": "x"}, _ctx(opener))  # type: ignore[union-attr]
        self.assertIsInstance(result, ToolError)
        self.assertEqual(result.code, "service_unavailable")  # type: ignore[union-attr]
        self.assertTrue(result.retryable)  # type: ignore[union-attr]


if __name__ == "__main__":
    unittest.main()
