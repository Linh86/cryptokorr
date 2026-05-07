/**
 * Vitest unit tests for the ZeroDev SDK glue. All SDK packages
 * are injected via the `deps` parameter so we never load the real
 * SDK in tests — fast + deterministic + no network.
 */

import {describe, it, expect, vi} from "vitest"

import {submitInstall, classifySendError, classifyReceiptError} from "../install_zerodev_client.js"

function buildFakeDeps(overrides = {}) {
  const sdkConstants = {
    getEntryPoint: vi.fn((v) => `entry-point-${v}`),
    KERNEL_V3_1: "kernel-v3.1",
  }
  const ecdsaValidator = {
    signerToEcdsaValidator: vi.fn(async () => ({type: "sudo-validator"})),
  }
  const permissions = {
    toPermissionValidator: vi.fn(async () => ({
      type: "permission-validator",
      getIdentifier: () => "0xa1b2c3d4",
    })),
  }
  const permissionsSigners = {
    toECDSASigner: vi.fn(async () => ({type: "ecdsa-signer"})),
  }
  const permissionsPolicies = {
    toSudoPolicy: vi.fn(() => ({type: "sudo-policy"})),
  }
  const sdk = {
    createKernelAccount: vi.fn(async () => ({
      address: "0xkernelAccountAddress",
      encodeCalls: vi.fn(async () => "0xcalldata"),
    })),
    createKernelAccountClient: vi.fn(() => ({
      sendUserOperation: vi.fn(async () => "0xuserOpHash"),
      waitForUserOperationReceipt: vi.fn(async () => ({
        success: true,
        receipt: {transactionHash: "0xtxHash", blockNumber: 12345n},
      })),
    })),
  }
  const viem = {
    createWalletClient: vi.fn(({account}) => ({account})),
    createPublicClient: vi.fn(() => ({type: "public-client"})),
    custom: vi.fn((p) => ({transport: "custom", provider: p})),
    http: vi.fn((url) => ({transport: "http", url})),
  }
  const viemAccounts = {
    toAccount: vi.fn((args) => ({type: "watch-only", ...args})),
  }
  const viemChains = {baseSepolia: {id: 84_532, name: "Base Sepolia"}}

  return {
    sdk,
    sdkConstants,
    ecdsaValidator,
    permissions,
    permissionsSigners,
    permissionsPolicies,
    viem,
    viemAccounts,
    viemChains,
    ...overrides,
  }
}

const FIXTURE_ENVELOPE = {
  binding_id: "b1",
  workspace_id: "w1",
  smart_account_id: "sa_wb_b1",
  chain_id: 84_532,
  entry_point_address: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  kernel_version: "v3.1",
  permissions_package_version: "5.6.3",
  session_signer_address: "0x" + "11".repeat(20),
  scope: {version: "1"},
  scope_hash: "0xscope",
  bundler_rpc_url: "https://bundler.example.invalid/api",
  human_readable_summary: "ok",
}

const FAKE_PROVIDER = {
  request: vi.fn(),
}

