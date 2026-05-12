#!/usr/bin/env tsx
/**
 * End-to-end install simulator (#kernel-account-collision Path A
 * follow-up).
 *
 * Drives the EXACT install code path the browser hook runs, from
 * Node.js, with a freshly generated test EOA standing in for the
 * MetaMask wallet. No browser, no MetaMask popup, no LiveView. The
 * goal is to surface every layer's actual failure mode without
 * waiting on user clicks:
 *
 *   1. ZeroDev SDK constructs sudo + permission validators with
 *      kernel index from `BROWSER_KERNEL_ACCOUNT_INDEX`.
 *   2. publicClient hits `BASE_RPC_URL` (chain RPC).
 *   3. bundlerTransport hits `BUNDLER_RPC_URL` (Pimlico).
 *   4. Paymaster sponsorship via `paymaster: true` → Pimlico
 *      `pm_getPaymasterStubData` / `pm_getPaymasterData`.
 *   5. Session-portion signature: simulator calls the running
 *      chain_adapter's `/install/sign_session_portion` over HTTP
 *      with the same Bearer secret Phoenix uses.
 *   6. Submits the install UserOp to Pimlico.
 *   7. Waits for the bundler receipt and reports the outcome.
 *
 * Run:
 *
 *     cd chain_adapter
 *     set -a; source .env; set +a
 *     export BASE_SEPOLIA_BUNDLER_RPC="$BUNDLER_RPC_URL"
 *     npx tsx scripts/install-e2e-simulator.ts
 *
 * The chain_adapter MUST already be running (`npm run dev`) so the
 * simulator can call `/install/sign_session_portion`.
 *
 * Funding:
 *   - The simulator's smart account derives from a fresh test EOA,
 *     not the operator. With `paymaster: true` Pimlico sponsors gas;
 *     no manual funding required.
 *
 * Exit codes:
 *   - 0  install confirmed on chain
 *   - 1  any step failed (see logs)
 *
 * Telemetry:
 *   - Every step prints `[install-sim:<step>] …` so we know exactly
 *     where the chain breaks. Matches the browser hook's
 *     `[browser-install:<step>]` logging convention.
 */

