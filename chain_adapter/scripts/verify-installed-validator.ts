/**
 * Operator-side template: verify that a Permission Validator is
 * installed against a Kernel v3 smart account, and capture the
 * validator's deployed bytecode hash for #83's tripwire fixture.
 *
 * NOT part of the adapter runtime. Read-only — does not modify chain
 * state. Run from the same operator workspace used for
 * `provision-kernel.ts`.
 *
 * Tracks: GitHub #84 (provisioning verification, Step 6) and feeds
 * #83 (validator artifact verification + ABI pin).
 *
 * The full step-by-step runbook lives in the Phoenix repo at
 * `docs/provisioning-kernel-v3.md`. This file implements
 * Step 6 of that runbook.
 *
 * ## Required env
 *
 *   - BASE_RPC_URL                  — Base RPC endpoint (Sepolia or mainnet).
 *   - SMART_ACCOUNT_ADDRESS         — output of provision-kernel Phase 1.
 *   - PERMISSION_VALIDATOR_ADDRESS  — chosen Permission Validator deployment.
 *   - KERNEL_FACTORY_ADDRESS        — Kernel v3 factory used for Phase 1.
 *   - VENDOR_SOURCE                 — canonical public source for the
 *                                     validator artifact/ABI pin.
 *
 * ## What it asserts
 *
 *   1. `eth_getCode(SMART_ACCOUNT_ADDRESS)` returns non-empty bytecode.
 *   2. `eth_getCode(PERMISSION_VALIDATOR_ADDRESS)` returns non-empty
 *      bytecode, and prints its keccak256 hash.
 *   3. The smart account reports the validator as installed via the
 *      ERC-7579 standard `isModuleInstalled(uint256, address, bytes)`
 *      entry, with `moduleType = 1` (validator).
 *
 * ## Output
 *
 * On success: prints a JSON-shaped receipt with the addresses, the
 * validator bytecode hash, the chain id, the Kernel factory address,
 * the artifact source hint, and a chain explorer URL for the validator
 * address. The receipt is the **chain-side input** to #83 and is shaped
 * to pass Phoenix's `Bank.Delegations.Provisioning.validate_receipt/1`
 * helper — it captures `chainId`, `address`, and
 * `deployedBytecodeKeccak256` of the `VerifiedPermissionValidator`
 * record that `src/chains/base/permission_validator.ts` documents.
 *
 * The receipt does NOT include the disable function ABI itself —
 * that is the **artifact-side input** to #83 and must be lifted from
 * one of: a Basescan-verified contract at `chain_explorer_url`, the
 * vendor's audited package source, or a vendor-published deployment
 * manifest. See `permission_validator.ts` ("What #83 must populate")
 * for the full pin contract.
 *
 * On any failure: exits non-zero with the specific assertion that
 * failed. Do NOT bind addresses to the runtime env until this script
 * passes.
 */

import {
  createPublicClient,
  http,
  isAddress,
  keccak256,
  type Address,
  type Hex,
} from "viem";
import { base, baseSepolia } from "viem/chains";

const PLACEHOLDER_PATTERN = /_placeholder$/i;

function refuse(reason: string): never {
  console.error(`verification refused: ${reason}`);
  process.exit(1);
}

function readRequired(name: string): string {
  const v = process.env[name];
  if (!v) refuse(`${name} is required`);
  if (PLACEHOLDER_PATTERN.test(v)) refuse(`${name} still has a placeholder value`);
  return v;
}

function readAddress(name: string, value: string): Address {
  if (!isAddress(value)) refuse(`${name} is not a valid 0x-prefixed address`);
  return value as Address;
}

function readVendorSource(): string {
  const value = readRequired("VENDOR_SOURCE");
  try {
    new URL(value);
    return value;
  } catch {
    refuse("VENDOR_SOURCE must be an absolute URL to the vendor artifact or verified contract");
  }
}

function configuredChain() {
  const rawChainId = process.env.BASE_CHAIN_ID ?? "84532";
  const chainId = Number(rawChainId);
  if (chainId === base.id) return base;
  if (chainId === baseSepolia.id) return baseSepolia;
  refuse("BASE_CHAIN_ID must be 84532 (Base Sepolia) or 8453 (Base mainnet)");
}

