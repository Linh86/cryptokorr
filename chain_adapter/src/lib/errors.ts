/**
 * Typed error classes for the adapter.
 *
 * Every error carries a stable `code` for programmatic handling
 * and a human-readable `message`.
 */

export class AdapterError extends Error {
  readonly code: string;
  readonly statusCode: number;
  readonly retryable: boolean;

  constructor(
    code: string,
    message: string,
    statusCode: number = 500,
    retryable: boolean = false,
  ) {
    super(message);
    this.name = "AdapterError";
    this.code = code;
    this.statusCode = statusCode;
    this.retryable = retryable;
  }
}

/** Request body failed Zod validation. */
export class ValidationError extends AdapterError {
  readonly details: unknown;

  constructor(message: string, details: unknown) {
    super("validation_error", message, 400, false);
    this.name = "ValidationError";
    this.details = details;
  }
}

/** Chain or asset not supported in this adapter version. */
export class UnsupportedError extends AdapterError {
  constructor(message: string) {
    super("unsupported", message, 422, false);
    this.name = "UnsupportedError";
  }
}

/** Chain-level execution failure (revert, gas, signing). */
export class ExecutionError extends AdapterError {
  constructor(code: string, message: string, retryable: boolean = false) {
    super(code, message, 502, retryable);
    this.name = "ExecutionError";
  }
}

/** Callback delivery to Phoenix failed. */
export class CallbackError extends AdapterError {
  constructor(message: string) {
    super("callback_failed", message, 502, true);
    this.name = "CallbackError";
  }
}

/** Feature is scaffolded but not wired to a real implementation. */
export class NotImplementedError extends AdapterError {
  constructor(feature: string) {
    super("not_implemented", `${feature} is not yet implemented`, 501, false);
    this.name = "NotImplementedError";
  }
}
