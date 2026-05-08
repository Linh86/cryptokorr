defmodule BankWeb.AgentLive.WalletCard do
  @moduledoc """
  Section 1 — Wallet status. Render-only function component.

  All state (wallet status, address, balance) lives in
  `BankWeb.AgentLive`. Events fire on the parent LiveView.

  Phase 2 wiring: the card root carries `phx-hook="WalletConnect"`,
  and the Connect button carries `id="wallet-connect-btn"` so the
  EIP-1193 JS hook can intercept clicks and drive the connect +
  challenge + verify dance against `Bank.WalletBindings`.
  """
  use Phoenix.Component

  import BankWeb.AgentComponents

  attr :wallet, :atom, required: true, doc: ":disconnected | :wrong_network | :connected"
  attr :address, :string, default: nil
  attr :balance, :any, required: true

  def wallet_card(assigns) do
    ~H"""
    <div id="wallet-card" phx-hook="WalletConnect">
      <.card>
        <.card_header eyebrow="01 — Wallet" title="Wallet status">
          <:right>
            <.status_pill kind={pill_kind(@wallet)} />
          </:right>
        </.card_header>
        <div :if={@wallet == :disconnected} class="card__body">
          <p class="lede">
            Connect a browser wallet to begin. The agent never holds keys — it only acts under
            a permission you install.
          </p>
          <div class="card__actions">
            <button id="wallet-connect-btn" type="button" class="btn btn--primary">
              <.cb_icon name="wallet" size={14} /> Connect wallet
            </button>
            <span class="hint">MetaMask, Rabby, Coinbase Wallet</span>
          </div>
        </div>
        <div :if={@wallet == :wrong_network} class="card__body">
          <p class="lede">
            Your wallet is on a different network. CryptoBank only operates on Base Sepolia
            during private alpha.
          </p>
          <div class="card__actions">
            <span class="hint">
              Switch your wallet to Base Sepolia (chain 84532). The page updates automatically.
            </span>
          </div>
        </div>
        <div :if={@wallet == :connected} class="card__body card__body--rows">
          <.data_row label="Address">
            <span class="mono">{@address}</span>
            <a class="link-mute" href="#">
              View on BaseScan <.cb_icon name="external" size={12} />
            </a>
          </.data_row>
          <.data_row label="Network">
            Base Sepolia · chain 84532
          </.data_row>
          <.data_row label="USDC balance">
            <span class="mono tnum">{format_usdc(@balance)}</span>
          </.data_row>
        </div>
      </.card>
    </div>
    """
  end

  defp pill_kind(:connected), do: "connected"
  defp pill_kind(:wrong_network), do: "wrong-network"
  defp pill_kind(_), do: "disconnected"

  defp format_usdc(%Decimal{} = d) do
    rounded = Decimal.round(d, 2) |> Decimal.to_string(:normal)
    "#{rounded} USDC"
  end

  defp format_usdc(n) when is_number(n),
    do: :erlang.float_to_binary(n / 1, decimals: 2) <> " USDC"

  defp format_usdc(_), do: "— USDC"
end
