/**
 * verify-installed-validator.ts tests.
 *
 * Pure / no RPC. The script's `observe()` step talks to chain via
 * RPC; tests do not exercise that path because it requires an
 * upstream Base RPC. We test parsing, pinning, finding-shaping, and
 * the pure `buildReceipt` against fabricated `ChainObservations`.
 */

import { describe, it, expect } from "vitest";
import {
  ALLOWED_CHAIN_IDS,
  RECEIPT_SCHEMA_VERSION,
  VerifyEnvError,
  buildReceipt,
  getPinnedExpectations,
  parseEnv,
  splitRootValidator,
  type VerifyEnv,
} from "../scripts/verify-installed-validator.js";

const SAMPLE_SMART_ACCOUNT =
  "0x9400286bC91d1a55369a09f61874792884FeD4B3" as const;

function env(overrides: Partial<NodeJS.ProcessEnv> = {}): NodeJS.ProcessEnv {
  return {
    SMART_ACCOUNT_ADDRESS: SAMPLE_SMART_ACCOUNT,
    BASE_RPC_URL: "https://sepolia.example",
    ...overrides,
  };
}

describe("parseEnv", () => {
  it("requires SMART_ACCOUNT_ADDRESS", () => {
    expect(() => parseEnv({ BASE_RPC_URL: "https://sepolia.example" })).toThrow(
      VerifyEnvError,
    );
  });

  it("requires BASE_RPC_URL", () => {
    expect(() =>
      parseEnv({ SMART_ACCOUNT_ADDRESS: SAMPLE_SMART_ACCOUNT }),
    ).toThrow(/BASE_RPC_URL is required/);
  });

  it("rejects placeholder smart account", () => {
    expect(() =>
      parseEnv(env({ SMART_ACCOUNT_ADDRESS: "0x_smart_account_placeholder" })),
    ).toThrow(/placeholder/);
  });

  it("rejects malformed smart account", () => {
    expect(() => parseEnv(env({ SMART_ACCOUNT_ADDRESS: "0xshort" }))).toThrow(
      /20-byte EVM address/,
    );
  });

  it("normalises the address to checksum form", () => {
    const cfg = parseEnv(
      env({ SMART_ACCOUNT_ADDRESS: SAMPLE_SMART_ACCOUNT.toLowerCase() }),
    );
    expect(cfg.smartAccountAddress).toBe(SAMPLE_SMART_ACCOUNT);
  });

  it("defaults BASE_CHAIN_ID to 84532", () => {
    expect(parseEnv(env()).baseChainId).toBe(84_532);
  });

  it("rejects unknown chain ids", () => {
    expect(() => parseEnv(env({ BASE_CHAIN_ID: "1" }))).toThrow(
      /84532 \(Sepolia\) or 8453/,
    );
  });
});

describe("getPinnedExpectations", () => {
  it("matches the same Kernel v3.1 deployment provision-kernel.ts targets", () => {
    // If these drift apart provisioning + verification will pass on
    // different deployments — bug. Pinning here, mirrored against
    // provision-kernel.test.ts.
    const pinned = getPinnedExpectations();
    expect(pinned.kernelVersion).toBe("0.3.1");
    expect(pinned.implementationAddress).toBe(
      "0xBAC849bB641841b44E965fB01A4Bf5F074f84b4D",
    );
    expect(pinned.rootValidatorAddress).toBe(
      "0x845ADb2C711129d4f3966735eD98a9F09fC4cE57",
    );
  });
});

describe("splitRootValidator", () => {
  // The kernel ABI returns `rootValidator()` as `bytes21` =
  // 1-byte type tag ‖ 20-byte module address.

  it("splits a VALIDATOR-type rootValidator (0x01 prefix)", () => {
    const raw = "0x01845ADb2C711129d4f3966735eD98a9F09fC4cE57" as const;
    const { typeTag, address } = splitRootValidator(raw);
    expect(typeTag).toBe("0x01");
    expect(address).toBe("0x845ADb2C711129d4f3966735eD98a9F09fC4cE57");
  });

  it("splits a PERMISSION-type rootValidator (0x02 prefix)", () => {
    // Type-tag 0x02 marks a kernel validation routed through a
    // permission rather than a direct validator module. We do not
    // expect to ever see this on a freshly-provisioned kernel, but
    // the helper is symmetric. 21 bytes = 0x + 1 type byte + 20
    // address bytes = 44 hex chars including the 0x prefix.
    const raw = "0x020000000000000000000000000000000000000000" as const;
    const { typeTag, address } = splitRootValidator(raw);
    expect(typeTag).toBe("0x02");
    expect(address).toBe("0x0000000000000000000000000000000000000000");
  });

  it("rejects wrong-length input", () => {
    expect(() => splitRootValidator("0x01dead" as `0x${string}`)).toThrow(
      /21 bytes/,
    );
  });
});

