"""Tests for ``cryptokorr_mcp.config``."""

from __future__ import annotations

import unittest

from tests._fixtures import _PROJECT_ROOT  # noqa: F401  (sys.path side effect)

from cryptokorr_mcp.config import (
    DEFAULT_BASE_URL,
    DEFAULT_TIMEOUT_MS,
    Config,
    ConfigError,
)


class ConfigFromEnvTests(unittest.TestCase):
    def test_minimal_env(self) -> None:
        config = Config.from_env({"CRYPTOKORR_API_KEY": "cb_abcdef0123"})
        self.assertEqual(config.api_key, "cb_abcdef0123")
        self.assertEqual(config.base_url, DEFAULT_BASE_URL)
        self.assertFalse(config.readonly)
        self.assertIsNone(config.agent_id)
        self.assertEqual(config.timeout_ms, DEFAULT_TIMEOUT_MS)

    def test_strips_trailing_slash_on_base_url(self) -> None:
        config = Config.from_env({
            "CRYPTOKORR_API_KEY": "cb_x",
            "CRYPTOKORR_BASE_URL": "https://api.example.com/",
        })
        self.assertEqual(config.base_url, "https://api.example.com")

    def test_readonly_truthy(self) -> None:
        for raw in ("true", "True", "1", "yes", "on"):
            with self.subTest(raw=raw):
                config = Config.from_env({
                    "CRYPTOKORR_API_KEY": "cb_x",
                    "CRYPTOKORR_READONLY": raw,
                })
                self.assertTrue(config.readonly, f"{raw!r} should be truthy")

    def test_readonly_falsy(self) -> None:
        for raw in ("false", "False", "0", "no", "off", ""):
            with self.subTest(raw=raw):
                config = Config.from_env({
                    "CRYPTOKORR_API_KEY": "cb_x",
                    "CRYPTOKORR_READONLY": raw,
                })
                self.assertFalse(config.readonly, f"{raw!r} should be falsy")

    def test_readonly_garbage_raises(self) -> None:
        with self.assertRaises(ConfigError):
            Config.from_env({
                "CRYPTOKORR_API_KEY": "cb_x",
                "CRYPTOKORR_READONLY": "maybe",
            })

    def test_missing_api_key_raises(self) -> None:
        with self.assertRaises(ConfigError) as ctx:
            Config.from_env({})
        self.assertIn("CRYPTOKORR_API_KEY", str(ctx.exception))

    def test_blank_api_key_raises(self) -> None:
        with self.assertRaises(ConfigError):
            Config.from_env({"CRYPTOKORR_API_KEY": "  "})

    def test_non_cb_prefix_rejected(self) -> None:
        with self.assertRaises(ConfigError) as ctx:
            Config.from_env({"CRYPTOKORR_API_KEY": "sk_other_key"})
        self.assertIn("cb_", str(ctx.exception))

    def test_bad_base_url_scheme(self) -> None:
        with self.assertRaises(ConfigError):
            Config.from_env({
                "CRYPTOKORR_API_KEY": "cb_x",
                "CRYPTOKORR_BASE_URL": "ftp://example.com",
            })

    def test_timeout_clamping(self) -> None:
        with self.assertRaises(ConfigError):
            Config.from_env({
                "CRYPTOKORR_API_KEY": "cb_x",
                "CRYPTOKORR_TIMEOUT_MS": "100",
            })
        with self.assertRaises(ConfigError):
            Config.from_env({
                "CRYPTOKORR_API_KEY": "cb_x",
                "CRYPTOKORR_TIMEOUT_MS": "9999999",
            })

    def test_timeout_garbage_raises(self) -> None:
        with self.assertRaises(ConfigError):
            Config.from_env({
                "CRYPTOKORR_API_KEY": "cb_x",
                "CRYPTOKORR_TIMEOUT_MS": "fast",
            })

    def test_agent_id_blank_to_none(self) -> None:
        config = Config.from_env({
            "CRYPTOKORR_API_KEY": "cb_x",
            "CRYPTOKORR_AGENT_ID": "  ",
        })
        self.assertIsNone(config.agent_id)

    def test_api_key_prefix_safe(self) -> None:
        config = Config.from_env({"CRYPTOKORR_API_KEY": "cb_abcdefghijklmnop"})
        self.assertEqual(config.api_key_prefix(), "cb_abcdefgh")
        # full key never returned
        self.assertNotEqual(config.api_key_prefix(), config.api_key)


if __name__ == "__main__":
    unittest.main()