// ERC-7579 normative `isModuleInstalled(uint256 moduleType,
// address module, bytes data)`. Validator moduleType is `1` per
// EIP-7579. We pass `0x` for `data` because the standard says
// validators ignore the additional context arg for presence checks.
const ERC_7579_IS_MODULE_INSTALLED_ABI = [
  {
    name: "isModuleInstalled",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "moduleType", type: "uint256" },
      { name: "module", type: "address" },
      { name: "data", type: "bytes" },
    ],
    outputs: [{ type: "bool" }],
  },
] as const;

const ERC_7579_VALIDATOR_MODULE_TYPE = 1n;

interface VerificationReceipt {
  chain_id: number;
  smart_account_address: Address;
  smart_account_code_size_bytes: number;
  permission_validator_address: Address;
  kernel_factory_address: Address;
  permission_validator_bytecode_keccak256: Hex;
  validator_bytecode_keccak256: Hex;
  permission_validator_code_size_bytes: number;
  validator_installed: boolean;
  vendor_source: string;
  // Chain explorer URL for the validator address. Populated for the
  // two chains the runbook supports (Base mainnet 8453, Base Sepolia
  // 84532). Other chain ids are refused before receipt emission.
  basescan_validator_url: string;
  chain_explorer_url: string;
  verified_at: string;
}

/**
 * Build a Basescan / Sepolia Basescan URL for the validator address.
 * Pinned to the two chains the runbook supports; returns null for any
 * other chain so the script refuses rather than silently producing a
 * Phoenix receipt with an unverifiable explorer URL.
 */
function chainExplorerUrl(chainId: number, address: Address): string | null {
  if (chainId === 8453) {
    return `https://basescan.org/address/${address}`;
  }
  if (chainId === 84532) {
    return `https://sepolia.basescan.org/address/${address}`;
  }
  return null;
}

