/**
 * provision-kernel.ts tests.
 *
 * Pure / dry-run only. No RPC, no secrets, no broadcast. The
 * `--broadcast` path uses live bundler + RPC by design, so it is
 * exercised by an operator on Base Sepolia, not in CI.
 */

import { describe, it, expect } from "vitest";
import { getAddress } from "viem";
import {
  ALLOWED_CHAIN_IDS,
  ProvisionEnvError,
  RECEIPT_SCHEMA_VERSION,
  buildDryRunReceipt,
  deriveExpectedKernelAddress,
  getKernelAddresses,
  getRootEcdsaValidatorAddress,
  parseBroadcastEnv,
  parseCli,
  parseDryRunEnv,
  type DryRunEnv,
} from "../scripts/provision-kernel.js";

const SAMPLE_OWNER = "0x000000000000000000000000000000000000dEaD" as const;

// A real, balanced dev EOA-style fixture (private key ↔ address).
// The key is a known test vector; never used on mainnet. The
// address is its EIP-55-checksummed derivation.
const SAMPLE_PRIVATE_KEY =
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80" as const;
const SAMPLE_PRIVATE_KEY_ADDRESS = getAddress(
  "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
);

function dryRunEnv(overrides: Partial<NodeJS.ProcessEnv> = {}): NodeJS.ProcessEnv {
  return {
    OPERATOR_ADDRESS: SAMPLE_OWNER,
    ...overrides,
  };
}

describe("parseDryRunEnv", () => {
  it("requires OPERATOR_ADDRESS", () => {
    expect(() => parseDryRunEnv({})).toThrow(ProvisionEnvError);
    expect(() => parseDryRunEnv({})).toThrow(/OPERATOR_ADDRESS is required/);
  });

  it("rejects placeholder OPERATOR_ADDRESS", () => {
    expect(() =>
      parseDryRunEnv({ OPERATOR_ADDRESS: "0x_operator_placeholder" }),
    ).toThrow(/placeholder/);
  });

  it("rejects malformed OPERATOR_ADDRESS", () => {
    expect(() => parseDryRunEnv({ OPERATOR_ADDRESS: "0xdead" })).toThrow(
      /20-byte EVM address/,
    );
  });

  it("normalises OPERATOR_ADDRESS to checksum form", () => {
    const env = parseDryRunEnv({
      OPERATOR_ADDRESS: SAMPLE_OWNER.toLowerCase(),
    });
    expect(env.ownerAddress).toBe(SAMPLE_OWNER);
  });

  it("defaults BASE_CHAIN_ID to Base Sepolia (84532)", () => {
    const env = parseDryRunEnv(dryRunEnv());
    expect(env.baseChainId).toBe(84_532);
  });

  it("accepts Base mainnet (8453)", () => {
    const env = parseDryRunEnv(dryRunEnv({ BASE_CHAIN_ID: "8453" }));
    expect(env.baseChainId).toBe(8453);
  });

  it("rejects unknown chain ids — including mainnet Ethereum", () => {
    expect(() => parseDryRunEnv(dryRunEnv({ BASE_CHAIN_ID: "1" }))).toThrow(
      /84532 \(Sepolia\) or 8453/,
    );
  });

  it("rejects BASE_CHAIN_ID with trailing junk (parseInt-leniency guard)", () => {
    // `Number.parseInt("84532abc", 10)` returns 84532; without the
    // strict-digits gate that would silently pass. Pin it.
    expect(() =>
      parseDryRunEnv(dryRunEnv({ BASE_CHAIN_ID: "84532abc" })),
    ).toThrow(/positive integer with no extra characters/);
  });

  it("rejects BASE_CHAIN_ID with leading whitespace", () => {
    expect(() =>
      parseDryRunEnv(dryRunEnv({ BASE_CHAIN_ID: " 84532" })),
    ).toThrow(/positive integer with no extra characters/);
  });

  it("defaults KERNEL_ACCOUNT_INDEX to 0", () => {
    const env = parseDryRunEnv(dryRunEnv());
    expect(env.kernelAccountIndex).toBe(0n);
  });

  it("parses KERNEL_ACCOUNT_INDEX as a bigint", () => {
    const env = parseDryRunEnv(dryRunEnv({ KERNEL_ACCOUNT_INDEX: "42" }));
    expect(env.kernelAccountIndex).toBe(42n);
  });

  it("rejects non-integer KERNEL_ACCOUNT_INDEX", () => {
    expect(() =>
      parseDryRunEnv(dryRunEnv({ KERNEL_ACCOUNT_INDEX: "deadbeef" })),
    ).toThrow(/non-negative integer/);
  });

  it("rejects negative KERNEL_ACCOUNT_INDEX (BigInt-leniency guard)", () => {
    // `BigInt("-1")` succeeds and produces -1n; the SDK's CREATE2
    // derivation expects an unsigned 256-bit salt and we lose the
    // ability to reproduce the address from a positive index later.
    // Pin the rejection.
    expect(() =>
      parseDryRunEnv(dryRunEnv({ KERNEL_ACCOUNT_INDEX: "-1" })),
    ).toThrow(/non-negative integer/);
  });

  it("rejects KERNEL_ACCOUNT_INDEX with trailing whitespace", () => {
    expect(() =>
      parseDryRunEnv(dryRunEnv({ KERNEL_ACCOUNT_INDEX: "5 " })),
    ).toThrow(/non-negative integer/);
  });

  it("rejects KERNEL_ACCOUNT_INDEX with a decimal point", () => {
    expect(() =>
      parseDryRunEnv(dryRunEnv({ KERNEL_ACCOUNT_INDEX: "3.14" })),
    ).toThrow(/non-negative integer/);
  });
});

