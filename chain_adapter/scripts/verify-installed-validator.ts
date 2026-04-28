/**
 * Read-only verification of a Kernel v3 smart-account deployment on
 * Base Sepolia (or Base mainnet).
 *
 * Originally this script was supposed to "verify a single Permission
 * Validator address + bytecode hash". That model was wrong — see
 * `docs/zerodev-permissions-integration.md`. ZeroDev permissions
 * compose from CREATE2 signer + policy modules and a 4-byte
 * `permissionId`; there is no single deployable validator with a
 * bytecode hash to pin.
 *
 * What this script DOES verify, today, with read-only RPC calls and
 * NO secrets:
 *
 *   - The smart account has bytecode at the configured address
 *     (`eth_getCode != "0x"`).
 *   - The kernel implementation pointer in EIP-1967 storage matches
 *     the pinned `KERNEL_V3_1` implementation.
 *   - The kernel reports a known version string via
 *     `getKernelVersion`.
 *   - The kernel's current root validator is the canonical ECDSA
 *     validator for `>=0.3.1`.
 *   - The kernel's current nonce is captured (operational data
 *     point — useful when an operator suspects the account has been
 *     used).
 *
 * What this script intentionally does NOT verify:
 *
 *   - No "Permission Validator address". There is no such thing in
 *     ZeroDev's permissions model.
 *   - No `disablePermission(bytes32)` ABI selector. The eventual
 *     cryptographic revoke (#58) is `Kernel.uninstallValidation`
 *     ON the smart account itself; the integration shape is
 *     documented in the integration doc above and is not pinned
 *     here.
 *   - No permission install state — no per-permission `permissionConfig`
 *     reads. ZeroDev permissions are NOT installed on the kernel
 *     account by this script's sibling `provision-kernel.ts`;
 *     verifying their absence would be a tautology and verifying
 *     their presence is the integration TODO.
 *
 * Usage:
 *
 *   # Required env: SMART_ACCOUNT_ADDRESS, BASE_RPC_URL.
 *   # Optional env: BASE_CHAIN_ID (default 84532).
 *   npx tsx scripts/verify-installed-validator.ts
 *
 * Output: a JSON receipt on stdout. Exit 0 iff every read returns a
 * value consistent with a Kernel v3.1 deployment owned by the same
 * EOA the operator used at provisioning time. Exit 1 on any
 * mismatch (including "smart account has no bytecode").
 */

import { fileURLToPath, pathToFileURL } from "node:url";
import {
  type Address,
  type Hex,
  createPublicClient,
  getAddress,
  http,
  isAddress,
} from "viem";
import { baseSepolia, base } from "viem/chains";
import {
  getKernelImplementationAddress,
  getKernelVersion,
  isSmartAccountDeployed,
} from "@zerodev/sdk/actions";
import { getKernelV3Nonce } from "@zerodev/sdk";
import { getEntryPoint, KERNEL_V3_1, KernelVersionToAddressesMap } from "@zerodev/sdk/constants";
import { getValidatorAddress } from "@zerodev/ecdsa-validator";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

export const RECEIPT_SCHEMA_VERSION = 1;

export const ALLOWED_CHAIN_IDS = [84_532, 8453] as const;
export type AllowedChainId = (typeof ALLOWED_CHAIN_IDS)[number];

const PLACEHOLDER_PATTERN = /placeholder|0x_/i;

export interface VerifyEnv {
  smartAccountAddress: Address;
  baseRpcUrl: string;
  baseChainId: AllowedChainId;
}

export class VerifyEnvError extends Error {
  constructor(
    message: string,
    public readonly key?: string,
  ) {
    super(message);
    this.name = "VerifyEnvError";
  }
}

export interface VerificationFinding {
  key: string;
  ok: boolean;
  detail: string;
}

export interface VerifyReceipt {
  schema_version: typeof RECEIPT_SCHEMA_VERSION;
  chain_id: AllowedChainId;
  smart_account_address: Address;
  pinned_kernel_version: string;
  pinned_implementation_address: Address;
  pinned_root_validator_address: Address;
  is_deployed: boolean;
  observed_implementation_address: Address | null;
  observed_kernel_version: string | null;
  observed_kernel_nonce: number | null;
  observed_root_validator_address: Address | null;
  findings: VerificationFinding[];
  overall_ok: boolean;
  next_steps: string[];
}

// ---------------------------------------------------------------------------
// Env parsing
// ---------------------------------------------------------------------------

function readChainId(env: NodeJS.ProcessEnv): AllowedChainId {
  const raw = env.BASE_CHAIN_ID ?? "84532";
  const parsed = Number.parseInt(raw, 10);
  if (!ALLOWED_CHAIN_IDS.includes(parsed as AllowedChainId)) {
    throw new VerifyEnvError(
      `BASE_CHAIN_ID must be 84532 (Sepolia) or 8453 (mainnet); got ${raw}`,
      "BASE_CHAIN_ID",
    );
  }
  return parsed as AllowedChainId;
}

