/**
 * API-key redaction helpers.
 *
 * Per `docs/api/sdk-surface.md`:
 *
 * > `api_key` is **never** logged, **never** included in error
 * > message text, and **never** echoed in repr/inspect output.
 * > Both SDKs strip it from formatted exceptions.
 *
 * The SDK runs every user-facing string (error messages, debug
 * output, `toString` results) through {@link redact} so a typo in
 * a future log line cannot leak the key.
 */

/**
 * The placeholder substituted for any matched API key.
 * Stable + greppable so log analysis can surface accidental leaks.
 */
export const REDACTED = "[REDACTED]";

/**
 * Match a CryptoBank API key (stable `cb_` prefix + opaque body of
 * 16+ url-safe characters). Defensive: matches anywhere inside a
 * larger string so we catch concatenations like
 * `Authorization: Bearer cb_abc...`.
 */
const API_KEY_PATTERN = /\bcb_[A-Za-z0-9_-]{16,}\b/g;

/**
 * Redact every CryptoBank API key from `value`. Pass through
 * non-string inputs unchanged.
 */
export function redact(value: unknown): unknown {
  if (typeof value === "string") return value.replace(API_KEY_PATTERN, REDACTED);
  return value;
}

/**
 * Redact every CryptoBank API key from a string.
 */
export function redactString(value: string): string {
  return value.replace(API_KEY_PATTERN, REDACTED);
}

/**
 * Recursively redact every string value in a header / detail map.
 * Object keys are preserved as-is; values are scrubbed. Used when
 * an error thrown by the SDK has to surface a request-shape hint
 * to a debug log without leaking the bearer token.
 */
export function redactHeaders(headers: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [name, value] of Object.entries(headers)) {
    out[name] = name.toLowerCase() === "authorization" ? REDACTED : redactString(value);
  }
  return out;
}