describe("buildReceipt", () => {
  const cfg: VerifyEnv = {
    smartAccountAddress: SAMPLE_SMART_ACCOUNT,
    baseRpcUrl: "https://sepolia.example",
    baseChainId: 84_532,
  };

  it("flags an undeployed account and recommends provision-kernel.ts", () => {
    const receipt = buildReceipt(cfg, {
      isDeployed: false,
      observedImplementationAddress: null,
      observedKernelVersion: null,
      observedKernelNonce: null,
      observedRootValidatorAddress: null,
    });
    expect(receipt.is_deployed).toBe(false);
    expect(receipt.overall_ok).toBe(false);
    expect(receipt.findings.find((f) => f.key === "is_deployed")?.ok).toBe(
      false,
    );
    expect(receipt.next_steps.join(" ")).toMatch(/provision-kernel\.ts/);
  });

  it("flags overall_ok=true when every observation matches the pin", () => {
    const pinned = getPinnedExpectations();
    const receipt = buildReceipt(cfg, {
      isDeployed: true,
      observedImplementationAddress: pinned.implementationAddress,
      observedKernelVersion: pinned.kernelVersion,
      observedKernelNonce: 0,
      observedRootValidatorAddress: pinned.rootValidatorAddress,
    });
    expect(receipt.overall_ok).toBe(true);
    expect(receipt.is_deployed).toBe(true);
    for (const f of receipt.findings) expect(f.ok).toBe(true);
    expect(receipt.next_steps.join(" ")).toMatch(/SMART_ACCOUNT_ADDRESS/);
  });

  it("flags drift when the implementation address does not match", () => {
    const pinned = getPinnedExpectations();
    const receipt = buildReceipt(cfg, {
      isDeployed: true,
      observedImplementationAddress:
        "0x0000000000000000000000000000000000000bad",
      observedKernelVersion: pinned.kernelVersion,
      observedKernelNonce: 0,
      observedRootValidatorAddress: pinned.rootValidatorAddress,
    });
    expect(receipt.overall_ok).toBe(false);
    const impl = receipt.findings.find(
      (f) => f.key === "implementation_address",
    );
    expect(impl?.ok).toBe(false);
    expect(impl?.detail).toMatch(/expected /);
    expect(receipt.next_steps.join(" ")).toMatch(/Do NOT bind/);
  });

  it("flags drift when the root validator does not match", () => {
    const pinned = getPinnedExpectations();
    const receipt = buildReceipt(cfg, {
      isDeployed: true,
      observedImplementationAddress: pinned.implementationAddress,
      observedKernelVersion: pinned.kernelVersion,
      observedKernelNonce: 0,
      observedRootValidatorAddress:
        "0x000000000000000000000000000000000000beef",
    });
    expect(receipt.overall_ok).toBe(false);
    const rv = receipt.findings.find((f) => f.key === "root_validator_address");
    expect(rv?.ok).toBe(false);
  });

  it("flags drift when kernel_version differs", () => {
    const pinned = getPinnedExpectations();
    const receipt = buildReceipt(cfg, {
      isDeployed: true,
      observedImplementationAddress: pinned.implementationAddress,
      observedKernelVersion: "0.3.0",
      observedKernelNonce: 0,
      observedRootValidatorAddress: pinned.rootValidatorAddress,
    });
    expect(receipt.overall_ok).toBe(false);
    const v = receipt.findings.find((f) => f.key === "kernel_version");
    expect(v?.ok).toBe(false);
  });

  it("emits a v1 schema receipt that round-trips through JSON", () => {
    const pinned = getPinnedExpectations();
    const receipt = buildReceipt(cfg, {
      isDeployed: true,
      observedImplementationAddress: pinned.implementationAddress,
      observedKernelVersion: pinned.kernelVersion,
      observedKernelNonce: 17,
      observedRootValidatorAddress: pinned.rootValidatorAddress,
    });
    expect(receipt.schema_version).toBe(RECEIPT_SCHEMA_VERSION);
    const parsed = JSON.parse(JSON.stringify(receipt));
    expect(parsed.observed_kernel_nonce).toBe(17);
  });
});

describe("ALLOWED_CHAIN_IDS", () => {
  it("is the Base mainnet + Sepolia pair only", () => {
    expect([...ALLOWED_CHAIN_IDS].sort()).toEqual([8453, 84_532]);
  });
});
