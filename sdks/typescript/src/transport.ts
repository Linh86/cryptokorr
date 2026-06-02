/**
 * Transport layer: fetch wrapper with auth, idempotency, retry, and
 * structured-error decoding. Every SDK method funnels through
 * {@link Transport.request}.
 */

import { toCamelDeep, toSnakeDeep } from "./case.js";
import {
  INITIAL_BACKOFF_MS,
  MAX_BACKOFF_MS,
  RETRY_BUDGET_MULTIPLIER,
  type ResolvedConfig,
} from "./config.js";
import { decodeError, type ErrorEnvelope } from "./errors.js";
import { redactString } from "./redaction.js";

export type HttpMethod = "GET" | "POST" | "PUT" | "PATCH" | "DELETE";

const WRITE_METHODS: ReadonlySet<HttpMethod> = new Set(["POST", "PUT", "PATCH", "DELETE"]);

export interface RequestOptions {
  method: HttpMethod;
  /** Path under the base URL, including the leading slash + `/v1`. */
  path: string;
  /**
   * Request body, in camelCase. Converted to snake_case before
   * serialization so the wire matches the OpenAPI spec.
   */
  body?: unknown;
  /** Query parameters; `undefined` values are dropped. */
  query?: Record<string, string | number | boolean | null | undefined>;
  /** Caller-supplied `Idempotency-Key` for write methods. */
  idempotencyKey?: string;
  /**
   * Skip the bearer auth header. Used by `getRuntimeStatus` since
   * `/v1/health/deep` is on the unauthenticated `:api` pipeline.
   */
  unauthenticated?: boolean;
  /**
   * Per-call timeout override. Defaults to the client's `timeoutMs`.
   */
  timeoutMs?: number;
  /** Per-call retry budget override (ms). */
  retryBudgetMs?: number;
}

/**
 * Polyfill `crypto.randomUUID` so the SDK works on Node 18 (which
 * does have it as `globalThis.crypto.randomUUID`) and older
 * runtimes that ship a partial `crypto` global.
 */
function newIdempotencyKey(): string {
  if (typeof globalThis.crypto?.randomUUID === "function") {
    return globalThis.crypto.randomUUID();
  }
  // Fallback — not cryptographically random; only used when the
  // runtime lacks `crypto.randomUUID`. The runtime accepts any
  // 1–255-char string for `Idempotency-Key`.
  const rand = (): string => Math.random().toString(36).slice(2, 10);
  return `${Date.now().toString(36)}-${rand()}-${rand()}`;
}

function buildUrl(
  baseUrl: string,
  path: string,
  query: RequestOptions["query"],
): string {
  const trimmedPath = path.startsWith("/") ? path : `/${path}`;
  if (!query) return baseUrl + trimmedPath;

  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (value === undefined || value === null) continue;
    params.append(key, String(value));
  }
  const qs = params.toString();
  return qs.length > 0 ? `${baseUrl}${trimmedPath}?${qs}` : baseUrl + trimmedPath;
}

function parseRetryAfter(headerValue: string | null): number | null {
  if (!headerValue) return null;
  const seconds = Number.parseInt(headerValue, 10);
  if (Number.isFinite(seconds) && seconds >= 0) return seconds;
  // RFC-7231 also allows an HTTP-date; we ignore that variant for
  // simplicity. Phoenix uses integer seconds.
  return null;
}

interface ParsedResponse {
  ok: boolean;
  status: number;
  body: unknown;
  requestId: string | null;
  retryAfterSeconds: number | null;
}

async function readResponse(response: Response): Promise<ParsedResponse> {
  const requestId = response.headers.get("x-request-id");
  const retryAfter = parseRetryAfter(response.headers.get("retry-after"));
  const text = await response.text();
  let parsed: unknown = null;
  if (text.length > 0) {
    try {
      parsed = JSON.parse(text) as unknown;
    } catch {
      parsed = { raw: text };
    }
  }
  return {
    ok: response.ok,
    status: response.status,
    body: parsed,
    requestId,
    retryAfterSeconds: retryAfter,
  };
}

