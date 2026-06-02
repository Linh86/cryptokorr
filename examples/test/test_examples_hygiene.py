"""Cross-example hygiene smoke (#482).

Static checks that survive without any of the examples'
frameworks installed:

  * No real API keys committed (only the documented placeholder).
  * No mainnet / paymaster / multi-account / arbitrary-calldata
    capability claims.
  * Every example README documents its env vars.
  * Every example pins Base Sepolia.
  * The Claude Desktop config carries the placeholder key, not a
    real one, and points at `cryptokorr-mcp`.
  * Each README documents `approval_required` as a successful
    response, not an error.
"""

from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
EXAMPLES = REPO_ROOT / "examples"

LANGGRAPH_README = EXAMPLES / "langgraph" / "README.md"
LANGGRAPH_MAIN = EXAMPLES / "langgraph" / "main.py"
VERCEL_README = EXAMPLES / "vercel-ai-sdk" / "README.md"
VERCEL_TOOLS = EXAMPLES / "vercel-ai-sdk" / "tools.ts"
VERCEL_PACKAGE = EXAMPLES / "vercel-ai-sdk" / "package.json"
VERCEL_DEMO = EXAMPLES / "vercel-ai-sdk" / "demo.ts"
CLAUDE_README = EXAMPLES / "claude-desktop" / "README.md"
CLAUDE_CONFIG = EXAMPLES / "claude-desktop" / "config.example.json"

ALL_README_FILES = [LANGGRAPH_README, VERCEL_README, CLAUDE_README]
ALL_FILES = [
    *ALL_README_FILES,
    LANGGRAPH_MAIN,
    VERCEL_TOOLS,
    VERCEL_PACKAGE,
    VERCEL_DEMO,
    CLAUDE_CONFIG,
]

# Real CryptoKorr API keys are `cb_` + 16+ url-safe characters.
# The documented placeholder is `cb_REPLACE_ME_DO_NOT_COMMIT`. We
# allow that exact string and refuse any other key-shaped value.
API_KEY_PATTERN = re.compile(r"\bcb_[A-Za-z0-9_-]{16,}\b")
ALLOWED_KEY_PLACEHOLDERS = {
    "cb_REPLACE_ME_DO_NOT_COMMIT",
    # Inside the static smoke we sometimes describe the placeholder
    # in prose; the smoke itself is allowed to contain it.
}


class TestNoRealAPIKeys(unittest.TestCase):
    """No file under examples/ may contain a key-shaped value other
    than the documented placeholder."""

    def test_no_real_api_keys(self) -> None:
        for path in ALL_FILES:
            with self.subTest(path=str(path)):
                self.assertTrue(path.exists(), f"missing example file: {path}")
                content = path.read_text()
                hits = [
                    match
                    for match in API_KEY_PATTERN.findall(content)
                    if match not in ALLOWED_KEY_PLACEHOLDERS
                ]
                self.assertEqual(
                    hits,
                    [],
                    f"{path.name} contains key-shaped values that look real: {hits}",
                )


class TestBaseSepoliaOnly(unittest.TestCase):
    """Every example must explicitly call out Base Sepolia."""

    def test_each_readme_names_base_sepolia(self) -> None:
        for path in ALL_README_FILES:
            with self.subTest(path=path.name):
                content = path.read_text()
                self.assertIn(
                    "base-sepolia",
                    content,
                    f"{path.name} does not name `base-sepolia`",
                )

    def test_no_mainnet_capability_claim(self) -> None:
        # The READMEs may *deny* mainnet (and one explicitly does);
        # the smoke refuses *capability* claims like "mainnet
        # supported" or "send to mainnet" or "deploy on mainnet".
        forbidden = [
            re.compile(r"mainnet (is|will be) (supported|allowed|enabled)", re.IGNORECASE),
            re.compile(r"deploy on mainnet", re.IGNORECASE),
            re.compile(r"send.*to mainnet", re.IGNORECASE),
            re.compile(r"mainnet writes? (are|is) (allowed|supported)", re.IGNORECASE),
        ]
        for path in ALL_README_FILES + [LANGGRAPH_MAIN, VERCEL_TOOLS, VERCEL_DEMO]:
            with self.subTest(path=path.name):
                content = path.read_text()
                for pattern in forbidden:
                    self.assertIsNone(
                        pattern.search(content),
                        f"{path.name} matches banned mainnet capability claim {pattern.pattern!r}",
                    )


