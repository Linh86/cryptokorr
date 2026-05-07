// Browser-driven ZeroDev session permission install hook (#473, #501).
//
// Drives the operator-facing flow for installing a Kernel session
// permission with the user's wallet as the kernel root signer. The
// signer of record is `window.ethereum` — never Phoenix, never
// the chain adapter, never an operator/server private key.
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

import {fetchInstallEnvelope, postSubmittedAttestation, postConfirmedAttestation, postFailureAttestation} from "./install_envelope_client.js"
import {submitInstall, classifySendError} from "./install_zerodev_client.js"

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
    const provider = window.ethereum
    if (!provider) {
      this.pushEvent("session_permission_install:failed", {reason: "unknown"})
      return
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
    await postSubmittedAttestation(bindingId, {
      install_userop_hash: result.install_userop_hash,
      permission_id: result.permission_id,
      validation_id: result.validation_id,
      smart_account_address: result.smart_account_address,
    })

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
    await postConfirmedAttestation(bindingId, {
      install_userop_hash: result.install_userop_hash,
      tx_hash: receipt.tx_hash,
      block_number: receipt.block_number,
    })

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

function readBindingId(el) {
  if (!el) return null
  // The button declares its binding id via `data-binding-id`.
  // The hook itself may be on a wrapper element — check both.
  const direct = el.dataset && el.dataset.bindingId
  if (direct) return direct
  const inner = el.querySelector && el.querySelector("[data-binding-id]")
  return inner ? inner.dataset.bindingId : null
}
