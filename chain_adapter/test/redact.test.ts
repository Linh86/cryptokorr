/**
 * URL-redaction helper tests.
 *
 * These exist because PR #127 review found that
 * `provision-kernel.ts` and `verify-installed-validator.ts` were
 * printing viem's raw `err.message` on failure, and viem embeds the
 * full RPC / bundler URL in its `HttpRequestError` chain. The
 * concrete repro:
 *
 *   BASE_RPC_URL='http://127.0.0.1:9/?apiKey=SHOULD_NOT_LEAK'
 *
 * The CLI catch block now runs `redactErrorMessage` first; these
 * tests pin the redactor so a future refactor can't re-leak.
 */

import { describe, it, expect } from "vitest";
import {
  redactErrorMessage,
  redactUrlsInString,
} from "../scripts/redact.js";

describe("redactUrlsInString", () => {
  it("redacts a query string with apiKey to host-only", () => {
    const input = "fetch failed: http://127.0.0.1:9/?apiKey=SHOULD_NOT_LEAK";
    const out = redactUrlsInString(input);
    expect(out).not.toContain("SHOULD_NOT_LEAK");
    expect(out).not.toContain("apiKey=");
    expect(out).toContain("127.0.0.1:9"); // host preserved
    expect(out).toContain("<redacted>");
  });

  it("redacts a bundler URL with a project-id path segment", () => {
    const input =
      "POST request failed: https://rpc.zerodev.app/api/v3/abc-secret-project-id/chain/84532";
    const out = redactUrlsInString(input);
    expect(out).not.toContain("abc-secret-project-id");
    expect(out).not.toContain("/api/v3/");
    expect(out).toContain("rpc.zerodev.app");
  });

  it("redacts multiple URLs in a single message", () => {
    const input =
      "primary failed http://a.example/?key=AAA, then http://b.example/?token=BBB";
    const out = redactUrlsInString(input);
    expect(out).not.toContain("AAA");
    expect(out).not.toContain("BBB");
    expect(out).not.toContain("?key=");
    expect(out).not.toContain("?token=");
    expect(out).toContain("a.example");
    expect(out).toContain("b.example");
  });

  it("keeps public addresses and hashes intact", () => {
    const input =
      "kernel 0x9400286bC91d1a55369a09f61874792884FeD4B3 reverted at tx 0xabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    const out = redactUrlsInString(input);
    // Both the address and the tx hash are public, not secrets;
    // they must survive redaction so the operator can correlate
    // the failure on a block explorer.
    expect(out).toContain("0x9400286bC91d1a55369a09f61874792884FeD4B3");
    expect(out).toContain(
      "0xabcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
    );
  });

  it("preserves message context around the URL", () => {
    const input = "before http://x.example/?key=secret after";
    const out = redactUrlsInString(input);
    expect(out).toMatch(/^before /);
    expect(out).toMatch(/ after$/);
  });

  it("handles a URL at end of sentence without absorbing the period", () => {
    const input =
      "could not reach http://endpoint.example/?key=secret. retrying.";
    const out = redactUrlsInString(input);
    expect(out).not.toContain("secret");
    // The trailing period must remain attached to the rest of the
    // sentence rather than being captured as part of the URL.
    expect(out).toMatch(/. retrying\./);
  });

  it("falls back to <redacted-url> for malformed URL substrings", () => {
    // Constructed pathological case: `https://` followed by chars
    // the regex grabs but `new URL(...)` rejects. We don't expect
    // this in practice, but if it ever happens the redactor must
    // not let any of the matched substring through.
    const input = "weird https://[invalid host extra";
    const out = redactUrlsInString(input);
    expect(out).not.toContain("[invalid");
  });

  it("does not redact ws://, file://, or other non-http schemes", () => {
    // The PR rule is specifically about RPC + bundler URLs, which
    // are http(s). We don't redact other schemes — they can carry
    // useful context (ws:// for a future WebSocket transport,
    // file:// for local paths in test failures) and they don't
    // commonly carry tokens.
    const input = "ws://localhost:8546 and file:///tmp/x.json";
    const out = redactUrlsInString(input);
    expect(out).toContain("ws://localhost:8546");
    expect(out).toContain("file:///tmp/x.json");
  });

  it("is a no-op on a string with no URL", () => {
    const input = "plain message with no URL anywhere";
    expect(redactUrlsInString(input)).toBe(input);
  });
});

describe("redactErrorMessage", () => {
  it("redacts URLs in a flat Error message", () => {
    const err = new Error(
      "fetch failed at http://127.0.0.1:9/?apiKey=SHOULD_NOT_LEAK",
    );
    const out = redactErrorMessage(err);
    expect(out).not.toContain("SHOULD_NOT_LEAK");
    expect(out).toContain("127.0.0.1:9");
  });

  it("walks the cause chain (viem-style HttpRequestError)", () => {
    // Imitates how viem nests its HTTP error: a top-level Error
    // with a `.cause` that itself has a deeper `.cause`. The URL
    // typically lives in one of the deeper layers.
    const root = new Error(
      "underlying fetch: GET http://127.0.0.1:9/?apiKey=SHOULD_NOT_LEAK",
    );
    const wrapped = new Error("RpcRequestError: rpc call failed", {
      cause: root,
    });
    const top = new Error("HttpRequestError: HTTP request failed", {
      cause: wrapped,
    });
    const out = redactErrorMessage(top);
    expect(out).not.toContain("SHOULD_NOT_LEAK");
    expect(out).toContain("HttpRequestError");
    expect(out).toContain("RpcRequestError");
    expect(out).toContain("127.0.0.1:9");
  });

  it("redacts a bundler URL with a token if it appears in the cause chain", () => {
    const inner = new Error(
      "POST failed for https://bundler.example.invalid/api/v3/abc-secret-project-id/chain/84532",
    );
    const outer = new Error("UserOpRevertedError", { cause: inner });
    const out = redactErrorMessage(outer);
    expect(out).not.toContain("abc-secret-project-id");
    expect(out).toContain("bundler.example.invalid");
  });

  it("handles a non-Error thrown value", () => {
    expect(redactErrorMessage("plain string thrown")).toBe(
      "plain string thrown",
    );
    expect(redactErrorMessage({ toString: () => "obj" })).toBe("obj");
  });

  it("handles a cyclic cause chain without looping forever", () => {
    const a: Error & { cause?: Error } = new Error("a");
    const b: Error & { cause?: Error } = new Error("b");
    a.cause = b;
    b.cause = a;
    // Should terminate via the seen-set guard, not throw.
    const out = redactErrorMessage(a);
    expect(out).toContain("a");
    expect(out).toContain("b");
  });

  it("returns a non-empty fallback for empty Error", () => {
    expect(redactErrorMessage(new Error(""))).toBe("<unknown error>");
    expect(redactErrorMessage(undefined)).toBe("<unknown error>");
    expect(redactErrorMessage(null)).toBe("<unknown error>");
  });
});
