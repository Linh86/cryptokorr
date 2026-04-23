/**
 * Contract tests — validate our Zod schemas against the canonical
 * Phoenix fixtures.
 *
 * If these tests fail, the contract has drifted between Phoenix and
 * the adapter. Fix the schema, not the fixture.
 */

import { describe, it, expect } from "vitest";
import {
  DispatchTransferSchema,
  DispatchSwapSchema,
  DispatchRevokeDelegationSchema,
  CallbackExecutionBroadcastSchema,
  CallbackExecutionConfirmedSchema,
  CallbackExecutionRevertedSchema,
  CallbackExecutionAbortedSchema,
  CallbackDelegationStateChangedSchema,
} from "../src/contracts/schemas.js";
import {
  dispatchTransfer,
  dispatchSwap,
  dispatchRevokeDelegation,
  callbackExecutionBroadcast,
  callbackExecutionConfirmed,
  callbackExecutionReverted,
  callbackExecutionAborted,
  callbackDelegationStateChanged,
} from "./fixtures/index.js";

describe("Contract: dispatch schemas match Phoenix fixtures", () => {
  it("dispatch_transfer.json validates against DispatchTransferSchema", () => {
    const result = DispatchTransferSchema.safeParse(dispatchTransfer);
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.action).toBe("transfer");
      expect(result.data.contract_version).toBe(1);
      expect(result.data.chain).toBe("base");
      expect(result.data.asset).toBe("USDC");
      expect(result.data.amount).toBe("50");
      expect(result.data.target.address).toMatch(/^0x/);
    }
  });

  it("dispatch_swap.json validates against DispatchSwapSchema", () => {
    const result = DispatchSwapSchema.safeParse(dispatchSwap);
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.action).toBe("swap");
      expect(result.data.contract_version).toBe(1);
      expect(result.data.input_asset).toBe("USDC");
      expect(result.data.output_asset).toBe("WETH");
      expect(result.data.slippage_bps).toBe(50);
      expect(result.data.route.venue).toBe("whitelisted_aggregator_v1");
    }
  });

  it("dispatch_revoke_delegation.json validates against DispatchRevokeDelegationSchema", () => {
    const result = DispatchRevokeDelegationSchema.safeParse(
      dispatchRevokeDelegation,
    );
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.action).toBe("revoke_delegation");
      expect(result.data.reason).toBe("operator_requested");
      expect(result.data.correlation_id).toBeNull();
      // `delegation_id` is required on the wire — Phoenix sources it
      // from the `delegations` projection row at dispatch time.
      expect(result.data.delegation_id).toBe("del_primary");
    }
  });
});

describe("Contract: callback schemas match Phoenix fixtures", () => {
  it("callback_execution_broadcast.json validates (AA-shaped tx_ref)", () => {
    // The Phoenix broadcast fixture carries the AA shape
    // (userop_hash + hex nonce + bundler) ahead of the #32 rollout.
    // The TxRefSchema accepts either EOA (hash) or AA (userop_hash),
    // so both coexist while we wait for the bundler integration.
    const result = CallbackExecutionBroadcastSchema.safeParse(
      callbackExecutionBroadcast,
    );
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.kind).toBe("execution.broadcast");
      expect(result.data.tx_refs.length).toBeGreaterThan(0);
      expect(result.data.tx_refs[0]!.chain).toBe("base");
      expect(result.data.tx_refs[0]!.userop_hash).toBeDefined();
    }
  });

  it("callback_execution_confirmed.json validates", () => {
    const result = CallbackExecutionConfirmedSchema.safeParse(
      callbackExecutionConfirmed,
    );
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.kind).toBe("execution.confirmed");
      expect(result.data.final_balance_changes.items.length).toBeGreaterThan(0);
      expect(result.data.tx_refs[0]!.block_number).toBeDefined();
    }
  });

  it("callback_execution_reverted.json validates", () => {
    const result = CallbackExecutionRevertedSchema.safeParse(
      callbackExecutionReverted,
    );
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.kind).toBe("execution.reverted");
      expect(result.data.reason).toBeTruthy();
      expect(result.data.tx_refs[0]!.status).toBe("reverted");
    }
  });

  it("callback_execution_aborted.json validates", () => {
    const result =
      CallbackExecutionAbortedSchema.safeParse(callbackExecutionAborted);
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.kind).toBe("execution.aborted");
      expect(result.data.reason).toBe("delegation_revoked");
    }
  });

  it("callback_delegation_state_changed.json validates", () => {
    const result = CallbackDelegationStateChangedSchema.safeParse(
      callbackDelegationStateChanged,
    );
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.kind).toBe("delegation.state_changed");
      expect(result.data.state).toBe("revoked");
      expect(result.data.delegation_id).toBe("del_primary");
    }
  });
});

describe("Contract: schemas reject malformed payloads", () => {
  it("rejects transfer with missing amount", () => {
    const bad = { ...dispatchTransfer, amount: undefined };
    expect(DispatchTransferSchema.safeParse(bad).success).toBe(false);
  });

  it("rejects transfer with wrong contract_version", () => {
    const bad = { ...dispatchTransfer, contract_version: 99 };
    expect(DispatchTransferSchema.safeParse(bad).success).toBe(false);
  });

  it("rejects swap with non-integer slippage_bps", () => {
    const bad = { ...dispatchSwap, slippage_bps: "fifty" };
    expect(DispatchSwapSchema.safeParse(bad).success).toBe(false);
  });

  it("rejects revoke_delegation with missing delegation_id", () => {
    const { delegation_id: _drop, ...bad } =
      dispatchRevokeDelegation as typeof dispatchRevokeDelegation & {
        delegation_id: string;
      };
    expect(DispatchRevokeDelegationSchema.safeParse(bad).success).toBe(false);
  });

  it("rejects revoke_delegation with empty delegation_id", () => {
    const bad = { ...dispatchRevokeDelegation, delegation_id: "" };
    expect(DispatchRevokeDelegationSchema.safeParse(bad).success).toBe(false);
  });

  it("rejects callback with invalid kind", () => {
    const bad = { ...callbackExecutionBroadcast, kind: "unknown.event" };
    expect(CallbackExecutionBroadcastSchema.safeParse(bad).success).toBe(false);
  });

  it("rejects delegation state_changed with invalid state", () => {
    const bad = { ...callbackDelegationStateChanged, state: "invalid" };
    expect(
      CallbackDelegationStateChangedSchema.safeParse(bad).success,
    ).toBe(false);
  });

  it("accepts delegation state_changed with state=revoke_failed", () => {
    // Issue #31 — the adapter emits revoke_failed on any chain-level
    // failure of the revoke attempt so Phoenix can distinguish a
    // confirmed revoke from a failed one.
    const ok = { ...callbackDelegationStateChanged, state: "revoke_failed" };
    expect(
      CallbackDelegationStateChangedSchema.safeParse(ok).success,
    ).toBe(true);
  });
});