describe("parseBroadcastEnv", () => {
  function broadcastEnv(
    overrides: Partial<NodeJS.ProcessEnv> = {},
  ): NodeJS.ProcessEnv {
    return {
      OPERATOR_ADDRESS: SAMPLE_PRIVATE_KEY_ADDRESS,
      OPERATOR_PRIVATE_KEY: SAMPLE_PRIVATE_KEY,
      BASE_RPC_URL: "https://sepolia.example",
      BUNDLER_RPC_URL: "https://bundler.example",
      ...overrides,
    };
  }

  it("requires the broadcast-only env vars", () => {
    expect(() =>
      parseBroadcastEnv({ OPERATOR_ADDRESS: SAMPLE_OWNER }),
    ).toThrow(/OPERATOR_PRIVATE_KEY is required/);
  });

  it("rejects http(s)-less RPC URLs", () => {
    expect(() =>
      parseBroadcastEnv(broadcastEnv({ BASE_RPC_URL: "ws://wrong.example" })),
    ).toThrow(/http\(s\) URL/);
  });

  it("rejects placeholder bundler URLs", () => {
    expect(() =>
      parseBroadcastEnv(
        broadcastEnv({ BUNDLER_RPC_URL: "https://bundler-placeholder" }),
      ),
    ).toThrow(/placeholder/);
  });

  it("rejects malformed private keys", () => {
    expect(() =>
      parseBroadcastEnv(broadcastEnv({ OPERATOR_PRIVATE_KEY: "0xshort" })),
    ).toThrow(/32-byte hex/);
  });

  it("rejects mismatch between OPERATOR_PRIVATE_KEY and OPERATOR_ADDRESS", () => {
    expect(() =>
      parseBroadcastEnv(broadcastEnv({ OPERATOR_ADDRESS: SAMPLE_OWNER })),
    ).toThrow(/OPERATOR_PRIVATE_KEY does not match OPERATOR_ADDRESS/);
  });

  it("accepts a key that derives to the configured address", () => {
    const env = parseBroadcastEnv(broadcastEnv());
    expect(env.operatorPrivateKey).toBe(SAMPLE_PRIVATE_KEY);
    expect(env.ownerAddress).toBe(SAMPLE_PRIVATE_KEY_ADDRESS);
  });
});

describe("CLI parsing", () => {
  it("--broadcast flips broadcast=true", () => {
    expect(parseCli([])).toEqual({ broadcast: false, help: false });
    expect(parseCli(["--broadcast"])).toEqual({
      broadcast: true,
      help: false,
    });
  });

  it("--help / -h flip help=true", () => {
    expect(parseCli(["--help"])).toEqual({ broadcast: false, help: true });
    expect(parseCli(["-h"])).toEqual({ broadcast: false, help: true });
  });
});

describe("getKernelAddresses + getRootEcdsaValidatorAddress", () => {
  it("returns the pinned Kernel v3.1 deployment values", () => {
    // These are CREATE2-deployed canonical addresses, the same on
    // every chain ZeroDev supports. Pinning them in the test
    // prevents an SDK upgrade from silently moving the deployment
    // target without reviewer attention.
    const addrs = getKernelAddresses();
    expect(addrs.kernelVersion).toBe("0.3.1");
    expect(addrs.factoryAddress).toBe(
      "0xaac5D4240AF87249B3f71BC8E4A2cae074A3E419",
    );
    expect(addrs.metaFactoryAddress).toBe(
      "0xd703aaE79538628d27099B8c4f621bE4CCd142d5",
    );
    expect(addrs.accountImplementationAddress).toBe(
      "0xBAC849bB641841b44E965fB01A4Bf5F074f84b4D",
    );
    expect(addrs.initCodeHash).toBe(
      "0x85d96aa1c9a65886d094915d76ccae85f14027a02c1647dde659f869460f03e6",
    );
  });

  it("returns the canonical ECDSA root validator address", () => {
    expect(getRootEcdsaValidatorAddress()).toBe(
      "0x845ADb2C711129d4f3966735eD98a9F09fC4cE57",
    );
  });
});

