// Browser-driven ZeroDev SDK install glue (#501). Mirrors
// `chain_adapter/src/chains/base/grant.ts` precisely, with the
// user's connected EOA replacing the operator EOA as the kernel's
// root validator and the operator-rotated session signer
// preserved as the *regular* permission validator.
//
// **No private keys, no mnemonics, no operator/server keys cross
// this module.** The user's wallet (`window.ethereum` proxied via
// viem's `custom` transport) signs the install UserOp's enable
// typed-data; the ZeroDev SDK orchestrates that exchange.
//
// **No bundler URL is hardcoded.** The bundler RPC URL is read
// from the canonical Phoenix-issued envelope's `bundler_rpc_url`
// field — Phoenix is the source of truth.
//
// The functions here are split into separate exports so vitest
// can stub them cleanly when testing the hook's outer state
// machine.

const ENTRY_POINT_VERSION = "0.7"
const RECEIPT_TIMEOUT_MS_DEFAULT = 45_000

/**
 * Hex-encode a byte string (no `0x` prefix). Used to format the
 * 4-byte permission_id and 21-byte validation_id for the
 * attestation POST.
 */
function bytesToHex(bytes) {
  if (typeof bytes === "string") return bytes // already hex
  return (
    "0x" +
    Array.from(bytes)
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("")
  )
}

/**
 * Build the install context and submit the install UserOp via the
 * bundler. Returns either:
 *
 *   - `{status: "submitted", install_userop_hash, permission_id,
 *      validation_id, smart_account_address, waitForReceipt}` —
 *      the bundler accepted the UserOp; caller should POST the
 *      `submitted` attestation, then call `waitForReceipt()`.
 *   - `{status: "failed", reason}` — pre-receipt failure;
 *      `reason` is a member of
 *      `Bank.SessionPermissions.BrowserInstall.failure_categories/0`.
 */
