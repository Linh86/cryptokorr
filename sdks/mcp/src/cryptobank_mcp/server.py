"""Stdio JSON-RPC 2.0 MCP server.

The MCP wire protocol is JSON-RPC 2.0 over framed stdin/stdout. We
implement only the subset the Claude Desktop / Cursor agent hosts call
during a normal session:

- ``initialize`` — return server info + capabilities.
- ``initialized`` — notification; no-op.
- ``tools/list`` — advertise visible tools + their JSON Schemas.
- ``tools/call`` — validate arguments, dispatch to the handler, wrap
  the result or error per the MCP tool-call response shape.
- ``ping`` — return ``{}`` (some hosts use this for keepalive).
- ``shutdown`` — accept and exit cleanly.

JSON-RPC errors (parse error, unknown method, invalid params) flow
through the standard error envelope. Tool-call errors flow through the
MCP tool-result error shape — ``isError: true`` plus the structured
``error`` object — because that is what models read.
"""

from __future__ import annotations

import json
import logging
import sys
from dataclasses import dataclass, field
from typing import IO, Any, Callable, Iterable, Mapping

from cryptobank_mcp import __version__ as VERSION
from cryptobank_mcp.client import HttpClient
from cryptobank_mcp.config import Config
from cryptobank_mcp.errors import ToolError
from cryptobank_mcp.tools import (
    Role,
    ToolContext,
    ToolRegistry,
    ToolSpec,
    probe_role,
)

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "cryptobank-mcp"
DEFAULT_RESULT_SIZE_CAP = 256 * 1024

JSONRPC_PARSE_ERROR = -32700
JSONRPC_INVALID_REQUEST = -32600
JSONRPC_METHOD_NOT_FOUND = -32601
JSONRPC_INVALID_PARAMS = -32602
JSONRPC_INTERNAL_ERROR = -32603

_log = logging.getLogger("cryptobank_mcp")


