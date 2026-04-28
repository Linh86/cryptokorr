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
  DispatchGrantDelegationSchema,
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
  dispatchGrantDelegation,
  callbackExecutionBroadcast,
  callbackExecutionConfirmed,
  callbackExecutionReverted,
  callbackExecutionAborted,
  callbackDelegationStateChanged,
  callbackDelegationGranted,
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

  it("dispatch_grant_delegation.json validates against DispatchGrantDelegationSchema (#58)", () => {
    const result = DispatchGrantDelegationSchema.safeParse(
      dispatchGrantDelegation,
    );
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.action).toBe("grant_delegation");
      expect(result.data.contract_version).toBe(1);
      expect(result.data.smart_account_id).toBe("sa_demo_01");
      expect(result.data.chain_id).toBe(84532);
      expect(result.data.account).toBe(
        "0xabc000000000000000000000000000000000dead",
      );
      expect(result.data.scope).toEqual({ asset: "USDC" });
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

  it("callback_delegation_granted.json validates and carries the full permission block (#58)", () => {
    const result = CallbackDelegationStateChangedSchema.safeParse(
      callbackDelegationGranted,
    );
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.kind).toBe("delegation.state_changed");
      expect(result.data.state).toBe("granted");
      // `delegation_id` MUST equal `permission.permission_id` for
      // cryptographic grants. Phoenix's worker chooses the
      // dispatch path on this id; pinning the equality keeps the
      // operator-visible identifier consistent across the row,
      // the audit trail, and future Etherscan / RPC lookups.
      expect(result.data.delegation_id).toBe(
        result.data.permission?.permission_id,
      );
      expect(result.data.permission).toBeDefined();
      expect(result.data.permission?.blob.length).toBeGreaterThan(0);
      expect(result.data.permission?.permission_id).toMatch(
        /^0x[0-9a-fA-F]{8}$/,
      );
      expect(result.data.permission?.validation_id).toMatch(
        /^0x[0-9a-fA-F]{42}$/,
      );
      expect(result.data.permission?.session_signer_address).toMatch(
        /^0x[0-9a-fA-F]{40}$/,
      );
      expect(result.data.permission?.kernel_version).toBe("0.3.1");
      expect(result.data.permission?.package_version).toBe("5.6.3");
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

  it("accepts revoke_delegation with a well-formed optional permission block (#58)", () => {
    const ok = {
      ...dispatchRevokeDelegation,
      permission: {
        blob: "eyJzZXJpYWxpemVkUGVybWlzc2lvbkFjY291bnQiOiJ0ZXN0In0=",
        permission_id: "0xa1b2c3d4",
        validation_id: "0x02a1b2c3d400000000000000000000000000000000",
        kernel_version: "0.3.1",
        package_version: "5.6.3",
      },
    };
    const result = DispatchRevokeDelegationSchema.safeParse(ok);
    expect(result.success).toBe(true);
    if (result.success) {
      expect(result.data.permission?.blob).toBe(ok.permission.blob);
    }
  });

  it("rejects revoke_delegation with a permission block whose permission_id has wrong byte length", () => {
    const bad = {
      ...dispatchRevokeDelegation,
      permission: {
        blob: "abc",
        permission_id: "0xa1b2", // 2 bytes, not 4
        validation_id: "0x02a1b200000000000000000000000000000000000000",
        kernel_version: "0.3.1",
        package_version: "5.6.3",
      },
    };
    expect(DispatchRevokeDelegationSchema.safeParse(bad).success).toBe(false);
  });

  it("rejects revoke_delegation with a permission block missing required fields", () => {
    const bad = {
      ...dispatchRevokeDelegation,
      permission: {
        blob: "abc",
        permission_id: "0xa1b2c3d4",
        // Missing validation_id, kernel_version, package_version.
      },
    };
    expect(DispatchRevokeDelegationSchema.safeParse(bad).success).toBe(false);
  });

  it("rejects grant_delegation with missing chain_id (#58)", () => {
    const { chain_id: _drop, ...bad } =
      dispatchGrantDelegation as typeof dispatchGrantDelegation & {
        chain_id: number;
      };
    expect(DispatchGrantDelegationSchema.safeParse(bad).success).toBe(false);
  });

  it("rejects grant_delegation with non-integer chain_id (#58)", () => {
    const bad = { ...dispatchGrantDelegation, chain_id: "84532" };
    expect(DispatchGrantDelegationSchema.safeParse(bad).success).toBe(false);
  });

  it("rejects callback granted with permission block whose session_signer_address is malformed (#58)", () => {
    const ok = callbackDelegationGranted as {
      permission: { session_signer_address: string };
    };
    const bad = {
      ...callbackDelegationGranted,
      permission: { ...ok.permission, session_signer_address: "0xnope" },
    };
    expect(
      CallbackDelegationStateChangedSchema.safeParse(bad).success,
    ).toBe(false);
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
