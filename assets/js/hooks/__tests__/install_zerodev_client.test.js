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
    // viem 2.x's `createWalletClient({account: "0x..."})` wraps the
    // raw string address into a JsonRpcAccount stored on `.account`.
    // The real shape is `{account: {address, type: "json-rpc"}, ...}`.
    // We mirror that here so the install hook's regression — passing
    // `walletClient.account` (an Account object without its own
    // `.account` field) into ZeroDev's `signerToEcdsaValidator` —
    // would have failed `toSigner`'s `walletClient.account.address`
    // lookup.
    createWalletClient: vi.fn(({account, chain, transport}) => ({
      account: {address: account, type: "json-rpc"},
      chain,
      transport,
      request: vi.fn(),
    })),
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
  // Distinct from `bundler_rpc_url` — the install hook uses this
  // for viem's `publicClient` (read-only `eth_call` etc.). See
  // `submitInstall` docstring for the full Pimlico-vs-ZeroDev
  // bundler-method split.
  chain_rpc_url: "https://chain-rpc.example.invalid/rpc",
  // Browser kernel CREATE2 salt. Phoenix defaults this to 1 in dev
  // so it doesn't collide with the chain_adapter's operator account
  // (index 0) when the demo wallet imports `OPERATOR_PRIVATE_KEY`.
  kernel_account_index: 1,
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

    // Regression: ZeroDev's `toSigner({signer})` expects the WHOLE
    // viem walletClient, not its `.account` JsonRpcAccount. Passing
    // `walletClient.account` crashed with
    // `Cannot read properties of undefined (reading 'address')`
    // because the JsonRpcAccount has no nested `.account` field.
    // The fix passes the walletClient itself; toSigner then reads
    // `signer.account.address` cleanly.
    expect(sudoArgs[1].signer).toBeTruthy()
    expect(sudoArgs[1].signer.account).toBeTruthy()
    expect(sudoArgs[1].signer.account.address).toBe("0xuserEoa")
  })

  it("uses envelope.session_signer_address as the regular permission signer (proxy-signed)", async () => {
    // The browser session account is "watch-only" w.r.t. private
    // keys — it never holds `DELEGATION_SIGNER_KEY`. Instead, its
    // `signMessage` proxies to Phoenix's
    // `/wallet_bindings/:id/sign_install_userop_hash` which
    // forwards to chain_adapter. This test pins:
    //   1. The session account carries the envelope's address.
    //   2. Calling its `signMessage({raw: hash})` triggers the
    //      proxy fetcher.
    //   3. The returned signature is what the SDK gets.
    const deps = buildFakeDeps()
    const sessionSignFetcher = vi.fn(async () => ({
      signature: "0xabc1234fakesig",
      session_signer_address: FIXTURE_ENVELOPE.session_signer_address,
    }))

    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps: {...deps, sessionSignFetcher},
    })

    const watchArgs = deps.viemAccounts.toAccount.mock.calls[0][0]
    expect(watchArgs.address).toBe(FIXTURE_ENVELOPE.session_signer_address)

    // Drive a signing call directly to confirm the proxy is wired
    // through. Real SDK call site passes
    // `{message: {raw: userOpHash}}`.
    const fakeHash = "0x" + "ab".repeat(32)
    const sig = await watchArgs.signMessage({message: {raw: fakeHash}})
    expect(sig).toBe("0xabc1234fakesig")

    expect(sessionSignFetcher).toHaveBeenCalledTimes(1)
    expect(sessionSignFetcher).toHaveBeenCalledWith(
      FIXTURE_ENVELOPE.binding_id,
      fakeHash,
      {sessionSignerAddress: FIXTURE_ENVELOPE.session_signer_address},
    )
  })

  it("session_signer refuses to sign anything other than a raw 32-byte hash", async () => {
    // The proxy endpoint is strictly scoped to install UserOp
    // hashes. The browser hook must NOT forward arbitrary message
    // strings (or anything that's not the SDK's exact
    // `{raw: hex}` shape) — that would let a future code path
    // accidentally use the operator's key for non-install signing.
    const deps = buildFakeDeps()
    const sessionSignFetcher = vi.fn()

    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps: {...deps, sessionSignFetcher},
    })

    const watchArgs = deps.viemAccounts.toAccount.mock.calls[0][0]

    // `signMessage` with a plain string message (not the raw shape)
    // must reject without touching the proxy.
    await expect(watchArgs.signMessage({message: "arbitrary string"})).rejects.toThrow(
      /session signer only signs raw 32-byte hashes/,
    )
    await expect(watchArgs.signMessage({})).rejects.toThrow()
    expect(sessionSignFetcher).not.toHaveBeenCalled()
  })

  it("propagates session_signer_unavailable when proxy errors with that code", async () => {
    const deps = buildFakeDeps()
    const sessionSignFetcher = vi.fn(async () => {
      const err = new Error("session_sign_network_error")
      err.code = "session_signer_unavailable"
      throw err
    })

    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps: {...deps, sessionSignFetcher},
    })

    const watchArgs = deps.viemAccounts.toAccount.mock.calls[0][0]

    const fakeHash = "0x" + "cd".repeat(32)
    await expect(watchArgs.signMessage({message: {raw: fakeHash}})).rejects.toMatchObject({
      code: "session_signer_unavailable",
    })
  })

  it("propagates session_signer_refused when proxy returns a 4xx", async () => {
    const deps = buildFakeDeps()
    const sessionSignFetcher = vi.fn(async () => {
      const err = new Error("session_sign_request_failed")
      err.code = "session_signer_refused"
      err.status = 422
      throw err
    })

    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps: {...deps, sessionSignFetcher},
    })

    const watchArgs = deps.viemAccounts.toAccount.mock.calls[0][0]

    const fakeHash = "0x" + "ef".repeat(32)
    await expect(watchArgs.signMessage({message: {raw: fakeHash}})).rejects.toMatchObject({
      code: "session_signer_refused",
    })
  })

  it("reads RPC URLs only from the envelope (no hardcoded URLs)", async () => {
    const deps = buildFakeDeps()
    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps,
    })

    const httpCalls = deps.viem.http.mock.calls.map((c) => c[0])
    // Every viem.http URL must come from one of the envelope's two
    // canonical RPC fields. Anything else is a hardcoded URL leak.
    const allowed = new Set([
      FIXTURE_ENVELOPE.bundler_rpc_url,
      FIXTURE_ENVELOPE.chain_rpc_url,
    ])
    expect(httpCalls.every((url) => allowed.has(url))).toBe(true)
  })

  it("publicClient uses chain_rpc_url, bundlerTransport uses bundler_rpc_url (P0 Pimlico fix)", async () => {
    // Regression: ZeroDev's `createKernelAccount` calls
    // `getSenderAddress`, which is an EntryPoint v0.7 simulation
    // routed through `publicClient` (= generic `eth_call`). Most
    // hosted bundlers (Pimlico, Stackup, Candide) reject
    // `eth_call` because their /rpc endpoint is bundler-only —
    // the SDK then crashes decoding the unexpected reply. The fix
    // pins the wiring: publicClient MUST use `chain_rpc_url`,
    // bundlerTransport MUST use `bundler_rpc_url`. Conflating them
    // is what broke the install with Pimlico configured.
    const deps = buildFakeDeps()
    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps,
    })

    // `viem.http` is called once for publicClient and again for
    // bundlerTransport (inside createKernelAccountClient). Track
    // by invocation order: the first call wires publicClient, the
    // second wires bundlerTransport.
    const httpCalls = deps.viem.http.mock.calls.map((c) => c[0])
    const createPublicClientArgs = deps.viem.createPublicClient.mock.calls[0][0]
    const createKernelClientArgs = deps.sdk.createKernelAccountClient.mock.calls[0][0]

    // publicClient transport was constructed with chain_rpc_url.
    expect(createPublicClientArgs.transport.url).toBe(FIXTURE_ENVELOPE.chain_rpc_url)
    // bundlerTransport was constructed with bundler_rpc_url.
    expect(createKernelClientArgs.bundlerTransport.url).toBe(FIXTURE_ENVELOPE.bundler_rpc_url)
    // Defense in depth: at least one viem.http call hit each URL.
    expect(httpCalls).toContain(FIXTURE_ENVELOPE.chain_rpc_url)
    expect(httpCalls).toContain(FIXTURE_ENVELOPE.bundler_rpc_url)
  })

  it("overrides estimateFeesPerGas so ZeroDev SDK doesn't call zd_getUserOperationGasPrice on non-ZeroDev bundlers", async () => {
    // Regression: ZeroDev SDK's default `userOperation.estimateFeesPerGas`
    // calls `zd_getUserOperationGasPrice` — a ZeroDev-bundler-only
    // RPC method. Pimlico/Stackup/Candide return
    // `MethodNotFoundRpcError: Validation error -32601` and the
    // install fails with `bundler_rejected`. The fix supplies our
    // own callback that probes Pimlico → ZeroDev → standard
    // EIP-1559 in order. This test pins that
    // `createKernelAccountClient` receives a custom callback so
    // the SDK never falls through to the hardcoded `zd_*` method.
    const deps = buildFakeDeps()
    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps,
    })

    const kernelClientArgs = deps.sdk.createKernelAccountClient.mock.calls[0][0]

    expect(kernelClientArgs.userOperation).toBeTruthy()
    expect(typeof kernelClientArgs.userOperation.estimateFeesPerGas).toBe("function")
  })

  it("estimateFeesPerGas prefers pimlico_getUserOperationGasPrice over zd_getUserOperationGasPrice", async () => {
    // The probe order matters: Pimlico-prefixed FIRST so an
    // operator on the standard Pimlico stack (the documented MVP
    // bundler) gets a native gas price without paying for a
    // failed ZeroDev probe round-trip. Validates the actual
    // request order against a fake bundler client.
    const deps = buildFakeDeps()
    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps,
    })
    const {estimateFeesPerGas} = deps.sdk.createKernelAccountClient.mock.calls[0][0].userOperation

    const requests = []
    const fakeBundler = {
      request: async ({method}) => {
        requests.push(method)
        if (method === "pimlico_getUserOperationGasPrice") {
          return {
            standard: {
              maxFeePerGas: "0x3b9aca00",
              maxPriorityFeePerGas: "0x3b9aca00",
            },
          }
        }
        throw new Error("unexpected method: " + method)
      },
    }

    const fees = await estimateFeesPerGas({bundlerClient: fakeBundler})

    expect(requests[0]).toBe("pimlico_getUserOperationGasPrice")
    expect(typeof fees.maxFeePerGas).toBe("bigint")
    expect(typeof fees.maxPriorityFeePerGas).toBe("bigint")
    expect(fees.maxFeePerGas).toBe(0x3b9aca00n)
  })

  it("estimateFeesPerGas falls back to zd_getUserOperationGasPrice when Pimlico method is unavailable", async () => {
    // Backward compatibility: an operator who switches back to
    // ZeroDev's hosted bundler still gets a working gas price
    // because the SDK's native method is the second probe.
    const deps = buildFakeDeps()
    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps,
    })
    const {estimateFeesPerGas} = deps.sdk.createKernelAccountClient.mock.calls[0][0].userOperation

    const fakeBundler = {
      request: async ({method}) => {
        if (method === "pimlico_getUserOperationGasPrice") {
          const err = new Error("Validation error")
          err.code = -32601
          throw err
        }
        if (method === "zd_getUserOperationGasPrice") {
          return {
            standard: {
              maxFeePerGas: "0x77359400",
              maxPriorityFeePerGas: "0x77359400",
            },
          }
        }
        throw new Error("unexpected method: " + method)
      },
    }

    const fees = await estimateFeesPerGas({bundlerClient: fakeBundler})

    expect(fees.maxFeePerGas).toBe(0x77359400n)
    expect(fees.maxPriorityFeePerGas).toBe(0x77359400n)
  })

  it("estimateFeesPerGas falls back to standard EIP-1559 when no bundler-native price method exists", async () => {
    // Self-hosted Alto / Skandha / any bundler that doesn't
    // ship its own gas oracle. The fallback hits the chain RPC
    // (publicClient) for `eth_maxPriorityFeePerGas` +
    // `eth_gasPrice` and computes
    // `maxFeePerGas = base + tip + base / 5` (20% buffer).
    const deps = buildFakeDeps()

    // Capture the publicClient that submitInstall builds so we
    // can stub its request method to drive the EIP-1559 path.
    let capturedPublicClient
    deps.viem.createPublicClient = vi.fn((opts) => {
      capturedPublicClient = {
        chain: opts.chain,
        transport: opts.transport,
        request: vi.fn(async ({method}) => {
          if (method === "eth_maxPriorityFeePerGas") return "0x3b9aca00"
          if (method === "eth_gasPrice") return "0x77359400"
          throw new Error("unexpected publicClient method: " + method)
        }),
      }
      return capturedPublicClient
    })

    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps,
    })

    const {estimateFeesPerGas} = deps.sdk.createKernelAccountClient.mock.calls[0][0].userOperation

    const fakeBundler = {
      request: async () => {
        const err = new Error("Validation error")
        err.code = -32601
        throw err
      },
    }

    const fees = await estimateFeesPerGas({bundlerClient: fakeBundler})

    expect(fees.maxPriorityFeePerGas).toBe(0x3b9aca00n)
    // base + tip + base/5
    //   = 0x77359400 + 0x3b9aca00 + 0x77359400/5
    //   = 2000000000 + 1000000000 + 400000000 = 3400000000 = 0xCA9A1400
    expect(fees.maxFeePerGas).toBe(2_000_000_000n + 1_000_000_000n + 2_000_000_000n / 5n)
  })

  it("falls back to bundler_rpc_url for publicClient when chain_rpc_url is missing", async () => {
    // Backward compat: envelopes issued before Phoenix gained the
    // `chain_rpc_url` field (or when the config var isn't set)
    // collapse to the legacy single-URL behavior. The SDK still
    // crashes on bundler-only endpoints, but at least the wiring
    // is deterministic and matches pre-fix behavior.
    const deps = buildFakeDeps()
    const envelope = {...FIXTURE_ENVELOPE, chain_rpc_url: null}

    await submitInstall({provider: FAKE_PROVIDER, account: "0xuserEoa", envelope, deps})

    const createPublicClientArgs = deps.viem.createPublicClient.mock.calls[0][0]
    expect(createPublicClientArgs.transport.url).toBe(envelope.bundler_rpc_url)
  })

  it("passes BigInt(envelope.kernel_account_index) to createKernelAccount (P0 kernel-collision fix)", async () => {
    // Regression: ZeroDev's `createKernelAccount(... {index})`
    // derives the smart-account address CREATE2-style from
    // `(sudo_validator_eoa, index)`. The chain_adapter runs runtime
    // UserOps on index 0 with the operator EOA. If a browser
    // install also lands on index 0 with the SAME EOA — which
    // happens in dev when the demo wallet imports
    // `OPERATOR_PRIVATE_KEY` — the derived address collides with
    // the already-deployed operator smart account and the install
    // UserOp reverts with `AA23 reverted 0x756688fe`. The fix is
    // to drive the index from the install envelope so Phoenix
    // controls the split server-side. Pin that:
    //   1. `createKernelAccount` receives an `index` arg.
    //   2. The arg is a bigint (SDK requires it; passing a Number
    //      makes the SDK silently fall back to 0n).
    //   3. The value matches the envelope's `kernel_account_index`.
    const deps = buildFakeDeps()
    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps,
    })

    const createKernelArgs = deps.sdk.createKernelAccount.mock.calls[0][1]
    expect(typeof createKernelArgs.index).toBe("bigint")
    expect(createKernelArgs.index).toBe(1n)
  })

  it("treats envelope kernel_account_index as a bigint even when it arrives as a Number", async () => {
    // JSON-decoded envelopes from Phoenix carry integers as JS
    // Numbers (no BigInt over the wire). The hook must `BigInt(...)`
    // before passing to the SDK or the SDK's strict equality
    // check (`typeof index === 'bigint'`) silently falls back to
    // 0n. This test simulates the wire path explicitly.
    const deps = buildFakeDeps()
    const envelope = {...FIXTURE_ENVELOPE, kernel_account_index: 2}

    await submitInstall({provider: FAKE_PROVIDER, account: "0xuserEoa", envelope, deps})

    const createKernelArgs = deps.sdk.createKernelAccount.mock.calls[0][1]
    expect(typeof createKernelArgs.index).toBe("bigint")
    expect(createKernelArgs.index).toBe(2n)
  })

  it("falls back to index 1n when envelope is missing kernel_account_index", async () => {
    // Defense in depth: a Phoenix regression that drops the field
    // from the envelope payload must NOT silently collapse the
    // browser install onto index 0 (the operator's). The hook
    // falls back to the documented dev default 1n so the
    // collision check still holds even with a half-broken envelope.
    const deps = buildFakeDeps()
    const envelope = {...FIXTURE_ENVELOPE}
    delete envelope.kernel_account_index

    await submitInstall({provider: FAKE_PROVIDER, account: "0xuserEoa", envelope, deps})

    const createKernelArgs = deps.sdk.createKernelAccount.mock.calls[0][1]
    expect(typeof createKernelArgs.index).toBe("bigint")
    expect(createKernelArgs.index).toBe(1n)
  })

  it("enables Pimlico paymaster sponsorship on the kernelClient (AA21 prefund fix)", async () => {
    // Regression: the freshly-derived browser smart account
    // (kernel index >= 1) has zero ETH on first install. Without
    // a paymaster the install UserOp reverts during simulation
    // with `AA21 didn't pay prefund`. The fix turns on viem's
    // `paymaster: true` flag, which routes
    // `pm_getPaymasterStubData` + `pm_getPaymasterData` to the
    // bundler transport. Pimlico's API key advertises both
    // methods on the `/v2/<chain>/rpc` endpoint (ERC-7677
    // standard + the older `pm_sponsorUserOperation` alias).
    // Pin that `createKernelAccountClient` actually receives the
    // flag — a regression that drops it silently re-introduces
    // the AA21 failure on every first install of every new
    // kernel index.
    const deps = buildFakeDeps()
    await submitInstall({
      provider: FAKE_PROVIDER,
      account: "0xuserEoa",
      envelope: FIXTURE_ENVELOPE,
      deps,
    })

    const kernelClientArgs = deps.sdk.createKernelAccountClient.mock.calls[0][0]
    expect(kernelClientArgs.paymaster).toBe(true)
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