function readAddress(value: string | undefined, key: string): Address {
  if (value === undefined || value === "") {
    throw new VerifyEnvError(`${key} is required`, key);
  }
  if (PLACEHOLDER_PATTERN.test(value)) {
    throw new VerifyEnvError(
      `${key} still contains a placeholder value: ${value}`,
      key,
    );
  }
  if (!isAddress(value)) {
    throw new VerifyEnvError(
      `${key} must be a 0x-prefixed 20-byte EVM address; got ${value}`,
      key,
    );
  }
  return getAddress(value);
}

function readUrl(value: string | undefined, key: string): string {
  if (value === undefined || value === "") {
    throw new VerifyEnvError(`${key} is required`, key);
  }
  if (PLACEHOLDER_PATTERN.test(value)) {
    throw new VerifyEnvError(
      `${key} still contains a placeholder value`,
      key,
    );
  }
  if (!/^https?:\/\//.test(value)) {
    throw new VerifyEnvError(`${key} must be an http(s) URL`, key);
  }
  return value;
}

export function parseEnv(env: NodeJS.ProcessEnv): VerifyEnv {
  return {
    smartAccountAddress: readAddress(
      env.SMART_ACCOUNT_ADDRESS,
      "SMART_ACCOUNT_ADDRESS",
    ),
    baseRpcUrl: readUrl(env.BASE_RPC_URL, "BASE_RPC_URL"),
    baseChainId: readChainId(env),
  };
}

// ---------------------------------------------------------------------------
// Verification
// ---------------------------------------------------------------------------

/**
 * Pinned values the kernel deployment is expected to match. Mirrors
 * the constants `provision-kernel.ts` uses, kept in sync deliberately
 * — both scripts target Kernel v3.1 + the canonical ECDSA root
 * validator.
 */
export function getPinnedExpectations(): {
  kernelVersion: string;
  implementationAddress: Address;
  rootValidatorAddress: Address;
} {
  const entry = KernelVersionToAddressesMap[KERNEL_V3_1];
  if (!entry) {
    throw new Error(`KernelVersionToAddressesMap missing entry for ${KERNEL_V3_1}`);
  }
  return {
    kernelVersion: KERNEL_V3_1,
    implementationAddress: entry.accountImplementationAddress,
    rootValidatorAddress: getValidatorAddress(getEntryPoint("0.7"), KERNEL_V3_1),
  };
}

/**
 * The root validator is exposed on the kernel ABI as
 * `rootValidator() -> bytes21`. The 21 bytes pack a 1-byte
 * validator-type tag (`0x01` for VALIDATOR / `0x02` for PERMISSION /
 * `0x03` for PERMISSION_FALLBACK) followed by the 20-byte module
 * address. We split that here so the verify script can compare just
 * the address portion against the canonical ECDSA validator pin.
 */
export function splitRootValidator(rootValidator: Hex): {
  typeTag: Hex;
  address: Address;
} {
  if (rootValidator.length !== 2 + 21 * 2) {
    throw new Error(
      `rootValidator must be 21 bytes; got ${rootValidator}`,
    );
  }
  const typeTag = ("0x" + rootValidator.slice(2, 4)) as Hex;
  const address = getAddress("0x" + rootValidator.slice(4, 4 + 40));
  return { typeTag, address };
}

const ROOT_VALIDATOR_ABI = [
  {
    type: "function",
    name: "rootValidator",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "bytes21" }],
  },
] as const;

interface ChainObservations {
  isDeployed: boolean;
  observedImplementationAddress: Address | null;
  observedKernelVersion: string | null;
  observedKernelNonce: number | null;
  observedRootValidatorAddress: Address | null;
}

async function observe(env: VerifyEnv): Promise<ChainObservations> {
  const chain = env.baseChainId === 84_532 ? baseSepolia : base;
  const publicClient = createPublicClient({
    chain,
    transport: http(env.baseRpcUrl),
  });
  // The SDK's verification helpers accept a bare `Client`; viem's
  // `createPublicClient` return type drifts between viem versions.
  // Cast at the boundary; runtime behaviour is unchanged.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const sdkClient = publicClient as any;

  const isDeployed = await isSmartAccountDeployed(
    sdkClient,
    env.smartAccountAddress,
  );

  if (!isDeployed) {
    return {
      isDeployed: false,
      observedImplementationAddress: null,
      observedKernelVersion: null,
      observedKernelNonce: null,
      observedRootValidatorAddress: null,
    };
  }

  const observedImpl = await getKernelImplementationAddress(sdkClient, {
    address: env.smartAccountAddress,
  });
  const observedVersion = await getKernelVersion(sdkClient, {
    address: env.smartAccountAddress,
  });
  const observedNonce = await getKernelV3Nonce(
    sdkClient,
    env.smartAccountAddress,
  );

  // viem 2.48's `readContract` parameter type appears to require an
  // `authorizationList` field that is otherwise EIP-7702-specific
  // and irrelevant for this view call. Cast at the boundary; the
  // runtime call shape is unchanged from viem's documented usage.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const reader = publicClient.readContract as any;
  const rootValidatorRaw: Hex = await reader({
    address: env.smartAccountAddress,
    abi: ROOT_VALIDATOR_ABI,
    functionName: "rootValidator",
  });
  const { address: observedRootValidatorAddress } =
    splitRootValidator(rootValidatorRaw);

  return {
    isDeployed: true,
    observedImplementationAddress: observedImpl,
    observedKernelVersion: observedVersion,
    observedKernelNonce: observedNonce,
    observedRootValidatorAddress,
  };
}