export async function submitInstall({provider, account, envelope, deps = {}}) {
  const sdk = deps.sdk || (await import("@zerodev/sdk"))
  const sdkConstants = deps.sdkConstants || (await import("@zerodev/sdk/constants"))
  const ecdsaValidator = deps.ecdsaValidator || (await import("@zerodev/ecdsa-validator"))
  const permissions = deps.permissions || (await import("@zerodev/permissions"))
  const permissionsSigners = deps.permissionsSigners || (await import("@zerodev/permissions/signers"))
  const permissionsPolicies = deps.permissionsPolicies || (await import("@zerodev/permissions/policies"))
  const viem = deps.viem || (await import("viem"))
  const viemAccounts = deps.viemAccounts || (await import("viem/accounts"))
  const viemChains = deps.viemChains || (await import("viem/chains"))

  const entryPoint = sdkConstants.getEntryPoint(ENTRY_POINT_VERSION)
  const kernelVersion = sdkConstants.KERNEL_V3_1
  const chain = viemChains.baseSepolia

  // Wallet client wraps `window.ethereum`. We hand ZeroDev's
  // `signerToEcdsaValidator` the WHOLE walletClient (not just its
  // `.account`) because ZeroDev's `toSigner` expects one of:
  //
  //   1. a LocalAccount / SmartAccount (`type === "local" | "smart"`),
  //      e.g. from `privateKeyToAccount` — what the chain_adapter
  //      uses with its operator EOA.
  //   2. an EIP-1193 provider with `.request` and no `.account`,
  //      which it auto-detects via `eth_requestAccounts`.
  //   3. a viem walletClient — read directly as `signer.account.address`.
  //
  // In the browser we don't have a private key (case 1), and we
  // can't safely pass the raw provider (case 2 would re-prompt
  // `eth_requestAccounts` and waste a wallet round-trip we already
  // did in the preflight). The viem walletClient (case 3) is the
  // right fit. Passing `walletClient.account` instead crashes with
  // `Cannot read properties of undefined (reading 'address')`
  // because viem's JsonRpcAccount has no `.account` field — that's
  // a property of the walletClient.
  const walletClient = viem.createWalletClient({
    account,
    chain,
    transport: viem.custom(provider),
  })

  // Public client for read-only RPC. Reads from
  // `envelope.chain_rpc_url` (e.g. `https://sepolia.base.org`),
  // NOT from `envelope.bundler_rpc_url` — most hosted bundlers
  // (Pimlico, Stackup, Candide) expose ONLY ERC-4337 bundler
  // methods (`eth_sendUserOperation`, `eth_estimateUserOperationGas`,
  // `eth_getUserOperationReceipt`) and reject generic chain calls
  // (`eth_call`, `eth_getCode`). ZeroDev's `createKernelAccount`
  // internally calls `getSenderAddress` (an EntryPoint v0.7
  // simulation via `eth_call`), and when that hits a bundler-only
  // endpoint, the SDK's revert-decoder regex fails on the unexpected
  // reply shape with `Cannot read properties of undefined (reading
  // 'match')`. ZeroDev's own hosted bundler (`rpc.zerodev.app`)
  // happens to serve both, which masked this for early dev.
  //
  // Fall back to `bundler_rpc_url` only when `chain_rpc_url` is
  // missing — Phoenix's `dev.exs` defaults `chain_rpc_url` to
  // `https://sepolia.base.org` so this fallback should never fire
  // in a correctly configured env.
  const chainRpcUrl = envelope.chain_rpc_url || envelope.bundler_rpc_url
  const publicClient = viem.createPublicClient({
    chain,
    transport: viem.http(chainRpcUrl),
  })

  // Sudo: the user's connected EOA. Mirrors grant.ts's
  // `signerToEcdsaValidator(... operatorAccount ...)` line-for-line
  // with the operator EOA replaced by the user's wallet account
  // (passed as the wrapping walletClient — see comment above).
  let sudoValidator
  try {
    sudoValidator = await ecdsaValidator.signerToEcdsaValidator(publicClient, {
      signer: walletClient,
      entryPoint,
      kernelVersion,
    })
  } catch (err) {
    logRawInstallError("signerToEcdsaValidator", err)
    return {status: "failed", reason: classifySendError(err)}
  }

  // Regular: operator-rotated session signer.
  //
  // The browser does NOT and MUST NOT hold the session signer's
  // private key — that lives in chain_adapter as
  // `DELEGATION_SIGNER_KEY`. ZeroDev's PermissionValidator.signUserOperation
  // calls `sessionAccount.signMessage({raw: userOpHash})` to produce
  // the regular validator's signature on the install UserOp (in
  // addition to the sudo enable signature). We satisfy that call by
  // POSTing the hash to Phoenix's
  // `/wallet_bindings/:id/sign_install_userop_hash` proxy, which
  // forwards it to chain_adapter; the adapter signs and returns
  // the signature. The browser never sees the key.
  //
  // `sessionSignFetcher` is injectable for tests; defaults to
  // `postSignInstallUserOpHash` from install_envelope_client.js.
  // It MUST extract the 32-byte hash from viem's `signMessage`
  // argument shape (`{message: {raw: hex}}` or `{message: string}`
  // — the SDK uses the raw shape) and POST it to Phoenix.
  const sessionSignFetcher =
    deps.sessionSignFetcher ||
    (await import("./install_envelope_client.js")).postSignInstallUserOpHash

  const bindingId = envelope.binding_id

  const sessionAccount = viemAccounts.toAccount({
    address: envelope.session_signer_address,
    async signMessage({message}) {
      // viem's `signMessage` API accepts:
      //   - `{message: "string"}` — UTF-8 personal_sign over the string
      //   - `{message: {raw: hex_or_bytes}}` — personal_sign over raw bytes
      //
      // ZeroDev's PermissionValidator passes `{raw: userOpHash}`
      // where `userOpHash` is the 32-byte ERC-4337 user-operation
      // hash. We refuse anything else — the proxy endpoint is
      // strictly scoped to install UserOp hashes; signing arbitrary
      // strings on the operator's session key is out of scope.
      if (!message || typeof message !== "object" || typeof message.raw !== "string") {
        const err = new Error("session signer only signs raw 32-byte hashes (install UserOp)")
        err.code = "session_signer_refused"
        throw err
      }

      const {signature} = await sessionSignFetcher(bindingId, message.raw, {
        sessionSignerAddress: envelope.session_signer_address,
      })

      return signature
    },
    signTransaction: () => Promise.reject(new Error("session signer never signs transactions in browser")),
  })
  const sessionSigner = await permissionsSigners.toECDSASigner({signer: sessionAccount})

  let permissionPlugin
  try {
    permissionPlugin = await permissions.toPermissionValidator(publicClient, {
      signer: sessionSigner,
      // v0.1 mirrors grant.ts's `toSudoPolicy({})`. Phoenix's outer
      // policy gate enforces every transfer / swap / Morpho deposit
      // independently; per-policy on-chain encoding is a v0.2 ticket.
      policies: [permissionsPolicies.toSudoPolicy({})],
      entryPoint,
      kernelVersion,
    })
  } catch (err) {
    logRawInstallError("toPermissionValidator", err)
    return {status: "failed", reason: classifySendError(err)}
  }

  const permissionId = permissionPlugin.getIdentifier()
  const permissionIdHex = bytesToHex(permissionId)
  // validation_id = 0x02 (VALIDATOR_TYPE.PERMISSION) +
  //                 permissionId padded right to 20 bytes.
  // 21 bytes total = 42 hex chars + 0x prefix = 44.
  const validationIdHex =
    "0x02" + permissionIdHex.slice(2).padEnd(40, "0")

  // Browser-specific Kernel CREATE2 salt. Phoenix's envelope
  // carries `kernel_account_index` from
  // `BROWSER_KERNEL_ACCOUNT_INDEX` (default 1 in dev). This MUST
  // be passed to `createKernelAccount` so the derived smart-
  // account address does NOT collide with the chain_adapter's
  // operator account (index 0). Without it, a demo user whose
  // MetaMask EOA equals `OPERATOR_ADDRESS` (e.g. importing the
  // adapter's private key) would derive the already-deployed
  // operator smart account, and the install UserOp would revert
  // with `AA23 reverted 0x756688fe` (Kernel's `InvalidSignature()`)
  // because the existing account state can't accept a fresh
  // enable signature. Phoenix-side preflight refuses to issue an
  // envelope in the collision case, so this is the wire-load-
  // bearing path.
  const kernelAccountIndex = readKernelAccountIndex(envelope)

  let kernelAccount
  try {
    kernelAccount = await sdk.createKernelAccount(publicClient, {
      entryPoint,
      kernelVersion,
      index: kernelAccountIndex,
      plugins: {sudo: sudoValidator, regular: permissionPlugin},
    })
  } catch (err) {
    logRawInstallError("createKernelAccount", err)
    return {status: "failed", reason: classifySendError(err)}
  }
  const smartAccountAddress = kernelAccount.address

  // Bundler-agnostic gas-price callback. ZeroDev SDK's default
  // `userOperation.estimateFeesPerGas` calls `zd_getUserOperationGasPrice` —
  // a ZeroDev-bundler-specific RPC method that Pimlico, Stackup,
  // Candide, etc. don't implement. Override here with a probe
  // sequence that works against any bundler:
  //
  //   1. `pimlico_getUserOperationGasPrice` — Pimlico's native shape
  //      (returns `{slow|standard|fast: {maxFeePerGas, maxPriorityFeePerGas}}`).
  //   2. `zd_getUserOperationGasPrice` — ZeroDev's shape (same
  //      structure, different prefix). Kept so an operator who
  //      switches back to ZeroDev's hosted bundler still works.
  //   3. Standard EIP-1559 (`eth_maxPriorityFeePerGas` on the
  //      chain RPC + `eth_gasPrice` for the base fee bump) — used
  //      by self-hosted Alto / Skandha / any bundler that doesn't
  //      bundle its own gas oracle.
  //
  // If all three fail we throw — the kernelClient retry logic
  // surfaces it via `classifySendError`, which already maps
  // `Validation error` / `-32601` to `bundler_rejected`.
  const estimateFeesPerGas = async ({bundlerClient}) => {
    for (const method of ["pimlico_getUserOperationGasPrice", "zd_getUserOperationGasPrice"]) {
      try {
        const gp = await bundlerClient.request({method, params: []})
        const std = gp && (gp.standard || gp.fast || gp.slow)
        if (std && std.maxFeePerGas && std.maxPriorityFeePerGas) {
          return {
            maxFeePerGas: BigInt(std.maxFeePerGas),
            maxPriorityFeePerGas: BigInt(std.maxPriorityFeePerGas),
          }
        }
      } catch (_e) {
        // Move on to the next probe.
      }
    }
    // Fallback: standard EIP-1559 on the chain RPC. Adds 20% to
    // the base fee suggestion so the UserOp doesn't underprice
    // and stick in the bundler's mempool.
    const tipHex = await publicClient.request({method: "eth_maxPriorityFeePerGas", params: []})
    const baseHex = await publicClient.request({method: "eth_gasPrice", params: []})
    const tip = BigInt(tipHex)
    const base = BigInt(baseHex)
    return {
      maxPriorityFeePerGas: tip,
      maxFeePerGas: base + tip + base / 5n,
    }
  }

  // Paymaster sponsorship. With `paymaster: true`, viem routes
  // `pm_getPaymasterStubData` (gas-estimation phase) and
  // `pm_getPaymasterData` (final phase) to the bundler transport —
  // Pimlico's API key advertises both methods on the same
  // `/v2/<chain>/rpc` endpoint (ERC-7677 + the older
  // `pm_sponsorUserOperation` alias). Without sponsorship the
  // browser install fails the very first time with
  // `AA21 didn't pay prefund` because the freshly-derived smart
  // account (kernel index >= 1) has zero ETH and there is no
  // funding path before the deploy-and-install UserOp.
  //
  // Operator pays for gas via Pimlico's verifying paymaster
  // (free tier on Base Sepolia). For production this is where a
  // policy-aware paymaster URL would be wired — kept off the
  // hot path here because the bundler URL already carries the
  // policy / key.
  const kernelClient = sdk.createKernelAccountClient({
    account: kernelAccount,
    chain,
    bundlerTransport: viem.http(envelope.bundler_rpc_url),
    client: publicClient,
    paymaster: true,
    userOperation: {estimateFeesPerGas},
  })

  // Install UserOp: an inert zero-value call to address(0). The
  // permission state change happens during VALIDATION (the kernel
  // accepts the enable signature), not in the execution phase.
  // Mirrors grant.ts.
  let userOpHash
  try {
    const callData = await kernelAccount.encodeCalls([
      {
        to: "0x0000000000000000000000000000000000000000",
        value: 0n,
        data: "0x",
      },
    ])
    userOpHash = await kernelClient.sendUserOperation({callData})
  } catch (err) {
    logRawInstallError("sendUserOperation", err)
    return {status: "failed", reason: classifySendError(err)}
  }

  return {
    status: "submitted",
    install_userop_hash: userOpHash,
    permission_id: permissionIdHex,
    validation_id: validationIdHex,
    smart_account_address: smartAccountAddress,
    waitForReceipt: () => waitForInstallReceipt(kernelClient, userOpHash),
  }
}

