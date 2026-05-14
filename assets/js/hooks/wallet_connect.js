// Wallet connect LiveView hook (EIP-1193 + EIP-6963).
//
// Attached to `#wallet-card`. The hook:
//
//   * Boots the shared EIP-6963 wallet registry (see
//     `assets/js/wallet_provider.js`) so this hook AND the sibling
//     `SessionPermissionInstall` hook always read the same selected
//     provider — no more drift where the user picks MetaMask but the
//     install flow keeps asking Trust.
//   * Pushes the announced wallet list to the LiveView so the picker
//     can render when multiple wallets are installed.
//   * Delegates clicks on `#wallet-connect-btn` to start the connect
//     flow with the active provider (selected wallet, or fallback).
//   * Listens for `wallet_connect:use_provider` server events (fired
//     after the user clicks an entry in the multi-wallet picker) and
//     sets the selection in the shared registry, then immediately
//     starts the connect flow.
//   * Listens for the EIP-1193 `accountsChanged` and `chainChanged`
//     events on the active provider so the LiveView reflects live
//     state.
//
// Two interactions touch the wallet, both gated behind explicit user
// actions:
//
//   * `eth_requestAccounts` — runs after a click on `#wallet-connect-btn`
//     (or a wallet-picker entry) and prompts the wallet to expose accounts.
//   * `personal_sign` — runs only when the server pushes a
//     `wallet_connect:challenge` event in response to a connected
//     wallet, and only signs the EIP-191 binding message that the
//     server issued. The message is server-issued, short-lived, and
//     single-use; the hook does not construct it.
//
// All other reads are passive: `eth_accounts` and `eth_chainId`. The
// hook never broadcasts a transaction, never handles private keys,
// and never invokes any other signing JSON-RPC method. Those
// invariants are pinned by `wallet_connect_hook_safety_test.exs`.

import {
  startDiscovery,
  subscribe,
  listInfos,
  selectByUuid,
  getProvider,
  autoSelectActive,
} from "../wallet_provider.js"

// Base Sepolia is the only enabled chain for the MVP wallet binding
// flow. Base mainnet (8453) must surface as wrong-chain so the operator
// switches before we ever issue a binding challenge.
const SUPPORTED_CHAIN_IDS = [84_532]

