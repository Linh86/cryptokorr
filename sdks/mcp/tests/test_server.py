"""Tests for the JSON-RPC stdio server."""

from __future__ import annotations

import io
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
from cryptobank_mcp.server import (
    JSONRPC_INVALID_PARAMS,
    JSONRPC_METHOD_NOT_FOUND,
    JSONRPC_PARSE_ERROR,
    PROTOCOL_VERSION,
    SERVER_NAME,
    Server,
)
from cryptobank_mcp.tools import Role, ToolRegistry


def _config(*, readonly: bool = False) -> Config:
    return Config(
        api_key="cb_supersecret0000",
        base_url="http://localhost:4000",
        readonly=readonly,
        agent_id=None,
        timeout_ms=15_000,
    )


def _make_server(opener: FakeOpener, *, readonly: bool = False, role: Role = Role.OPERATOR) -> Server:
    config = _config(readonly=readonly)
    client = HttpClient(
        api_key=config.api_key,
        base_url=config.base_url,
        timeout_seconds=config.timeout_seconds,
        opener=opener,
    )
    registry = ToolRegistry(config=config, role=role)
    return Server(
        config=config,
        registry=registry,
        client=client,
        stdin=io.StringIO(""),
        stdout=io.StringIO(),
    )


def _send(server: Server, message: dict) -> dict | None:
    raw = server.handle_message(message)
    if raw is None:
        return None
    return json.loads(raw)


class InitializeTests(unittest.TestCase):
    def test_initialize_returns_server_info(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener)
        response = _send(server, {"jsonrpc": "2.0", "id": 1, "method": "initialize"})
        self.assertEqual(response["result"]["protocolVersion"], PROTOCOL_VERSION)
        self.assertEqual(response["result"]["serverInfo"]["name"], SERVER_NAME)
        self.assertIn("tools", response["result"]["capabilities"])

    def test_ping_returns_empty(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener)
        response = _send(server, {"jsonrpc": "2.0", "id": 1, "method": "ping"})
        self.assertEqual(response["result"], {})

    def test_initialized_notification_no_response(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener)
        response = _send(server, {"jsonrpc": "2.0", "method": "initialized"})
        self.assertIsNone(response)


class ToolsListTests(unittest.TestCase):
    def test_lists_visible_tools(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener, readonly=False, role=Role.OPERATOR)
        response = _send(server, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        names = [t["name"] for t in response["result"]["tools"]]
        self.assertIn("get_intent", names)
        self.assertIn("submit_transfer", names)
        self.assertIn("approve_decision", names)

    def test_readonly_omits_writes_from_listing(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener, readonly=True)
        response = _send(server, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        names = {t["name"] for t in response["result"]["tools"]}
        self.assertIn("get_intent", names)
        for hidden in (
            "submit_transfer",
            "submit_swap",
            "submit_allocate_idle_capital",
            "approve_decision",
            "reject_decision",
            "pause_runtime",
            "resume_runtime",
            "list_pending_approvals",
        ):
            self.assertNotIn(hidden, names, f"{hidden} must be hidden in readonly")

    def test_each_tool_carries_input_schema_with_type_object(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener)
        response = _send(server, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        for tool in response["result"]["tools"]:
            self.assertIn("inputSchema", tool, tool["name"])
            self.assertEqual(tool["inputSchema"]["type"], "object", tool["name"])
            self.assertIn("description", tool, tool["name"])


class ToolsCallTests(unittest.TestCase):
    def test_success_serializes_result_as_text_content(self) -> None:
        opener = FakeOpener(static_responder(200, {"id": "i-1", "state": "submitted"}))
        server = _make_server(opener)
        response = _send(server, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "get_intent", "arguments": {"intent_id": "i-1"}},
        })
        result = response["result"]
        self.assertFalse(result.get("isError"))
        text = result["content"][0]["text"]
        self.assertEqual(json.loads(text), {"id": "i-1", "state": "submitted"})

    def test_unknown_tool_returns_isError(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener)
        response = _send(server, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "nonexistent", "arguments": {}},
        })
        result = response["result"]
        self.assertTrue(result["isError"])
        self.assertEqual(result["error"]["code"], "tool_not_found")

    def test_invalid_arguments_return_isError(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener)
        response = _send(server, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "get_intent", "arguments": {}},  # missing intent_id
        })
        result = response["result"]
        self.assertTrue(result["isError"])
        self.assertEqual(result["error"]["code"], "invalid_body")
        self.assertIn("errors", result["error"]["details"])

    def test_invalid_amount_pattern_rejected(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener)
        response = _send(server, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "submit_transfer",
                "arguments": {
                    "agent_id": "a",
                    "asset": "USDC",
                    "chain": "base-sepolia",
                    "amount": "abc",  # fails pattern
                    "target": {"raw_address": "0x" + "1" * 40},
                },
            },
        })
        result = response["result"]
        self.assertTrue(result["isError"])
        self.assertEqual(result["error"]["code"], "invalid_body")

    def test_unknown_property_rejected(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener)
        response = _send(server, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "get_intent",
                "arguments": {"intent_id": "x", "ghost": "field"},
            },
        })
        result = response["result"]
        self.assertTrue(result["isError"])

    def test_http_error_propagated_as_tool_error(self) -> None:
        opener = FakeOpener(raise_http_error_responder(
            429,
            {"error": {"code": "rate_limited", "message": "Too many.", "retryable": True}},
        ))
        server = _make_server(opener)
        response = _send(server, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "get_intent", "arguments": {"intent_id": "x"}},
        })
        result = response["result"]
        self.assertTrue(result["isError"])
        self.assertEqual(result["error"]["code"], "rate_limited")
        self.assertTrue(result["error"]["retryable"])

    def test_hidden_tool_invocation_in_readonly_mode_returns_not_found(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener, readonly=True)
        response = _send(server, {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": "submit_transfer", "arguments": {}},
        })
        result = response["result"]
        self.assertTrue(result["isError"])
        self.assertEqual(result["error"]["code"], "tool_not_found")
        self.assertEqual(opener.recorded, [], "no HTTP call should have been issued")


