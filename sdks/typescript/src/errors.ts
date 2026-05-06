/**
 * Typed exception hierarchy mirroring `docs/api/error-codes.md`.
 *
 * SDK consumers `instanceof`-check the class to react to a class
 * of failures (e.g. "any validation error") and switch on `.code`
 * to react to a specific error code. Both surfaces are stable.
 */

import { redactString } from "./redaction.js";

/**
 * Raw error envelope from `/v1/*` non-2xx responses.
 *
 * ```jsonc
 * { "error": { "code": "...", "message": "...",
 *              "hint": "...", "retryable": true,
 *              "details": { "field": ["..."] } } }
 * ```
 */
export interface ErrorEnvelope {
  code: string;
  message: string;
  hint?: string | null;
  retryable?: boolean;
  details?: Record<string, string[]>;
}

export interface APIErrorOptions {
  status: number;
  code: string;
  message: string;
  hint?: string | null;
  retryable?: boolean;
  details?: Record<string, string[]>;
  requestId?: string | null;
  retryAfterSeconds?: number | null;
}

/**
 * Base class. Every non-2xx response surfaces as an `APIError`
 * subclass keyed off the wire `error.code`. The `code`,
 * `retryable`, and `details` fields are stable across releases —
 * `message` and `hint` are operator copy and may be reworded.
 */
export class APIError extends Error {
  public readonly status: number;
  public readonly code: string;
  public readonly hint: string | null;
  public readonly retryable: boolean;
  public readonly details: Record<string, string[]>;
  public readonly requestId: string | null;
  public readonly retryAfterSeconds: number | null;

  constructor(opts: APIErrorOptions) {
    super(redactString(opts.message ?? ""));
    this.name = new.target.name;
    this.status = opts.status;
    this.code = opts.code;
    this.hint = opts.hint ?? null;
    this.retryable = Boolean(opts.retryable);
    this.details = opts.details ?? {};
    this.requestId = opts.requestId ?? null;
    this.retryAfterSeconds = opts.retryAfterSeconds ?? null;

    // Restore the prototype chain for ES5 targets.
    Object.setPrototypeOf(this, new.target.prototype);
  }

  /** API-key-redacted, copy-paste-safe summary. */
  override toString(): string {
    return `${this.name}(${this.code}): ${this.message}`;
  }
}

// --- 401 / 403 ----------------------------------------------------------

export class AuthenticationError extends APIError {}
export class AuthorizationError extends APIError {}

// --- 404 ----------------------------------------------------------------

export class NotFoundError extends APIError {}

// --- 422 ----------------------------------------------------------------

export class ValidationError extends APIError {}
/** Subclass for the `swap_*` family. */
export class SwapSafetyError extends ValidationError {}
/** Subclass for the `morpho_*` family. */
export class MorphoSafetyError extends ValidationError {}

// --- 409 ----------------------------------------------------------------

export class ConflictError extends APIError {}
export class IdempotencyConflictError extends ConflictError {}
export class WrongStateError extends ConflictError {}

// --- 429 ----------------------------------------------------------------

export class RateLimitError extends APIError {}

// --- 5xx ----------------------------------------------------------------

export class ServiceUnavailableError extends APIError {}
export class WorkspacePausedError extends ServiceUnavailableError {}
export class ChainPausedError extends ServiceUnavailableError {}
export class UpstreamError extends ServiceUnavailableError {}

// --- Decoder ------------------------------------------------------------

const SWAP_PREFIX = "swap_";
const MORPHO_PREFIX = "morpho_";

/** Pick the most specific `APIError` subclass for `(status, code)`. */
export function classifyError(
  status: number,
  code: string,
): new (opts: APIErrorOptions) => APIError {
  switch (status) {
    case 401:
      return AuthenticationError;
    case 403:
      return AuthorizationError;
    case 404:
      return NotFoundError;
    case 409:
      if (code === "idempotency_conflict") return IdempotencyConflictError;
      if (code === "wrong_state" || code === "not_safe_to_abort") return WrongStateError;
      return ConflictError;
    case 422:
      if (code.startsWith(SWAP_PREFIX)) return SwapSafetyError;
      if (code.startsWith(MORPHO_PREFIX)) return MorphoSafetyError;
      return ValidationError;
    case 429:
      return RateLimitError;
    case 502:
    case 504:
      return UpstreamError;
    case 503:
      if (code === "workspace_paused") return WorkspacePausedError;
      if (code === "chain_paused") return ChainPausedError;
      if (code === "upstream_unavailable") return UpstreamError;
      return ServiceUnavailableError;
    default:
      return APIError;
  }
}

export interface DecodeErrorContext {
  status: number;
  envelope: ErrorEnvelope;
  requestId?: string | null;
  retryAfterSeconds?: number | null;
}

/** Build the right `APIError` subclass instance from a non-2xx response. */
export function decodeError(ctx: DecodeErrorContext): APIError {
  const { status, envelope, requestId, retryAfterSeconds } = ctx;
  const ErrorClass = classifyError(status, envelope.code);
  return new ErrorClass({
    status,
    code: envelope.code,
    message: envelope.message,
    hint: envelope.hint ?? null,
    retryable: Boolean(envelope.retryable),
    details: envelope.details ?? {},
    requestId: requestId ?? null,
    retryAfterSeconds: retryAfterSeconds ?? null,
  });
}
