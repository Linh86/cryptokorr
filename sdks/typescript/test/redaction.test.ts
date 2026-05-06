import { describe, expect, it } from "vitest";
import { REDACTED, redact, redactHeaders, redactString } from "../src/redaction.js";

describe("redactString", () => {
  it("strips a bare API key", () => {
    expect(redactString("cb_abcdef0123456789")).toBe(REDACTED);
  });

  it("strips an API key embedded in a longer string", () => {
    expect(redactString("Authorization: Bearer cb_abcdef0123456789!")).toBe(
      "Authorization: Bearer [REDACTED]!",
    );
  });

  it("leaves content without a key alone", () => {
    expect(redactString("nothing to see here")).toBe("nothing to see here");
  });

  it("strips multiple keys in one string", () => {
    expect(
      redactString(
        "key1=cb_abcdefghij1234567 and key2=cb_zzzzzzzzzz98765432",
      ),
    ).toBe("key1=[REDACTED] and key2=[REDACTED]");
  });

  it("does not match short suffixes that look key-like", () => {
    // `cb_` followed by < 16 chars is not matched; this is a
    // deliberate floor so we don't redact unrelated prefixes.
    expect(redactString("cb_abc")).toBe("cb_abc");
  });
});

describe("redact", () => {
  it("scrubs strings", () => {
    expect(redact("cb_abcdefghij1234567")).toBe(REDACTED);
  });

  it("passes non-strings through", () => {
    expect(redact(42)).toBe(42);
    expect(redact(null)).toBeNull();
    const obj = { foo: "bar" };
    expect(redact(obj)).toBe(obj);
  });
});

describe("redactHeaders", () => {
  it("redacts Authorization regardless of value shape", () => {
    expect(redactHeaders({ Authorization: "Bearer cb_abcdefghij1234567" })).toEqual({
      Authorization: REDACTED,
    });
  });

  it("redacts Authorization case-insensitively", () => {
    expect(redactHeaders({ authorization: "cb_abcdefghij1234567" })).toEqual({
      authorization: REDACTED,
    });
  });

  it("scrubs API keys from non-Authorization headers too", () => {
    expect(
      redactHeaders({ "x-trace": "request emitted by cb_abcdefghij1234567 backend" }),
    ).toEqual({ "x-trace": "request emitted by [REDACTED] backend" });
  });
});
