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

  attr :wallet, :atom,
    required: true,
    doc:
      ":disconnected | :connecting | :wrong_network | :connected | " <>
        ":browser_disconnected | :wrong_chain | :account_mismatch"

  attr :address, :string, default: nil
  attr :balance, :any, required: true

  attr :providers, :list,
    default: [],
    doc: "EIP-6963 announced providers (each %{\"uuid\", \"name\", \"rdns\", \"icon\"})"

  attr :browser_state, :map,
    default: %{status: :unknown, accounts: [], chain_id: nil, permissions_count: 0},
    doc:
      "Live browser-provider snapshot pushed by the WalletConnect JS hook. " <>
        "Used to render reason copy under the wallet-stale states " <>
        "(:browser_disconnected / :wrong_chain / :account_mismatch). " <>
        "The pill is driven from :wallet, not from here."

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
          <%!--
            Multi-wallet picker (EIP-6963). When more than one browser
            wallet announces itself (e.g. Trust + MetaMask both fight
            over `window.ethereum`), pick which one to use explicitly
            instead of letting whichever wallet won the last-write
            race silently hijack the connect flow.
          --%>
          <div :if={length(@providers) > 1} class="cb-wallet-picker">
            <div class="cb-wallet-picker__head">Choose a wallet</div>
            <ul class="cb-wallet-picker__list">
              <li :for={provider <- @providers}>
                <button
                  type="button"
                  class="cb-wallet-picker__btn"
                  phx-click="wallet_connect:select_provider"
                  phx-value-uuid={provider["uuid"]}
                >
                  <img
                    :if={provider["icon"]}
                    src={provider["icon"]}
                    alt=""
                    class="cb-wallet-picker__icon"
                    width="20"
                    height="20"
                  />
                  <span class="cb-wallet-picker__name">{provider["name"]}</span>
                </button>
              </li>
            </ul>
          </div>
          <div :if={length(@providers) <= 1} class="card__actions">
            <button id="wallet-connect-btn" type="button" class="btn btn--primary">
              <.cb_icon name="wallet" size={14} />
              <%= case @providers do %>
                <% [%{"name" => name}] -> %>
                  Connect {name}
                <% _ -> %>
                  Connect wallet
              <% end %>
            </button>
            <span class="hint">MetaMask, Rabby, Coinbase Wallet</span>
          </div>
        </div>
        <%!--
          `:connecting` — the JS hook called `eth_requestAccounts` and is
          waiting on the wallet popup. Render an explicit "check your
          wallet popup" affordance so the user knows where to look. If
          the popup is dismissed or another popup hijacks focus, the
          hook surfaces `:cancelled` / `:error` and we fall back to
          `:disconnected` (with the Connect button reappearing).
        --%>
        <div :if={@wallet == :connecting} class="card__body">
          <p class="lede">
            Open your wallet to approve the connection. Check the MetaMask /
            Rabby / Coinbase Wallet icon in your browser toolbar — the popup
            may be queued behind another window.
          </p>
          <div class="card__actions">
            <div class="installing-row">
              <div class="spinner"></div>
              <span>Waiting for wallet approval…</span>
            </div>
            <button id="wallet-connect-btn" type="button" class="link-btn">
              Cancel and retry
            </button>
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
          <%!--
            Explicit Disconnect CTA. MetaMask's "Disconnect this site"
            does NOT reliably emit `accountsChanged: []` to dApps in
            current versions, so a server-driven disconnect handler is
            the safest path. Pushes `wallet_connect:disconnect`, which
            `BankWeb.AgentLive` routes to
            `revoke_active_binding(:operator_requested)` — clears the
            DB binding row, fail-closes the permission card to
            `:not_installed`, and rolls the hero copy back to "Connect
            a wallet to begin." on the next render.
          --%>
          <div class="card__actions" style="padding-top: 12px;">
            <button
              id="wallet-disconnect-btn"
              type="button"
              class="btn btn--ghost-danger"
              phx-click="wallet_connect:disconnect"
            >
              <.cb_icon name="x" size={14} /> Disconnect wallet
            </button>
          </div>
        </div>
        <%!--
          `:browser_disconnected` — server has a verified binding row
          but the live browser provider currently exposes no account
          for this origin. Two main causes:
            * Operator clicked "Disconnect this site" in the wallet's
              own panel (EIP-2255 site revoke). The DB row survives
              for audit, but the wallet won't sign anything until the
              site is re-permissioned.
            * The page lost its provider mid-session (extension
              reload, tab restore from a cold browser, multi-wallet
              race lost MetaMask).
          UI must NOT call this "Connected"; the Install button is
          disabled by the permission card under the same gate.
        --%>
        <div :if={@wallet == :browser_disconnected} class="card__body card__body--rows">
          <p class="lede">
            Your browser wallet is no longer exposing
            <span :if={@address} class="mono">{@address}</span>
            for this site. Reconnect to continue, or disconnect to clear the saved binding.
          </p>
          <.data_row :if={@address} label="Bound address">
            <span class="mono">{@address}</span>
          </.data_row>
          <.data_row label="Network">
            Base Sepolia · chain 84532
          </.data_row>
          <div class="card__actions" style="padding-top: 12px;">
            <button id="wallet-connect-btn" type="button" class="btn btn--primary">
              <.cb_icon name="wallet" size={14} /> Reconnect wallet
            </button>
            <button
              id="wallet-disconnect-btn"
              type="button"
              class="btn btn--ghost-danger"
              phx-click="wallet_connect:disconnect"
            >
              <.cb_icon name="x" size={14} /> Disconnect
            </button>
          </div>
        </div>
        <%!--
          `:wrong_chain` — binding verified, browser exposes the right
          account, but the wallet's active network is not Base Sepolia.
          Tell the operator exactly which chain id is active and what
          to switch to. We do not auto-prompt `wallet_switchEthereumChain`
          here — that's a write that would surface in the wallet popup
          and we want every wallet-popup interaction to come from an
          explicit user click, not page mount.
        --%>
        <div :if={@wallet == :wrong_chain} class="card__body card__body--rows">
          <p class="lede">
            Your wallet is on chain
            <span :if={@browser_state && @browser_state.chain_id} class="mono">
              {@browser_state.chain_id}
            </span>
            <span :if={!@browser_state || is_nil(@browser_state.chain_id)}>
              another network
            </span>
            . Switch to Base Sepolia (chain 84532) to continue.
          </p>
          <.data_row :if={@address} label="Bound address">
            <span class="mono">{@address}</span>
          </.data_row>
          <div class="card__actions" style="padding-top: 12px;">
            <span class="hint">
              Open your wallet's network picker and select Base Sepolia. The page updates automatically.
            </span>
            <button
              id="wallet-disconnect-btn"
              type="button"
              class="btn btn--ghost-danger"
              phx-click="wallet_connect:disconnect"
            >
              <.cb_icon name="x" size={14} /> Disconnect
            </button>
          </div>
        </div>
        <%!--
          `:account_mismatch` — binding verified, browser exposes an
          account, but it's not the bound one. The user likely
          switched MetaMask's selected account after binding. Either
          they switch back, or they rebind with the new account.
        --%>
        <div :if={@wallet == :account_mismatch} class="card__body card__body--rows">
          <p class="lede">
            Your wallet is exposing a different account than the one bound to this workspace.
            Switch back in your wallet, or reconnect to bind the new account.
          </p>
          <.data_row :if={@address} label="Bound address">
            <span class="mono">{@address}</span>
          </.data_row>
          <.data_row :if={browser_first_account(@browser_state)} label="Exposed account">
            <span class="mono">{short_address(browser_first_account(@browser_state))}</span>
          </.data_row>
          <div class="card__actions" style="padding-top: 12px;">
            <button id="wallet-connect-btn" type="button" class="btn btn--primary">
              <.cb_icon name="wallet" size={14} /> Reconnect wallet
            </button>
            <button
              id="wallet-disconnect-btn"
              type="button"
              class="btn btn--ghost-danger"
              phx-click="wallet_connect:disconnect"
            >
              <.cb_icon name="x" size={14} /> Disconnect
            </button>
          </div>
        </div>
      </.card>
    </div>
    """
  end

  defp pill_kind(:connected), do: "connected"
  defp pill_kind(:wrong_network), do: "wrong-network"
  defp pill_kind(:wrong_chain), do: "wrong-network"
  defp pill_kind(:account_mismatch), do: "account-mismatch"
  defp pill_kind(:browser_disconnected), do: "browser-disconnected"
  defp pill_kind(:connecting), do: "pending"
  defp pill_kind(_), do: "disconnected"

  # Pull the first account string from the browser snapshot (already
  # lowercased upstream). nil when no account exposed — the
  # `:account_mismatch` branch only renders this row when present.
  defp browser_first_account(%{accounts: [first | _]}) when is_binary(first), do: first
  defp browser_first_account(_), do: nil

  # Same `0x1234…ABCD` short form used for the bound address. Inlined
  # here (instead of importing from the LiveView) so the card is a
  # pure render component.
  defp short_address("0x" <> _ = address) when byte_size(address) == 42 do
    "0x" <> binary_part(address, 2, 4) <> "…" <> binary_part(address, 38, 4)
  end

  defp short_address(other) when is_binary(other), do: other
  defp short_address(_), do: nil

  defp format_usdc(%Decimal{} = d) do
    rounded = Decimal.round(d, 2) |> Decimal.to_string(:normal)
    "#{rounded} USDC"
  end

  defp format_usdc(n) when is_number(n),
    do: :erlang.float_to_binary(n / 1, decimals: 2) <> " USDC"

  defp format_usdc(_), do: "— USDC"
end