@dataclass
class Server:
    config: Config
    registry: ToolRegistry
    client: HttpClient
    stdin: IO[str] = field(default_factory=lambda: sys.stdin)
    stdout: IO[str] = field(default_factory=lambda: sys.stdout)
    result_size_cap: int = DEFAULT_RESULT_SIZE_CAP

    def __post_init__(self) -> None:
        self._tool_ctx = ToolContext(
            config=self.config,
            client=self.client,
            role=Role.OPERATOR if self.config.readonly is False else Role.VIEWER,
        )
        self._handlers: dict[str, Callable[[Mapping[str, Any]], Any]] = {
            "initialize": self._handle_initialize,
            "initialized": self._handle_notification,
            "notifications/initialized": self._handle_notification,
            "ping": self._handle_ping,
            "tools/list": self._handle_tools_list,
            "tools/call": self._handle_tools_call,
            "shutdown": self._handle_shutdown,
            "exit": self._handle_notification,
        }
        self._shutdown = False

    # ------------------------------------------------------------------
    # Public entry
    # ------------------------------------------------------------------

    def serve_forever(self) -> int:
        for line in self.stdin:
            self.handle_line(line)
            if self._shutdown:
                break
        return 0

    def handle_line(self, line: str) -> str | None:
        line = line.strip()
        if not line:
            return None
        try:
            message = json.loads(line)
        except json.JSONDecodeError as exc:
            return self._send(_jsonrpc_error(None, JSONRPC_PARSE_ERROR, f"Parse error: {exc}"))
        if not isinstance(message, dict):
            return self._send(_jsonrpc_error(None, JSONRPC_INVALID_REQUEST, "Invalid request."))
        return self.handle_message(message)

    def handle_message(self, message: Mapping[str, Any]) -> str | None:
        msg_id = message.get("id")
        method = message.get("method")
        params = message.get("params") or {}
        if not isinstance(method, str):
            return self._send(_jsonrpc_error(msg_id, JSONRPC_INVALID_REQUEST, "Missing method."))
        handler = self._handlers.get(method)
        if handler is None:
            if msg_id is None:
                return None  # unknown notification — drop silently
            return self._send(_jsonrpc_error(msg_id, JSONRPC_METHOD_NOT_FOUND, f"Unknown method: {method}"))
        try:
            result = handler(params)
        except _ParamError as exc:
            return self._send(_jsonrpc_error(msg_id, JSONRPC_INVALID_PARAMS, str(exc)))
        except Exception as exc:  # noqa: BLE001
            _log.exception("internal error in handler %s", method)
            return self._send(
                _jsonrpc_error(msg_id, JSONRPC_INTERNAL_ERROR, f"Internal error: {type(exc).__name__}")
            )
        if result is None and msg_id is None:
            return None
        return self._send({"jsonrpc": "2.0", "id": msg_id, "result": result})

    # ------------------------------------------------------------------
    # JSON-RPC handlers
    # ------------------------------------------------------------------

    def _handle_initialize(self, _params: Mapping[str, Any]) -> dict[str, Any]:
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "serverInfo": {"name": SERVER_NAME, "version": VERSION},
            "capabilities": {
                "tools": {"listChanged": False},
                "logging": {},
            },
        }

    def _handle_ping(self, _params: Mapping[str, Any]) -> dict[str, Any]:
        return {}

    def _handle_notification(self, _params: Mapping[str, Any]) -> None:
        return None

    def _handle_shutdown(self, _params: Mapping[str, Any]) -> dict[str, Any]:
        self._shutdown = True
        return {}

    def _handle_tools_list(self, _params: Mapping[str, Any]) -> dict[str, Any]:
        return {"tools": [_tool_to_wire(t) for t in self.registry.visible_tools]}

    def _handle_tools_call(self, params: Mapping[str, Any]) -> dict[str, Any]:
        name = params.get("name")
        if not isinstance(name, str):
            raise _ParamError("Missing tool name.")
        arguments = params.get("arguments") or {}
        if not isinstance(arguments, Mapping):
            raise _ParamError("arguments must be an object.")
        tool = self.registry.get(name)
        if tool is None:
            return _tool_error_payload(
                ToolError(
                    code="tool_not_found",
                    message=f"Tool {name!r} is not advertised by this server.",
                    retryable=False,
                    hint=(
                        "List tools with tools/list. Write/operator tools "
                        "are hidden when CRYPTOBANK_READONLY=true."
                    ),
                )
            )
        validation_error = _validate(arguments, tool.input_schema)
        if validation_error is not None:
            return _tool_error_payload(validation_error)
        result = tool.handler(arguments, self._tool_ctx)
        if isinstance(result, ToolError):
            self._log_call(tool.name, ok=False, size=None, code=result.code)
            return _tool_error_payload(result)
        text = json.dumps(_apply_size_cap(result, self.result_size_cap), ensure_ascii=False)
        self._log_call(tool.name, ok=True, size=len(text), code=None)
        return {"content": [{"type": "text", "text": text}], "isError": False}

    # ------------------------------------------------------------------
    # Output / logging
    # ------------------------------------------------------------------

    def _send(self, message: Mapping[str, Any]) -> str:
        line = json.dumps(message, ensure_ascii=False)
        self.stdout.write(line + "\n")
        self.stdout.flush()
        return line

    def _log_call(self, name: str, *, ok: bool, size: int | None, code: str | None) -> None:
        prefix = self.config.api_key_prefix()
        if ok:
            _log.info("tool=%s ok=true key=%s size=%s", name, prefix, size)
        else:
            _log.info("tool=%s ok=false key=%s code=%s", name, prefix, code)


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

class _ParamError(ValueError):
    pass


def _tool_to_wire(tool: ToolSpec) -> dict[str, Any]:
    return {
        "name": tool.name,
        "description": tool.description,
        "inputSchema": dict(tool.input_schema),
    }


def _tool_error_payload(error: ToolError) -> dict[str, Any]:
    summary = f"{error.code}: {error.message}"
    return {
        "content": [{"type": "text", "text": summary}],
        "isError": True,
        "error": error.to_payload(),
    }


def _jsonrpc_error(msg_id: Any, code: int, message: str) -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": msg_id,
        "error": {"code": code, "message": message},
    }


