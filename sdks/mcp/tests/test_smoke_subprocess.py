"""End-to-end smoke: run the MCP server in a subprocess via stdio.

We point ``CRYPTOBANK_BASE_URL`` at a localhost port that is not
listening, so role probing fails open and no real network traffic
leaves the process. Then we drive the JSON-RPC handshake (initialize
+ tools/list) over stdin/stdout to confirm the server boots and
advertises tools.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import unittest

from tests._fixtures import _PROJECT_ROOT  # noqa: F401  (sys.path side effect)


def _spawn(env_overrides: dict[str, str]) -> subprocess.Popen:
    env = os.environ.copy()
    env.update({
        "CRYPTOBANK_API_KEY": "cb_smoketest000000000",
        "CRYPTOBANK_BASE_URL": "http://127.0.0.1:1",
        "CRYPTOBANK_TIMEOUT_MS": "1000",
        "CRYPTOBANK_LOG_LEVEL": "ERROR",
        "PYTHONPATH": _PROJECT_ROOT + "/src",
    })
    env.update(env_overrides)
    return subprocess.Popen(
        [sys.executable, "-m", "cryptobank_mcp"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
        text=True,
        bufsize=1,
    )


def _request(proc: subprocess.Popen, message: dict) -> dict:
    proc.stdin.write(json.dumps(message) + "\n")
    proc.stdin.flush()
    line = proc.stdout.readline()
    if not line:
        stderr = proc.stderr.read() if proc.stderr else ""
        raise AssertionError(f"server closed stdin without responding; stderr={stderr!r}")
    return json.loads(line)


def _shutdown(proc: subprocess.Popen) -> None:
    try:
        if proc.stdin and not proc.stdin.closed:
            proc.stdin.close()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait(timeout=5)
    finally:
        for stream in (proc.stdin, proc.stdout, proc.stderr):
            if stream is not None and not stream.closed:
                try:
                    stream.close()
                except Exception:  # noqa: BLE001 - best-effort cleanup
                    pass


class StdioSmokeTests(unittest.TestCase):
    def test_initialize_then_list_tools_default_mode(self) -> None:
        proc = _spawn({})
        try:
            init = _request(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize"})
            self.assertIn("serverInfo", init["result"])
            tools = _request(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
            names = {t["name"] for t in tools["result"]["tools"]}
            self.assertIn("get_intent", names)
            self.assertIn("submit_transfer", names)
        finally:
            _shutdown(proc)

    def test_initialize_then_list_tools_readonly_mode(self) -> None:
        proc = _spawn({"CRYPTOBANK_READONLY": "true"})
        try:
            _request(proc, {"jsonrpc": "2.0", "id": 1, "method": "initialize"})
            tools = _request(proc, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
            names = {t["name"] for t in tools["result"]["tools"]}
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
                self.assertNotIn(hidden, names)
        finally:
            _shutdown(proc)

    def test_missing_api_key_exits_with_message(self) -> None:
        env = os.environ.copy()
        env.pop("CRYPTOBANK_API_KEY", None)
        env["PYTHONPATH"] = _PROJECT_ROOT + "/src"
        proc = subprocess.Popen(
            [sys.executable, "-m", "cryptobank_mcp"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            text=True,
        )
        try:
            _, err = proc.communicate(timeout=5)
        finally:
            for stream in (proc.stdout, proc.stderr):
                if stream is not None and not stream.closed:
                    stream.close()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("CRYPTOBANK_API_KEY", err)


if __name__ == "__main__":
    unittest.main()
