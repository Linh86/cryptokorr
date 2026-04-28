/**
 * Secret redaction helpers for the operator scripts.
 *
 * Both `provision-kernel.ts` and `verify-installed-validator.ts`
 * print error messages to stderr on failure. viem and the ZeroDev
 * SDK happily embed the full RPC / bundler URL — including any
 * `?apiKey=…`, `?bundlerKey=…`, or path-segment project IDs — in
 * the formatted message of their `HttpRequestError` /
 * `RpcRequestError` chain. That fails our PR rule: never log full
 * RPC URLs, bundler URLs, or bearer secrets.
 *
 * `redactUrlsInString` strips every `http(s)://…` URL down to
 * `<protocol>//<host>/<redacted>`. `redactErrorMessage` walks an
 * error's `.cause` chain (capped to keep cyclic causes bounded),
 * concatenates each layer's message, and applies the URL redactor
 * to the whole thing.
 *
 * The redactor is intentionally aggressive about URLs and
 * conservative about everything else: public addresses, hashes,
 * permission ids, kernel version strings, and ABI selectors are
 * left intact so the error remains diagnosable.
 */

/** Cap how far we'll walk an error's cause chain. */
const MAX_CAUSE_DEPTH = 8;

/** Chars we will NOT consume as part of a URL match. */
const URL_TERMINATORS = " \t\r\n'\"`<>";

/**
 * The matcher for an http(s) URL inside a free-form string. We bound
 * the URL on whitespace and a small set of common message
 * delimiters; any URL that contains spaces or quotes is by
 * definition malformed in the error string and the next iteration
 * picks it up.
 */
const URL_PATTERN = new RegExp(
  String.raw`https?:\/\/[^${URL_TERMINATORS.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}]+`,
  "gi",
);

/**
 * Replace every http(s) URL in `input` with a host-only stub.
 *
 * Examples:
 *   redactUrlsInString("fetch failed: http://127.0.0.1:9/?apiKey=secret")
 *     ⇒ "fetch failed: http://127.0.0.1:9/<redacted>"
 *   redactUrlsInString("https://rpc.example/v3/abc-secret-id/chain/84532")
 *     ⇒ "https://rpc.example/<redacted>"
 *
 * If the matched substring fails to parse as a `URL` (rare; usually
 * happens when the regex over-grabs trailing punctuation), the whole
 * match is replaced with the literal `<redacted-url>` rather than
 * letting any remnant of the original URL leak through.
 */
export function redactUrlsInString(input: string): string {
  return input.replace(URL_PATTERN, (raw) => {
    // Strip a trailing punctuation mark that the regex may have
    // greedily consumed (e.g. a `.` ending a sentence after a URL).
    const stripped = raw.replace(/[.,;:]+$/, "");
    try {
      const u = new URL(stripped);
      return `${u.protocol}//${u.host}/<redacted>`;
    } catch {
      return "<redacted-url>";
    }
  });
}

/**
 * Build a single redacted message from an unknown thrown value.
 *
 * Walks the `cause` chain (viem's `HttpRequestError` nests the raw
 * `RpcRequestError` under `.cause` and that nests the underlying
 * fetch failure further down) and joins each layer's message with
 * ` | `. Final string is run through `redactUrlsInString`.
 */
export function redactErrorMessage(err: unknown): string {
  const messages: string[] = [];
  const seen = new Set<unknown>();
  let current: unknown = err;
  let depth = 0;
  while (
    current !== undefined &&
    current !== null &&
    depth < MAX_CAUSE_DEPTH &&
    !seen.has(current)
  ) {
    seen.add(current);
    if (current instanceof Error) {
      if (current.message) {
        messages.push(current.message);
      }
      current = (current as { cause?: unknown }).cause;
    } else {
      messages.push(String(current));
      break;
    }
    depth++;
  }
  if (messages.length === 0) {
    return "<unknown error>";
  }
  return redactUrlsInString(messages.join(" | "));
}