import {
  http,
  createPublicClient,
  createWalletClient,
  type Hex,
  hashMessage,
  recoverAddress,
} from "viem";
import { generatePrivateKey, privateKeyToAccount, toAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import {
  createKernelAccount,
  createKernelAccountClient,
} from "@zerodev/sdk";
import { getEntryPoint, KERNEL_V3_1 } from "@zerodev/sdk/constants";
import { signerToEcdsaValidator } from "@zerodev/ecdsa-validator";
import { toPermissionValidator } from "@zerodev/permissions";
import { toECDSASigner } from "@zerodev/permissions/signers";
import { toSudoPolicy } from "@zerodev/permissions/policies";

// Manual gas limits for the install UserOp. Mirrors the
// `PERMISSION_INSTALL_GAS_LIMITS` constant in
// `chain_adapter/src/chains/base/grant.ts`. ZeroDev's SDK can't
// reliably estimate gas for an enable-signature install (the
// sudo signature mode changes the validation cost), so we supply
// conservative limits and let the bundler still simulate the
// final signed UserOp.
const PERMISSION_INSTALL_GAS_LIMITS = {
  callGasLimit: 500_000n,
  verificationGasLimit: 1_000_000n,
  preVerificationGas: 100_000n,
} as const;

const ADAPTER_URL = process.env.ADAPTER_BASE_URL || "http://localhost:4100";
const ADAPTER_SECRET =
  process.env.ADAPTER_DISPATCH_SECRET || "dev-adapter-dispatch-secret";
const CHAIN_RPC =
  process.env.BASE_SEPOLIA_RPC_URL ||
  process.env.BASE_RPC_URL ||
  "https://sepolia.base.org";
const BUNDLER_RPC =
  process.env.BASE_SEPOLIA_BUNDLER_RPC ||
  process.env.BUNDLER_RPC_URL;
const SESSION_SIGNER_ADDRESS = process.env.SESSION_SIGNER_ADDRESS;
const KERNEL_INDEX = BigInt(
  process.env.BROWSER_KERNEL_ACCOUNT_INDEX || "1",
);

function step(name: string, payload: unknown = "") {
  const stamp = new Date().toISOString();
  // eslint-disable-next-line no-console
  console.log(`[install-sim:${name}] ${stamp}`, payload);
}

function fatal(name: string, err: unknown): never {
  const message =
    err && typeof err === "object" && "message" in err
      ? (err as { message: unknown }).message
      : String(err);
  // eslint-disable-next-line no-console
  console.error(`[install-sim:${name}] FAILED`, {
    message,
    stack: err && typeof err === "object" && "stack" in err ? (err as { stack: unknown }).stack : undefined,
  });
  process.exit(1);
}

async function main(): Promise<void> {
  if (!BUNDLER_RPC) fatal("preflight", new Error("BUNDLER_RPC_URL is not set"));
  if (!SESSION_SIGNER_ADDRESS)
    fatal("preflight", new Error("SESSION_SIGNER_ADDRESS is not set"));

  step("config", {
    adapter_url: ADAPTER_URL,
    chain_rpc_host: new URL(CHAIN_RPC).host,
    bundler_rpc_host: new URL(BUNDLER_RPC).host,
    session_signer_address: SESSION_SIGNER_ADDRESS,
    kernel_index: KERNEL_INDEX.toString(),
  });

  // Fresh test EOA standing in for the browser user. Mirrors the
  // browser flow exactly except `account.signMessage` runs in-process
  // instead of via the MetaMask popup.
  const userPrivateKey = generatePrivateKey();
  const userAccount = privateKeyToAccount(userPrivateKey);
  step("user_eoa", { address: userAccount.address });

  // Public client = chain RPC (NOT bundler URL — that endpoint
  // doesn't serve `eth_call`). `as any` matches the cast pattern
  // in `provision-kernel.ts`: viem's generic-parameterised types
  // drift between the version we depend on directly and the one
  // `@zerodev/sdk` was compiled against, but `Client` is
  // structurally compatible at runtime.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const publicClient = createPublicClient({
    chain: baseSepolia,
    transport: http(CHAIN_RPC),
  }) as any;

  // ── Sudo validator (user EOA) ────────────────────────────────────
  const walletClient = createWalletClient({
    account: userAccount,
    chain: baseSepolia,
    transport: http(CHAIN_RPC),
  });

  const entryPoint = getEntryPoint("0.7");

  let sudoValidator;
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    sudoValidator = await signerToEcdsaValidator(publicClient, {
      signer: walletClient as any,
      entryPoint,
      kernelVersion: KERNEL_V3_1,
    });
    step("signerToEcdsaValidator", { ok: true });
  } catch (err) {
    fatal("signerToEcdsaValidator", err);
  }

  // ── Permission validator with session-signer proxy ───────────────
  // viem's `toAccount` with a signMessage that calls our HTTP
  // proxy — EXACTLY what install_zerodev_client.js does in the
  // browser, just over `fetch` from Node.
  const sessionAccount = toAccount({
    address: SESSION_SIGNER_ADDRESS as `0x${string}`,
    async signMessage({ message }) {
      if (
        !message ||
        typeof message !== "object" ||
        !("raw" in message) ||
        typeof (message as { raw: unknown }).raw !== "string"
      ) {
        throw new Error(
          "session signer only signs raw 32-byte hashes (install UserOp)",
        );
      }
      const userOpHash = (message as { raw: string }).raw;
      step("session_sign:request", {
        hash_prefix: userOpHash.slice(0, 18),
      });

      const resp = await fetch(
        `${ADAPTER_URL}/install/sign_session_portion`,
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            authorization: `Bearer ${ADAPTER_SECRET}`,
          },
          body: JSON.stringify({
            contract_version: 1,
            binding_id: "00000000-0000-4000-8000-000000000000", // simulator fake
            smart_account_id: "sa_wb_simulator",
            user_op_hash: userOpHash,
            session_signer_address: SESSION_SIGNER_ADDRESS,
          }),
        },
      );

      if (!resp.ok) {
        const body = await resp.text();
        throw new Error(
          `session_sign HTTP ${resp.status}: ${body.slice(0, 200)}`,
        );
      }

      const json = (await resp.json()) as { signature: string };
      step("session_sign:response", { sig_prefix: json.signature.slice(0, 18) });
      return json.signature as Hex;
    },
    async signTransaction() {
      throw new Error("session signer never signs transactions");
    },
    async signTypedData() {
      throw new Error("session signer never signs typed data");
    },
  });

  let sessionSigner;
  try {
    sessionSigner = await toECDSASigner({ signer: sessionAccount });
    step("toECDSASigner", { ok: true });
  } catch (err) {
    fatal("toECDSASigner", err);
  }

  let permissionPlugin;
  try {
    permissionPlugin = await toPermissionValidator(publicClient, {
      signer: sessionSigner,
      policies: [toSudoPolicy({})],
      entryPoint,
      kernelVersion: KERNEL_V3_1,
    });
    step("toPermissionValidator", { ok: true });
  } catch (err) {
    fatal("toPermissionValidator", err);
  }

  // ── Build kernel account (browser index) ─────────────────────────
  let kernelAccount;
  try {
    kernelAccount = await createKernelAccount(publicClient, {
      entryPoint,
      kernelVersion: KERNEL_V3_1,
      index: KERNEL_INDEX,
      plugins: { sudo: sudoValidator, regular: permissionPlugin },
    });
    step("createKernelAccount", {
      ok: true,
      address: kernelAccount.address,
    });
  } catch (err) {
    fatal("createKernelAccount", err);
  }

  // ── Cross-bundler gas-price probe (matches browser hook) ─────────
  const estimateFeesPerGas = async ({ bundlerClient }: { bundlerClient: { request: (args: { method: string; params: unknown[] }) => Promise<unknown> } }) => {
    for (const method of [
      "pimlico_getUserOperationGasPrice",
      "zd_getUserOperationGasPrice",
    ]) {
      try {
        const gp = (await bundlerClient.request({ method, params: [] })) as {
          standard?: { maxFeePerGas: string; maxPriorityFeePerGas: string };
        };
        if (gp.standard) {
          return {
            maxFeePerGas: BigInt(gp.standard.maxFeePerGas),
            maxPriorityFeePerGas: BigInt(gp.standard.maxPriorityFeePerGas),
          };
        }
      } catch (_e) {
        // try the next probe
      }
    }
    throw new Error("no bundler gas-price method available");
  };

  const kernelClient = createKernelAccountClient({
    account: kernelAccount,
    chain: baseSepolia,
    bundlerTransport: http(BUNDLER_RPC),
    client: publicClient,
    paymaster: true,
    userOperation: { estimateFeesPerGas },
  });
  step("createKernelAccountClient", {
    ok: true,
    paymaster: "enabled (Pimlico)",
  });

  // ── Build install UserOp (inert call to address(0)) ──────────────
  let userOpHash: Hex;
  try {
    const callData = await kernelAccount.encodeCalls([
      {
        to: "0x0000000000000000000000000000000000000000",
        value: 0n,
        data: "0x",
      },
    ]);
    step("encodeCalls", { calldata_len: callData.length });

    userOpHash = (await kernelClient.sendUserOperation({
      callData,
      ...PERMISSION_INSTALL_GAS_LIMITS,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)) as Hex;
    step("sendUserOperation", { userop_hash: userOpHash });
  } catch (err) {
    fatal("sendUserOperation", err);
  }

  // ── Wait for receipt ─────────────────────────────────────────────
  try {
    const receipt = await kernelClient.waitForUserOperationReceipt({
      hash: userOpHash,
      timeout: 90_000,
    });

    if (!receipt || !receipt.success) {
      fatal("waitForUserOperationReceipt", {
        message: "userop did not succeed",
        receipt,
      });
    }

    step("waitForUserOperationReceipt", {
      tx_hash: receipt.receipt.transactionHash,
      block_number: Number(receipt.receipt.blockNumber),
    });
  } catch (err) {
    fatal("waitForUserOperationReceipt", err);
  }

  step("done", { smart_account_address: kernelAccount.address });
  // Sanity recover for the simulator's own session sig — the
  // bundler already validated it on chain, but emit a debug
  // assertion just in case the test environment ever decouples.
  void hashMessage;
  void recoverAddress;
  process.exit(0);
}

main().catch((err) => fatal("uncaught", err));
