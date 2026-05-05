// Wallet connect LiveView hook (EIP-1193).
//
// Attached to `#wallet-status-card` so it persists across re-renders. The
// hook delegates clicks on `#wallet-connect-btn` to start the flow, and
// listens for the EIP-1193 `accountsChanged` and `chainChanged` events so
// the LiveView reflects the wallet's live state.
//
// The hook only reads from the wallet:
//
//   * `eth_requestAccounts` — gated behind a user click, prompts the
//     wallet to expose accounts.
//   * `eth_accounts` — passive read after `accountsChanged`.
//   * `eth_chainId` — passive read of the active network.
//
// It never asks the wallet to sign, broadcast, or expose key material.
// Signing + delegation grants are out of scope for #168 and land with
// the SDK + adapter integration tracked in `docs/wallet-connect.md`.

const SUPPORTED_CHAIN_IDS = [8453, 84532] // Base mainnet, Base Sepolia

export const WalletConnect = {
  mounted() {
    this.handleClick = this.handleClick.bind(this)
    this.handleAccountsChanged = this.handleAccountsChanged.bind(this)
    this.handleChainChanged = this.handleChainChanged.bind(this)

    this.el.addEventListener("click", this.handleClick)

    const provider = window.ethereum
    if (provider && typeof provider.on === "function") {
      provider.on("accountsChanged", this.handleAccountsChanged)
      provider.on("chainChanged", this.handleChainChanged)
    }
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick)

    const provider = window.ethereum
    if (provider && typeof provider.removeListener === "function") {
      provider.removeListener("accountsChanged", this.handleAccountsChanged)
      provider.removeListener("chainChanged", this.handleChainChanged)
    }
  },

  handleClick(event) {
    if (!event.target.closest("#wallet-connect-btn")) return
    event.preventDefault()
    this.beginConnect()
  },

  async beginConnect() {
    const provider = window.ethereum
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
    const provider = window.ethereum
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
    const provider = window.ethereum
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
}
