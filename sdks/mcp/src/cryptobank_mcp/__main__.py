"""Console-script entrypoint: ``cryptokorr-mcp``.

Reads config from env, probes role, then drives the JSON-RPC stdio
loop until stdin closes.
"""

from __future__ import annotations

import logging
import os
import sys

from cryptokorr_mcp.config import ConfigError
from cryptokorr_mcp.server import build_default_server


def main(argv: list[str] | None = None) -> int:
    _configure_logging(os.environ.get("CRYPTOKORR_LOG_LEVEL", "INFO"))
    try:
        server = build_default_server(os.environ)
    except ConfigError as exc:
        sys.stderr.write(f"cryptokorr-mcp: {exc}\n")
        return 2
    return server.serve_forever()


def _configure_logging(level: str) -> None:
    numeric = getattr(logging, level.upper(), logging.INFO)
    logging.basicConfig(
        stream=sys.stderr,
        level=numeric,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
