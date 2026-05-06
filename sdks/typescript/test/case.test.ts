import { describe, expect, it } from "vitest";
import { toCamelDeep, toSnakeDeep } from "../src/case.js";

describe("toCamelDeep", () => {
  it("converts top-level keys", () => {
    expect(toCamelDeep({ intent_id: "abc", state: "submitted" })).toEqual({
      intentId: "abc",
      state: "submitted",
    });
  });

  it("walks nested objects + arrays", () => {
    const out = toCamelDeep({
      data: [
        { counterparty_id: "cp_1", address_label_id: "al_1" },
        { raw_address: "0xabc" },
      ],
      page: { next_cursor: "x" },
    });
    expect(out).toEqual({
      data: [
        { counterpartyId: "cp_1", addressLabelId: "al_1" },
        { rawAddress: "0xabc" },
      ],
      page: { nextCursor: "x" },
    });
  });

  it("passes class instances through unchanged", () => {
    const date = new Date("2026-05-06T00:00:00Z");
    expect(toCamelDeep({ created_at: date })).toEqual({ createdAt: date });
  });

  it("passes scalars and null through", () => {
    expect(toCamelDeep(null)).toBeNull();
    expect(toCamelDeep("hello")).toBe("hello");
    expect(toCamelDeep(42)).toBe(42);
  });
});

describe("toSnakeDeep", () => {
  it("converts camelCase to snake_case", () => {
    expect(
      toSnakeDeep({ agentId: "a", smartAccountId: "sa", target: { rawAddress: "0xabc" } }),
    ).toEqual({
      agent_id: "a",
      smart_account_id: "sa",
      target: { raw_address: "0xabc" },
    });
  });

  it("walks arrays element-wise", () => {
    expect(toSnakeDeep([{ fooBar: 1 }, { bazQux: 2 }])).toEqual([
      { foo_bar: 1 },
      { baz_qux: 2 },
    ]);
  });

  it("round-trips snake → camel → snake", () => {
    const snake = {
      intent_id: "abc",
      target: { counterparty_id: "cp" },
      links: { self: "/v1/intents/abc" },
    };
    expect(toSnakeDeep(toCamelDeep(snake))).toEqual(snake);
  });
});
