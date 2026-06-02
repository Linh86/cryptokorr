"""Unit tests for the sync ``CryptoKorr`` client.

The tests patch ``Transport._urlopen`` with ``CallRecorder`` so a
single fixture pins what the SDK puts on the wire (method, path,
headers, body) and what it parses out of the response.
"""

from __future__ import annotations

import os
from unittest.mock import patch

import pytest

# conftest.py prepends src/ to sys.path; these imports work without
# an editable install.
import cryptokorr
from cryptokorr import CryptoKorr
from cryptokorr.errors import (
    AuthenticationError,
    AuthorizationError,
    ConflictError,
    IdempotencyConflictError,
    MorphoSafetyError,
    NotFoundError,
    RateLimitError,
    SwapSafetyError,
    UpstreamError,
    ValidationError,
    WorkspacePausedError,
    WrongStateError,
)

from conftest import CallRecorder, FakeResponse


def _client(recorder: CallRecorder, *, base_url: str = "https://api.example.test") -> CryptoKorr:
    client = CryptoKorr(api_key="cb_testkey_xxxxxxxxxxxxxxxxxxxxxxxxxxxx", base_url=base_url)
    # Patch the transport's seam.
    client._transport._urlopen = recorder  # type: ignore[method-assign]
    return client


# -- Construction + auth ----------------------------------------------------


class TestConstruction:
    def test_requires_api_key(self):
        with pytest.raises(ValueError, match="api_key"):
            CryptoKorr(api_key="", base_url="https://api.example.test")

    def test_requires_base_url(self):
        with pytest.raises(ValueError, match="base_url"):
            CryptoKorr(api_key="cb_x", base_url="")

    def test_timeout_must_be_positive(self):
        with pytest.raises(ValueError, match="timeout_ms"):
            CryptoKorr(api_key="cb_x", base_url="https://api.example.test", timeout_ms=0)

    def test_from_env_reads_required_vars(self, monkeypatch):
        monkeypatch.setenv("CRYPTOKORR_API_KEY", "cb_envkey_xxxxxxxxxxxxxxxxxxxxxx")
        monkeypatch.setenv("CRYPTOKORR_BASE_URL", "https://api.from-env.test")
        client = CryptoKorr.from_env()
        assert client._base_url == "https://api.from-env.test"

    def test_from_env_missing_api_key_raises(self, monkeypatch):
        monkeypatch.delenv("CRYPTOKORR_API_KEY", raising=False)
        with pytest.raises(ValueError, match="CRYPTOKORR_API_KEY"):
            CryptoKorr.from_env()

    def test_from_env_invalid_timeout_raises(self, monkeypatch):
        monkeypatch.setenv("CRYPTOKORR_API_KEY", "cb_x")
        monkeypatch.setenv("CRYPTOKORR_TIMEOUT_MS", "not-an-int")
        with pytest.raises(ValueError, match="CRYPTOKORR_TIMEOUT_MS"):
            CryptoKorr.from_env()


# -- Secret hygiene ---------------------------------------------------------


class TestSecretHygiene:
    """The API key must NEVER appear in repr / str output."""

    def test_repr_redacts_api_key(self):
        secret = "cb_supersecret_DO_NOT_LEAK_xxxxxxxxxxxxxxxxxxxx"
        client = CryptoKorr(api_key=secret, base_url="https://api.example.test")
        rendered = repr(client)
        assert secret not in rendered
        assert "DO_NOT_LEAK" not in rendered
        assert "supersecret" not in rendered
        # The cb_ prefix marker is preserved so operators can
        # correlate without echoing the secret body.
        assert "cb_" in rendered

    def test_repr_redacts_short_key(self):
        client = CryptoKorr(api_key="cb_short", base_url="https://api.example.test")
        rendered = repr(client)
        assert "cb_short" not in rendered

    def test_error_str_does_not_contain_key(self):
        recorder = CallRecorder([
            FakeResponse(
                status=401,
                body={"error": {"code": "invalid_credentials", "message": "bad", "retryable": False}},
            )
        ])
        client = _client(recorder)
        with pytest.raises(AuthenticationError) as ei:
            client.get_intent("11111111-1111-4111-8111-111111111111")

        secret = "cb_testkey_xxxxxxxxxxxxxxxxxxxxxxxxxxxx"
        rendered = str(ei.value) + repr(ei.value)
        assert secret not in rendered


# -- Wire shape: method / path / headers ------------------------------------


