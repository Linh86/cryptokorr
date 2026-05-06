// Browser-driven ZeroDev session permission install hook (#473).
//
// Drives the operator-facing flow for signing the session permission
// install in the browser. Replaces the server-driven dispatch path
// (`phx-click="install_session_permission"`) with a flow where the
// operator's wallet — not Phoenix or the chain adapter — is the
// signer of record.
//
// ## State machine
//
//   idle
//     ── click #session-permission-browser-install-btn
//     ──→ awaiting_signature  (chain checked; scope summary shown)
//     ── personal_sign over server-issued scope-bound message
//     ──→ signing             (wallet prompt open)
//     ── wallet returned signature
//     ──→ submitted           (signature pushed back to LiveView)
//     ── synthesized confirmation (real bundler poll deferred to #472)
//     ──→ confirmed
//
//   On any error: ──→ failed (with structured reason)
//
// ## Hard safety boundaries (pinned by the source-hygiene test)
//
//   * Base Sepolia (84532) ONLY. Any other chain pushes
//     `session_permission_install:wrong_chain` — the hook does
//     not attempt to switch chains for the operator.
//   * No private keys, no mnemonic, no seed phrase.
//   * No transaction broadcast methods (`eth_sendTransaction` etc.).
//   * Only `personal_sign` is allowed for signing — typed-data and
//     legacy `eth_sign` are forbidden so the hook can never be
//     talked into signing a structured payload it didn't author.
//   * The scope-bound message is server-issued via a
//     `session_permission_install:scope_message` push event. The
//     hook does not build the message (Phoenix is the source of
//     truth for the canonical scope summary the operator
//     consents to).
//   * No unlimited approval, no arbitrary calldata, no
//     borrow/leverage/withdraw authority — these are all on
//     Phoenix's `Bank.SessionPermissions.Scope.default/0` denied
//     list and the server-issued message embeds the scope
//     summary verbatim.
//   * Bundler / RPC integration is intentionally stubbed in this
//     scaffold. The real ZeroDev SDK + bundler wiring lands once
//     #472's design note pins the package set; for now, the hook
//     synthesizes the `submitted → confirmed` transition so the
//     operator-facing UI states are exercisable end-to-end.

const SUPPORTED_CHAIN_IDS = [84_532]

// Synthesized confirmation delay (ms). Stand-in for the real
// bundler `waitForUserOperationReceipt` poll — keep small enough
// that the operator sees the transition cleanly without staring
// at the spinner. The real integration replaces this with the
// bundler's receipt promise.
const SYNTHETIC_CONFIRMATION_MS = 1500

export const SessionPermissionInstall = {
  mounted() {
    this.handleClick = this.handleClick.bind(this)
    this.el.addEventListener("click", this.handleClick)

    // Phoenix pushes the canonical scope-bound message after
    // accepting the install request. The hook signs that message
    // and never builds one of its own.
    this.handleEvent(
      "session_permission_install:scope_message",
      (payload) => this.signScopeMessage(payload),
    )
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
  },

  handleClick(event) {
    if (!event.target.closest("#session-permission-browser-install-btn")) return
    event.preventDefault()
    this.beginInstall()
  },

  async beginInstall() {
    const provider = window.ethereum
    if (!provider) {
      this.pushEvent("session_permission_install:failed", {
        reason: "no_provider",
      })
      return
    }

    try {
      const chainIdHex = await provider.request({method: "eth_chainId"})
      const chainId = parseInt(chainIdHex, 16)

      if (!SUPPORTED_CHAIN_IDS.includes(chainId)) {
        this.pushEvent("session_permission_install:wrong_chain", {
          chain_id: chainId,
        })
        return
      }

      // Ask Phoenix for the canonical scope-bound message. Phoenix
      // responds via `session_permission_install:scope_message`
      // (handled by `signScopeMessage` below).
      this.pushEvent("session_permission_install:requested", {
        chain_id: chainId,
      })
    } catch (err) {
      this.pushEvent("session_permission_install:failed", {
        reason: classifyError(err),
        message: err && err.message ? err.message : String(err),
      })
    }
  },

  async signScopeMessage(payload) {
    const message = payload && payload.message
    const account = payload && payload.address

    if (!message || !account) {
      this.pushEvent("session_permission_install:failed", {
        reason: "invalid_scope_message",
      })
      return
    }

    const provider = window.ethereum
    if (!provider) {
      this.pushEvent("session_permission_install:failed", {
        reason: "no_provider",
      })
      return
    }

    try {
      const signature = await provider.request({
        method: "personal_sign",
        params: [message, account],
      })

      this.pushEvent("session_permission_install:signed", {
        signature,
      })

      // Stand-in for the bundler `waitForUserOperationReceipt`
      // poll. Real ZeroDev SDK integration replaces this with
      // the actual UserOp submission + receipt. Documented in
      // the moduledoc above.
      window.setTimeout(() => {
        this.pushEvent("session_permission_install:confirmed", {})
      }, SYNTHETIC_CONFIRMATION_MS)
    } catch (err) {
      this.pushEvent("session_permission_install:failed", {
        reason: classifyError(err),
        message: err && err.message ? err.message : String(err),
      })
    }
  },
}

// Map provider errors to a fixed allowlist of reason atoms so
// Phoenix renders stable failure copy. EIP-1193 codes:
//   4001 — user rejected request
//   4100 — unauthorized
//   4200 — unsupported method
//   -32000 — generic JSON-RPC error (often "insufficient funds" / bundler reject)
function classifyError(err) {
  const code = err && typeof err.code === "number" ? err.code : null
  const message = err && err.message ? String(err.message).toLowerCase() : ""

  if (code === 4001) return "user_rejected"
  if (message.includes("user rejected") || message.includes("user denied")) {
    return "user_rejected"
  }
  if (message.includes("insufficient funds") || message.includes("insufficient gas")) {
    return "insufficient_gas"
  }
  if (message.includes("bundler") || code === -32000) return "bundler_rejected"
  if (message.includes("network") || message.includes("fetch")) return "network_error"
  return "unknown_error"
}
