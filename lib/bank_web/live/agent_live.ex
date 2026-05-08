defmodule BankWeb.AgentLive do
  @moduledoc """
  Agent Control screen — the default landing page of the Plynn redesign.

  Six sections in a single editorial column:
    1. Wallet status
    2. Agent permission (scope list + install / revoke)
    3. Agent mode (segmented Hold / Swap / Earn + per-mode fields)
    4. Test intent
    5. Recent activity (top 5 strip)
    6. Emergency stop

  Phase 2 (wallet section): the wallet card now drives the real
  EIP-1193 `WalletConnect` JS hook + `Bank.WalletBindings`
  challenge / verify flow. Permission, mode, intent, and activity
  remain on dummy state pending sibling phase 2 worktrees.
  """
  use BankWeb, :live_view

  import BankWeb.AgentComponents
  import BankWeb.AgentLive.WalletCard
  import BankWeb.AgentLive.PermissionCard
  import BankWeb.AgentLive.TestIntentCard
  import BankWeb.AgentLive.ActivityStrip
  alias Bank.WalletBindings
  alias BankWeb.AgentLayouts

  @seed_activity [
    %{
      id: "a3",
      t: "2 min ago",
      kind: "permission",
      status: "pending",
      title: "Permission ready to install",
      reason: "Waiting for your signature.",
      amount: nil
    },
    %{
      id: "a2",
      t: "14 min ago",
      kind: "wallet",
      status: "note",
      title: "Wallet connected",
      reason: "Base Sepolia · 0x7a2f…d31c",
      amount: nil
    },
    %{
      id: "a1",
      t: "Yesterday",
      kind: "wallet",
      status: "note",
      title: "Faucet drip received",
      reason: "Test funds added to your smart account.",
      amount: "+ 25 USDC"
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Agent")
      |> assign(:balance_usdc, Decimal.new("124.50"))
      |> assign(:permission, :not_installed)
      |> assign(:mode, "hold")
      |> assign(:settings, %{
        "per_trade" => "50.00",
        "per_deposit" => "50.00",
        "session" => "100.00",
        "daily" => "500.00",
        "slippage" => "0.50",
        "vault" => "re7-usdc"
      })
      |> assign(:intent, :idle)
      |> assign(:last_result, nil)
      |> assign(:intent_counter, 0)
      |> assign(:activity, @seed_activity)
      |> assign(:stop_open, false)
      |> load_wallet_binding()

    {:ok, socket}
  end

  # ── Topbar / global events ───────────────────────────────────────────

  # The WalletConnect JS hook intercepts clicks on `#wallet-connect-btn`
  # and drives the connect flow itself, so the wallet card's button
  # has no `phx-click`. The topbar still has a Connect button but its
  # phase 3 wiring is out of scope here — accept and ignore the event
  # so an accidental click doesn't crash the LiveView.
  @impl true
  def handle_event("topbar:connect_wallet", _, socket), do: {:noreply, socket}
  def handle_event("topbar:switch_network", _, socket), do: {:noreply, socket}

  def handle_event("topbar:stop_agent", _, socket),
    do: {:noreply, assign(socket, :stop_open, true)}

  # ── Wallet (real WalletConnect hook + Bank.WalletBindings) ───────────
  #
  # The EIP-1193 `WalletConnect` JS hook drives the connect flow:
  # request accounts → push `:connected{account, chain_id}`. Phoenix
  # issues a short-lived signed challenge, pushes it back to the
  # browser, the wallet signs via `personal_sign`, the hook returns
  # `:verify{challenge_id, signature}`, and Phoenix verifies the
  # signature recovers the connected EOA. The agent design exposes
  # only three wallet states so we collapse the richer ControlLive
  # state machine into `:disconnected | :wrong_network | :connected`.

  def handle_event("wallet_connect:unavailable", _params, socket) do
    {:noreply, reset_wallet(socket)}
  end

  def handle_event("wallet_connect:connecting", _params, socket) do
    {:noreply, socket}
  end

  def handle_event(
        "wallet_connect:connected",
        %{"account" => account, "chain_id" => chain_id},
        socket
      ) do
    workspace_id = socket.assigns.current_scope.workspace.id
    user_id = socket.assigns.current_scope.user.id

    case WalletBindings.issue_challenge(workspace_id, user_id, %{
           address: account,
           chain_id: chain_id
         }) do
      {:ok, binding} ->
        {:noreply,
         socket
         |> apply_binding(binding)
         |> push_event("wallet_connect:challenge", %{
           challenge_id: binding.id,
           message: binding.challenge_message,
           address: binding.address
         })}

      {:error, :chain_not_supported} ->
        {:noreply,
         socket
         |> assign(:wallet, :wrong_network)
         |> assign(:address, short_address(account))
         |> assign(:wallet_binding, nil)}

      {:error, _other} ->
        {:noreply, reset_wallet(socket)}
    end
  end

  def handle_event(
        "wallet_connect:verify",
        %{"challenge_id" => challenge_id, "signature" => signature},
        socket
      )
      when is_binary(challenge_id) and is_binary(signature) do
    case WalletBindings.verify_and_bind(challenge_id, signature) do
      {:ok, binding} ->
        {:noreply, apply_binding(socket, binding)}

      {:error, _reason} ->
        {:noreply, reset_wallet(socket)}
    end
  end

  def handle_event("wallet_connect:verify_error", _params, socket) do
    {:noreply, reset_wallet(socket)}
  end

  def handle_event(
        "wallet_connect:wrong_chain",
        %{"chain_id" => _chain_id} = params,
        socket
      ) do
    account = Map.get(params, "account")

    {:noreply,
     socket
     |> assign(:wallet, :wrong_network)
     |> assign(:address, account && short_address(account))
     |> assign(:wallet_binding, nil)}
  end

  def handle_event("wallet_connect:cancelled", _params, socket) do
    {:noreply, reset_wallet(socket)}
  end

  def handle_event("wallet_connect:disconnected", _params, socket) do
    {:noreply, socket |> revoke_active_binding(:wallet_disconnected) |> reset_wallet()}
  end

  def handle_event("wallet_connect:disconnect", _params, socket) do
    {:noreply, socket |> revoke_active_binding(:operator_requested) |> reset_wallet()}
  end

  def handle_event("wallet_connect:error", _params, socket) do
    {:noreply, reset_wallet(socket)}
  end

  # ── Permission ───────────────────────────────────────────────────────

  def handle_event("permission:install", _, socket) do
    if socket.assigns.wallet == :connected do
      Process.send_after(self(), :permission_signed, 1100)
      {:noreply, assign(socket, :permission, :installing)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("permission:revoke", _, socket),
    do: {:noreply, assign(socket, :stop_open, true)}

  def handle_event("confirm_stop:cancel", _, socket),
    do: {:noreply, assign(socket, :stop_open, false)}

  def handle_event("confirm_stop:revoke", _, socket) do
    activity =
      [
        %{
          id: new_id(socket),
          t: "just now",
          kind: "permission",
          status: "revoked",
          title: "Permission revoked",
          reason: "You revoked the agent. The agent can no longer move funds.",
          amount: nil
        }
        | socket.assigns.activity
      ]

    socket =
      socket
      |> assign(:permission, :revoked)
      |> assign(:stop_open, false)
      |> assign(:activity, activity)

    socket =
      if socket.assigns.intent == :executing do
        assign(socket, :intent, :blocked)
        |> assign(:last_result, %{
          state: "blocked",
          reason: "Intent blocked: permission was revoked mid-flight.",
          tx_hash: nil
        })
      else
        socket
      end

    {:noreply, socket}
  end

  # ── Mode ─────────────────────────────────────────────────────────────

  def handle_event("mode:select", %{"mode" => mode}, socket) when mode in ~w(hold swap earn) do
    {:noreply, assign(socket, :mode, mode)}
  end

  def handle_event("mode:field_change", %{"_target" => [field], "settings" => settings}, socket) do
    settings = Map.merge(socket.assigns.settings, Map.take(settings, [field]))
    {:noreply, assign(socket, :settings, settings)}
  end

  def handle_event("mode:field_change", %{"settings" => settings}, socket) do
    settings = Map.merge(socket.assigns.settings, settings)
    {:noreply, assign(socket, :settings, settings)}
  end

  # ── Intent ───────────────────────────────────────────────────────────

  def handle_event("intent:run", _, socket) do
    if socket.assigns.permission == :active do
      Process.send_after(self(), :intent_resolved, 1100)
      {:noreply, socket |> assign(:intent, :executing) |> assign(:last_result, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("intent:approve", _, socket) do
    activity =
      [
        %{
          id: new_id(socket),
          t: "just now",
          kind: "intent",
          status: "executed",
          title: "Approved & executed",
          reason: "You approved the over-limit intent once. Funds settled on Base Sepolia.",
          amount: nil
        }
        | socket.assigns.activity
      ]

    {:noreply,
     socket
     |> assign(:intent, :executed)
     |> assign(:last_result, %{
       state: "executed",
       action: "Intent approved and executed",
       tx_hash: "0xa2…9f"
     })
     |> assign(:activity, activity)}
  end

  # ── Async transitions ────────────────────────────────────────────────

  @impl true
  def handle_info(:permission_signed, socket) do
    activity =
      [
        %{
          id: new_id(socket),
          t: "just now",
          kind: "permission",
          status: "installed",
          title: "Permission installed",
          reason:
            "Scope: swap (0x), deposit (Morpho), transfer ≤ limits. Expires in 7 days.",
          amount: nil
        }
        | socket.assigns.activity
      ]

    {:noreply,
     socket
     |> assign(:permission, :active)
     |> assign(:activity, activity)}
  end

  def handle_info(:intent_resolved, socket) do
    counter = socket.assigns.intent_counter
    outcomes = ~w(executed blocked needs-approval)
    out = Enum.at(outcomes, rem(counter, length(outcomes)))
    mode = socket.assigns.mode

    {entry, last_result, intent_state} = build_intent_outcome(out, mode)

    {:noreply,
     socket
     |> assign(:intent, intent_state)
     |> assign(:last_result, last_result)
     |> assign(:intent_counter, counter + 1)
     |> update(:activity, &[Map.merge(%{id: new_id(socket), t: "just now"}, entry) | &1])}
  end

  defp build_intent_outcome("executed", "swap") do
    {%{
       kind: "intent",
       status: "executed",
       title: "Swap executed",
       reason: "10.00 USDC → 9.96 USDbC · 0x route · 0.4% slippage",
       amount: "− 10.00 USDC"
     },
     %{state: "executed", action: "Swap executed", tx_hash: "0x8c…42"}, :executed}
  end

  defp build_intent_outcome("executed", "earn") do
    {%{
       kind: "intent",
       status: "executed",
       title: "Morpho deposit executed",
       reason: "Deposited into Re7 USDC · earning ~5.1% APY",
       amount: "− 25.00 USDC"
     },
     %{state: "executed", action: "Morpho deposit executed", tx_hash: "0x3e…7d"}, :executed}
  end

  defp build_intent_outcome("executed", _) do
    {%{
       kind: "intent",
       status: "executed",
       title: "No-op intent executed",
       reason: "Heartbeat OK. The agent stayed idle.",
       amount: nil
     },
     %{state: "executed", action: "No-op intent executed", tx_hash: "0x1b…05"}, :executed}
  end

  defp build_intent_outcome("blocked", mode) do
    reason =
      case mode do
        "swap" -> "Swap blocked: 0x quote slippage 1.4% exceeds your 0.5% limit."
        "earn" -> "Deposit blocked: amount 250 USDC exceeds per-deposit cap of 50 USDC."
        _ -> "Intent blocked: target outside permission scope."
      end

    {%{
       kind: "intent",
       status: "blocked",
       title: "Intent blocked",
       reason: reason,
       amount: nil
     },
     %{state: "blocked", reason: reason, tx_hash: nil}, :blocked}
  end

  defp build_intent_outcome("needs-approval", _) do
    reason = "Per-trade limit would be exceeded. Approve once or raise the limit."

    {%{
       kind: "intent",
       status: "needs-approval",
       title: "Intent needs approval",
       reason: reason,
       amount: nil
     },
     %{state: "needs-approval", reason: reason, tx_hash: nil}, :needs_approval}
  end

  # ── Helpers ──────────────────────────────────────────────────────────

  # Mount-time loader: pull any active verified binding from the DB so
  # a refresh / reconnect lands directly in the connected state without
  # forcing the operator to re-sign. Returns the socket with the wallet
  # assigns populated (or set to disconnected when no binding exists).
  defp load_wallet_binding(socket) do
    case socket.assigns[:current_scope] do
      %{workspace: %{id: workspace_id}} when is_binary(workspace_id) ->
        case WalletBindings.get_active_binding(workspace_id) do
          nil -> reset_wallet(socket)
          %_{} = binding -> apply_binding(socket, binding)
        end

      _ ->
        reset_wallet(socket)
    end
  end

  # Map a `%WalletBinding{}` row onto the design's three-state wallet
  # enum. The card renders one of these three; we collapse pending,
  # bound, and revoked into them. Pending = challenge issued but not
  # yet verified — the card stays on `:disconnected` until the
  # signature lands and `verified_at` is stamped.
  defp apply_binding(socket, binding) do
    socket
    |> assign(:wallet, derive_wallet_state(binding))
    |> assign(:address, short_address(binding.address))
    |> assign(:wallet_binding, binding)
  end

  defp reset_wallet(socket) do
    socket
    |> assign(:wallet, :disconnected)
    |> assign(:address, nil)
    |> assign(:wallet_binding, nil)
  end

  # Best-effort revoke for the currently-active binding. The wallet
  # disconnect event isn't load-bearing for state — we always reset
  # afterwards — so we tolerate revoke errors silently.
  defp revoke_active_binding(socket, reason) do
    case socket.assigns[:wallet_binding] do
      %_{id: id} when is_binary(id) ->
        _ = WalletBindings.revoke_binding(id, reason)
        socket

      _ ->
        socket
    end
  end

  # Derive the three-state agent design enum from a binding row.
  defp derive_wallet_state(nil), do: :disconnected

  defp derive_wallet_state(%{revoked_at: revoked_at}) when not is_nil(revoked_at),
    do: :disconnected

  defp derive_wallet_state(%{} = binding) do
    expired? =
      binding.expires_at &&
        DateTime.compare(DateTime.utc_now(), binding.expires_at) == :gt

    cond do
      binding.chain_id != 84_532 -> :wrong_network
      not is_nil(binding.verified_at) -> :connected
      expired? -> :disconnected
      true -> :disconnected
    end
  end

  # Render an EIP-55ish short form: `0x` + first 4 hex + … + last 4 hex.
  # Bank.WalletBindings already lowercases addresses, so we only have
  # to slice. Defensive on non-strings so a stale assign doesn't crash.
  defp short_address("0x" <> _ = address) when byte_size(address) == 42 do
    "0x" <> binary_part(address, 2, 4) <> "…" <> binary_part(address, 38, 4)
  end

  defp short_address(other) when is_binary(other), do: other
  defp short_address(_), do: nil

  defp new_id(socket), do: "a" <> Integer.to_string(length(socket.assigns.activity) + 10)

  # ── Render ───────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <AgentLayouts.app
      flash={@flash}
      wallet={@wallet}
      permission={@permission}
      address={@address}
      active={:agent}
    >
      <header class="ac__hero">
        <div>
          <div class="ucase" style="color: var(--ink-3);">Agent Control</div>
          <h1 class="ac__title serif">{hero_title(@wallet, @permission)}</h1>
          <p class="ac__lede">{hero_lede(@permission, @mode)}</p>
        </div>
        <div class="ac__meta">
          <.data_row label="Mode">
            <span class="mono">{mode(@mode).label}</span>
          </.data_row>
          <.data_row label="Permission">
            <.status_pill kind={permission_pill_kind(@permission)} size="sm" />
          </.data_row>
        </div>
      </header>

      <div class="ac__col">
        <.wallet_card wallet={@wallet} address={@address} balance={@balance_usdc} />
        <.permission_card wallet={@wallet} permission={@permission} />
        <.mode_card mode={@mode} settings={@settings} permission={@permission} />
        <.test_intent_card mode={@mode} intent={@intent} last_result={@last_result} permission={@permission} />
        <.activity_strip activity={@activity} />
        <.stop_card permission={@permission} />
      </div>

      <AgentLayouts.confirm_stop_modal open={@stop_open} />
    </AgentLayouts.app>
    """
  end

  # ── Hero copy ──────────────────────────────────────────────────────

  defp hero_title(_, :active), do: "Your agent is on duty."
  defp hero_title(:connected, _), do: "Set the agent up in two steps."
  defp hero_title(_, _), do: "Connect a wallet to begin."

  defp hero_lede(:active, mode_id) do
    "Mode: #{mode(mode_id).label}. The agent will only act inside the limits below. You can stop it any time."
  end

  defp hero_lede(_, _) do
    "Non-custodial. The agent never holds your keys — it acts under a permission you install and can revoke instantly."
  end

  # Local copy of `permission_card/1`'s pill mapping — kept inline so
  # the hero meta row doesn't need to import the card module.
  defp permission_pill_kind(:not_installed), do: "not-installed"
  defp permission_pill_kind(other), do: Atom.to_string(other) |> String.replace("_", "-")

  # ── Section 3: Agent mode ──────────────────────────────────────────

  attr :mode, :string, required: true
  attr :settings, :map, required: true
  attr :permission, :atom, required: true

  defp mode_card(assigns) do
    locked? = assigns.permission != :active
    assigns = assign(assigns, :locked?, locked?)

    ~H"""
    <.card>
      <.card_header eyebrow="03 — Mode" title="Agent mode">
        <:right>
          <span class="hint">{if @locked?, do: "Locked — install permission first", else: "Live"}</span>
        </:right>
      </.card_header>
      <div class={["card__body", @locked? && "is-locked"]}>
        <.mode_segmented mode={@mode} />
        <div class="mode-sub">{mode(@mode).sub}</div>
        <.mode_fields mode={@mode} settings={@settings} />
      </div>
    </.card>
    """
  end

  attr :mode, :string, required: true

  defp mode_segmented(assigns) do
    modes = modes()
    idx = Enum.find_index(modes, &(&1.id == assigns.mode)) || 0
    n = length(modes)
    assigns = assign(assigns, modes: modes, idx: idx, n: n)

    ~H"""
    <div class="seg" data-n={@n}>
      <div
        class="seg__thumb"
        style={"left: calc(4px + #{@idx} * (100% - 8px) / #{@n}); width: calc((100% - 8px) / #{@n});"}
      >
      </div>
      <button
        :for={m <- @modes}
        type="button"
        class={["seg__btn", @mode == m.id && "is-on"]}
        phx-click="mode:select"
        phx-value-mode={m.id}
      >
        <.cb_icon name={m.icon} size={14} /> {m.label}
      </button>
    </div>
    """
  end

  attr :mode, :string, required: true
  attr :settings, :map, required: true

  defp mode_fields(assigns) do
    fields = mode(assigns.mode).fields
    assigns = assign(assigns, :fields, fields)

    ~H"""
    <form class="fields" phx-change="mode:field_change">
      <.field :if={"per_trade" in @fields} label="Max per trade" hint="USDC">
        <input
          type="text"
          name="settings[per_trade]"
          value={@settings["per_trade"]}
          class="num-input mono tnum"
        />
      </.field>
      <.field :if={"per_deposit" in @fields} label="Max per deposit" hint="USDC">
        <input
          type="text"
          name="settings[per_deposit]"
          value={@settings["per_deposit"]}
          class="num-input mono tnum"
        />
      </.field>
      <.field :if={"session" in @fields} label="Session limit" hint="USDC across one session">
        <input
          type="text"
          name="settings[session]"
          value={@settings["session"]}
          class="num-input mono tnum"
        />
      </.field>
      <.field :if={"daily" in @fields} label="Daily limit" hint="USDC across all intents today">
        <input
          type="text"
          name="settings[daily]"
          value={@settings["daily"]}
          class="num-input mono tnum"
        />
      </.field>
      <.field :if={"slippage" in @fields} label="Slippage limit" hint="Block swaps above this">
        <div class="num-input num-input--row">
          <input type="text" name="settings[slippage]" value={@settings["slippage"]} class="mono tnum" />
          <span class="num-input__suffix">%</span>
        </div>
      </.field>
      <.field :if={"vault" in @fields} label="Morpho vault" hint="Allowlisted vaults only">
        <select name="settings[vault]" class="num-input num-input--select">
          <option value="re7-usdc" selected={@settings["vault"] == "re7-usdc"}>
            Re7 USDC · Base Sepolia
          </option>
          <option value="gauntlet-prime" selected={@settings["vault"] == "gauntlet-prime"}>
            Gauntlet Prime · Base Sepolia
          </option>
          <option value="moonwell-usdc" selected={@settings["vault"] == "moonwell-usdc"}>
            Moonwell Flagship · Base Sepolia
          </option>
        </select>
      </.field>
    </form>
    """
  end

  # ── Section 6: Emergency stop ─────────────────────────────────────

  attr :permission, :atom, required: true

  defp stop_card(assigns) do
    active? = assigns.permission in [:active, :installing]
    assigns = assign(assigns, :active?, active?)

    ~H"""
    <.card tone="danger">
      <div class="stop">
        <div>
          <div class="stop__eye ucase">06 — Emergency stop</div>
          <div class="serif stop__title">Stop the agent</div>
          <div class="stop__sub">
            Revokes permission immediately.
            <%= if @active? do %>
              In-flight intents will be blocked. You can reinstall later.
            <% else %>
              No agent permission is active right now — the agent already cannot move funds.
            <% end %>
          </div>
        </div>
        <button
          type="button"
          class="btn btn--danger"
          disabled={not @active?}
          phx-click="permission:revoke"
        >
          <.cb_icon name="stop" size={14} /> Revoke permission
        </button>
      </div>
    </.card>
    """
  end

end