class TestWireShape:
    def test_get_intent_uses_get_and_authorization_header(self):
        recorder = CallRecorder([FakeResponse(body={"intent": {"id": "abc", "state": "submitted"}})])
        client = _client(recorder)
        client.get_intent("abc")

        call = recorder.calls[0]
        assert call.method == "GET"
        assert call.path == "/v1/intents/abc"
        assert call.headers["authorization"].startswith("Bearer cb_testkey_")
        assert "idempotency-key" not in call.headers, "GET must not carry an Idempotency-Key"

    def test_submit_transfer_carries_idempotency_key_when_supplied(self):
        recorder = CallRecorder([FakeResponse(status=202, body={"intent_id": "i", "state": "submitted"})])
        client = _client(recorder)
        client.submit_transfer(
            agent_id="agent-test",
            asset="USDC",
            chain="base-sepolia",
            amount="10",
            target={"raw_address": "0x" + "a" * 40},
            idempotency_key="my-key-1",
        )

        call = recorder.calls[0]
        assert call.method == "POST"
        assert call.path == "/v1/intents"
        assert call.headers["idempotency-key"] == "my-key-1"
        assert call.json_body["idempotency_key"] == "my-key-1"
        assert call.json_body["kind"] == "transfer"
        assert call.json_body["chain"] == "base-sepolia"
        assert call.json_body["target"] == {"raw_address": "0x" + "a" * 40}

    def test_submit_transfer_auto_generates_idempotency_key(self):
        recorder = CallRecorder([FakeResponse(status=202, body={"intent_id": "i", "state": "submitted"})])
        client = _client(recorder)
        client.submit_transfer(
            agent_id="agent-test",
            asset="USDC",
            chain="base-sepolia",
            amount="10",
            target={"raw_address": "0x" + "a" * 40},
        )

        call = recorder.calls[0]
        # 32 hex chars from secrets.token_hex(16).
        assert len(call.headers["idempotency-key"]) == 32
        assert call.headers["idempotency-key"] == call.json_body["idempotency_key"]

    def test_submit_swap_uses_swap_kind(self):
        recorder = CallRecorder([FakeResponse(status=202, body={"intent_id": "i", "state": "submitted"})])
        client = _client(recorder)
        client.submit_swap(
            agent_id="agent-test",
            chain="base-sepolia",
            source_asset="USDC",
            destination_asset="USDC",
            amount="10",
        )

        call = recorder.calls[0]
        assert call.json_body["kind"] == "swap"
        assert call.json_body["chain"] == "base-sepolia"
        assert call.json_body["destination_asset"] == "USDC"

    def test_submit_allocate_idle_capital_uses_public_wire_kind(self):
        # The Phoenix wire enum is `allocate_idle_capital` (public
        # name) — `priv/openapi/openapi.json` `IntentSubmissionRequest.kind`
        # only accepts `transfer | swap | scheduled_transfer |
        # allocate_idle_capital`. The persisted `AgentIntent.kind`
        # atom is `:defi_yield_deposit` internally, but submitting
        # the internal name is rejected with `{:invalid, :kind}`.
        recorder = CallRecorder([FakeResponse(status=202, body={"intent_id": "i", "state": "submitted"})])
        client = _client(recorder)
        client.submit_allocate_idle_capital(
            agent_id="agent-test",
            amount="100",
            vault_address="0xvault000000000000000000000000000000000001",
        )

        call = recorder.calls[0]
        assert call.json_body["kind"] == "allocate_idle_capital"
        # Defaults for asset / chain align with MVP Morpho.
        assert call.json_body["asset"] == "USDC"
        assert call.json_body["chain"] == "base-sepolia"
        assert call.json_body["target"] == {"raw_address": "0xvault000000000000000000000000000000000001"}

    def test_simulate_intent_default_reason_is_refresh(self):
        recorder = CallRecorder([FakeResponse(body={"intent_id": "i"})])
        client = _client(recorder)
        client.simulate_intent("intent-1")

        call = recorder.calls[0]
        assert call.path == "/v1/intents/intent-1/simulate"
        assert call.json_body == {"reason": "refresh"}

    def test_cancel_intent_requires_reason(self):
        recorder = CallRecorder([FakeResponse(body={"intent_id": "i"})])
        client = _client(recorder)
        client.cancel_intent("intent-1", reason="superseded")

        call = recorder.calls[0]
        assert call.path == "/v1/intents/intent-1/cancel"
        assert call.json_body == {"reason": "superseded"}

    def test_get_audit_trail_calls_replay_endpoint(self):
        recorder = CallRecorder([FakeResponse(body={"intent": {}, "audit": []})])
        client = _client(recorder)
        client.get_audit_trail("intent-1")

        call = recorder.calls[0]
        assert call.method == "GET"
        assert call.path == "/v1/intents/intent-1/replay"

    def test_runtime_status_calls_health_deep(self):
        recorder = CallRecorder([FakeResponse(body={"status": "ok"})])
        client = _client(recorder)
        client.get_runtime_status()

        call = recorder.calls[0]
        assert call.method == "GET"
        assert call.path == "/v1/health/deep"


# -- Decision waiter -------------------------------------------------------


