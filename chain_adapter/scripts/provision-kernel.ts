/**
 * Operator-side template: provision a Kernel v3 smart account on Base
 * and install a Permission Validator against it.
 *
 * NOT part of the adapter runtime. NOT runnable from a production
 * adapter container — see `scripts/README.md` for why. Copy this file
 * into a separate operator workspace, `npm install` the vendor SDK,
 * fill in the marked placeholders, and run with `npx tsx`.
 *
 * Tracks: GitHub #84 (provisioning).
 *
 * The full step-by-step runbook lives in the Phoenix repo at
 * `docs/provisioning-kernel-v3.md`. This file implements
 * Steps 4 and 5 of that runbook in template form. Read the runbook
 * before running.
 *
 * ## Two phases
 *
 *   - Phase 1 (default): deploy the Kernel v3 smart account.
 *   - Phase 2 (`INSTALL_VALIDATOR=true`): install the Permission
 *     Validator against the previously-deployed account.
 *
 * Phases are gated on a single env var so the operator can verify
 * Phase 1 on chain before committing to Phase 2.
 *
 * ## Required env (both phases)
 *
 *   - OPERATOR_PRIVATE_KEY    — pays gas for the deployment + install.
 *   - BASE_RPC_URL            — Base RPC endpoint (Sepolia or mainnet).
 *   - BUNDLER_RPC_URL         — ERC-4337 v0.7 bundler endpoint.
 *   - KERNEL_FACTORY_ADDRESS  — Kernel v3 factory on the target chain.
 *   - PERMISSION_VALIDATOR_ADDRESS — chosen Permission Validator deployment.
 *
 * ## Phase 1 additionally
 *
 *   - DELEGATION_SIGNER_PUBKEY — 0x-prefixed EOA address that the
 *     validator will authorise (NOT the operator EOA).
 *
 * ## Phase 2 additionally
 *
 *   - SMART_ACCOUNT_ADDRESS   — output of Phase 1.
 *
 * ## Refusal modes (loud failure beats silent miss-deploy)
 *
 * The script refuses to run if:
 *   - any required env is missing;
 *   - any address is the literal placeholder `0x_..._placeholder`;
 *   - the operator EOA has zero balance on the target chain.
 */

