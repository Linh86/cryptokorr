import { describe, expect, it } from "vitest";
import {
  APIError,
  AuthenticationError,
  AuthorizationError,
  ChainPausedError,
  ConflictError,
  IdempotencyConflictError,
  MorphoSafetyError,
  NotFoundError,
  RateLimitError,
  ServiceUnavailableError,
  SwapSafetyError,
  UpstreamError,
  ValidationError,
  WorkspacePausedError,
  WrongStateError,
  classifyError,
  decodeError,
} from "../src/errors.js";

describe("classifyError", () => {
  const cases: Array<[number, string, typeof APIError]> = [
    [401, "missing_authorization", AuthenticationError],
    [401, "invalid_credentials", AuthenticationError],
    [403, "insufficient_role", AuthorizationError],
    [404, "not_found", NotFoundError],
    [409, "idempotency_conflict", IdempotencyConflictError],
    [409, "wrong_state", WrongStateError],
    [409, "not_safe_to_abort", WrongStateError],
    [409, "something_else", ConflictError],
    [422, "invalid_amount", ValidationError],
    [422, "swap_amount_invalid", SwapSafetyError],
    [422, "swap_chain_not_supported", SwapSafetyError],
    [422, "morpho_vault_not_allowlisted", MorphoSafetyError],
    [422, "morpho_snapshot_drifted", MorphoSafetyError],
    [429, "rate_limited", RateLimitError],
    [502, "upstream_unavailable", UpstreamError],
    [503, "workspace_paused", WorkspacePausedError],
    [503, "chain_paused", ChainPausedError],
    [503, "upstream_unavailable", UpstreamError],
    [503, "service_unavailable", ServiceUnavailableError],
    [504, "upstream_timeout", UpstreamError],
    [499, "weird_status", APIError],
  ];

  for (const [status, code, klass] of cases) {
    it(`maps (${status}, ${code}) to ${klass.name}`, () => {
      expect(classifyError(status, code)).toBe(klass);
    });
  }
});

describe("decodeError", () => {
  it("builds a structured error with all envelope fields", () => {
    const err = decodeError({
      status: 422,
      envelope: {
        code: "invalid_amount",
        message: "amount must be a positive decimal",
        hint: "use \"10.5\"",
        retryable: false,
        details: { amount: ["must be greater than zero"] },
      },
      requestId: "req_abc",
      retryAfterSeconds: null,
    });

    expect(err).toBeInstanceOf(ValidationError);
    expect(err).toBeInstanceOf(APIError);
    expect(err.code).toBe("invalid_amount");
    expect(err.message).toBe("amount must be a positive decimal");
    expect(err.hint).toBe('use "10.5"');
    expect(err.retryable).toBe(false);
    expect(err.details).toEqual({ amount: ["must be greater than zero"] });
    expect(err.requestId).toBe("req_abc");
  });

  it("redacts API keys leaked into the message text", () => {
    const err = decodeError({
      status: 401,
      envelope: {
        code: "invalid_credentials",
        message: "key cb_abcdefghij1234567 is no good",
        retryable: false,
      },
    });

    expect(err.message).toBe("key [REDACTED] is no good");
    expect(err.toString()).toBe("AuthenticationError(invalid_credentials): key [REDACTED] is no good");
  });

  it("preserves Retry-After on rate-limit errors", () => {
    const err = decodeError({
      status: 429,
      envelope: { code: "rate_limited", message: "slow down", retryable: true },
      retryAfterSeconds: 12,
    });

    expect(err).toBeInstanceOf(RateLimitError);
    expect(err.retryable).toBe(true);
    expect(err.retryAfterSeconds).toBe(12);
  });

  it("classifies 502 as UpstreamError regardless of code", () => {
    const err = decodeError({
      status: 502,
      envelope: { code: "anything", message: "bad gateway", retryable: true },
    });
    expect(err).toBeInstanceOf(UpstreamError);
    expect(err).toBeInstanceOf(ServiceUnavailableError);
  });

  it("classifies idempotency_conflict via 409", () => {
    const err = decodeError({
      status: 409,
      envelope: {
        code: "idempotency_conflict",
        message: "key reused with mismatched body",
        hint: "prior intent: int_xyz",
        retryable: false,
      },
    });
    expect(err).toBeInstanceOf(IdempotencyConflictError);
    expect(err.hint).toBe("prior intent: int_xyz");
  });
});