export const WalletConnect = {
  mounted() {
    this.handleClick = this.handleClick.bind(this)
    this.handleAccountsChanged = this.handleAccountsChanged.bind(this)
    this.handleChainChanged = this.handleChainChanged.bind(this)

    // The provider we currently have `accountsChanged` / `chainChanged`
    // listeners on. We re-attach whenever the shared registry tells us
    // the selection changed.
    this.activeListenerProvider = null

    this.el.addEventListener("click", this.handleClick)

    // Server-pushed binding challenge — sign it and push the signature
    // back to the LiveView for verification.
    this.handleEvent("wallet_connect:challenge", (payload) => this.signChallenge(payload))

    // EIP-2255 dApp-side revoke of MetaMask's "Connected sites" entry
    // for this origin. The server pushes this after a successful
    // `wallet_connect:disconnect` handler so the wallet's own
    // permissions panel reflects the same state our DB just wrote.
    // Without this MetaMask keeps `localhost:4000` (or whatever the
    // production origin is) in its connected-sites list, the user
    // tries to disconnect from MM and nothing happens, and clicking
    // Connect again silently re-uses the cached account instead of
    // re-prompting. `wallet_revokePermissions` is a read-only,
    // signing-free RPC — it removes site permissions, never produces
    // a signature, never touches funds; the hook safety test
    // allowlists it on those grounds.
    this.handleEvent("wallet_connect:revoke_permissions", () => this.revokePermissions())

    // Server pushes this when the user clicks a wallet entry in the
    // multi-wallet picker. Sets the registry's selection and runs
    // `beginConnect` against that provider only.
    this.handleEvent("wallet_connect:use_provider", (payload) => {
      const uuid = payload && payload.uuid
      const provider = selectByUuid(uuid)
      if (!provider) {
        this.pushEvent("wallet_connect:error", {message: `Unknown wallet: ${uuid}`})
        return
      }
      this.beginConnect()
    })

    // Boot EIP-6963 discovery (idempotent across hook lifecycles).
    startDiscovery()

    // Subscribe to registry changes — the picker stays in sync with
    // late wallet announcements, and listener attachment follows the
    // active provider. Every announcement triggers an
    // `autoSelectActive` retry: if no wallet was persisted from a
    // previous session, scan the announced providers for one that
    // already has authorized accounts (the user previously connected
    // it to this origin). Stops the install flow from defaulting to
    // whichever wallet won the `window.ethereum` last-write race
    // after a page reload. `autoSelectActive` is idempotent — once a
    // selection lands, subsequent calls no-op.
    this.unsubscribe = subscribe((infos, selected) => {
      this.pushEvent("wallet_connect:providers_discovered", {providers: infos})
      const provider = getProvider()
      if (provider) {
        this.attachListenersTo(provider)
        // On every re-attach (initial mount + after auto-select),
        // probe the provider's exposed state and push it to the
        // server so the UI never derives "Connected" purely from
        // a stale DB binding when MetaMask has dropped the origin.
        this.pushBrowserStatus(provider).catch(() => {})
      } else {
        // No provider yet — surface explicit `:no_provider` browser
        // state so the LiveView can short-circuit Install UX before
        // any envelope/UserOp request fires.
        this.pushEvent("wallet_connect:browser_status", {
          status: "no_provider",
          accounts: [],
          chain_id: null,
          permissions_count: 0,
        })
      }

      if (!selected && infos.length > 0) {
        autoSelectActive().catch(() => {})
      }
    })
  },

  // Read the active provider's live state (accounts + chain + EIP-2255
  // permissions) and push a single `browser_status` event the
  // LiveView can use as the **source of truth** for "is MetaMask
  // actually exposing an account for this origin right now?". The
  // server still keeps the DB `wallet_binding` row for audit/replay
  // — the row by itself NEVER drives the "Connected" pill. The pill
  // requires this probe to confirm the live provider state matches
  // the bound address.
  //
  // Signing-free: only reads `eth_accounts`, `eth_chainId`, and
  // `wallet_getPermissions`. None of these prompt the wallet popup
  // or move funds. The hook safety test allowlists all three.
  async pushBrowserStatus(provider) {
    let accounts = []
    let chainIdHex = null
    let permissionsCount = 0

    try {
      accounts = await provider.request({method: "eth_accounts"})
    } catch (_e) {
      accounts = []
    }

    try {
      chainIdHex = await provider.request({method: "eth_chainId"})
    } catch (_e) {
      chainIdHex = null
    }

    try {
      const perms = await provider.request({method: "wallet_getPermissions"})
      permissionsCount = Array.isArray(perms) ? perms.length : 0
    } catch (_e) {
      // Older / non-MM providers may not implement EIP-2255. Treat
      // permissions_count as "unknown" by leaving it at 0; the
      // accounts probe is the authoritative signal.
      permissionsCount = 0
    }

    const chainId =
      typeof chainIdHex === "string" ? parseInt(chainIdHex, 16) : null

    this.pushEvent("wallet_connect:browser_status", {
      status:
        Array.isArray(accounts) && accounts.length > 0
          ? "exposed_account"
          : "no_account",
      accounts: Array.isArray(accounts) ? accounts : [],
      chain_id: chainId,
      permissions_count: permissionsCount,
    })
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
    this.detachListeners()
    if (typeof this.unsubscribe === "function") this.unsubscribe()
  },

  handleClick(event) {
    if (!event.target.closest("#wallet-connect-btn")) return
    event.preventDefault()
    this.beginConnect()
  },

  attachListenersTo(provider) {
    if (provider === this.activeListenerProvider) return
    this.detachListeners()
    if (provider && typeof provider.on === "function") {
      provider.on("accountsChanged", this.handleAccountsChanged)
      provider.on("chainChanged", this.handleChainChanged)
      this.activeListenerProvider = provider
    }
  },

  detachListeners() {
    const provider = this.activeListenerProvider
    if (provider && typeof provider.removeListener === "function") {
      provider.removeListener("accountsChanged", this.handleAccountsChanged)
      provider.removeListener("chainChanged", this.handleChainChanged)
    }
    this.activeListenerProvider = null
  },

  async beginConnect() {
    const provider = getProvider()
    if (!provider) {
      this.pushEvent("wallet_connect:unavailable", {reason: "no_provider"})
      return
    }

    this.pushEvent("wallet_connect:connecting", {})

    try {
      const accounts = await provider.request({method: "eth_requestAccounts"})

      if (!accounts || accounts.length === 0) {
        this.pushEvent("wallet_connect:cancelled", {})
        return
      }

      const chainIdHex = await provider.request({method: "eth_chainId"})
      const chainId = parseInt(chainIdHex, 16)
      const account = accounts[0]

      if (!SUPPORTED_CHAIN_IDS.includes(chainId)) {
        this.pushEvent("wallet_connect:wrong_chain", {account, chain_id: chainId})
        return
      }

      this.pushEvent("wallet_connect:connected", {account, chain_id: chainId})
    } catch (err) {
      this.pushEvent("wallet_connect:error", {message: err?.message || String(err)})
    }
  },

  handleAccountsChanged(accounts) {
    // Every account-state transition refreshes the SERVER-VISIBLE
    // browser status FIRST. The LiveView uses that to gate
    // `:wallet == :connected` (and therefore Install permission)
    // before we send any binding/install event downstream. Without
    // this, a tab that's been open since before the user toggled
    // MetaMask's "Disconnect this site" would keep claiming
    // Connected on the strength of a stale DB binding row.
    const provider = getProvider()
    if (provider) this.pushBrowserStatus(provider).catch(() => {})

    if (!accounts || accounts.length === 0) {
      this.pushEvent("wallet_connect:disconnected", {})
      return
    }
    this.refreshState(accounts[0])
  },

  handleChainChanged(_chainIdHex) {
    const provider = getProvider()
    if (!provider) return

    // Push the latest browser status so the LiveView sees the new
    // chain id immediately — even if accounts didn't change. The
    // `:wrong_chain` derived state needs this.
    this.pushBrowserStatus(provider).catch(() => {})

    provider
      .request({method: "eth_accounts"})
      .then((accounts) => {
        if (!accounts || accounts.length === 0) {
          this.pushEvent("wallet_connect:disconnected", {})
          return
        }
        this.refreshState(accounts[0])
      })
      .catch((err) => {
        this.pushEvent("wallet_connect:error", {message: err?.message || String(err)})
      })
  },

  async refreshState(account) {
    const provider = getProvider()
    if (!provider) return

    try {
      const chainIdHex = await provider.request({method: "eth_chainId"})
      const chainId = parseInt(chainIdHex, 16)

      if (!SUPPORTED_CHAIN_IDS.includes(chainId)) {
        this.pushEvent("wallet_connect:wrong_chain", {account, chain_id: chainId})
        return
      }

      this.pushEvent("wallet_connect:connected", {account, chain_id: chainId})
    } catch (err) {
      this.pushEvent("wallet_connect:error", {message: err?.message || String(err)})
    }
  },

  // EIP-2255 — ask the wallet to drop this origin from its
  // connected-sites list. Best-effort: older wallets and providers
  // that don't implement EIP-2255 reject with method-not-found,
  // which is fine — the server-side binding revoke already
  // happened by the time we get here, and the UI is already in
  // "Not connected" state. Logs the rejection at debug but never
  // surfaces an error: failing to revoke a wallet-side permission
  // must not block the dApp-side disconnect we already committed.
  async revokePermissions() {
    const provider = getProvider()
    if (!provider) return

    try {
      await provider.request({
        method: "wallet_revokePermissions",
        params: [{eth_accounts: {}}],
      })
    } catch (err) {
      // -32601 = method not found (older wallets); 4001 = user rejected.
      // Either way the dApp-side disconnect is already done; this is
      // only a wallet-UI sync nicety.
      if (typeof console !== "undefined" && console.debug) {
        console.debug(
          "wallet_revokePermissions failed (non-fatal):",
          err && (err.message || err.code) || err,
        )
      }
    }
  },

  // Sign a server-issued EIP-191 challenge for wallet identity binding.
  // The hook does not build the message — it only forwards what the
  // server pushed. The server alone owns the nonce, expiry, and shape.
  async signChallenge(payload) {
    const challengeId = payload && payload.challenge_id
    const message = payload && payload.message
    const account = payload && payload.address

    if (!challengeId || !message || !account) {
      this.pushEvent("wallet_connect:verify_error", {
        challenge_id: challengeId || null,
        reason: "invalid_challenge",
      })
      return
    }

    const provider = getProvider()
    if (!provider) {
      this.pushEvent("wallet_connect:verify_error", {
        challenge_id: challengeId,
        reason: "no_provider",
      })
      return
    }

    try {
      const signature = await provider.request({
        method: "personal_sign",
        params: [message, account],
      })
      this.pushEvent("wallet_connect:verify", {
        challenge_id: challengeId,
        signature,
      })
    } catch (err) {
      this.pushEvent("wallet_connect:verify_error", {
        challenge_id: challengeId,
        reason: err?.message || String(err),
      })
    }
  },
}
