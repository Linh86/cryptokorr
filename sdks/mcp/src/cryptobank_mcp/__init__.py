"""stdio MCP server for CryptoBank agent tools.

Public surface:

- ``Config`` — env-driven settings.
- ``HttpClient`` — internal Phoenix client (swappable for the Python SDK
  from #479 when it lands).
- ``ToolRegistry`` — tool list with readonly / role gating.
- ``Server`` — JSON-RPC stdio loop.

The ``cryptobank-mcp`` console script is the user-facing entrypoint;
direct importers should compose the pieces themselves.
"""

__version__ = "0.1.0"

from cryptobank_mcp.client import HttpClient, HttpResponse
from cryptobank_mcp.config import Config, ConfigError
from cryptobank_mcp.errors import (
    ToolError,
    map_http_error,
    map_transport_error,
)
from cryptobank_mcp.server import Server
from cryptobank_mcp.tools import ToolRegistry, ToolSpec

__all__ = [
    "Config",
    "ConfigError",
    "HttpClient",
    "HttpResponse",
    "Server",
    "ToolError",
    "ToolRegistry",
    "ToolSpec",
    "map_http_error",
    "map_transport_error",
]