function extractEnvelope(body: unknown): ErrorEnvelope {
  if (
    body !== null &&
    typeof body === "object" &&
    "error" in body &&
    typeof (body as { error: unknown }).error === "object" &&
    (body as { error: unknown }).error !== null
  ) {
    const err = (body as { error: ErrorEnvelope }).error;
    return {
      code: typeof err.code === "string" ? err.code : "unknown_error",
      message: typeof err.message === "string" ? err.message : "Unknown error",
      hint: typeof err.hint === "string" ? err.hint : null,
      retryable: Boolean(err.retryable),
      details: err.details ?? {},
    };
  }
  return {
    code: "unknown_error",
    message: "Non-JSON or unrecognized error envelope",
    hint: null,
    retryable: false,
  };
}

function backoffDelay(attempt: number, retryAfterSeconds: number | null): number {
  if (retryAfterSeconds !== null) {
    return Math.min(retryAfterSeconds * 1000, MAX_BACKOFF_MS);
  }
  // Exponential: 250ms, 500ms, 1s, 2s, ... capped at 30s.
  const base = INITIAL_BACKOFF_MS * 2 ** attempt;
  return Math.min(base, MAX_BACKOFF_MS);
}

function sleep(ms: number, signal?: AbortSignal): Promise<void> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new Error("Aborted"));
      return;
    }
    const timer = setTimeout(() => {
      signal?.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = (): void => {
      clearTimeout(timer);
      reject(new Error("Aborted"));
    };
    signal?.addEventListener("abort", onAbort, { once: true });
  });
}

export class Transport {
  constructor(private readonly cfg: ResolvedConfig) {}

  async request<T = unknown>(opts: RequestOptions): Promise<T> {
    const url = buildUrl(this.cfg.baseUrl, opts.path, opts.query);
    const isWrite = WRITE_METHODS.has(opts.method);
    const idempotencyKey =
      isWrite ? (opts.idempotencyKey ?? newIdempotencyKey()) : undefined;

    const headers: Record<string, string> = {
      "user-agent": this.cfg.userAgent,
      accept: "application/json",
    };
    if (!opts.unauthenticated) headers["authorization"] = `Bearer ${this.cfg.apiKey}`;
    if (idempotencyKey !== undefined) headers["idempotency-key"] = idempotencyKey;

    let bodyText: string | undefined;
    if (opts.body !== undefined && opts.body !== null) {
      headers["content-type"] = "application/json";
      bodyText = JSON.stringify(toSnakeDeep(opts.body));
    }

    const timeoutMs = opts.timeoutMs ?? this.cfg.timeoutMs;
    const retryBudgetMs =
      opts.retryBudgetMs ?? this.cfg.timeoutMs * RETRY_BUDGET_MULTIPLIER;

    const startedAt = Date.now();
    let attempt = 0;

    // Retry loop. Only retries on `error.retryable === true` AND
    // when the request carried an `Idempotency-Key` (auto or
    // caller-supplied) — matches the spec in
    // `docs/api/error-codes.md`.
    while (true) {
      attempt += 1;

      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), timeoutMs);

      let parsed: ParsedResponse;
      try {
        const init: RequestInit = {
          method: opts.method,
          headers,
          signal: controller.signal,
        };
        if (bodyText !== undefined) init.body = bodyText;
        const response = await this.cfg.fetch(url, init);
        parsed = await readResponse(response);
      } catch (rawErr) {
        clearTimeout(timer);
        const err = rawErr instanceof Error ? rawErr : new Error(String(rawErr));
        // `AbortError` is named differently across runtimes; check
        // both shape and name.
        const isAbort = err.name === "AbortError" || /aborted/i.test(err.message);
        if (isAbort) {
          throw new Error(
            `Cryptokorr: request to ${redactString(opts.path)} timed out after ${timeoutMs}ms`,
          );
        }
        throw new Error(
          `Cryptokorr: network error contacting ${redactString(opts.path)}: ${redactString(err.message)}`,
        );
      } finally {
        clearTimeout(timer);
      }

      if (parsed.ok) {
        return toCamelDeep(parsed.body) as T;
      }

      const envelope = extractEnvelope(parsed.body);
      const apiError = decodeError({
        status: parsed.status,
        envelope,
        requestId: parsed.requestId,
        retryAfterSeconds: parsed.retryAfterSeconds,
      });

      const canRetry =
        envelope.retryable === true &&
        idempotencyKey !== undefined &&
        Date.now() - startedAt <
          retryBudgetMs - backoffDelay(attempt, parsed.retryAfterSeconds);

      if (!canRetry) throw apiError;

      const delay = backoffDelay(attempt, parsed.retryAfterSeconds);
      await sleep(delay);
    }
  }
}