/**
 * Wait for the bundler to confirm the install UserOp. Returns:
 *   - `{success: true, tx_hash, block_number}`
 *   - `{success: false, reason: <failure_category>}`
 */
async function waitForInstallReceipt(kernelClient, userOpHash) {
  let receipt
  try {
    receipt = await kernelClient.waitForUserOperationReceipt({
      hash: userOpHash,
      timeout: RECEIPT_TIMEOUT_MS_DEFAULT,
    })
  } catch (err) {
    return {success: false, reason: classifyReceiptError(err)}
  }

  if (!receipt || !receipt.success) {
    return {success: false, reason: "userop_reverted"}
  }
  return {
    success: true,
    tx_hash: receipt.receipt.transactionHash,
    block_number: Number(receipt.receipt.blockNumber),
  }
}

/**
 * Print the raw error to the console BEFORE the classifier
 * collapses it onto the wire allowlist. Without this, every
 * unrecognised SDK / bundler / viem error surfaces as the generic
 * `unknown` failure-category atom and the operator has no idea
 * which step failed — `mix bank.browser_install.smoke` only covers
 * the preflight, not the post-envelope SDK chain. We log here so a
 * dev/operator can diff the cryptic-but-precise stack against the
 * step label.
 *
 * The raw error is dev-debug-only. The wire payload still uses the
 * sanitised failure category — Phoenix's audit and the install
 * attestation route never see this message.
 */
