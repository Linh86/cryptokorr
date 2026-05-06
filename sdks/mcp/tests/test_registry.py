"""Tests for the tool registry: tier filtering + forbidden surface."""

from __future__ import annotations

import unittest

from tests._fixtures import _PROJECT_ROOT  # noqa: F401  (sys.path side effect)

from cryptobank_mcp.config import Config
from cryptobank_mcp.tools import (
    ALL_TOOLS,
    Role,
    Tier,
    ToolRegistry,
    forbidden_tool_names,
)


def _config(*, readonly: bool = False) -> Config:
    return Config(
        api_key="cb_x",
        base_url="http://localhost:4000",
        readonly=readonly,
        agent_id=None,
        timeout_ms=15_000,
    )


READ_TOOLS = {
    "get_intent",
    "get_decision",
    "wait_for_decision",
    "get_audit_trail",
    "list_counterparties",
    "get_runtime_status",
    "get_policy",
}

WRITE_TOOLS = {"submit_transfer", "submit_swap", "submit_allocate_idle_capital"}
OPERATOR_TOOLS = {"approve_decision", "reject_decision", "pause_runtime", "resume_runtime"}
READ_OPERATOR_TOOLS = {"list_pending_approvals"}


class ToolListingTests(unittest.TestCase):
    def test_readonly_hides_writes_and_operator(self) -> None:
        registry = ToolRegistry(config=_config(readonly=True), role=Role.OPERATOR)
        names = set(registry.visible_names())
        self.assertEqual(names, READ_TOOLS)
        for forbidden in WRITE_TOOLS | OPERATOR_TOOLS | READ_OPERATOR_TOOLS:
            self.assertNotIn(forbidden, names, f"{forbidden} must be hidden in readonly")

    def test_operator_role_sees_all_non_forbidden(self) -> None:
        registry = ToolRegistry(config=_config(readonly=False), role=Role.OPERATOR)
        names = set(registry.visible_names())
        expected = READ_TOOLS | READ_OPERATOR_TOOLS | WRITE_TOOLS | OPERATOR_TOOLS
        self.assertEqual(names, expected)

    def test_admin_role_same_as_operator_for_advertising(self) -> None:
        registry = ToolRegistry(config=_config(readonly=False), role=Role.ADMIN)
        names = set(registry.visible_names())
        expected = READ_TOOLS | READ_OPERATOR_TOOLS | WRITE_TOOLS | OPERATOR_TOOLS
        self.assertEqual(names, expected)

    def test_viewer_role_hides_operator_but_keeps_writes_visible(self) -> None:
        registry = ToolRegistry(config=_config(readonly=False), role=Role.VIEWER)
        names = set(registry.visible_names())
        self.assertEqual(names, READ_TOOLS | WRITE_TOOLS)
        for hidden in OPERATOR_TOOLS | READ_OPERATOR_TOOLS:
            self.assertNotIn(hidden, names)

    def test_unknown_role_treated_optimistically_for_writes(self) -> None:
        registry = ToolRegistry(config=_config(readonly=False), role=Role.UNKNOWN)
        names = set(registry.visible_names())
        self.assertIn("submit_transfer", names)
        for hidden in OPERATOR_TOOLS | READ_OPERATOR_TOOLS:
            self.assertNotIn(hidden, names)

    def test_lookup_by_name(self) -> None:
        registry = ToolRegistry(config=_config(), role=Role.OPERATOR)
        self.assertIsNotNone(registry.get("get_intent"))
        self.assertIsNone(registry.get("nonexistent"))


class ForbiddenSurfaceTests(unittest.TestCase):
    def test_forbidden_tools_never_in_all_tools(self) -> None:
        all_names = {t.name for t in ALL_TOOLS}
        for forbidden in forbidden_tool_names():
            self.assertNotIn(
                forbidden,
                all_names,
                f"forbidden surface {forbidden} must never appear in the registry",
            )

    def test_forbidden_tools_never_visible_at_any_tier(self) -> None:
        for role in (Role.VIEWER, Role.OPERATOR, Role.ADMIN, Role.UNKNOWN):
            for readonly in (False, True):
                registry = ToolRegistry(config=_config(readonly=readonly), role=role)
                visible = set(registry.visible_names())
                for forbidden in forbidden_tool_names():
                    self.assertNotIn(
                        forbidden,
                        visible,
                        f"{forbidden} visible at role={role} readonly={readonly}",
                    )

    def test_forbidden_lookup_returns_none(self) -> None:
        registry = ToolRegistry(config=_config(), role=Role.ADMIN)
        for name in forbidden_tool_names():
            self.assertIsNone(registry.get(name))


class TierExhaustivenessTests(unittest.TestCase):
    def test_every_tool_has_a_known_tier(self) -> None:
        for tool in ALL_TOOLS:
            self.assertIn(
                tool.tier,
                (Tier.READ, Tier.READ_OPERATOR, Tier.WRITE, Tier.OPERATOR),
                tool.name,
            )

    def test_every_advertised_tool_has_input_schema(self) -> None:
        for tool in ALL_TOOLS:
            schema = tool.input_schema
            self.assertEqual(schema.get("type"), "object", tool.name)
            self.assertIn("properties", schema, tool.name)


if __name__ == "__main__":
    unittest.main()
