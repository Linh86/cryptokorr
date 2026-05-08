// Wallet connect LiveView hook (EIP-1193 + EIP-6963).
//
// Attached to `#wallet-card`. The hook:
//
//   * Discovers all browser-injected wallet providers via EIP-6963
//     (`eip6963:announceProvider` events). Pushes the list to the
//     LiveView so the picker can render when multiple wallets are
//     installed (e.g. Trust + MetaMask both fight over `window.ethereum`).
//   * Delegates clicks on `#wallet-connect-btn` to start the flow with
//     the legacy `window.ethereum` provider — used when only one wallet
//     is announced.
//   * Listens for `wallet_connect:select_provider` events pushed FROM
//     the server when the user picks a wallet from the picker — that
//     selects the matching provider and immediately starts connect.
//   * Listens for the EIP-1193 `accountsChanged` and `chainChanged`
//     events so the LiveView reflects the wallet's live state.
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

// Base Sepolia is the only enabled chain for the MVP wallet binding
// flow. Base mainnet (8453) must surface as wrong-chain so the operator
// switches before we ever issue a binding challenge.
const SUPPORTED_CHAIN_IDS = [84_532]

// EIP-6963 announce window — wallets fire `eip6963:announceProvider`
// in response to our `eip6963:requestProvider`. Most fire synchronously
// or within a tick, but we wait 250ms for slower wallets / extension
// startup races.
const EIP6963_DISCOVER_MS = 250

export const WalletConnect = {
  mounted() {
    this.handleClick = this.handleClick.bind(this)
    this.handleAccountsChanged = this.handleAccountsChanged.bind(this)
    this.handleChainChanged = this.handleChainChanged.bind(this)
    this.handleEip6963Announce = this.handleEip6963Announce.bind(this)

    // EIP-6963 provider registry. Map keyed by `info.uuid` → { info, provider }.
    this.providers = new Map()
    // The provider the user picked from the LiveView picker (or the
    // single discovered provider). Falls back to `window.ethereum`
    // for legacy single-injection wallets that don't speak EIP-6963.
    this.selectedProvider = null
    // The provider we currently have `accountsChanged` / `chainChanged`
    // listeners on, so we can detach them on `destroyed()` or before
    // re-attaching to a different selection.
    this.activeListenerProvider = null

    this.el.addEventListener("click", this.handleClick)
    window.addEventListener("eip6963:announceProvider", this.handleEip6963Announce)

    // Server-pushed binding challenge — sign it and push the signature
    // back to the LiveView for verification.
    this.handleEvent("wallet_connect:challenge", (payload) => this.signChallenge(payload))

    // Server pushes this when the user clicks a wallet entry in the
    // multi-wallet picker. Payload `{ uuid }` matches an info.uuid we
    // already announced via `wallet_connect:providers_discovered`.
    this.handleEvent("wallet_connect:use_provider", (payload) => {
      const uuid = payload && payload.uuid
      const entry = this.providers.get(uuid)
      if (!entry) {
        this.pushEvent("wallet_connect:error", {message: `Unknown wallet: ${uuid}`})
        return
      }
      this.selectedProvider = entry.provider
      this.attachListenersTo(entry.provider)
      this.beginConnect()
    })

    // Kick off EIP-6963 discovery. Wallets that already announced before
    // the listener attached miss the event; the spec requires them to
    // re-announce when we dispatch the request below.
    window.dispatchEvent(new Event("eip6963:requestProvider"))

    setTimeout(() => this.publishProviders(), EIP6963_DISCOVER_MS)

    // Attach legacy listeners as a fallback so single-injection wallets
    // (no EIP-6963) still surface accountsChanged / chainChanged.
    if (this.providers.size === 0 && window.ethereum) {
      this.attachListenersTo(window.ethereum)
    }
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
    window.removeEventListener("eip6963:announceProvider", this.handleEip6963Announce)
    this.detachListeners()
  },

  // EIP-6963 provider announcement. Each event represents one wallet
  // installed in the browser; the spec says any number of wallets can
  // coexist. We index by uuid (stable per browser session) so the
  // server-side picker can later say "use this uuid".
  handleEip6963Announce(event) {
    const detail = event && event.detail
    if (!detail || !detail.info || !detail.provider) return
    const info = detail.info
    if (!info.uuid) return
    this.providers.set(info.uuid, {info, provider: detail.provider})
    // Re-publish the list so the LiveView picker stays in sync as more
    // wallets announce (e.g. extension that woke up late).
    this.publishProviders()
  },

  publishProviders() {
    const list = []
    for (const {info} of this.providers.values()) {
      list.push({uuid: info.uuid, name: info.name, rdns: info.rdns, icon: info.icon})
    }
    this.pushEvent("wallet_connect:providers_discovered", {providers: list})
  },

  handleClick(event) {
    if (!event.target.closest("#wallet-connect-btn")) return
    event.preventDefault()
    // The single-button path uses the first announced provider, OR
    // the legacy `window.ethereum` if no EIP-6963 wallets answered.
    if (!this.selectedProvider) {
      this.selectedProvider = this.firstAnnouncedProvider() || window.ethereum
      if (this.selectedProvider) this.attachListenersTo(this.selectedProvider)
    }
    this.beginConnect()
  },

  firstAnnouncedProvider() {
    for (const {provider} of this.providers.values()) return provider
    return null
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

  // Returns the provider the user picked, falling back to whichever
  // wallet won `window.ethereum`. Always check non-null before use —
  // e.g. an operator with NO wallet at all gets `:unavailable`.
  provider() {
    return this.selectedProvider || window.ethereum || null
  },

  async beginConnect() {
    const provider = this.provider()
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
    if (!accounts || accounts.length === 0) {
      this.pushEvent("wallet_connect:disconnected", {})
      return
    }
    this.refreshState(accounts[0])
  },

  handleChainChanged(_chainIdHex) {
    const provider = this.provider()
    if (!provider) return

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
    const provider = this.provider()
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

    const provider = this.provider()
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