// OPERATOR: install with `npm install viem` in your provisioning workspace.
import {
  createPublicClient,
  createWalletClient,
  http,
  isAddress,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
// OPERATOR: install with `npm install @zerodev/sdk` (or the equivalent
// vendor SDK if pivoting to Biconomy Nexus per #56's documented
// fallback). The shapes below assume ZeroDev's API; adjust import
// names + signatures if you swap vendors.
//
// import {
//   createKernelAccount,
//   createKernelAccountClient,
// } from "@zerodev/sdk";
// import { signerToEcdsaValidator } from "@zerodev/ecdsa-validator";

// ---------- env loading + refusal -----------------------------------

interface ProvisioningEnv {
  operatorPrivateKey: Hex;
  baseRpcUrl: string;
  bundlerRpcUrl: string;
  kernelFactoryAddress: Address;
  permissionValidatorAddress: Address;
  delegationSignerPubkey?: Address;
  smartAccountAddress?: Address;
  installValidator: boolean;
}

const PLACEHOLDER_PATTERN = /_placeholder$/i;

function refuse(reason: string): never {
  console.error(`refusing to provision: ${reason}`);
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

function loadEnv(): ProvisioningEnv {
  const operatorPrivateKey = readRequired("OPERATOR_PRIVATE_KEY");
  if (!operatorPrivateKey.startsWith("0x") || operatorPrivateKey.length !== 66) {
    refuse("OPERATOR_PRIVATE_KEY must be 0x-prefixed 32-byte hex");
  }

  const baseRpcUrl = readRequired("BASE_RPC_URL");
  const bundlerRpcUrl = readRequired("BUNDLER_RPC_URL");
  const kernelFactoryAddress = readAddress(
    "KERNEL_FACTORY_ADDRESS",
    readRequired("KERNEL_FACTORY_ADDRESS"),
  );
  const permissionValidatorAddress = readAddress(
    "PERMISSION_VALIDATOR_ADDRESS",
    readRequired("PERMISSION_VALIDATOR_ADDRESS"),
  );

  const installValidator = process.env.INSTALL_VALIDATOR === "true";

  if (installValidator) {
    const smartAccountAddress = readAddress(
      "SMART_ACCOUNT_ADDRESS",
      readRequired("SMART_ACCOUNT_ADDRESS"),
    );
    return {
      operatorPrivateKey: operatorPrivateKey as Hex,
      baseRpcUrl,
      bundlerRpcUrl,
      kernelFactoryAddress,
      permissionValidatorAddress,
      smartAccountAddress,
      installValidator: true,
    };
  } else {
    const delegationSignerPubkey = readAddress(
      "DELEGATION_SIGNER_PUBKEY",
      readRequired("DELEGATION_SIGNER_PUBKEY"),
    );
    return {
      operatorPrivateKey: operatorPrivateKey as Hex,
      baseRpcUrl,
      bundlerRpcUrl,
      kernelFactoryAddress,
      permissionValidatorAddress,
      delegationSignerPubkey,
      installValidator: false,
    };
  }
}

// ---------- phase 1: deploy Kernel v3 smart account ----------------

async function phaseDeploy(env: ProvisioningEnv): Promise<void> {
  console.log("== PHASE 1: deploy Kernel v3 smart account ==");
  console.log(`  base_rpc_url               : ${env.baseRpcUrl}`);
  console.log(`  bundler_rpc_url            : ${env.bundlerRpcUrl}`);
  console.log(`  kernel_factory_address     : ${env.kernelFactoryAddress}`);
  console.log(`  delegation_signer_pubkey   : ${env.delegationSignerPubkey}`);

  const operator = privateKeyToAccount(env.operatorPrivateKey);
  const publicClient = createPublicClient({ transport: http(env.baseRpcUrl) });
  const walletClient = createWalletClient({
    account: operator,
    transport: http(env.baseRpcUrl),
  });

  // Sanity check: the operator EOA must have non-zero balance on the
  // target chain. A zero-balance run will fail at user-op submission;
  // catching it here gives the operator a clearer signal.
  const balance = await publicClient.getBalance({ address: operator.address });
  if (balance === 0n) {
    refuse(
      `operator EOA ${operator.address} has zero balance on ${env.baseRpcUrl}; ` +
        `fund it before running phase 1`,
    );
  }
  console.log(`  operator                   : ${operator.address}`);
  console.log(`  operator_balance_wei       : ${balance.toString()}`);

  // OPERATOR: the actual deployment call shape depends on the vendor
  // SDK. With ZeroDev the typical sequence is:
  //
  //   const ecdsaValidator = await signerToEcdsaValidator(publicClient, {
  //     signer: privateKeyToAccount(env.operatorPrivateKey),
  //     entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  //     kernelVersion: "0.3.x",
  //     validatorAddress: <KERNEL_DEFAULT_VALIDATOR_FOR_VERSION>,
  //   });
  //
  //   const kernelAccount = await createKernelAccount(publicClient, {
  //     plugins: { sudo: ecdsaValidator },
  //     entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  //     kernelVersion: "0.3.x",
  //     factoryAddress: env.kernelFactoryAddress,
  //   });
  //
  //   const accountClient = createKernelAccountClient({
  //     account: kernelAccount,
  //     bundlerTransport: http(env.bundlerRpcUrl),
  //     entryPoint: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  //   });
  //
  //   // Deployment is implicit on first user-op; force one with a
  //   // no-op self-call so the deploy lands deterministically.
  //   const userOpHash = await accountClient.sendUserOperation({
  //     callData: await kernelAccount.encodeCallData({
  //       to: kernelAccount.address,
  //       value: 0n,
  //       data: "0x",
  //     }),
  //   });
  //   const receipt = await accountClient.waitForUserOperationReceipt({
  //     hash: userOpHash,
  //   });
  //
  //   console.log(`  smart_account_address     : ${kernelAccount.address}`);
  //   console.log(`  deploy_userop_hash        : ${userOpHash}`);
  //   console.log(`  deploy_tx_hash            : ${receipt.receipt.transactionHash}`);

  console.warn(
    "PHASE 1 stub: vendor SDK call sequence is documented inline " +
      "above as comments. Uncomment + adapt to your vendor before " +
      "running for real. See `docs/provisioning-kernel-v3.md` " +
      "Step 4.",
  );

  // Touch the unused-but-validated env so eslint/tsc don't flag it
  // when an operator runs the stub before filling in the SDK calls.
  void walletClient;
}

// ---------- phase 2: install Permission Validator -------------------

async function phaseInstallValidator(env: ProvisioningEnv): Promise<void> {
  console.log("== PHASE 2: install Permission Validator ==");
  console.log(`  smart_account_address       : ${env.smartAccountAddress}`);
  console.log(`  permission_validator_address: ${env.permissionValidatorAddress}`);

  const operator = privateKeyToAccount(env.operatorPrivateKey);
  const publicClient = createPublicClient({ transport: http(env.baseRpcUrl) });

  // Confirm phase 1 actually landed before attempting install.
  const code = await publicClient.getCode({
    address: env.smartAccountAddress as Address,
  });
  if (!code || code === "0x") {
    refuse(
      `SMART_ACCOUNT_ADDRESS ${env.smartAccountAddress} has no bytecode on ` +
        `${env.baseRpcUrl}; either phase 1 did not land or you pointed at the ` +
        `wrong chain`,
    );
  }

  // OPERATOR: the install user-op calls ERC-7579's standard
  // `installModule(uint256 moduleType, address module, bytes initData)`
  // entry on the smart account, with `moduleType = 1` (validator).
  // The exact `initData` shape is validator-specific — see the
  // vendor's docs for the chosen Permission Validator deployment.
  // Typical ZeroDev sequence:
  //
  //   const installCallData = encodeFunctionData({
  //     abi: [
  //       {
  //         name: "installModule",
  //         type: "function",
  //         stateMutability: "payable",
  //         inputs: [
  //           { name: "moduleType", type: "uint256" },
  //           { name: "module", type: "address" },
  //           { name: "initData", type: "bytes" },
  //         ],
  //         outputs: [],
  //       },
  //     ],
  //     functionName: "installModule",
  //     args: [
  //       1n, // ERC-7579 moduleType: validator
  //       env.permissionValidatorAddress,
  //       <initData per the validator's docs>,
  //     ],
  //   });
  //
  //   const userOpHash = await accountClient.sendUserOperation({
  //     callData: installCallData,
  //   });
  //   const receipt = await accountClient.waitForUserOperationReceipt({
  //     hash: userOpHash,
  //   });
  //
  //   console.log(`  install_userop_hash       : ${userOpHash}`);
  //   console.log(`  install_tx_hash           : ${receipt.receipt.transactionHash}`);

  console.warn(
    "PHASE 2 stub: vendor SDK call sequence is documented inline " +
      "above as comments. Uncomment + adapt before running for real. " +
      "See `docs/provisioning-kernel-v3.md` Step 5.",
  );

  void operator;
}

// ---------- entry point --------------------------------------------

async function main(): Promise<void> {
  const env = loadEnv();
  if (env.installValidator) {
    await phaseInstallValidator(env);
  } else {
    await phaseDeploy(env);
  }
  console.log(
    "\nNext: run `scripts/verify-installed-validator.ts` against the " +
      "deployed addresses (Step 6 of the runbook).",
  );
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