// Read the browser kernel CREATE2 salt from the install envelope
// and coerce to a `bigint` (ZeroDev SDK's `createKernelAccount`
// requires a bigint here — passing a Number triggers a silent
// `index === undefined` fallback to 0, which is the operator's
// index and the whole collision the field exists to prevent).
//
// Phoenix sends an integer when present; JSON parsing yields a
// JS Number. We `BigInt(...)` defensively. When missing /
// malformed, fall back to 1n (the documented dev default) so an
// envelope-shape regression doesn't silently collapse to the
// operator's index.
function readKernelAccountIndex(envelope) {
  const raw = envelope && envelope.kernel_account_index
  if (raw === null || raw === undefined) return 1n

  // Numbers, numeric strings, and explicit bigints all coerce.
  try {
    return BigInt(raw)
  } catch (_e) {
    return 1n
  }
}

function logRawInstallError(step, err) {
  if (typeof console === "undefined") return
  try {
    const code = err && typeof err.code !== "undefined" ? err.code : null
    const message = err && err.message ? err.message : String(err)
    const cause = err && err.cause ? err.cause.message || err.cause : null
    const details = err && err.details ? err.details : null
    const shortMessage = err && err.shortMessage ? err.shortMessage : null
    // viem nests bundler / RPC error messages under `metaMessages` and
    // a chain of `cause` errors. We dump the surface fields plus the
    // raw object so dev tools can drill in.
    console.error(`[browser-install:${step}] raw error:`, {
      code,
      message,
      shortMessage,
      details,
      cause,
    })
    console.error(`[browser-install:${step}] raw object:`, err)
  } catch (_e) {
    // Logging must never throw — the classifier still has to run.
  }
}