def _apply_size_cap(value: Any, cap: int) -> Any:
    encoded = json.dumps(value, ensure_ascii=False)
    if len(encoded) <= cap:
        return value
    if isinstance(value, dict):
        truncated: dict[str, Any] = {
            "truncated": True,
            "size_bytes": len(encoded),
            "size_cap_bytes": cap,
            "hint": (
                f"Result exceeded the MCP server's {cap}-byte cap. Fetch "
                "the full record via the SDK or the REST API directly."
            ),
        }
        for key in ("id", "intent_id", "decision_id", "state", "outcome", "kind"):
            if key in value:
                truncated[key] = value[key]
        return truncated
    return {
        "truncated": True,
        "size_bytes": len(encoded),
        "size_cap_bytes": cap,
        "hint": (
            f"Result exceeded the MCP server's {cap}-byte cap. Fetch the "
            "full record via the SDK or the REST API directly."
        ),
    }


# Tiny JSON-Schema validator. Implements the keywords our tool schemas
# actually use: type, required, properties, additionalProperties, enum,
# pattern, minimum, maximum, minLength, maxLength. No remote $refs.

_PATTERN_CACHE: dict[str, "Any"] = {}


def _validate(args: Mapping[str, Any], schema: Mapping[str, Any]) -> ToolError | None:
    issues: list[str] = []
    _walk(args, schema, "$", issues)
    if not issues:
        return None
    return ToolError(
        code="invalid_body",
        message=f"Tool arguments failed validation: {issues[0]}",
        retryable=False,
        details={"errors": issues},
    )


def _walk(value: Any, schema: Mapping[str, Any], path: str, issues: list[str]) -> None:
    expected_type = schema.get("type")
    if expected_type and not _check_type(value, expected_type):
        issues.append(f"{path}: expected {expected_type}")
        return
    if expected_type == "object":
        _walk_object(value, schema, path, issues)
    elif expected_type == "string":
        _walk_string(value, schema, path, issues)
    elif expected_type == "integer":
        _walk_integer(value, schema, path, issues)
    if "enum" in schema and value not in schema["enum"]:
        issues.append(f"{path}: must be one of {schema['enum']}")


def _walk_object(value: Mapping[str, Any], schema: Mapping[str, Any], path: str, issues: list[str]) -> None:
    properties: Mapping[str, Mapping[str, Any]] = schema.get("properties") or {}
    required: Iterable[str] = schema.get("required") or ()
    additional = schema.get("additionalProperties", True)
    for name in required:
        if name not in value:
            issues.append(f"{path}.{name}: required")
    for key, sub in value.items():
        if key in properties:
            _walk(sub, properties[key], f"{path}.{key}", issues)
        elif additional is False:
            issues.append(f"{path}.{key}: unknown property")


def _walk_string(value: str, schema: Mapping[str, Any], path: str, issues: list[str]) -> None:
    pattern = schema.get("pattern")
    if pattern is not None:
        compiled = _PATTERN_CACHE.get(pattern)
        if compiled is None:
            import re

            compiled = re.compile(pattern)
            _PATTERN_CACHE[pattern] = compiled
        if compiled.search(value) is None:
            issues.append(f"{path}: does not match {pattern!r}")
    min_length = schema.get("minLength")
    if min_length is not None and len(value) < min_length:
        issues.append(f"{path}: minLength {min_length}")
    max_length = schema.get("maxLength")
    if max_length is not None and len(value) > max_length:
        issues.append(f"{path}: maxLength {max_length}")


def _walk_integer(value: int, schema: Mapping[str, Any], path: str, issues: list[str]) -> None:
    minimum = schema.get("minimum")
    if minimum is not None and value < minimum:
        issues.append(f"{path}: minimum {minimum}")
    maximum = schema.get("maximum")
    if maximum is not None and value > maximum:
        issues.append(f"{path}: maximum {maximum}")


def _check_type(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, Mapping)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "array":
        return isinstance(value, list)
    if expected == "null":
        return value is None
    return True


def build_default_server(env: Mapping[str, str] | None = None) -> Server:
    """Construct a Server from the process environment.

    Used by the console-script entrypoint and by smoke tests.
    """
    config = Config.from_env(env)
    client = HttpClient(
        api_key=config.api_key,
        base_url=config.base_url,
        timeout_seconds=config.timeout_seconds,
    )
    role_override = (env.get("CRYPTOBANK_ROLE") if env else None) or _maybe_env("CRYPTOBANK_ROLE")
    role = probe_role(client, override=role_override)
    registry = ToolRegistry(config=config, role=role)
    return Server(config=config, registry=registry, client=client)


def _maybe_env(name: str) -> str | None:
    import os

    value = os.environ.get(name)
    return value or None