async function main(): Promise<void> {
  const baseRpcUrl = readRequired("BASE_RPC_URL");
  const smartAccountAddress = readAddress(
    "SMART_ACCOUNT_ADDRESS",
    readRequired("SMART_ACCOUNT_ADDRESS"),
  );
  const permissionValidatorAddress = readAddress(
    "PERMISSION_VALIDATOR_ADDRESS",
    readRequired("PERMISSION_VALIDATOR_ADDRESS"),
  );
  const kernelFactoryAddress = readAddress(
    "KERNEL_FACTORY_ADDRESS",
    readRequired("KERNEL_FACTORY_ADDRESS"),
  );
  const vendorSource = readVendorSource();

  const publicClient = createPublicClient({
    chain: configuredChain(),
    transport: http(baseRpcUrl),
  });
  const chainId = await publicClient.getChainId();
  const validatorExplorerUrl = chainExplorerUrl(chainId, permissionValidatorAddress);
  if (!validatorExplorerUrl) {
    refuse(
      `unsupported chain id ${chainId}; this verification template only emits ` +
        `Phoenix-ready receipts for Base mainnet (8453) and Base Sepolia (84532)`,
    );
  }

  // 1. Smart account must be deployed.
  const accountCode = await publicClient.getCode({ address: smartAccountAddress });
  if (!accountCode || accountCode === "0x") {
    refuse(
      `SMART_ACCOUNT_ADDRESS ${smartAccountAddress} has no bytecode on chain ${chainId}; ` +
        `either provisioning did not land or you pointed at the wrong RPC`,
    );
  }

  // 2. Validator must be deployed; capture its bytecode hash.
  const validatorCode = await publicClient.getCode({
    address: permissionValidatorAddress,
  });
  if (!validatorCode || validatorCode === "0x") {
    refuse(
      `PERMISSION_VALIDATOR_ADDRESS ${permissionValidatorAddress} has no bytecode on chain ${chainId}; ` +
        `the address is wrong or the validator has not been deployed on this chain`,
    );
  }
  const validatorBytecodeHash = keccak256(validatorCode);

  // 3. Smart account must report the validator as installed.
  let validatorInstalled = false;
  try {
    validatorInstalled = (await publicClient.readContract({
      address: smartAccountAddress,
      abi: ERC_7579_IS_MODULE_INSTALLED_ABI,
      functionName: "isModuleInstalled",
      args: [ERC_7579_VALIDATOR_MODULE_TYPE, permissionValidatorAddress, "0x"],
      authorizationList: undefined,
    })) as boolean;
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    refuse(
      `isModuleInstalled call reverted on ${smartAccountAddress}; the account ` +
        `may not implement the ERC-7579 module-introspection ABI (then it is ` +
        `not a Kernel v3 / ERC-7579 account, and the rest of the runbook does ` +
        `not apply). RPC error: ${message}`,
    );
  }

  if (!validatorInstalled) {
    refuse(
      `smart account ${smartAccountAddress} does NOT report ${permissionValidatorAddress} ` +
        `as an installed validator (moduleType=1). Run provision-kernel.ts ` +
        `Phase 2 (INSTALL_VALIDATOR=true) before re-verifying.`,
    );
  }

  const receipt: VerificationReceipt = {
    chain_id: chainId,
    smart_account_address: smartAccountAddress,
    smart_account_code_size_bytes: (accountCode.length - 2) / 2,
    permission_validator_address: permissionValidatorAddress,
    kernel_factory_address: kernelFactoryAddress,
    permission_validator_bytecode_keccak256: validatorBytecodeHash,
    validator_bytecode_keccak256: validatorBytecodeHash,
    permission_validator_code_size_bytes: (validatorCode.length - 2) / 2,
    validator_installed: true,
    vendor_source: vendorSource,
    basescan_validator_url: validatorExplorerUrl,
    chain_explorer_url: validatorExplorerUrl,
    verified_at: new Date().toISOString(),
  };

  console.log("verification PASS — record this in the deployment journal:");
  console.log(JSON.stringify(receipt, null, 2));
  console.log(
    [
      "",
      "Next steps for #83 (validator artifact verification + ABI pin):",
      "",
      "  1. The receipt above is the CHAIN-SIDE input to #83. It pins:",
      "       - chainId                       (receipt.chain_id)",
      "       - validator address             (receipt.permission_validator_address)",
      "       - validator bytecode keccak256  (receipt.permission_validator_bytecode_keccak256)",
      "       - Kernel factory address         (receipt.kernel_factory_address)",
      "       - artifact source hint          (receipt.vendor_source)",
      "     The receipt is shaped to pass Phoenix's",
      "     `Bank.Delegations.Provisioning.validate_receipt/1` helper.",
      "     The first three fields populate `chainId`, `address`, and",
      "     `deployedBytecodeKeccak256` of the VerifiedPermissionValidator",
      "     contract documented in",
      "     `chain_adapter/src/chains/base/permission_validator.ts`",
      "     under \"What #83 must populate\".",
      "",
      "  2. The receipt does NOT include the disable function ABI. #83",
      "     must lift that fragment from a concrete artifact:",
      `       - Visit ${receipt.chain_explorer_url} and confirm the contract is verified;`,
      "       - OR locate the canonical audited package whose source",
      "         compiles to this exact bytecode hash;",
      "       - OR locate the vendor's deployment manifest pinning",
      "         this bytecode hash + ABI.",
      "     Whichever artifact is used, record `artifactSource.kind`,",
      "     `artifactSource.url`, and `artifactSource.note` exactly as",
      "     `permission_validator.ts` specifies.",
      "",
      "  3. Hand the receipt above + the artifact reference from step 2",
      "     to whoever is working #83. Do NOT bind",
      "     PERMISSION_VALIDATOR_ADDRESS into the runtime env until #83",
      "     has landed the verified pin — `requirePermissionValidatorAddress`",
      "     succeeds the moment the env is set, but `executeRevoke`",
      "     would still be sentinel without #83's pin (no behavioural",
      "     downgrade, but a misleading config posture).",
    ].join("\n"),
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
