/**
 * Adapter env loader tests for the operator (kernel root) signer
 * provisioning that the cryptographic revoke path needs (#58).
 *
 * The loader (`loadConfig` in `src/config/index.ts`) refuses every
 * boundary failure that could cause the cryptographic revoke to
 * either silently downgrade to sentinel or, worse, broadcast an
 * unsigned-by-the-right-key UserOp. The tests below pin those
 * refusals so a future env-loader edit cannot weaken the contract
 * without explicit reviewer attention.
 *
 * Each test seeds + restores `process.env` around the call so
 * tests do not pollute the live shell or each other.
 */

import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { privateKeyToAccount } from "viem/accounts";
import { loadConfig } from "../src/config/index.js";

// A pair of unrelated 32-byte hex private keys. The runtime rejects
// any config where these two derive to the same EOA, so we use
// distinct entropies.
const OPERATOR_KEY = ("0x" + "11".repeat(32)) as `0x${string}`;
const DELEGATION_KEY = ("0x" + "22".repeat(32)) as `0x${string}`;
const OPERATOR_ADDRESS = privateKeyToAccount(OPERATOR_KEY).address;

const MINIMAL_REQUIRED_ENV: Record<string, string> = {
  ADAPTER_DISPATCH_SECRET: "test-dispatch-secret",
  ADAPTER_CALLBACK_SECRET: "test-callback-secret",
  PHOENIX_BASE_URL: "http://localhost:4000",
  BASE_RPC_URL: "https://base-sepolia.example/rpc",
  BUNDLER_RPC_URL: "https://bundler.example/rpc",
  SMART_ACCOUNT_ADDRESS: "0x0000000000000000000000000000000000000a11",
  USDC_CONTRACT_ADDRESS: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  DELEGATION_SIGNER_KEY: DELEGATION_KEY,
};

describe("loadConfig — operator (kernel root) signer", () => {
  // Snapshot every env var the loader touches so the tests don't
  // pollute each other or the host shell.
  const TOUCHED = [
    ...Object.keys(MINIMAL_REQUIRED_ENV),
    "OPERATOR_PRIVATE_KEY",
    "OPERATOR_ADDRESS",
    "ADAPTER_TLS_CERT_PATH",
    "ADAPTER_TLS_KEY_PATH",
    "PORT",
    "HOST",
    "BASE_CHAIN_ID",
    "ENTRY_POINT_ADDRESS",
    "CONTRACT_VERSION",
  ];
  let snapshot: Record<string, string | undefined>;

  beforeEach(() => {
    snapshot = Object.fromEntries(TOUCHED.map((k) => [k, process.env[k]]));
    for (const k of TOUCHED) delete process.env[k];
    Object.assign(process.env, MINIMAL_REQUIRED_ENV);
  });

  afterEach(() => {
    for (const k of TOUCHED) delete process.env[k];
    for (const [k, v] of Object.entries(snapshot)) {
      if (v !== undefined) process.env[k] = v;
    }
  });

  it("leaves operator key fields undefined when both env vars are unset", () => {
    // Backwards-compat: operators that haven't migrated to the
    // cryptographic revoke path keep loading config without setting
    // anything new. The runtime then refuses to honor any dispatch
    // carrying a `permission` block (see executeRevoke) — the
    // refusal happens in the executor, NOT here.
    const cfg = loadConfig();
    expect(cfg.operatorPrivateKey).toBeUndefined();
    expect(cfg.operatorAddress).toBeUndefined();
  });

  it("populates operator key + address when both env vars are set and consistent", () => {
    process.env.OPERATOR_PRIVATE_KEY = OPERATOR_KEY;
    process.env.OPERATOR_ADDRESS = OPERATOR_ADDRESS;

    const cfg = loadConfig();
    expect(cfg.operatorPrivateKey).toBe(OPERATOR_KEY);
    expect(cfg.operatorAddress).toBe(OPERATOR_ADDRESS);
  });

  it("rejects setting OPERATOR_PRIVATE_KEY without OPERATOR_ADDRESS", () => {
    process.env.OPERATOR_PRIVATE_KEY = OPERATOR_KEY;
    expect(() => loadConfig()).toThrow(/must be set together/);
  });

  it("rejects setting OPERATOR_ADDRESS without OPERATOR_PRIVATE_KEY", () => {
    process.env.OPERATOR_ADDRESS = OPERATOR_ADDRESS;
    expect(() => loadConfig()).toThrow(/must be set together/);
  });

  it("rejects placeholder operator key", () => {
    process.env.OPERATOR_PRIVATE_KEY = "0x_dev_placeholder";
    process.env.OPERATOR_ADDRESS = OPERATOR_ADDRESS;
    expect(() => loadConfig()).toThrow(/placeholder/);
  });

  it("rejects placeholder operator address", () => {
    process.env.OPERATOR_PRIVATE_KEY = OPERATOR_KEY;
    process.env.OPERATOR_ADDRESS = "0x_placeholder";
    expect(() => loadConfig()).toThrow(/placeholder/);
  });

  it("rejects an operator key that is not 32-byte hex", () => {
    process.env.OPERATOR_PRIVATE_KEY = "0x1234"; // too short
    process.env.OPERATOR_ADDRESS = OPERATOR_ADDRESS;
    expect(() => loadConfig()).toThrow(/0x-prefixed 32-byte hex/);
  });

  it("rejects an operator address that is not a valid EVM address", () => {
    process.env.OPERATOR_PRIVATE_KEY = OPERATOR_KEY;
    process.env.OPERATOR_ADDRESS = "0xnotanaddress";
    expect(() => loadConfig()).toThrow(/valid 0x-prefixed EVM address/);
  });

  it("rejects an operator key whose derived EOA does not match OPERATOR_ADDRESS", () => {
    // Defense in depth: catches a paste-mismatch where the operator
    // copied the wrong public address into env.
    process.env.OPERATOR_PRIVATE_KEY = OPERATOR_KEY;
    process.env.OPERATOR_ADDRESS = "0x0000000000000000000000000000000000000001";
    expect(() => loadConfig()).toThrow(/does not derive to OPERATOR_ADDRESS/);
  });

  it("REFUSES to conflate OPERATOR with DELEGATION_SIGNER_KEY (same EOA)", () => {
    // The kernel root signer is a different role from the runtime
    // session signer. A single EOA serving both lets a leak of the
    // session key escalate to root authority. Refusing is a hard
    // architectural invariant — A security review explicitly
    // called this out and the loader enforces it.
    process.env.OPERATOR_PRIVATE_KEY = DELEGATION_KEY;
    process.env.OPERATOR_ADDRESS = privateKeyToAccount(DELEGATION_KEY).address;

    expect(() => loadConfig()).toThrow(
      /MUST derive to different EOAs|refusing to conflate/,
    );
  });
});
