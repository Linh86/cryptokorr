// Wallet connect LiveView hook (scaffold).
//
// Attach to the "Connect wallet" button on the control tower with
// phx-hook="WalletConnect". On click the hook:
//   1. Detects an EIP-1193 wallet provider (window.ethereum).
//   2. Requests the user's accounts.
//   3. Verifies the wallet is on a supported chain (Base / Base Sepolia).
//   4. Asks the wallet to sign a delegation grant payload.
//   5. Pushes the signed payload back to the server as a
//      `wallet_connect:request` event.
//
// Steps 4 + 5 are gated behind the real wallet SDK integration
// (wagmi/viem/WalletConnect) — see docs/wallet-connect.md for the
// full plan. Until that lands, the hook returns {status: "unavailable"}
// and the LiveView keeps the button disabled with a tooltip.

const SUPPORTED_CHAIN_IDS = [8453, 84532] // Base mainnet, Base Sepolia

export const WalletConnect = {
  mounted() {
    this.el.addEventListener("click", (event) => {
      event.preventDefault()
      this.beginConnect()
    })
  },

  async beginConnect() {
    const provider = window.ethereum
    if (!provider) {
      this.pushEvent("wallet_connect:unavailable", {reason: "no_provider"})
      return
    }

    try {
      const accounts = await provider.request({method: "eth_requestAccounts"})
      const chainIdHex = await provider.request({method: "eth_chainId"})
      const chainId = parseInt(chainIdHex, 16)

      if (!SUPPORTED_CHAIN_IDS.includes(chainId)) {
        this.pushEvent("wallet_connect:wrong_chain", {chainId})
        return
      }

      if (!accounts || accounts.length === 0) {
        this.pushEvent("wallet_connect:cancelled", {})
        return
      }

      // TODO(v1.1): build and sign the delegation grant payload via
      // the chosen wallet SDK (wagmi/viem). The signed result goes
      // to the server with:
      //
      //   this.pushEvent("wallet_connect:request", {
      //     account: accounts[0],
      //     chain_id: chainId,
      //     delegation_payload: <signed-payload>,
      //   })
      //
      // For now the scaffolding reports back so operators see the
      // signal without a real signing flow.
      this.pushEvent("wallet_connect:stub", {
        account: accounts[0],
        chain_id: chainId,
      })
    } catch (err) {
      this.pushEvent("wallet_connect:error", {message: err?.message || String(err)})
    }
  },
}
