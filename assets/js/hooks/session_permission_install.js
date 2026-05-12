// Browser-driven ZeroDev session permission install hook (#473, #501).
//
// Drives the operator-facing flow for installing a Kernel session
// permission with the user's wallet as the kernel root signer. The
// signer of record is the EIP-6963 wallet the user picked from the
// shared wallet registry (or, for single-wallet browsers, whichever
// EIP-1193 provider answered the EIP-6963 broadcast — falling back
// to `window.ethereum` on legacy single-injection wallets). It is
// never Phoenix, never the chain adapter, never an operator/server
// private key.
//
// ## State machine
//
//   idle
//     ── click #session-permission-browser-install-btn
//     ──→ awaiting (chain checked; envelope fetched; balance preflight)
//     ── ZeroDev SDK builds + signs install UserOp via wallet
//     ──→ submitted (real bundler hash; attestation POSTed)
//     ── bundler confirms receipt
//     ──→ confirmed (tx_hash + block_number; attestation POSTed)
//     ── on-chain verifier (#474) flips delegation row to :active
//
//   On any error: ──→ failed (with structured reason from
//                            BrowserInstall.failure_categories/0)
//
// ## Hard safety boundaries (pinned by the source-hygiene test)
//
//   * Base Sepolia (84532) ONLY. Wallet `eth_chainId` AND
//     envelope `chain_id` BOTH must equal 84532 — the hook
//     refuses before constructing any SDK objects otherwise.
//   * No private keys, no mnemonic, no seed phrase — the user's
//     wallet is the only signer.
//   * No transaction broadcast methods (`eth_sendTransaction`
//     etc.). The install is dispatched as an EIP-4337
//     UserOperation through the bundler, never as a raw EOA
//     transaction.
//   * No legacy `eth_sign` and no hand-built typed-data payloads.
//     The install enable signature is built by the ZeroDev SDK
//     against the canonical envelope; the hook never authors a
//     typed-data struct of its own.
//   * No hardcoded bundler URL — the hook reads
//     `envelope.bundler_rpc_url` from the canonical
//     Phoenix-issued envelope.
//   * No unlimited approval, no arbitrary calldata, no
//     borrow/leverage/withdraw authority surface — these are
//     Phoenix-side scope decisions and the install scope mirrors
//     `Bank.SessionPermissions.Scope.default/0`.
//   * Failure reasons are restricted to the wire allowlist
//     `Bank.SessionPermissions.BrowserInstall.failure_categories/0`.

import {fetchInstallEnvelope, postSubmittedAttestation, postConfirmedAttestation, postFailureAttestation, mapBeFailureCode} from "./install_envelope_client.js"
import {submitInstall, classifySendError} from "./install_zerodev_client.js"
import {startDiscovery, getProvider} from "../wallet_provider.js"

const SUPPORTED_CHAIN_IDS = [84_532]
// Pre-flight gas floor — refuse to construct SDK objects below
// this so a wallet popup doesn't fire just to fail at bundler
// simulation. 0.005 ETH on Base Sepolia is generous for one
// install; tighten after measuring real installs.
const MIN_GAS_BALANCE_WEI = 5_000_000_000_000_000n

