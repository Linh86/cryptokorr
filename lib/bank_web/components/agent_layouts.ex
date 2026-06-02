defmodule BankWeb.AgentLayouts do
  @moduledoc """
  App shell for the Agent Control redesign: TopBar + NavRail + main slot.

  Mirrors `TopBar` / `NavRail` / `App` in `reference/root.jsx` +
  `reference/app.jsx`. Wraps everything in `<div class="cb">` so the
  scoped styles in `cb.css` apply without colliding with DaisyUI on
  the operator screens.

  This is a separate shell from `BankWeb.Layouts.app/1`; the operator
  control tower keeps that one. Once the cutover lands, the operator
  shell can be retired.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: BankWeb.Endpoint,
    router: BankWeb.Router,
    statics: BankWeb.static_paths()

  import BankWeb.AgentComponents
  alias Bank.Delegations.Delegation
  alias Phoenix.LiveView.JS

  @doc """
  Renders the redesigned app shell. Children render inside `<main class="main">`.

  Required:
  - `flash` — flash map (rendered via the existing `flash_group`).
  - `wallet` — `:disconnected | :wrong_network | :connected`.
  - `permission` — `:not_installed | :installing | :active | :revoked | :expired | :failed`.
  - `address` — short-form wallet address string (or nil).
  - `active` — `:agent | :activity | :advanced`.
  """
  attr :flash, :map, required: true
  attr :wallet, :atom, required: true
  attr :permission, :atom, required: true
  attr :address, :string, default: nil
  attr :active, :atom, required: true
  attr :delegation, :any, default: nil

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="cb">
      <div class="app">
        <.top_bar
          wallet={@wallet}
          permission={@permission}
          address={@address}
          delegation={@delegation}
        />
        <div class="layout">
          <.nav_rail active={@active} permission={@permission} />
          <main class="main">
            {render_slot(@inner_block)}
          </main>
        </div>
      </div>
      <BankWeb.Layouts.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  TopBar: brand + testnet badge on the left; wallet/network CTAs +
  Stop agent button on the right.

  `delegation` (P5): the design enum collapses `:revoking` →
  `:installing`, which would falsely re-enable the Stop button while
  a revoke is in flight. When the live raw-state delegation is
  available, we gate Stop on it directly so a half-revoked row
  blocks Stop until the row settles or the revoke fails.
  """
  attr :wallet, :atom, required: true
  attr :permission, :atom, required: true
  attr :address, :string, default: nil
  attr :delegation, :any, default: nil

  def top_bar(assigns) do
    # `:revoke_failed` is a special-case: the design enum collapses it
    # to `:permission == :failed` (so the `:active`/`:installing` gate
    # below would block Stop), but the domain semantics say the
    # on-chain delegation may still be live and the operator MUST be
    # able to retry revoke. So we allow Stop explicitly when the raw
    # delegation row is `:revoke_failed`, in addition to the normal
    # active/installing path.
    can_stop? =
      delegation_retry_revoke?(assigns.delegation) or
        (assigns.permission in [:active, :installing] and
           not stop_blocked_by_delegation?(assigns.delegation))

    assigns = assign(assigns, :can_stop?, can_stop?)

    ~H"""
    <header class="topbar">
      <div class="topbar__brand">
        <a href={~p"/"} class="brand">
          <span class="brand__mark" aria-hidden="true">
            <.cb_icon name="brand" size={22} />
          </span>
          <span class="brand__name serif">CryptoKorr</span>
        </a>
        <div class="testnet-badge" title="This prototype is wired to Base Sepolia testnet only">
          <i class="testnet-badge__dot"></i>
          <span>Base Sepolia · testnet</span>
        </div>
      </div>
      <div class="topbar__right">
        <%!-- When the wallet is on the wrong chain, keep the warn
        affordance in the topbar — the WalletConnect hook listens
        for the message and prompts the wallet to switch. --%>
        <span
          :if={@wallet == :wrong_network}
          class="btn btn--warn is-disabled"
          title="Switch your wallet to Base Sepolia"
        >
          <.cb_icon name="warning" size={14} /> Wrong network
        </span>
        <div :if={@wallet == :connected} class="wallet-chip">
          <i class="wallet-chip__dot"></i>
          <span class="mono">{@address || "0x…"}</span>
        </div>
        <%!-- When disconnected, the agent screen's WalletCard owns the
        primary Connect CTA. The topbar stays quiet so we don't ship
        two competing connect buttons. --%>
        <button
          type="button"
          class={["btn btn--ghost-danger", not @can_stop? && "is-disabled"]}
          disabled={not @can_stop?}
          phx-click={JS.push("topbar:stop_agent")}
          title={if(@can_stop?, do: "Revoke agent permission", else: "No active agent to stop")}
        >
          <.cb_icon name="stop" size={14} /> Stop agent
        </button>
      </div>
    </header>
    """
  end

  @doc """
  Left nav rail: Agent / Activity / Advanced + permission status footer.
  """
  attr :active, :atom, required: true
  attr :permission, :atom, required: true

  def nav_rail(assigns) do
    ~H"""
    <nav class="navrail" aria-label="Primary">
      <.nav_item id="agent" label="Agent" icon="agent" href={~p"/"} active={@active == :agent} />
      <.nav_item
        id="activity"
        label="Activity"
        icon="activity"
        href={~p"/activity"}
        active={@active == :activity}
      />
      <.nav_item
        id="advanced"
        label="Advanced"
        icon="tools"
        href={~p"/advanced"}
        active={@active == :advanced}
      />
      <div class="navrail__foot">
        <div class="navrail__hint">
          <span class="ucase" style="color: var(--ink-3);">Agent</span>
          <div style="margin-top: 6px;">
            <.status_pill kind={Atom.to_string(@permission) |> String.replace("_", "-")} size="sm" />
          </div>
        </div>
        <.theme_toggle />
      </div>
    </nav>
    """
  end

  @doc """
  Three-state theme toggle (system / light / dark).

  Reuses the existing `phx:set-theme` event the operator console
  already dispatches (handled by `assets/js/theme-init.js`), so the
  redesigned shell shares the same source of truth — switching theme
  here flips operator screens too, and vice versa.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="cb-theme">
      <button
        type="button"
        class="cb-theme__btn"
        title="Match system theme"
        phx-click={Phoenix.LiveView.JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.cb_icon name="desktop" size={14} />
      </button>
      <button
        type="button"
        class="cb-theme__btn"
        title="Light theme"
        phx-click={Phoenix.LiveView.JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.cb_icon name="sun" size={14} />
      </button>
      <button
        type="button"
        class="cb-theme__btn"
        title="Dark theme"
        phx-click={Phoenix.LiveView.JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.cb_icon name="moon" size={14} />
      </button>
    </div>
    """
  end

  # `:revoke_failed` is intentionally NOT in the blocked list. The
  # domain state machine says a `:revoke_failed` row may still be a
  # live on-chain delegation, so the operator must be able to retry
  # revoke. The Stop button stays enabled for that state via
  # `delegation_retry_revoke?/1`. Other terminal states (`:revoked`,
  # `:expired`, `:install_failed`) and in-flight `:revoking` block
  # Stop because there's nothing left to revoke or the request is
  # already inbound.
  defp stop_blocked_by_delegation?(%Delegation{state: state})
       when state in [:revoking, :revoked, :expired, :install_failed],
       do: true

  defp stop_blocked_by_delegation?(_), do: false

  defp delegation_retry_revoke?(%Delegation{state: :revoke_failed}), do: true
  defp delegation_retry_revoke?(_), do: false

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :href, :string, required: true
  attr :active, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={["navrail__item", @active && "is-active"]}
      data-nav-id={@id}
    >
      <.cb_icon name={@icon} size={16} />
      <span>{@label}</span>
    </.link>
    """
  end

  @doc """
  Confirm-stop modal. Shown when the user clicks Stop agent in the
  TopBar or the Revoke button in the StopCard.

  Renders nothing when `open` is false. The scrim click and the
  "Keep agent active" button both push `confirm_stop:cancel`; the
  red Revoke button pushes `confirm_stop:revoke`.
  """
  attr :open, :boolean, required: true

  def confirm_stop_modal(assigns) do
    ~H"""
    <div :if={@open} class="modal-scrim" phx-click="confirm_stop:cancel">
      <div
        class="cb-modal"
        role="dialog"
        aria-modal="true"
        phx-click-away="confirm_stop:cancel"
        phx-window-keydown="confirm_stop:cancel"
        phx-key="escape"
      >
        <div class="modal__icon">
          <.cb_icon name="stop" size={20} />
        </div>
        <h3 class="serif modal__title">Stop the agent?</h3>
        <p class="modal__body">
          This revokes the agent permission immediately. Any in-flight intent will be
          blocked. You can re-install permission later — funds are never at risk.
        </p>
        <div class="modal__actions">
          <button type="button" class="btn btn--secondary" phx-click="confirm_stop:cancel">
            Keep agent active
          </button>
          <button type="button" class="btn btn--danger" phx-click="confirm_stop:revoke">
            <.cb_icon name="stop" size={14} /> Revoke permission
          </button>
        </div>
      </div>
    </div>
    """
  end
end