/**
 * Map an EIP-1193 / viem error to a member of
 * `Bank.SessionPermissions.BrowserInstall.failure_categories/0`.
 *
 * Allowed: user_rejected | bundler_rejected | bundler_unavailable
 *        | chain_id_mismatch | insufficient_funds | userop_reverted
 *        | attestation_timeout | unknown
 */
export function classifySendError(err) {
  const code = err && typeof err.code === "number" ? err.code : null
  const message = err && err.message ? String(err.message).toLowerCase() : ""

  if (code === 4001 || message.includes("user rejected") || message.includes("user denied")) {
    return "user_rejected"
  }
  if (message.includes("insufficient funds") || message.includes("insufficient gas")) {
    return "insufficient_funds"
  }
  if (message.includes("chain id") || message.includes("chain mismatch")) {
    return "chain_id_mismatch"
  }
  // viem's `HttpRequestError` for bundler 4xx; `FetchError` /
  // `TransportError` for outright unavailability. We fold them into
  // distinct categories so Phoenix can render different copy.
  if (
    message.includes("network") ||
    message.includes("fetch") ||
    message.includes("timeout") ||
    message.includes("503") ||
    message.includes("502") ||
    message.includes("504") ||
    message.includes("429")
  ) {
    return "bundler_unavailable"
  }
  if (
    message.includes("revert") ||
    message.includes("rejected") ||
    message.includes("validation") ||
    code === -32000
  ) {
    return "bundler_rejected"
  }
  return "unknown"
}

export function classifyReceiptError(err) {
  const message = err && err.message ? String(err.message).toLowerCase() : ""
  // Order matters: HTTP-status markers win over the "timeout" word
  // because bundler 5xx surfaces with "gateway timeout" / "request
  // timeout" copy that we want classified as `bundler_unavailable`,
  // not as a wallclock attestation timeout.
  if (
    message.includes("503") ||
    message.includes("502") ||
    message.includes("504") ||
    message.includes("429")
  ) {
    return "bundler_unavailable"
  }
  if (message.includes("network") || message.includes("fetch")) return "bundler_unavailable"
  if (message.includes("timeout") || message.includes("timed out")) return "attestation_timeout"
  return "unknown"
}