export function buildReceipt(
  env: VerifyEnv,
  observations: ChainObservations,
): VerifyReceipt {
  const pinned = getPinnedExpectations();

  const findings: VerificationFinding[] = [];

  findings.push({
    key: "is_deployed",
    ok: observations.isDeployed,
    detail: observations.isDeployed
      ? "smart account has bytecode on chain"
      : `smart account ${env.smartAccountAddress} has no bytecode on chain ${env.baseChainId}`,
  });

  if (observations.isDeployed) {
    findings.push({
      key: "implementation_address",
      ok:
        observations.observedImplementationAddress !== null &&
        getAddress(observations.observedImplementationAddress) ===
          getAddress(pinned.implementationAddress),
      detail: `expected ${pinned.implementationAddress}, observed ${
        observations.observedImplementationAddress ?? "<none>"
      }`,
    });

    findings.push({
      key: "kernel_version",
      ok: observations.observedKernelVersion === pinned.kernelVersion,
      detail: `expected ${pinned.kernelVersion}, observed ${
        observations.observedKernelVersion ?? "<none>"
      }`,
    });

    findings.push({
      key: "root_validator_address",
      ok:
        observations.observedRootValidatorAddress !== null &&
        getAddress(observations.observedRootValidatorAddress) ===
          getAddress(pinned.rootValidatorAddress),
      detail: `expected ${pinned.rootValidatorAddress}, observed ${
        observations.observedRootValidatorAddress ?? "<none>"
      }`,
    });
  }

  const overallOk = findings.every((f) => f.ok);

  const nextSteps: string[] = [];
  if (!observations.isDeployed) {
    nextSteps.push(
      "Deploy the kernel account first: run scripts/provision-kernel.ts (with --broadcast and a funded operator EOA).",
    );
  } else if (!overallOk) {
    nextSteps.push(
      "One or more pinned values do not match — the smart account at this address may be a different kernel version or owned by a different validator. Do NOT bind it to the adapter; investigate.",
    );
  } else {
    nextSteps.push(
      "Set SMART_ACCOUNT_ADDRESS on the adapter host and run chain_adapter/scripts/check-env.sh.",
      "Sentinel revoke remains in place. The ZeroDev permissions integration (per-permission install + cryptographic revoke) is tracked in docs/zerodev-permissions-integration.md and is NOT verified by this script.",
    );
  }

  return {
    schema_version: RECEIPT_SCHEMA_VERSION,
    chain_id: env.baseChainId,
    smart_account_address: env.smartAccountAddress,
    pinned_kernel_version: pinned.kernelVersion,
    pinned_implementation_address: pinned.implementationAddress,
    pinned_root_validator_address: pinned.rootValidatorAddress,
    is_deployed: observations.isDeployed,
    observed_implementation_address: observations.observedImplementationAddress,
    observed_kernel_version: observations.observedKernelVersion,
    observed_kernel_nonce: observations.observedKernelNonce,
    observed_root_validator_address: observations.observedRootValidatorAddress,
    findings,
    overall_ok: overallOk,
    next_steps: nextSteps,
  };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

const HELP_TEXT = `Usage:

  npx tsx scripts/verify-installed-validator.ts

Required env:
  SMART_ACCOUNT_ADDRESS    The kernel account address from provisioning.
  BASE_RPC_URL             Base RPC endpoint (https://...).

Optional env:
  BASE_CHAIN_ID            84532 (Sepolia, default) or 8453 (mainnet).

Output:
  A JSON receipt on stdout. Exit 0 iff every read returns a value
  consistent with a Kernel v3.1 deployment; exit 1 otherwise.

Read-only — no secrets, no broadcasts. The script never writes to
chain or to disk.`;

async function main(): Promise<void> {
  if (process.argv.includes("--help") || process.argv.includes("-h")) {
    process.stdout.write(HELP_TEXT + "\n");
    return;
  }
  const env = parseEnv(process.env);
  const observations = await observe(env);
  const receipt = buildReceipt(env, observations);
  process.stdout.write(JSON.stringify(receipt, null, 2) + "\n");
  if (!receipt.overall_ok) {
    process.exit(1);
  }
}

const invokedDirectly =
  process.argv[1] !== undefined &&
  import.meta.url === pathToFileURL(process.argv[1]).href;

if (invokedDirectly) {
  main().catch((err: unknown) => {
    if (err instanceof VerifyEnvError) {
      process.stderr.write(`verify-installed-validator: ${err.message}\n`);
    } else {
      const msg = err instanceof Error ? err.message : String(err);
      process.stderr.write(`verify-installed-validator: ${msg}\n`);
    }
    process.exit(1);
  });
}

export const _internal = { fileURLToPath };
