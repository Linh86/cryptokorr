"""Environment-driven configuration.

The MCP server reads everything from the process env so Claude Desktop /
Cursor can configure it via their JSON config files. There is no
fallback to a config file in MVP.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Mapping


class ConfigError(ValueError):
    """Raised when required env vars are absent or malformed."""


_TRUE = frozenset({"1", "true", "yes", "on"})
_FALSE = frozenset({"0", "false", "no", "off", ""})

DEFAULT_BASE_URL = "http://localhost:4000"
DEFAULT_TIMEOUT_MS = 15_000
MIN_TIMEOUT_MS = 1_000
MAX_TIMEOUT_MS = 120_000


@dataclass(frozen=True)
class Config:
    api_key: str
    base_url: str
    readonly: bool
    agent_id: str | None
    timeout_ms: int

    @property
    def timeout_seconds(self) -> float:
        return self.timeout_ms / 1000.0

    def api_key_prefix(self) -> str:
        """Safe-to-log prefix (first 8 chars after ``cb_``)."""
        if self.api_key.startswith("cb_"):
            return "cb_" + self.api_key[3:11]
        return self.api_key[:8]

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None) -> "Config":
        env = env if env is not None else os.environ
        api_key = (env.get("CRYPTOKORR_API_KEY") or "").strip()
        if not api_key:
            raise ConfigError(
                "CRYPTOKORR_API_KEY is required. Set it in the MCP "
                "client config (Claude Desktop / Cursor)."
            )
        if not api_key.startswith("cb_"):
            raise ConfigError(
                "CRYPTOKORR_API_KEY must start with 'cb_'. Get a key "
                "from the operator console."
            )

        base_url = (env.get("CRYPTOKORR_BASE_URL") or DEFAULT_BASE_URL).strip()
        base_url = base_url.rstrip("/")
        if not (base_url.startswith("http://") or base_url.startswith("https://")):
            raise ConfigError(
                "CRYPTOKORR_BASE_URL must be an http(s) URL "
                f"(got {base_url!r})."
            )

        readonly = _parse_bool(env.get("CRYPTOKORR_READONLY"), default=False)

        agent_id_raw = (env.get("CRYPTOKORR_AGENT_ID") or "").strip()
        agent_id = agent_id_raw or None

        timeout_ms = _parse_int(
            env.get("CRYPTOKORR_TIMEOUT_MS"),
            default=DEFAULT_TIMEOUT_MS,
            field="CRYPTOKORR_TIMEOUT_MS",
        )
        if not (MIN_TIMEOUT_MS <= timeout_ms <= MAX_TIMEOUT_MS):
            raise ConfigError(
                f"CRYPTOKORR_TIMEOUT_MS must be between {MIN_TIMEOUT_MS} and "
                f"{MAX_TIMEOUT_MS} (got {timeout_ms})."
            )

        return cls(
            api_key=api_key,
            base_url=base_url,
            readonly=readonly,
            agent_id=agent_id,
            timeout_ms=timeout_ms,
        )


def _parse_bool(raw: str | None, *, default: bool) -> bool:
    if raw is None:
        return default
    value = raw.strip().lower()
    if value in _TRUE:
        return True
    if value in _FALSE:
        return default if value == "" else False
    raise ConfigError(
        f"Boolean env var must be one of true/false/yes/no/on/off (got {raw!r})."
    )


def _parse_int(raw: str | None, *, default: int, field: str) -> int:
    if raw is None or raw.strip() == "":
        return default
    try:
        return int(raw.strip())
    except ValueError as exc:
        raise ConfigError(f"{field} must be an integer (got {raw!r}).") from exc