describe("deriveExpectedKernelAddress", () => {
  // The whole point of the dry-run path is that this derivation is
  // deterministic and pure. These tests pin specific (owner, index)
  // → kernel address pairs so any drift in the SDK's CREATE2
  // calculation surfaces immediately.

  it("derives the expected address for a fixed (owner, index=0)", async () => {
    const env: DryRunEnv = {
      ownerAddress: SAMPLE_OWNER,
      kernelAccountIndex: 0n,
      baseChainId: 84_532,
    };
    const addr = await deriveExpectedKernelAddress(env);
    expect(addr).toBe("0x9400286bC91d1a55369a09f61874792884FeD4B3");
  });

  it("derives a different address for a different index", async () => {
    const a = await deriveExpectedKernelAddress({
      ownerAddress: SAMPLE_OWNER,
      kernelAccountIndex: 0n,
      baseChainId: 84_532,
    });
    const b = await deriveExpectedKernelAddress({
      ownerAddress: SAMPLE_OWNER,
      kernelAccountIndex: 1n,
      baseChainId: 84_532,
    });
    expect(a).not.toBe(b);
  });

  it("derives a different address for a different owner", async () => {
    const a = await deriveExpectedKernelAddress({
      ownerAddress: SAMPLE_OWNER,
      kernelAccountIndex: 0n,
      baseChainId: 84_532,
    });
    const b = await deriveExpectedKernelAddress({
      ownerAddress: SAMPLE_PRIVATE_KEY_ADDRESS,
      kernelAccountIndex: 0n,
      baseChainId: 84_532,
    });
    expect(a).not.toBe(b);
  });

  it("is chain-id-independent — same address on Base Sepolia and Base mainnet", async () => {
    // Kernel v3.1 factory + impl are CREATE2-deployed at the same
    // address on every chain. The derivation does not consume
    // chain id; the same (owner, index) yields the same kernel
    // address everywhere.
    const sepolia = await deriveExpectedKernelAddress({
      ownerAddress: SAMPLE_OWNER,
      kernelAccountIndex: 0n,
      baseChainId: 84_532,
    });
    const mainnet = await deriveExpectedKernelAddress({
      ownerAddress: SAMPLE_OWNER,
      kernelAccountIndex: 0n,
      baseChainId: 8453,
    });
    expect(sepolia).toBe(mainnet);
  });
});

describe("buildDryRunReceipt", () => {
  it("produces a complete v1 receipt that round-trips through JSON", async () => {
    const env: DryRunEnv = {
      ownerAddress: SAMPLE_OWNER,
      kernelAccountIndex: 7n,
      baseChainId: 84_532,
    };
    const expected = await deriveExpectedKernelAddress(env);
    const receipt = buildDryRunReceipt(env, expected);

    expect(receipt.schema_version).toBe(RECEIPT_SCHEMA_VERSION);
    expect(receipt.mode).toBe("dry-run");
    expect(receipt.chain_id).toBe(84_532);
    expect(receipt.kernel_version).toBe("0.3.1");
    expect(receipt.expected_smart_account_address).toBe(expected);
    expect(receipt.kernel_account_index).toBe("7");
    expect(receipt.next_steps.length).toBeGreaterThan(0);

    // Receipt must be JSON-serialisable end-to-end. bigint inside
    // would break this — `kernel_account_index` is intentionally a
    // string for that reason.
    const json = JSON.stringify(receipt);
    const parsed = JSON.parse(json);
    expect(parsed.expected_smart_account_address).toBe(expected);
  });

  it("does not leak the operator private key or RPC URLs", async () => {
    // Even when those env vars are populated (broadcast mode would
    // read them), the dry-run code path NEVER touches them — so
    // they must not appear in the dry-run receipt regardless. We
    // pin that here by populating fake values into the env-shaped
    // record buildDryRunReceipt is given and asserting they don't
    // surface in the JSON.
    const fakeKey =
      "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
    const fakeRpc =
      "https://sepolia.example.invalid?apiKey=secret-token-must-not-leak";
    process.env.OPERATOR_PRIVATE_KEY = fakeKey;
    process.env.BASE_RPC_URL = fakeRpc;
    process.env.BUNDLER_RPC_URL = fakeRpc;
    try {
      const env: DryRunEnv = {
        ownerAddress: SAMPLE_OWNER,
        kernelAccountIndex: 0n,
        baseChainId: 84_532,
      };
      const expected = await deriveExpectedKernelAddress(env);
      const receipt = buildDryRunReceipt(env, expected);
      const json = JSON.stringify(receipt);

      expect(json).not.toContain(fakeKey);
      expect(json).not.toContain("apiKey=");
      expect(json).not.toContain("secret-token-must-not-leak");
      // The legitimate 32-byte `init_code_hash` is a public CREATE2
      // constant; it deliberately stays in the receipt.
      expect(json).toContain(
        "85d96aa1c9a65886d094915d76ccae85f14027a02c1647dde659f869460f03e6",
      );
    } finally {
      delete process.env.OPERATOR_PRIVATE_KEY;
      delete process.env.BASE_RPC_URL;
      delete process.env.BUNDLER_RPC_URL;
    }
  });
});

describe("ALLOWED_CHAIN_IDS", () => {
  it("is the Base mainnet + Sepolia pair only", () => {
    expect([...ALLOWED_CHAIN_IDS].sort()).toEqual([8453, 84_532]);
  });
});
