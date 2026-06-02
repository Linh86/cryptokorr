/**
 * Client config + environment loader.
 *
 * Per `docs/api/sdk-surface.md`:
 *
 * | Setting       | Env var                | Default                       |
 * | ------------- | ---------------------- | ----------------------------- |
 * | `apiKey`      | `CRYPTOKORR_API_KEY`   | (required, no default)        |
 * | `baseUrl`     | `CRYPTOKORR_BASE_URL`  | `http://localhost:4000`       |
 * | `timeoutMs`   | `CRYPTOKORR_TIMEOUT_MS`| `15_000` (ms)                 |
 */

export const SDK_VERSION = "0.1.0";
export const DEFAULT_BASE_URL = "http://localhost:4000";
export const DEFAULT_TIMEOUT_MS = 15_000;
export const DEFAULT_USER_AGENT = `cryptokorr-js/${SDK_VERSION}`;
/** Hard cap on retry budget (`timeoutMs * RETRY_BUDGET_MULTIPLIER`). */
export const RETRY_BUDGET_MULTIPLIER = 4;
/** Exponential backoff cap. */
export const MAX_BACKOFF_MS = 30_000;
/** Initial backoff. */
export const INITIAL_BACKOFF_MS = 250;

/** Minimal pinned `fetch` signature so we can swap in a mock for tests. */
export type FetchLike = (
  input: string | URL,
  init?: RequestInit,
) => Promise<Response>;

export interface ClientConfig {
  /**
   * Workspace API key in `cb_<...>` form. Sent on every authed
   * request as `Authorization: Bearer <apiKey>`. Never logged,
   * never echoed in errors / `toString` / debug output.
   */
  apiKey: string;
  /** Default `http://localhost:4000`. No trailing slash. */
  baseUrl?: string;
  /** Per-request HTTP timeout. Default 15s. */
  timeoutMs?: number;
  /** `User-Agent` override. Default `cryptokorr-js/<version>`. */
  userAgent?: string;
  /** Override `globalThis.fetch` — handy for tests. */
  fetch?: FetchLike;
}

export interface ResolvedConfig {
  apiKey: string;
  baseUrl: string;
  timeoutMs: number;
  userAgent: string;
  fetch: FetchLike;
}

export function resolveConfig(input: ClientConfig): ResolvedConfig {
  if (typeof input.apiKey !== "string" || input.apiKey.length === 0) {
    throw new Error(
      "CryptoKorr: missing apiKey. Pass `apiKey` to the constructor or set CRYPTOKORR_API_KEY.",
    );
  }
  if (!input.apiKey.startsWith("cb_")) {
    throw new Error(
      'CryptoKorr: apiKey must be a workspace API key in `cb_<...>` form.',
    );
  }

  const baseUrl = (input.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, "");
  const timeoutMs = input.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    throw new Error("CryptoKorr: timeoutMs must be a positive number of milliseconds.");
  }
  const userAgent = input.userAgent ?? DEFAULT_USER_AGENT;
  const fetchImpl =
    input.fetch ??
    (typeof globalThis.fetch === "function"
      ? (globalThis.fetch.bind(globalThis) as FetchLike)
      : null);
  if (!fetchImpl) {
    throw new Error(
      "CryptoKorr: no global `fetch` available. Run on Node 18+ or pass `fetch` in the config.",
    );
  }

  return { apiKey: input.apiKey, baseUrl, timeoutMs, userAgent, fetch: fetchImpl };
}

export function readConfigFromEnv(env: NodeJS.ProcessEnv = process.env): ClientConfig {
  const apiKey = env["CRYPTOKORR_API_KEY"];
  if (typeof apiKey !== "string" || apiKey.length === 0) {
    throw new Error(
      "CryptoKorr.fromEnv: CRYPTOKORR_API_KEY is not set. Export it before calling fromEnv() or pass apiKey to the constructor.",
    );
  }

  const baseUrl = env["CRYPTOKORR_BASE_URL"];
  const timeoutEnv = env["CRYPTOKORR_TIMEOUT_MS"];
  let timeoutMs: number | undefined;
  if (typeof timeoutEnv === "string" && timeoutEnv.length > 0) {
    const parsed = Number.parseInt(timeoutEnv, 10);
    if (!Number.isFinite(parsed) || parsed <= 0) {
      throw new Error(
        `CryptoKorr.fromEnv: CRYPTOKORR_TIMEOUT_MS must be a positive integer, got ${JSON.stringify(timeoutEnv)}.`,
      );
    }
    timeoutMs = parsed;
  }

  const config: ClientConfig = { apiKey };
  if (typeof baseUrl === "string" && baseUrl.length > 0) config.baseUrl = baseUrl;
  if (typeof timeoutMs === "number") config.timeoutMs = timeoutMs;
  return config;
}