export const SessionPermissionInstall = {
  mounted() {
    this.handleClick = this.handleClick.bind(this)
    this.el.addEventListener("click", this.handleClick)
    // Boot the shared EIP-6963 registry. Idempotent — the WalletConnect
    // hook may have already started discovery; either way we'll see
    // the same announced wallets and the user's selection via
    // `getProvider()` once they pick from the wallet picker.
    startDiscovery()
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
  },

  handleClick(event) {
    if (!event.target.closest("#session-permission-browser-install-btn")) return
    event.preventDefault()
    this.beginInstall().catch((err) => {
      const reason = classifySendError(err)
      this.pushEvent("session_permission_install:failed", {reason})
    })
  },

  async beginInstall() {
    // Read the wallet the user picked from the multi-wallet picker
    // (or the lone announced wallet, or legacy `window.ethereum`).
    // The shared registry is updated synchronously from the server's
    // `wallet_connect:use_provider` event handler in WalletConnect,
    // so by the time the user clicks Install the right wallet is
    // here.
    const provider = getProvider()
    if (!provider) {
      this.pushEvent("session_permission_install:failed", {reason: "wallet_not_connected"})
      return
    }

    // 0. PASSIVE LIVENESS PREFLIGHT — the most important client-side
    //    gate. The render-time `:wallet == :connected` guard in
    //    `BankWeb.AgentLive` already disables the install button when
    //    the live browser provider stopped exposing the bound account
    //    (or the operator switched MetaMask account / chain /
    //    revoked the site permission), but a stale tab / scripted
    //    click / keyboard shortcut can still reach this hook. We
    //    re-check on the trust boundary BEFORE fetching the install
    //    envelope from Phoenix:
    //
    //      * `eth_accounts` is the read-only version of
    //        `eth_requestAccounts` — it returns the currently
    //        exposed accounts without prompting MetaMask. An empty
    //        array means "this site is not currently permissioned",
    //        regardless of whether a DB binding row exists.
    //      * Comparing the exposed account against the binding's
    //        bound address (rendered as `data-bound-address` by
    //        Phoenix) catches the case where the operator switched
    //        MetaMask accounts after binding — the DB row still
    //        carries the OLD account.
    //
    //    Either failure exits before any envelope/bundler/sign call
    //    so the operator never sees a half-started install.
    let exposedAccounts
    try {
      exposedAccounts = await provider.request({method: "eth_accounts"})
    } catch (_e) {
      exposedAccounts = []
    }
    if (!Array.isArray(exposedAccounts) || exposedAccounts.length === 0) {
      this.pushEvent("session_permission_install:failed", {reason: "wallet_not_connected"})
      return
    }

    const boundAddress = readBoundAddress(this.el)
    if (boundAddress) {
      const exposed = exposedAccounts.map((a) => (typeof a === "string" ? a.toLowerCase() : ""))
      if (!exposed.includes(boundAddress.toLowerCase())) {
        this.pushEvent("session_permission_install:failed", {reason: "account_mismatch"})
        return
      }
    }

    // 1. Wallet chain check — refuse before SDK construction.
    const walletChainId = await readChainId(provider)
    if (!SUPPORTED_CHAIN_IDS.includes(walletChainId)) {
      this.pushEvent("session_permission_install:wrong_chain", {chain_id: walletChainId})
      return
    }

    // 2. Read binding id from a `data-binding-id` attribute on the
    //    install button. Phoenix renders this from the operator's
    //    verified wallet binding.
    const bindingId = readBindingId(this.el)
    if (!bindingId) {
      this.pushEvent("session_permission_install:failed", {reason: "unknown"})
      return
    }

    // 3. Fetch canonical envelope. Phoenix is the source of truth.
    let envelope
    try {
      envelope = await fetchInstallEnvelope(bindingId)
    } catch (err) {
      const reason = (err && err.code) || "unknown"
      this.pushEvent("session_permission_install:failed", {reason})
      return
    }

    // 4. Envelope chain check — defense in depth.
    if (envelope.chain_id !== SUPPORTED_CHAIN_IDS[0]) {
      this.pushEvent("session_permission_install:wrong_chain", {chain_id: envelope.chain_id})
      return
    }

    // 4b. Bundler URL check — the ZeroDev SDK needs a real ERC-4337
    //     bundler to submit the install UserOp. Phoenix returns null
    //     when none of `BASE_SEPOLIA_BUNDLER_RPC` / `BUNDLER_URL` /
    //     `BUNDLER_RPC_URL` is set in the env (see `config/dev.exs`);
    //     without it the SDK call would either hang or fail with a
    //     cryptic network error. Fail fast here with a categorised
    //     reason the UI can show instead.
    //
    //     `bundler_not_configured` is distinct from `bundler_unavailable`:
    //     the former means Phoenix never had a URL to send, the latter
    //     means we tried to reach a URL and the network/origin rejected
    //     us (CORS, DNS, 5xx). Both surface different operator-facing
    //     copy.
    if (!envelope.bundler_rpc_url || typeof envelope.bundler_rpc_url !== "string") {
      this.pushEvent("session_permission_install:failed", {reason: "bundler_not_configured"})
      return
    }

    // 5. Get user account.
    let account
    try {
      const accounts = await provider.request({method: "eth_requestAccounts"})
      account = accounts && accounts[0]
    } catch (err) {
      const reason = classifySendError(err)
      this.pushEvent("session_permission_install:failed", {reason})
      return
    }
    if (!account) {
      this.pushEvent("session_permission_install:failed", {reason: "user_rejected"})
      return
    }

    // 6. Balance pre-flight.
    try {
      const balanceHex = await provider.request({
        method: "eth_getBalance",
        params: [account, "latest"],
      })
      if (BigInt(balanceHex) < MIN_GAS_BALANCE_WEI) {
        await postFailureAttestation(bindingId, "insufficient_funds")
        this.pushEvent("session_permission_install:failed", {reason: "insufficient_funds"})
        return
      }
    } catch (err) {
      const reason = classifySendError(err)
      this.pushEvent("session_permission_install:failed", {reason})
      return
    }

    this.pushEvent("session_permission_install:awaiting", {})

    // 7. SDK install dance.
    let result
    try {
      result = await submitInstall({provider, account, envelope})
    } catch (err) {
      // The SDK chain logs each step internally, but if `submitInstall`
      // itself throws (e.g. failed dynamic import, viem misuse) we
      // still surface the raw error to the console so the operator
      // can see what happened before the classifier collapses it.
      if (typeof console !== "undefined" && console.error) {
        console.error("[browser-install:submitInstall throw] raw error:", err)
      }
      const reason = classifySendError(err)
      await postFailureAttestation(bindingId, reason)
      this.pushEvent("session_permission_install:failed", {reason})
      return
    }

    if (result.status === "failed") {
      await postFailureAttestation(bindingId, result.reason)
      this.pushEvent("session_permission_install:failed", {reason: result.reason})
      return
    }

    // 8. POST submitted attestation BEFORE awaiting receipt — this
    //    guarantees Phoenix has an anchored `:pending` row before
    //    the receipt arrives (or the tab closes).
    //
    //    STRICT GATE: if Phoenix rejects the attestation
    //    (workspace paused, binding revoked, invalid payload, …)
    //    the hook MUST NOT push `:submitted`. Otherwise the UI
    //    would advance past `:installing` while the DB has no
    //    `:pending` row to anchor it. We push `:failed` instead,
    //    mapping the BE error code to a failure-category atom.
    try {
      await postSubmittedAttestation(bindingId, {
        install_userop_hash: result.install_userop_hash,
        permission_id: result.permission_id,
        validation_id: result.validation_id,
        smart_account_address: result.smart_account_address,
      })
    } catch (err) {
      const reason = mapBeFailureCode(err && err.code) || "bundler_rejected"
      this.pushEvent("session_permission_install:failed", {reason})
      return
    }

    this.pushEvent("session_permission_install:submitted", {
      install_userop_hash: result.install_userop_hash,
      permission_id: result.permission_id,
      validation_id: result.validation_id,
      smart_account_address: result.smart_account_address,
    })

    // 9. Wait for the real bundler receipt. The synthetic
    //    confirmation stand-in from the original scaffold was
    //    removed under #501; the hook-safety test pins its
    //    absence so a future regression cannot reintroduce it.
    const receipt = await result.waitForReceipt()
    if (!receipt.success) {
      const reason = receipt.reason || "userop_reverted"
      await postFailureAttestation(bindingId, reason, {
        install_userop_hash: result.install_userop_hash,
      })
      this.pushEvent("session_permission_install:failed", {reason})
      return
    }

    // 10. POST confirmed attestation. Phoenix only flips the row
    //     to :active after the on-chain verifier (#474) re-checks
    //     kernel state — this attestation is the trigger.
    //
    //     STRICT GATE: same posture as the `:submitted` POST. If
    //     Phoenix refuses (e.g. binding revoked between submit
    //     and confirm, or the userop hash doesn't match the row
    //     it expected) we push `:failed` and bail, leaving the
    //     LiveView in `:installing` rather than advancing past
    //     it on a lie.
    try {
      await postConfirmedAttestation(bindingId, {
        install_userop_hash: result.install_userop_hash,
        tx_hash: receipt.tx_hash,
        block_number: receipt.block_number,
      })
    } catch (err) {
      const reason = mapBeFailureCode(err && err.code) || "bundler_rejected"
      this.pushEvent("session_permission_install:failed", {reason})
      return
    }

    this.pushEvent("session_permission_install:confirmed", {
      install_userop_hash: result.install_userop_hash,
      tx_hash: receipt.tx_hash,
      block_number: receipt.block_number,
    })
  },
}

async function readChainId(provider) {
  const chainIdHex = await provider.request({method: "eth_chainId"})
  return parseInt(chainIdHex, 16)
}

// Server-rendered bound EOA (lowercased upstream). Used by the
// passive `eth_accounts` preflight to catch a stale tab whose
// browser wallet has switched to a different account. Returns null
// when the attribute isn't set (e.g. test fixtures without a
// binding) — in that case the bound-address check is skipped and
// only the empty-accounts check applies.
function readBoundAddress(el) {
  if (!el) return null
  const direct = el.dataset && el.dataset.boundAddress
  if (direct) return direct
  const inner = el.querySelector && el.querySelector("[data-bound-address]")
  return inner && inner.dataset && inner.dataset.boundAddress
}

function readBindingId(el) {
  if (!el) return null
  // The button declares its binding id via `data-binding-id`.
  // The hook itself may be on a wrapper element — check both.
  const direct = el.dataset && el.dataset.bindingId
  if (direct) return direct
  const inner = el.querySelector && el.querySelector("[data-binding-id]")
  return inner ? inner.dataset.bindingId : null
}
