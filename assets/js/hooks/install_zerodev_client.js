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

  // Wallet client wraps `window.ethereum`; its `account` is the
  // viem JsonRpcAccount that signs via the wallet's RPC. ZeroDev's
  // sudo validator delegates `signMessage` / `signTypedData` to
  // this account when it builds the install enable signature.
  const walletClient = viem.createWalletClient({
    account,
    chain,
    transport: viem.custom(provider),
  })

  // Public client for read-only RPC. We reuse the bundler URL: the
  // Pimlico endpoint exposes generic JSON-RPC methods alongside
  // bundler-specific ones, which is what the adapter does too.
  const publicClient = viem.createPublicClient({
    chain,
    transport: viem.http(envelope.bundler_rpc_url),
  })

  // Sudo: the user's connected EOA. Mirrors grant.ts's
  // `signerToEcdsaValidator(... operatorAccount ...)` line-for-line
  // with the operator EOA replaced by the user's wallet account.
  let sudoValidator
  try {
    sudoValidator = await ecdsaValidator.signerToEcdsaValidator(publicClient, {
      signer: walletClient.account,
      entryPoint,
      kernelVersion,
    })
  } catch (err) {
    return {status: "failed", reason: classifySendError(err)}
  }

  // Regular: operator-rotated session signer's *address only*. The
  // browser does not (and must not) hold the session signer's
  // private key — that lives in the adapter for runtime UserOps.
  // viem's `toAccount` accepts a watch-only LocalAccount whose
  // sign methods reject; ZeroDev's `toECDSASigner` is satisfied by
  // the address alone during install (the regular validator's
  // signMessage is invoked at runtime, not at install).
  const sessionAccount = viemAccounts.toAccount({
    address: envelope.session_signer_address,
    signMessage: () => Promise.reject(new Error("session signer not available in browser")),
    signTransaction: () => Promise.reject(new Error("session signer not available in browser")),
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
    return {status: "failed", reason: classifySendError(err)}
  }

  const permissionId = permissionPlugin.getIdentifier()
  const permissionIdHex = bytesToHex(permissionId)
  // validation_id = 0x02 (VALIDATOR_TYPE.PERMISSION) +
  //                 permissionId padded right to 20 bytes.
  // 21 bytes total = 42 hex chars + 0x prefix = 44.
  const validationIdHex =
    "0x02" + permissionIdHex.slice(2).padEnd(40, "0")

  let kernelAccount
  try {
    kernelAccount = await sdk.createKernelAccount(publicClient, {
      entryPoint,
      kernelVersion,
      plugins: {sudo: sudoValidator, regular: permissionPlugin},
    })
  } catch (err) {
    return {status: "failed", reason: classifySendError(err)}
  }
  const smartAccountAddress = kernelAccount.address

  const kernelClient = sdk.createKernelAccountClient({
    account: kernelAccount,
    chain,
    bundlerTransport: viem.http(envelope.bundler_rpc_url),
    client: publicClient,
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