class TestWaitForDecision:
    def test_returns_immediately_when_intent_already_decided(self):
        intent = {"id": "i", "state": "decided", "current_decision_id": "d-1"}
        decision = {"id": "d-1", "intent_id": "i", "outcome": "approval_required"}
        recorder = CallRecorder([
            FakeResponse(body=intent),
            FakeResponse(body={"decision": decision}),
        ])
        client = _client(recorder)
        result = client.wait_for_decision("i", timeout_seconds=10, poll_interval_ms=10)

        assert result["timed_out"] is False
        assert result["requires_approval"] is True
        assert result["decision"]["outcome"] == "approval_required"

    def test_polls_until_state_changes(self):
        recorder = CallRecorder([
            FakeResponse(body={"id": "i", "state": "evaluating", "current_decision_id": None}),
            FakeResponse(body={"id": "i", "state": "decided", "current_decision_id": "d-1"}),
            FakeResponse(body={"decision": {"id": "d-1", "outcome": "auto_exec"}}),
        ])
        client = _client(recorder)
        result = client.wait_for_decision("i", timeout_seconds=10, poll_interval_ms=10)

        assert result["timed_out"] is False
        assert result["requires_approval"] is False
        assert result["decision"]["outcome"] == "auto_exec"

    def test_times_out_when_state_never_changes(self):
        # Two evaluating polls; the second consumes the deadline.
        evaluating = {"id": "i", "state": "evaluating", "current_decision_id": None}
        recorder = CallRecorder([
            FakeResponse(body=evaluating),
            FakeResponse(body=evaluating),
            FakeResponse(body=evaluating),
            FakeResponse(body=evaluating),
        ])
        client = _client(recorder)
        # 0.05s timeout + 30ms poll → at most a couple of iterations.
        result = client.wait_for_decision("i", timeout_seconds=0.05, poll_interval_ms=30)

        assert result["timed_out"] is True
        assert result["requires_approval"] is False


# -- Typed exceptions -------------------------------------------------------


class TestTypedExceptions:
    @pytest.mark.parametrize(
        "status,code,exc",
        [
            (401, "missing_authorization", AuthenticationError),
            (401, "invalid_credentials", AuthenticationError),
            (403, "insufficient_role", AuthorizationError),
            (404, "not_found", NotFoundError),
            (409, "wrong_state", WrongStateError),
            (409, "idempotency_conflict", IdempotencyConflictError),
            (422, "invalid_body", ValidationError),
            (422, "swap_amount_invalid", SwapSafetyError),
            (422, "swap_deadline_expired", SwapSafetyError),
            (422, "morpho_snapshot_expired", MorphoSafetyError),
            (403, "operator_role_required", MorphoSafetyError),
            (429, "rate_limited", RateLimitError),
            (503, "workspace_paused", WorkspacePausedError),
            (502, "upstream_unavailable", UpstreamError),
            (504, "upstream_timeout", UpstreamError),
        ],
    )
    def test_status_code_maps_to_typed_exception(self, status, code, exc):
        recorder = CallRecorder([
            FakeResponse(
                status=status,
                body={"error": {"code": code, "message": "x", "retryable": False}},
            )
        ])
        client = _client(recorder)
        with pytest.raises(exc) as ei:
            client.get_intent("abc")
        assert ei.value.code == code
        assert ei.value.status == status

    def test_idempotency_conflict_inherits_from_conflict(self):
        recorder = CallRecorder([
            FakeResponse(
                status=409,
                body={"error": {"code": "idempotency_conflict", "message": "x", "retryable": False, "hint": "prior=abc"}},
            )
        ])
        client = _client(recorder)
        with pytest.raises(IdempotencyConflictError) as ei:
            client.submit_transfer(
                agent_id="a",
                asset="USDC",
                chain="base-sepolia",
                amount="1",
                target={"raw_address": "0x" + "0" * 40},
            )
        assert isinstance(ei.value, ConflictError)
        assert ei.value.hint == "prior=abc"

    def test_unknown_code_falls_back_to_status_class(self):
        recorder = CallRecorder([
            FakeResponse(
                status=422,
                body={"error": {"code": "future_code_not_yet_in_sdk", "message": "x", "retryable": False}},
            )
        ])
        client = _client(recorder)
        with pytest.raises(ValidationError) as ei:
            client.get_intent("abc")
        assert ei.value.code == "future_code_not_yet_in_sdk"

    def test_malformed_envelope_does_not_crash(self):
        # No `error` key — surface as a synthetic http_<status>.
        recorder = CallRecorder([FakeResponse(status=500, body={"unexpected": True})])
        client = _client(recorder)
        with pytest.raises(cryptokorr.APIError) as ei:
            client.get_intent("abc")
        assert ei.value.code == "http_500"


# -- Retry posture ---------------------------------------------------------