describe("submitInstall", () => {
  it("orchestrates the SDK call sequence and returns submitted result", async () => {
    const deps = buildFakeDeps()

    const result = await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps,
    })

    expect(result.status).toBe("submitted")
    expect(result.install_userop_hash).toBe("0xuserOpHash")
    expect(result.permission_id).toBe("0xa1b2c3d4")
    // validation_id = 21 bytes total = 0x02 + 4-byte permissionId
    // padded right to 20 bytes (32 zero hex chars). String length:
    // 2 (0x) + 2 (02) + 8 (perm) + 32 (pad) = 44.
    expect(result.validation_id).toBe(
      "0x02a1b2c3d400000000000000000000000000000000",
    )
    expect(result.validation_id.length).toBe(44)
    expect(result.smart_account_address).toBe("0xkernelAccountAddress")
    expect(typeof result.waitForReceipt).toBe("function")

    // Call ordering: viem clients → sudo validator → permission validator
    // → kernel account → kernel client → sendUserOperation.
    const callOrder = [
      deps.viem.createWalletClient.mock.invocationCallOrder[0],
      deps.viem.createPublicClient.mock.invocationCallOrder[0],
      deps.ecdsaValidator.signerToEcdsaValidator.mock.invocationCallOrder[0],
      deps.permissionsSigners.toECDSASigner.mock.invocationCallOrder[0],
      deps.permissions.toPermissionValidator.mock.invocationCallOrder[0],
      deps.sdk.createKernelAccount.mock.invocationCallOrder[0],
      deps.sdk.createKernelAccountClient.mock.invocationCallOrder[0],
    ]
    const sorted = [...callOrder].sort((a, b) => a - b)
    expect(callOrder).toEqual(sorted)
  })

  it("uses the user EOA as sudo signer (not the operator session signer)", async () => {
    const deps = buildFakeDeps()
    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps,
    })

    const sudoArgs = deps.ecdsaValidator.signerToEcdsaValidator.mock.calls[0]
    // Wallet client fake returns `{account}`; the hook passes
    // `walletClient.account` as the signer, so the signer IS the
    // user's EOA address string here.
    expect(sudoArgs[1].signer).toBe("0xuserEoa")
  })

  it("uses envelope.session_signer_address as the regular permission signer (watch-only)", async () => {
    const deps = buildFakeDeps()
    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps,
    })

    const watchArgs = deps.viemAccounts.toAccount.mock.calls[0][0]
    expect(watchArgs.address).toBe(FIXTURE_ENVELOPE.session_signer_address)
    // Watch-only signer rejects when invoked.
    await expect(watchArgs.signMessage()).rejects.toThrow(/not available in browser/)
  })

  it("reads the bundler URL only from the envelope", async () => {
    const deps = buildFakeDeps()
    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps,
    })

    const httpCalls = deps.viem.http.mock.calls.map((c) => c[0])
    expect(httpCalls.every((url) => url === FIXTURE_ENVELOPE.bundler_rpc_url)).toBe(true)
  })

  it("uses Base Sepolia chain object", async () => {
    const deps = buildFakeDeps()
    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps,
    })

    expect(deps.viem.createPublicClient.mock.calls[0][0].chain).toBe(deps.viemChains.baseSepolia)
  })

  it("encodes an inert install call (zero address, zero value, empty data)", async () => {
    const deps = buildFakeDeps()
    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps,
    })

    // mock.results[0].value is the awaited Promise resolution for
    // an async fake; `await` materialises it.
    const kernel = await deps.sdk.createKernelAccount.mock.results[0].value
    const calls = kernel.encodeCalls.mock.calls[0][0]
    expect(calls).toEqual([
      {
        to: "0x0000000000000000000000000000000000000000",
        value: 0n,
        data: "0x",
      },
    ])
  })

  describe("submitInstall failure paths", () => {
    it("returns user_rejected when sendUserOperation throws 4001", async () => {
      const deps = buildFakeDeps()
      deps.sdk.createKernelAccountClient = vi.fn(() => ({
        sendUserOperation: vi.fn(async () => {
          const e = new Error("User rejected the request")
          e.code = 4001
          throw e
        }),
      }))
      const result = await submitInstall({
        provider: FAKE_PROVIDER,
        account: "0xuser",
        envelope: FIXTURE_ENVELOPE,
        deps,
      })
      expect(result).toEqual({status: "failed", reason: "user_rejected"})
    })

    it("returns bundler_rejected on a -32000 send error", async () => {
      const deps = buildFakeDeps()
      deps.sdk.createKernelAccountClient = vi.fn(() => ({
        sendUserOperation: vi.fn(async () => {
          const e = new Error("user op validation failed")
          e.code = -32000
          throw e
        }),
      }))
      const result = await submitInstall({
        provider: FAKE_PROVIDER,
        account: "0xuser",
        envelope: FIXTURE_ENVELOPE,
        deps,
      })
      expect(result).toEqual({status: "failed", reason: "bundler_rejected"})
    })

    it("returns bundler_unavailable on a network-shaped error", async () => {
      const deps = buildFakeDeps()
      deps.sdk.createKernelAccountClient = vi.fn(() => ({
        sendUserOperation: vi.fn(async () => {
          throw new Error("fetch failed: 503 Service Unavailable")
        }),
      }))
      const result = await submitInstall({
        provider: FAKE_PROVIDER,
        account: "0xuser",
        envelope: FIXTURE_ENVELOPE,
        deps,
      })
      expect(result).toEqual({status: "failed", reason: "bundler_unavailable"})
    })

    it("returns insufficient_funds when error mentions insufficient funds", async () => {
      const deps = buildFakeDeps()
      deps.sdk.createKernelAccountClient = vi.fn(() => ({
        sendUserOperation: vi.fn(async () => {
          throw new Error("insufficient funds for gas")
        }),
      }))
      const result = await submitInstall({
        provider: FAKE_PROVIDER,
        account: "0xuser",
        envelope: FIXTURE_ENVELOPE,
        deps,
      })
      expect(result).toEqual({status: "failed", reason: "insufficient_funds"})
    })
  })

  describe("waitForReceipt", () => {
    it("returns success on a confirmed receipt", async () => {
      const deps = buildFakeDeps()
      const result = await submitInstall({
        provider: FAKE_PROVIDER,
        account: "0xuser",
        envelope: FIXTURE_ENVELOPE,
        deps,
      })
      const receipt = await result.waitForReceipt()
      expect(receipt).toEqual({success: true, tx_hash: "0xtxHash", block_number: 12345})
    })

    it("returns userop_reverted when the receipt fails", async () => {
      const deps = buildFakeDeps()
      deps.sdk.createKernelAccountClient = vi.fn(() => ({
        sendUserOperation: vi.fn(async () => "0xuserOpHash"),
        waitForUserOperationReceipt: vi.fn(async () => ({success: false, reason: "out of gas"})),
      }))
      const result = await submitInstall({
        provider: FAKE_PROVIDER,
        account: "0xuser",
        envelope: FIXTURE_ENVELOPE,
        deps,
      })
      const receipt = await result.waitForReceipt()
      expect(receipt).toEqual({success: false, reason: "userop_reverted"})
    })

    it("returns attestation_timeout on a timeout error", async () => {
      const deps = buildFakeDeps()
      deps.sdk.createKernelAccountClient = vi.fn(() => ({
        sendUserOperation: vi.fn(async () => "0xuserOpHash"),
        waitForUserOperationReceipt: vi.fn(async () => {
          throw new Error("Operation timed out after 45000ms")
        }),
      }))
      const result = await submitInstall({
        provider: FAKE_PROVIDER,
        account: "0xuser",
        envelope: FIXTURE_ENVELOPE,
        deps,
      })
      const receipt = await result.waitForReceipt()
      expect(receipt).toEqual({success: false, reason: "attestation_timeout"})
    })
  })
})

describe("classifySendError", () => {
  it.each([
    [{code: 4001}, "user_rejected"],
    [{message: "User denied transaction signature"}, "user_rejected"],
    [{message: "insufficient funds for gas"}, "insufficient_funds"],
    [{message: "chain id mismatch with bundler"}, "chain_id_mismatch"],
    [{message: "fetch failed"}, "bundler_unavailable"],
    [{message: "503 service unavailable"}, "bundler_unavailable"],
    [{code: -32000, message: "validation failed"}, "bundler_rejected"],
    [{message: "execution reverted"}, "bundler_rejected"],
    [{message: "something weird"}, "unknown"],
  ])("classifies %j as %s", (err, expected) => {
    expect(classifySendError(err)).toBe(expected)
  })
})

describe("classifyReceiptError", () => {
  it.each([
    [{message: "Operation timed out"}, "attestation_timeout"],
    [{message: "fetch failed"}, "bundler_unavailable"],
    [{message: "504 gateway timeout"}, "bundler_unavailable"],
    [{message: "weird"}, "unknown"],
  ])("classifies %j as %s", (err, expected) => {
    expect(classifyReceiptError(err)).toBe(expected)
  })
})