class JsonRpcEnvelopeTests(unittest.TestCase):
    def test_parse_error_for_non_json(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener)
        raw = server.handle_line("{not json}")
        self.assertIsNotNone(raw)
        envelope = json.loads(raw)  # type: ignore[arg-type]
        self.assertEqual(envelope["error"]["code"], JSONRPC_PARSE_ERROR)

    def test_method_not_found(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener)
        response = _send(server, {"jsonrpc": "2.0", "id": 1, "method": "no/such"})
        self.assertEqual(response["error"]["code"], JSONRPC_METHOD_NOT_FOUND)

    def test_unknown_notification_dropped(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener)
        response = _send(server, {"jsonrpc": "2.0", "method": "no/such"})
        self.assertIsNone(response)

    def test_tools_call_missing_name_returns_invalid_params(self) -> None:
        opener = FakeOpener(static_responder(200, {}))
        server = _make_server(opener)
        response = _send(server, {
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {},
        })
        self.assertEqual(response["error"]["code"], JSONRPC_INVALID_PARAMS)


class SizeCapTests(unittest.TestCase):
    def test_large_result_is_truncated(self) -> None:
        large_payload = {"id": "i-1", "blob": "x" * 1024}
        opener = FakeOpener(static_responder(200, large_payload))
        server = _make_server(opener)
        server.result_size_cap = 256
        response = _send(server, {
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "get_intent", "arguments": {"intent_id": "i-1"}},
        })
        text = response["result"]["content"][0]["text"]
        parsed = json.loads(text)
        self.assertTrue(parsed["truncated"])
        self.assertEqual(parsed["id"], "i-1")
        self.assertIn("hint", parsed)

    def test_small_result_passes_through(self) -> None:
        opener = FakeOpener(static_responder(200, {"id": "i-1"}))
        server = _make_server(opener)
        response = _send(server, {
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "get_intent", "arguments": {"intent_id": "i-1"}},
        })
        parsed = json.loads(response["result"]["content"][0]["text"])
        self.assertEqual(parsed, {"id": "i-1"})
        self.assertNotIn("truncated", parsed)


class SecretHygieneTests(unittest.TestCase):
    def test_api_key_never_in_response_text(self) -> None:
        opener = FakeOpener(static_responder(200, {"id": "i-1"}))
        server = _make_server(opener)
        response = _send(server, {
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "get_intent", "arguments": {"intent_id": "i-1"}},
        })
        serialized = json.dumps(response)
        self.assertNotIn("cb_supersecret0000", serialized)

    def test_api_key_never_in_error_text(self) -> None:
        opener = FakeOpener(raise_http_error_responder(
            500,
            "internal error referencing cb_supersecret0000 by accident",
        ))
        server = _make_server(opener)
        response = _send(server, {
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "get_intent", "arguments": {"intent_id": "i-1"}},
        })
        serialized = json.dumps(response)
        # Body wasn't valid JSON; mapper falls back to status defaults so
        # the secret never makes it onto the wire.
        self.assertNotIn("cb_supersecret0000", serialized)


if __name__ == "__main__":
    unittest.main()
