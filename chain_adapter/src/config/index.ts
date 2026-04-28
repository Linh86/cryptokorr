/**
 * Environment-based configuration.
 *
 * Every value is read from `process.env` at import time.
 * Missing required values throw immediately so the service
 * fails at startup rather than mid-request.
 */

import { getAddress, isAddress, isHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

function required(key: string): string {
  const value = process.env[key];
  if (!value) {
    throw new Error(`Missing required env var: ${key}`);
  }
  return value;
}

function optional(key: string, fallback: string): string {
  return process.env[key] || fallback;
}

function optionalInt(key: string, fallback: number): number {
  const raw = process.env[key];
  if (!raw) return fallback;
  const n = parseInt(raw, 10);
  if (isNaN(n)) throw new Error(`Env var ${key} must be an integer, got: ${raw}`);
  return n;
}

function optionalString(key: string): string | undefined {
  const value = process.env[key];
  return value && value.length > 0 ? value : undefined;
}

const PLACEHOLDER_PATTERN = /placeholder|0x_/i;

export interface AdapterConfig {
  /** HTTP server */
  port: number;
  host: string;

  /**
   * Optional TLS material. When both `tlsCertPath` and `tlsKeyPath`
   * are set, the Fastify listener serves HTTPS instead of plain HTTP.
   * Most deployments terminate TLS at an upstream ingress and leave
   * these unset; this hook exists for operators who want the adapter
   * itself to terminate TLS (e.g. when there is no ingress in front
   * of it on a private subnet).
   */
  tlsCertPath?: string;
  tlsKeyPath?: string;

  /**
   * Bearer the adapter REQUIRES on inbound `POST /dispatch/*`
   * requests. Phoenix sends this on every dispatch. Compared in
   * constant time. The pair on the Phoenix side is
   * `:bank, Bank.AdapterClient, :dispatch_secret` /
   * `ADAPTER_DISPATCH_SECRET`.
   */
  dispatchAuthSecret: string;

  /** Phoenix callback */
  phoenixBaseUrl: string;
  /**
   * Bearer the adapter SENDS on outbound `POST /internal/adapter/callback`
   * to Phoenix. Phoenix's `BankWeb.Plugs.VerifyAdapterAuth` validates
   * it. The pair on the Phoenix side is
   * `:bank, Bank.AdapterClient, :callback_secret` /
   * `ADAPTER_CALLBACK_SECRET`.
   *
   * Distinct from `dispatchAuthSecret` so each direction can be
   * rotated independently and a leak in one direction does not
   * authenticate the other.
   */
  callbackAuthSecret: string;

  /** Base chain */
  baseRpcUrl: string;
  baseChainId: number;

  /**
   * Bundler JSON-RPC endpoint for ERC-4337 v0.7 UserOperations.
   * Distinct from `baseRpcUrl` so the adapter can point at a dedicated
   * bundler (Pimlico, Alchemy AA, Stackup, etc.) separate from its
   * state-reading RPC. For local dev a combined RPC can be used by
   * setting both to the same URL.
   */
  bundlerRpcUrl: string;

  /**
   * The smart account address this adapter is bonded to (the `sender`
   * of every UserOperation in v0.1). Must already be deployed on the
   * target chain and funded. In production this comes from a smart
   * account provisioning flow; in v0.1 it is a single operator-managed
   * account.
   */
  smartAccountAddress: `0x${string}`;

  /** EntryPoint v0.7 address — same on every EVM chain. Overridable
   * for test networks that deploy a non-canonical EntryPoint. */
  entryPointAddress: `0x${string}`;

  /** Smart account / delegation */
  delegationSignerKey: string;

  /**
   * Optional kernel ROOT-validator (sudo) signer. Required only for the
   * cryptographic revoke path (#58); when unset the adapter falls back
   * to the sentinel revoke and refuses to honor any dispatch carrying a
   * `permission` block.
   *
   * `operatorPrivateKey` is the EOA bound to the kernel's root ECDSA
   * validator at provisioning time (`provision-kernel.ts` deploys the
   * kernel with this same EOA). Used to sign
   * `Kernel.uninstallValidation(...)` UserOps because the kernel's
   * `onlyEntryPointOrSelfOrRoot` guard demands a sudo signature. NOT
   * the same key as `delegationSignerKey` — that is the runtime
   * session key for transfers, with strictly narrower authority.
   *
   * If set, both must be set together and the private key must derive
   * to the public address. The two keys must also derive to DIFFERENT
   * EOAs — refusing to conflate the runtime session key with the
   * kernel root key is a defense-in-depth invariant: a leak of the
   * delegation key must not also disclose sudo authority over the
   * smart account.
   */
  operatorPrivateKey?: `0x${string}`;
  operatorAddress?: `0x${string}`;

  /** USDC on Base */
  usdcContractAddress: `0x${string}`;

  /** Contract version advertised to Phoenix */
  contractVersion: number;
}

/**
 * Read the optional operator-signer pair, refusing pasted placeholders
 * and any half-set / mismatched / role-conflated configuration. Returns
 * `{ key: undefined, address: undefined }` only if BOTH env vars are
 * absent — otherwise throws so the adapter fails at startup rather
 * than mid-request.
 *
 * Validation matches `provision-kernel.ts`'s `readPrivateKey` /
 * `readAddress` posture: 0x-prefixed 32-byte hex, address must be
 * checksum-castable, derived EOA must equal the public address.
 *
 * The `delegationSignerKey` is passed in so we can refuse a pasted
 * config that uses the same EOA for both roles — the kernel root key
 * and the runtime session key MUST be distinct EOAs.
 */
function readOperatorSigner(
  env: NodeJS.ProcessEnv,
  delegationSignerKey: string,
): { key?: `0x${string}`; address?: `0x${string}` } {
  const rawKey = env.OPERATOR_PRIVATE_KEY;
  const rawAddress = env.OPERATOR_ADDRESS;
  const keySet = rawKey !== undefined && rawKey.length > 0;
  const addressSet = rawAddress !== undefined && rawAddress.length > 0;

  if (!keySet && !addressSet) {
    return {};
  }
  if (keySet !== addressSet) {
    throw new Error(
      "OPERATOR_PRIVATE_KEY and OPERATOR_ADDRESS must be set together (or both unset to fall back to the sentinel revoke path).",
    );
  }

  // Both set — validate.
  if (PLACEHOLDER_PATTERN.test(rawKey!) || PLACEHOLDER_PATTERN.test(rawAddress!)) {
    throw new Error(
      "OPERATOR_PRIVATE_KEY / OPERATOR_ADDRESS still contain a placeholder value",
    );
  }
  if (!isHex(rawKey!) || rawKey!.length !== 66) {
    throw new Error(
      "OPERATOR_PRIVATE_KEY must be a 0x-prefixed 32-byte hex private key",
    );
  }
  if (!isAddress(rawAddress!)) {
    throw new Error("OPERATOR_ADDRESS must be a valid 0x-prefixed EVM address");
  }

  const operatorPrivateKey = rawKey as `0x${string}`;
  const operatorAddress = getAddress(rawAddress!);

  // Derived EOA must match the public address.
  const derived = privateKeyToAccount(operatorPrivateKey).address;
  if (derived !== operatorAddress) {
    throw new Error(
      `OPERATOR_PRIVATE_KEY does not derive to OPERATOR_ADDRESS (key derives ${derived}, env says ${operatorAddress})`,
    );
  }

  // Refuse role conflation. The cryptographic revoke (#58) needs the
  // ROOT validator EOA for `onlyEntryPointOrSelfOrRoot`; the runtime
  // delegation signer is a SESSION key. A single EOA serving both
  // roles would let a leak of the session key escalate to root.
  // `delegationSignerKey` may be a placeholder during early dev,
  // which would make `privateKeyToAccount` throw — guard with
  // `isHex` so we only apply the check when both keys are real.
  if (isHex(delegationSignerKey) && delegationSignerKey.length === 66) {
    const delegationDerived = privateKeyToAccount(
      delegationSignerKey as `0x${string}`,
    ).address;
    if (delegationDerived === operatorAddress) {
      throw new Error(
        "OPERATOR_PRIVATE_KEY and DELEGATION_SIGNER_KEY MUST derive to different EOAs (refusing to conflate the kernel root validator with the runtime session signer)",
      );
    }
  }

  return { key: operatorPrivateKey, address: operatorAddress };
}

export function loadConfig(): AdapterConfig {
  const delegationSignerKey = required("DELEGATION_SIGNER_KEY");
  const operator = readOperatorSigner(process.env, delegationSignerKey);

  return {
    port: optionalInt("PORT", 4100),
    host: optional("HOST", "0.0.0.0"),

    tlsCertPath: optionalString("ADAPTER_TLS_CERT_PATH"),
    tlsKeyPath: optionalString("ADAPTER_TLS_KEY_PATH"),

    dispatchAuthSecret: required("ADAPTER_DISPATCH_SECRET"),

    phoenixBaseUrl: required("PHOENIX_BASE_URL"),
    callbackAuthSecret: required("ADAPTER_CALLBACK_SECRET"),

    baseRpcUrl: required("BASE_RPC_URL"),
    baseChainId: optionalInt("BASE_CHAIN_ID", 8453),

    bundlerRpcUrl: required("BUNDLER_RPC_URL"),
    smartAccountAddress: required("SMART_ACCOUNT_ADDRESS") as `0x${string}`,
    entryPointAddress: optional(
      "ENTRY_POINT_ADDRESS",
      "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    ) as `0x${string}`,

    delegationSignerKey,

    operatorPrivateKey: operator.key,
    operatorAddress: operator.address,

    usdcContractAddress: required("USDC_CONTRACT_ADDRESS") as `0x${string}`,

    contractVersion: optionalInt("CONTRACT_VERSION", 1),
  };
}

/**
 * Test-safe config with sensible defaults. Use in tests only.
 *
 * Operator key fields are populated with a distinct test fixture so
 * the cryptographic revoke path can be exercised in unit tests
 * without leaking a real key. The key is `0x` + `cd` × 32, distinct
 * from `delegationSignerKey` (`ab` × 32) so the role-conflation
 * guard in `readOperatorSigner` does not trip when both are set.
 */
export function testConfig(overrides: Partial<AdapterConfig> = {}): AdapterConfig {
  const delegationSignerKey = ("0x" + "ab".repeat(32)) as `0x${string}`;
  const operatorPrivateKey = ("0x" + "cd".repeat(32)) as `0x${string}`;

  return {
    port: 0, // random port
    host: "127.0.0.1",
    dispatchAuthSecret: "test-dispatch-secret",
    phoenixBaseUrl: "http://localhost:4000",
    callbackAuthSecret: "test-callback-secret",
    baseRpcUrl: "http://localhost:8545",
    baseChainId: 8453,
    bundlerRpcUrl: "http://localhost:4337",
    smartAccountAddress: "0x0000000000000000000000000000000000000a11",
    entryPointAddress: "0x0000000071727de22e5e9d8baf0edac6f37da032",
    delegationSignerKey,
    operatorPrivateKey,
    operatorAddress: privateKeyToAccount(operatorPrivateKey).address,
    usdcContractAddress: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    contractVersion: 1,
    ...overrides,
  };
}
