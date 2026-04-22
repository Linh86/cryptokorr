/**
 * Callback client tests — payload shaping and self-validation.
 */

import { describe, it, expect, beforeEach } from "vitest";
import {
  createTestCallbackClient,
  nextCallbackId,
  resetCallbackSeq,
} from "../src/callbacks/client.js";
import type { CallbackPayload } from "../src/contracts/schemas.js";

describe("Callback client", () => {
  beforeEach(() => {
    resetCallbackSeq();
  });

  it("accepts a valid execution.broadcast callback", async () => {
    const client = createTestCallbackClient();
    const payload: CallbackPayload = {
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "execution.broadcast",
      execution_plan_id: "11111111-1111-4111-8111-111111111111",
      tx_refs: [{ chain: "base", hash: "0xabcd", nonce: 7 }],
      emitted_at: new Date().toISOString(),
    };

    await client.send(payload);
    expect(client.payloads).toHaveLength(1);
    expect(client.payloads[0]!.kind).toBe("execution.broadcast");
  });

  it("accepts a valid execution.confirmed callback", async () => {
    const client = createTestCallbackClient();
    const payload: CallbackPayload = {
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "execution.confirmed",
      execution_plan_id: "11111111-1111-4111-8111-111111111111",
      tx_refs: [
        { chain: "base", hash: "0xabcd", block_number: 100, status: "success" },
      ],
      final_balance_changes: {
        items: [{ asset: "USDC", amount: "-50" }],
      },
      emitted_at: new Date().toISOString(),
    };

    await client.send(payload);
    expect(client.payloads).toHaveLength(1);
  });

  it("accepts a valid execution.aborted callback", async () => {
    const client = createTestCallbackClient();
    const payload: CallbackPayload = {
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "execution.aborted",
      execution_plan_id: "11111111-1111-4111-8111-111111111111",
      reason: "delegation_revoked",
      emitted_at: new Date().toISOString(),
    };

    await client.send(payload);
    expect(client.payloads).toHaveLength(1);
  });

  it("accepts a valid delegation.state_changed callback", async () => {
    const client = createTestCallbackClient();
    const payload: CallbackPayload = {
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "delegation.state_changed",
      smart_account_id: "sa_0xdeadbeef",
      delegation_id: "del_primary",
      state: "revoked",
      reason: "operator_requested",
      emitted_at: new Date().toISOString(),
    };

    await client.send(payload);
    expect(client.payloads).toHaveLength(1);
  });

  it("rejects a malformed callback payload", async () => {
    const client = createTestCallbackClient();
    // Missing execution_plan_id
    const bad = {
      contract_version: 1,
      callback_id: nextCallbackId(),
      kind: "execution.broadcast" as const,
      tx_refs: [{ chain: "base", hash: "0xabcd" }],
      emitted_at: new Date().toISOString(),
    };

    await expect(client.send(bad as CallbackPayload)).rejects.toThrow(
      /self-validation failed/,
    );
  });

  it("generates monotonic callback ids", () => {
    resetCallbackSeq();
    expect(nextCallbackId()).toBe("cb_0001");
    expect(nextCallbackId()).toBe("cb_0002");
    expect(nextCallbackId()).toBe("cb_0003");
  });

  it("clears collected payloads", async () => {
    const client = createTestCallbackClient();
    await client.send({
      contract_version: 1,
      callback_id: "cb_test",
      kind: "execution.aborted",
      execution_plan_id: "11111111-1111-4111-8111-111111111111",
      reason: "test",
      emitted_at: new Date().toISOString(),
    });
    expect(client.payloads).toHaveLength(1);
    client.clear();
    expect(client.payloads).toHaveLength(0);
  });
});