class TestRetry:
    def test_retries_on_retryable_then_succeeds(self):
        # First call returns rate-limited with retry-after 0; second
        # call returns 200. Sleep is patched to keep the test fast.
        recorder = CallRecorder([
            FakeResponse(
                status=429,
                body={"error": {"code": "rate_limited", "message": "x", "retryable": True}},
                headers={"retry-after": "0"},
            ),
            FakeResponse(status=200, body={"id": "ok"}),
        ])
        client = _client(recorder)
        with patch("cryptokorr._http.time.sleep"):
            result = client.get_runtime_status()
        assert result == {"id": "ok"}
        assert len(recorder.calls) == 2

    def test_does_not_retry_when_error_is_not_retryable(self):
        recorder = CallRecorder([
            FakeResponse(
                status=422,
                body={"error": {"code": "invalid_body", "message": "x", "retryable": False}},
            )
        ])
        client = _client(recorder)
        with pytest.raises(ValidationError):
            client.submit_transfer(
                agent_id="a",
                asset="USDC",
                chain="base-sepolia",
                amount="1",
                target={"raw_address": "0x" + "0" * 40},
            )
        assert len(recorder.calls) == 1, "non-retryable error must not be retried"

    def test_does_not_auto_retry_security_endpoints(self):
        # Even though 429 is retryable, /v1/security/* must surface
        # immediately so the operator-cap throttling is loud.
        recorder = CallRecorder([
            FakeResponse(
                status=429,
                body={"error": {"code": "rate_limited", "message": "x", "retryable": True}},
                headers={"retry-after": "1"},
            )
        ])
        client = _client(recorder)
        with pytest.raises(RateLimitError):
            client.operator.pause_runtime()
        assert len(recorder.calls) == 1

    def test_transport_error_surfaces_as_upstream_error(self):
        import urllib.error

        boom = urllib.error.URLError("connection refused")
        # Provide enough fake responses for 1 attempt + 4 retries.
        recorder = CallRecorder([boom, boom, boom, boom, boom])
        client = _client(recorder)
        with patch("cryptokorr._http.time.sleep"):
            with pytest.raises(UpstreamError) as ei:
                client.get_runtime_status()
        assert ei.value.retryable is True
        assert ei.value.status == 0


# -- Operator namespace ----------------------------------------------------


class TestOperator:
    def test_approve_decision_calls_approval_endpoint(self):
        recorder = CallRecorder([FakeResponse(body={"intent_id": "i", "decision_id": "d"})])
        client = _client(recorder)
        client.operator.approve_decision("d", actor_id="me", reason="ok")

        call = recorder.calls[0]
        assert call.method == "POST"
        assert call.path == "/v1/approvals/d/approve"
        assert call.json_body == {"actor_id": "me", "reason": "ok"}

    def test_reject_decision_calls_reject_endpoint(self):
        recorder = CallRecorder([FakeResponse(body={"intent_id": "i", "decision_id": "d"})])
        client = _client(recorder)
        client.operator.reject_decision("d", actor_id="me")

        call = recorder.calls[0]
        assert call.path == "/v1/approvals/d/reject"
        assert call.json_body == {"actor_id": "me"}

    def test_pause_resume_runtime(self):
        recorder = CallRecorder([
            FakeResponse(body={"paused": True}),
            FakeResponse(body={"paused": False}),
        ])
        client = _client(recorder)
        paused = client.operator.pause_runtime()
        resumed = client.operator.resume_runtime()
        assert paused == {"paused": True}
        assert resumed == {"paused": False}

        assert recorder.calls[0].path == "/v1/security/pause"
        assert recorder.calls[1].path == "/v1/security/resume"


# -- Approval-required is a successful response ----------------------------


class TestApprovalRequiredAsSuccess:
    """Acceptance: SDK handles approval_required as a normal result, not an exception."""

    def test_submit_followed_by_wait_returns_approval_required(self):
        intent_after_submit = {"intent_id": "i", "state": "submitted"}
        intent_decided = {"id": "i", "state": "decided", "current_decision_id": "d-1"}
        decision = {"id": "d-1", "intent_id": "i", "outcome": "approval_required"}

        recorder = CallRecorder([
            FakeResponse(status=202, body=intent_after_submit),
            FakeResponse(body=intent_decided),
            FakeResponse(body={"decision": decision}),
        ])
        client = _client(recorder)
        client.submit_transfer(
            agent_id="agent-test",
            asset="USDC",
            chain="base-sepolia",
            amount="10",
            target={"raw_address": "0x" + "a" * 40},
        )
        result = client.wait_for_decision("i", timeout_seconds=10, poll_interval_ms=10)

        # No exception was raised at any step — approval_required is a
        # successful response surface.
        assert result["requires_approval"] is True
        assert result["decision"]["outcome"] == "approval_required"