class TestNoBannedCapabilityClaims(unittest.TestCase):
    """Examples must not claim paymaster, multi-account, unlimited-
    token, or arbitrary-calldata capabilities."""

    BANNED_PATTERNS = [
        # Paymaster / sponsored gas — the MVP has none.
        re.compile(r"paymaster (covers|sponsors|funds) gas", re.IGNORECASE),
        re.compile(r"sponsored gas (is|will be) (provided|available)", re.IGNORECASE),
        # Multi-account selector — single active delegation in MVP.
        re.compile(r"multi-account (support|selector) (is|will be) (available|provided)", re.IGNORECASE),
        re.compile(r"switch (workspaces|accounts) (in|via) the agent", re.IGNORECASE),
        # Unlimited token approvals.
        re.compile(r"unlimited token (spend|approval) (is|will be) (allowed|granted)", re.IGNORECASE),
        # Arbitrary contract calls.
        re.compile(r"agent can call any contract", re.IGNORECASE),
        re.compile(r"arbitrary contract calls? (are|is) (allowed|supported)", re.IGNORECASE),
    ]

    def test_no_banned_claims(self) -> None:
        for path in ALL_README_FILES + [LANGGRAPH_MAIN, VERCEL_TOOLS, VERCEL_DEMO]:
            with self.subTest(path=path.name):
                content = path.read_text()
                for pattern in self.BANNED_PATTERNS:
                    self.assertIsNone(
                        pattern.search(content),
                        f"{path.name} matches banned capability claim {pattern.pattern!r}",
                    )


class TestApprovalRequiredAsSuccess(unittest.TestCase):
    """Each README must explicitly model `approval_required` as a
    successful response, not an error."""

    def test_each_readme_explains_approval_required(self) -> None:
        for path in ALL_README_FILES:
            with self.subTest(path=path.name):
                content = path.read_text()
                self.assertIn(
                    "approval_required",
                    content,
                    f"{path.name} does not name `approval_required`",
                )
                self.assertRegex(
                    content,
                    r"approval[_ ]?required.*successful",
                    f"{path.name} does not flag approval_required as a successful response",
                )


class TestEnvVarTablesPresent(unittest.TestCase):
    """Each README must document its env vars in a markdown table."""

    REQUIRED_VARS_BY_README = {
        LANGGRAPH_README: ["CRYPTOKORR_API_KEY", "MORPHO_VAULT_ADDRESS"],
        VERCEL_README: ["CRYPTOKORR_API_KEY"],
        CLAUDE_README: ["CRYPTOKORR_API_KEY", "CRYPTOKORR_READONLY"],
    }

    def test_required_env_vars_documented(self) -> None:
        for path, required in self.REQUIRED_VARS_BY_README.items():
            with self.subTest(path=path.name):
                content = path.read_text()
                self.assertIn(
                    "Environment variables",
                    content,
                    f"{path.name} missing the `Environment variables` heading",
                )
                for var in required:
                    self.assertIn(
                        var,
                        content,
                        f"{path.name} env-var table missing {var}",
                    )


class TestClaudeDesktopConfig(unittest.TestCase):
    """The Claude Desktop config must use the placeholder key and
    invoke the `cryptokorr-mcp` binary."""

    def test_config_shape(self) -> None:
        config = json.loads(CLAUDE_CONFIG.read_text())
        self.assertIn("mcpServers", config)
        self.assertIn("cryptokorr", config["mcpServers"])

        server = config["mcpServers"]["cryptokorr"]
        self.assertEqual(server["command"], "cryptokorr-mcp")
        self.assertIn("env", server)

        env = server["env"]
        self.assertEqual(env["CRYPTOKORR_API_KEY"], "cb_REPLACE_ME_DO_NOT_COMMIT")
        self.assertIn(env["CRYPTOKORR_BASE_URL"], {"http://localhost:4000"})
        # READONLY may be either string boolean ("true"/"false")
        self.assertIn(env["CRYPTOKORR_READONLY"], {"true", "false"})


class TestSdkImportPaths(unittest.TestCase):
    """Examples import the SDKs from the canonical paths."""

    def test_langgraph_imports_python_sdk(self) -> None:
        content = LANGGRAPH_MAIN.read_text()
        self.assertIn(
            "from cryptokorr import CryptoKorr",
            content,
            "langgraph/main.py does not import from cryptokorr",
        )
        self.assertIn(
            "submit_allocate_idle_capital",
            content,
            "langgraph/main.py does not call submit_allocate_idle_capital",
        )

    def test_vercel_imports_typescript_sdk(self) -> None:
        content = VERCEL_TOOLS.read_text()
        self.assertIn(
            'from "@cryptokorr/sdk"',
            content,
            "vercel-ai-sdk/tools.ts does not import @cryptokorr/sdk",
        )
        self.assertIn(
            "submitAllocateIdleCapital",
            content,
            "vercel-ai-sdk/tools.ts does not call submitAllocateIdleCapital",
        )


if __name__ == "__main__":
    unittest.main()
