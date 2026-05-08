defmodule BankWeb.AgentComponents do
  @moduledoc """
  Shared Phoenix.Components for the Plynn redesign.

  Mirrors `reference/app.jsx` + `reference/agent-control.jsx` from the
  design handoff package. Class names match the React reference 1:1
  (BEM-style) so future merges with the design package stay readable.

  Every selector is scoped under `.cb` in `assets/css/cb.css` to avoid
  colliding with DaisyUI on existing operator screens. The
  `BankWeb.AgentLayouts.app/1` shell wraps redesigned screens in
  `<div class="cb">`; these components assume that wrapper exists.
  """
  use Phoenix.Component

  # ── Icon ────────────────────────────────────────────────────────────
  # Inline 24×24 SVG, 1.6 stroke. Matches `app.jsx`'s Icon switch.
  # Heroicons would work for most, but the brand cube + a few bespoke
  # ones (vault, swap, agent) need the design's exact paths to keep
  # visual consistency, so we ship one inline SVG per name.

  @doc """
  Inline SVG icon by name. Mirrors the `Icon` component in `app.jsx`.

  Named `cb_icon` (not `icon`) so it doesn't collide with
  `BankWeb.CoreComponents.icon/1`, which every LiveView imports via
  `use BankWeb, :live_view`. The CoreComponents helper is heroicons-
  based and unrelated to this design's inline-SVG glyphs.
  """
  attr :name, :string, required: true
  attr :size, :integer, default: 16
  attr :stroke, :float, default: 1.6
  attr :class, :string, default: nil

  def cb_icon(assigns) do
    ~H"""
    <svg
      width={@size}
      height={@size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width={@stroke}
      stroke-linecap="round"
      stroke-linejoin="round"
      class={@class}
    >
      {Phoenix.HTML.raw(icon_path(@name))}
    </svg>
    """
  end

  defp icon_path("brand"),
    do: ~s(<path d="M4 7.5 12 4l8 3.5v9L12 20l-8-3.5v-9Z"/><path d="M12 4v16M4 7.5l8 3.5 8-3.5"/>)

  defp icon_path("wallet"),
    do:
      ~s(<path d="M3 7a2 2 0 0 1 2-2h13v4"/><path d="M3 7v11a2 2 0 0 0 2 2h15a1 1 0 0 0 1-1v-3"/><path d="M16 12h5v4h-5a2 2 0 0 1 0-4Z"/>)

  defp icon_path("shield"),
    do: ~s(<path d="M12 3 4 6v6c0 4.5 3.5 8.5 8 9 4.5-.5 8-4.5 8-9V6l-8-3Z"/>)

  defp icon_path("agent"),
    do:
      ~s(<circle cx="12" cy="12" r="3.2"/><path d="M12 4v2M12 18v2M4 12h2M18 12h2M6.3 6.3l1.4 1.4M16.3 16.3l1.4 1.4M6.3 17.7l1.4-1.4M16.3 7.7l1.4-1.4"/>)

  defp icon_path("activity"), do: ~s(<path d="M3 12h4l2-6 4 12 2-6h6"/>)

  defp icon_path("tools"),
    do:
      ~s(<path d="M14 6.5a3.5 3.5 0 0 0 4.6 4.6L21 13.5 13.5 21l-2.4-2.4A3.5 3.5 0 0 0 6.5 14L3 17.5"/><path d="m9 9 3 3"/>)

  defp icon_path("check"), do: ~s(<path d="m4 12 5 5L20 6"/>)
  defp icon_path("x"), do: ~s(<path d="M5 5l14 14M19 5 5 19"/>)
  defp icon_path("minus"), do: ~s(<path d="M5 12h14"/>)
  defp icon_path("plus"), do: ~s(<path d="M12 5v14M5 12h14"/>)
  defp icon_path("arrow-right"), do: ~s(<path d="M5 12h14M13 6l6 6-6 6"/>)
  defp icon_path("chevron-right"), do: ~s(<path d="m9 6 6 6-6 6"/>)
  defp icon_path("chevron-down"), do: ~s(<path d="m6 9 6 6 6-6"/>)

  defp icon_path("lock"),
    do: ~s(<rect x="4" y="11" width="16" height="9" rx="2"/><path d="M8 11V8a4 4 0 0 1 8 0v3"/>)

  defp icon_path("stop"), do: ~s(<rect x="6" y="6" width="12" height="12" rx="1.5"/>)

  defp icon_path("warning"),
    do:
      ~s(<path d="M10.6 3.6 2.7 17.4A1.6 1.6 0 0 0 4.1 20h15.8a1.6 1.6 0 0 0 1.4-2.6L13.4 3.6a1.6 1.6 0 0 0-2.8 0Z"/><path d="M12 10v4M12 17.5v.1"/>)

  defp icon_path("info"),
    do: ~s(<circle cx="12" cy="12" r="9"/><path d="M12 8v.1M11 12h1v5h1"/>)

  defp icon_path("swap"), do: ~s(<path d="M4 8h13l-3-3M20 16H7l3 3"/>)

  defp icon_path("vault"),
    do:
      ~s(<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="14" cy="12" r="3"/><path d="M14 12h3M5 9v6"/>)

  defp icon_path("hold"),
    do: ~s(<circle cx="12" cy="12" r="9"/><path d="M9 9h2v6M14 9h.01M14 12v3"/>)

  defp icon_path("play"), do: ~s(<path d="M7 5v14l12-7Z"/>)

  defp icon_path("external"),
    do:
      ~s(<path d="M14 4h6v6M20 4l-9 9M19 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V6a1 1 0 0 1 1-1h5"/>)

  defp icon_path("history"),
    do: ~s(<path d="M3 12a9 9 0 1 0 3-6.7L3 8"/><path d="M3 4v4h4M12 8v4l3 2"/>)

  defp icon_path("queue"), do: ~s(<path d="M4 6h12M4 12h16M4 18h10"/>)
  defp icon_path("health"), do: ~s(<path d="M3 12h3l2-5 4 10 2-5h7"/>)

  defp icon_path("mail"),
    do: ~s(<rect x="3" y="5" width="18" height="14" rx="2"/><path d="m4 7 8 6 8-6"/>)

  defp icon_path("doc"),
    do: ~s(<path d="M6 3h8l4 4v14H6Z"/><path d="M14 3v4h4M9 13h6M9 17h6M9 9h2"/>)

  defp icon_path("sun"),
    do:
      ~s(<circle cx="12" cy="12" r="4"/><path d="M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6l1.4 1.4M17 17l1.4 1.4M5.6 18.4 7 17M17 7l1.4-1.4"/>)

  defp icon_path("moon"),
    do: ~s(<path d="M20 14.5A8 8 0 1 1 9.5 4a7 7 0 0 0 10.5 10.5Z"/>)

  defp icon_path("desktop"),
    do: ~s(<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M9 20h6M12 16v4"/>)

  defp icon_path(_), do: ""

  # ── Status pill ────────────────────────────────────────────────────
  # Mirrors STATUS_CONFIG from `app.jsx`. Drives wallet / permission /
  # intent / activity status surfaces.

  @doc """
  Coloured status pill. `kind` accepts the same strings the React
  reference uses (e.g. "active", "needs-approval", "wrong-network").
  """
  attr :kind, :string, required: true
  attr :label, :string, default: nil
  attr :size, :string, values: ~w(sm md), default: "md"

  def status_pill(assigns) do
    {color, default_label, dot?} = pill_config(assigns.kind)

    assigns =
      assigns
      |> assign(:color, color)
      |> assign(:default_label, default_label)
      |> assign(:dot?, dot?)

    ~H"""
    <span class={["pill", "pill--#{@color}", "pill--#{@size}"]}>
      <i :if={@dot?} class="pill__dot"></i>
      {@label || @default_label}
    </span>
    """
  end

  defp pill_config("ok"), do: {"ok", "Active", true}
  defp pill_config("active"), do: {"ok", "Active", true}
  defp pill_config("executed"), do: {"ok", "Executed", true}
  defp pill_config("installed"), do: {"ok", "Installed", true}
  defp pill_config("connected"), do: {"ok", "Connected", true}
  defp pill_config("pending"), do: {"warn", "Pending", true}
  defp pill_config("installing"), do: {"warn", "Installing…", true}
  defp pill_config("executing"), do: {"warn", "Executing…", true}
  defp pill_config("needs-approval"), do: {"warn", "Needs approval", true}
  defp pill_config("wrong-network"), do: {"warn", "Wrong network", true}
  defp pill_config("blocked"), do: {"danger", "Blocked", true}
  defp pill_config("failed"), do: {"danger", "Failed", true}
  defp pill_config("revoked"), do: {"ink", "Revoked", false}
  defp pill_config("expired"), do: {"ink", "Expired", false}
  defp pill_config("disconnected"), do: {"ink", "Not connected", false}
  defp pill_config("not-installed"), do: {"ink", "Not installed", false}
  defp pill_config("idle"), do: {"ink", "Idle", false}
  defp pill_config("note"), do: {"info", "Note", false}
  defp pill_config(other), do: {"ink", other, false}

  # Status-to-color used by the timeline row (timeline__row--ok, etc).
  @doc false
  def status_color(kind) do
    {c, _l, _d} = pill_config(kind)
    c
  end

  # ── Card primitives ────────────────────────────────────────────────

  attr :tone, :string, default: nil, values: [nil, "danger"]
  attr :class, :string, default: nil
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <section class={["card", @tone && "card--#{@tone}", @class]}>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :eyebrow, :string, default: nil
  attr :title, :string, required: true
  slot :right

  def card_header(assigns) do
    ~H"""
    <header class="card__head">
      <div>
        <div :if={@eyebrow} class="card__eye ucase">{@eyebrow}</div>
        <h2 class="card__title serif">{@title}</h2>
      </div>
      <div class="card__right">{render_slot(@right)}</div>
    </header>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  def data_row(assigns) do
    ~H"""
    <div class="datarow">
      <div class="datarow__label">{@label}</div>
      <div class="datarow__value">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :kind, :string, required: true, values: ~w(info warn danger)
  slot :inner_block, required: true

  def banner(assigns) do
    ~H"""
    <div class={["banner", "banner--#{@kind}"]}>
      <.cb_icon name={if @kind == "info", do: "info", else: "warning"} size={14} />
      <span>{render_slot(@inner_block)}</span>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :hint, :string, default: nil
  slot :inner_block, required: true

  def field(assigns) do
    ~H"""
    <label class="field">
      <span class="field__label">{@label}</span>
      {render_slot(@inner_block)}
      <span :if={@hint} class="field__hint">{@hint}</span>
    </label>
    """
  end

  # ── Scope list ─────────────────────────────────────────────────────
  # Reads from `Bank.SessionPermissions.Scope.default/0` so the on-screen
  # copy stays in lockstep with the canonical scope persisted on the
  # delegation row and audited at install time.

  def scope_list(assigns) do
    scope = Bank.SessionPermissions.Scope.default()

    allow =
      Enum.map(scope["allowed"], fn entry ->
        %{
          icon: icon_for_kind(entry["kind"]),
          label: entry["label"],
          detail: entry["rationale"]
        }
      end)

    deny =
      Enum.map(scope["denied"], fn entry -> %{label: entry["label"]} end)

    assigns = assign(assigns, allow: allow, deny: deny)

    ~H"""
    <div class="scope">
      <div class="scope__col">
        <h4 class="scope__h"><.cb_icon name="check" size={14} /> The agent can</h4>
        <ul class="scope__items">
          <li :for={p <- @allow} class="scope__item scope__item--ok">
            <.cb_icon name={p.icon} size={14} />
            <div>
              <div>{p.label}</div>
              <div class="scope__detail">{p.detail}</div>
            </div>
          </li>
        </ul>
      </div>
      <div class="scope__col">
        <h4 class="scope__h"><.cb_icon name="x" size={14} /> The agent cannot</h4>
        <ul class="scope__items">
          <li :for={p <- @deny} class="scope__item scope__item--no">
            <.cb_icon name="minus" size={14} /> {p.label}
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp icon_for_kind("zero_x_swap"), do: "swap"
  defp icon_for_kind("morpho_4626_deposit"), do: "vault"
  defp icon_for_kind("usdc_transfer"), do: "arrow-right"
  defp icon_for_kind(_), do: "check"

  # ── Activity row ───────────────────────────────────────────────────
  # Used by both the compact strip on Agent Control and the full
  # timeline on the Activity screen.

  attr :item, :map, required: true

  def activity_row(assigns) do
    color = status_color(assigns.item.status)
    assigns = assign(assigns, :color, color)

    ~H"""
    <li class={["timeline__row", "timeline__row--#{@color}"]}>
      <div class="timeline__rail">
        <i class="timeline__dot"></i>
      </div>
      <div class="timeline__main">
        <div class="timeline__head">
          <.status_pill kind={@item.status} size="sm" />
          <span class="timeline__title">{@item.title}</span>
          <span :if={@item[:amount]} class="timeline__amt mono tnum">{@item.amount}</span>
        </div>
        <div :if={@item[:reason]} class="timeline__reason">{@item.reason}</div>
      </div>
      <div class="timeline__t">{@item.t}</div>
    </li>
    """
  end

  # ── Mode metadata ──────────────────────────────────────────────────
  # Mirrors MODES + INTENT_EXAMPLES from agent-control.jsx so callers
  # don't recompute the per-mode field/label tables.

  @modes [
    %{
      id: "hold",
      icon: "hold",
      label: "Hold USDC",
      sub: "Agent does nothing. Funds stay in your smart account.",
      fields: ~w(session daily)
    },
    %{
      id: "swap",
      icon: "swap",
      label: "Swap",
      sub: "Agent can route USDC through 0x within slippage limit.",
      fields: ~w(per_trade daily slippage)
    },
    %{
      id: "earn",
      icon: "vault",
      label: "Earn in Morpho",
      sub: "Agent deposits idle USDC into the vault you choose.",
      fields: ~w(vault per_deposit daily)
    }
  ]

  @intent_examples %{
    "hold" => %{
      title: "No-op intent",
      body: "Confirm the agent is reachable but does nothing."
    },
    "swap" => %{
      title: "Swap 10 USDC → USDbC",
      body: "Test the 0x route inside slippage limit."
    },
    "earn" => %{
      title: "Deposit 25 USDC into Re7 USDC",
      body: "Allowlisted Morpho vault."
    }
  }

  def modes, do: @modes
  def mode(id), do: Enum.find(@modes, &(&1.id == id))
  def intent_example(mode_id), do: Map.get(@intent_examples, mode_id)
end
