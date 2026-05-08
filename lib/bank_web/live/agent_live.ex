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

  Phase 2 (in progress):
    * Wallet (section 1) — real `WalletConnect` JS hook + the
      `Bank.WalletBindings` challenge/verify flow.
    * Permission (section 2) — real `SessionPermissionInstall` JS
      hook + `Bank.SessionPermissions.BrowserInstall` envelope /
      attestation flow; revoke goes through `Bank.Security`.
    * Test intent (section 4) — `Bank.Intents.submit/2` evaluation
      pipeline + `Bank.Decisions.approve/2`. The LiveView subscribes
      to `Bank.Runtime.PubSub.intent(intent_id)` after submit and
      maps decision/execution events to the four IntentResult
      variants (executed / blocked / needs-approval / failed). All
      payloads pinned to `chain: "base-sepolia"`.
    * Activity feed (section 5) — subscribed to `audit:stream` and
      backed by `Bank.Audit.list_events/2` scoped to the workspace.
      Empty workspaces render the empty-state copy in
      `BankWeb.AgentLive.ActivityStrip`; no seed data.
  """
  use BankWeb, :live_view

  import BankWeb.AgentComponents
  import BankWeb.AgentLive.WalletCard
  import BankWeb.AgentLive.PermissionCard
  import BankWeb.AgentLive.TestIntentCard
  import BankWeb.AgentLive.ActivityStrip
  alias Bank.Audit
  alias Bank.Audit.{ActivityView, AuditEvent}
  alias Bank.Delegations
  alias Bank.Delegations.Delegation
  alias Bank.Repo
  alias Bank.Runtime.PubSub, as: RuntimePubSub
  alias Bank.SessionPermissions
  alias Bank.SessionPermissions.BrowserInstall
  alias Bank.WalletBindings
  alias Bank.WalletBindings.WalletBinding
  alias BankWeb.AgentLayouts
  alias BankWeb.LiveAuth

  # Cap the in-memory activity list. AgentActivityLive paginates
  # cleanly via the Audit reader; the strip itself only renders the
  # top 5, so 50 is plenty of headroom for live prepends without
  # leaking memory on long-lived sockets.
  @activity_cap 50

  # ── Permission install polling ──────────────────────────────────────
  #
  # Defense-in-depth for the install confirmation path. After the JS
  # hook reports `:confirmed`, the BE has scheduled
  # `Bank.Runtime.Workers.VerifyInstallOnchain` which flips
  # `delegation.state` from `:pending` to `:active`. That worker
  # broadcasts on `audit:stream` + `security:events` and we already
  # subscribe to both — so under normal conditions the LiveView
  # picks up the flip via PubSub.
  #
  # Polling backstops three failure modes:
  #
  #   1. The PubSub broadcast is missed (process restart between
  #      the worker write and the LiveView mount).
  #   2. The worker takes longer than usual (chain reorg, slow
  #      receipt) and the operator stares at "Installing…" wondering
  #      whether the page is wedged.
  #   3. The browser tab was backgrounded and the WebSocket
  #      reconnected with a stale assigns snapshot.
  #
  # Exponential backoff (2s, 4s, 8s, 16s, 32s, 32s) capped at 32s
  # per attempt; max 6 attempts ≈ 94s wall-clock. We stop early as
  # soon as `permission == :active`.
  @install_poll_attempts 6
  @install_poll_max_ms 32_000
  @install_poll_base_ms 2_000

  # ── Intent run timeout ──────────────────────────────────────────────
  #
  # If neither `:decision_updated` nor `:execution_updated` lands within
  # 30s of `intent:run` we flip the IntentResult into a non-terminal
  # `:slow` variant so the operator stops staring at the spinner. The
  # `:slow` state isn't a terminal — a real PubSub event arriving later
  # still overwrites `:intent` + `:last_result` via the existing
  # `handle_decision_updated` / `handle_execution_updated` helpers.
  @intent_timeout_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      # I2 — delegation state transitions (revoke flow + on-chain
      # confirmation flips :pending → :active).
      RuntimePubSub.subscribe(RuntimePubSub.security_events())
      # I4 — audit:stream feeds the activity strip + AgentActivityLive.
      RuntimePubSub.subscribe(RuntimePubSub.audit_stream())
    end

    socket =
      socket
      |> assign(:page_title, "Agent")
      # I1 — loads active binding + sets :wallet, :address,
      # :wallet_binding via assign/3. Done first so the permission
      # card's `refresh_delegation` can read :wallet_binding.
      |> load_wallet_binding()
      # I2 / I3 / I4 — `assign_new/3` so parallel-agent mount paths
      # don't stomp each other.
      |> assign_new(:wallet, fn -> :disconnected end)
      |> assign_new(:address, fn -> nil end)
      # USDC balance is loaded after the binding lands via
      # `refresh_balance/2` (called from `apply_binding/2` and
      # `load_wallet_binding/1`). When no binding exists yet, `nil`
      # → `format_usdc/1` renders "— USDC".
      |> assign_new(:balance_usdc, fn -> nil end)
      |> assign_new(:mode, fn -> "hold" end)
      |> assign_new(:settings, fn ->
        %{
          "per_trade" => "50.00",
          "per_deposit" => "50.00",
          "session" => "100.00",
          "daily" => "500.00",
          "slippage" => "0.50",
          "vault" => "re7-usdc"
        }
      end)
      |> assign_new(:intent, fn -> :idle end)
      |> assign_new(:last_result, fn -> nil end)
      |> assign_new(:active_intent_id, fn -> nil end)
      # I4 — load_activity reads workspace audit slice via
      # Bank.Audit.list_events; falls back to [] when no scope.
      |> assign_new(:activity, fn -> load_activity(socket) end)
      |> assign_new(:stop_open, fn -> false end)
      # I2 permission-card-owned assigns.
      |> assign_new(:browser_install_state, fn -> :idle end)
      |> assign_new(:install_failure_reason, fn -> nil end)
      |> assign_new(:wrong_chain_id, fn -> nil end)
      |> assign_new(:delegation, fn -> nil end)
      |> assign_new(:permission_ambiguous?, fn -> false end)
      |> refresh_delegation()
      |> recompute_permission()

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
  # four wallet states (`:disconnected | :connecting | :wrong_network
  # | :connected`) — we add `:connecting` so the user sees an explicit
  # "check your wallet popup" affordance once the hook has fired
  # `eth_requestAccounts` and is waiting on MetaMask. Without that
  # transition the click looked like it did nothing — the popup may
  # be queued behind other windows.

  def handle_event("wallet_connect:unavailable", _params, socket) do
    {:noreply, reset_wallet(socket)}
  end

  def handle_event("wallet_connect:connecting", _params, socket) do
    # Flip the card into the `:connecting` variant so the user has a
    # visual cue to look for the wallet popup. Cleared by the
    # downstream `:connected` / `:wrong_chain` / `:cancelled` /
    # `:error` events the hook always emits afterwards.
    {:noreply, assign(socket, :wallet, :connecting)}
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
      {:ok, _binding} ->
        # Reload from DB after a successful verify so the in-memory
        # assigns match what a fresh page load would see. This pins
        # the LiveView to the persisted truth — if a parallel
        # revoke landed between verify_and_bind and now, the
        # reloaded binding will be `nil` and the card flips back
        # to disconnected rather than showing stale "connected".
        ws_id = workspace_id_from_socket(socket)
        reloaded = ws_id && WalletBindings.get_active_binding(ws_id)

        case reloaded do
          %WalletBinding{} = b -> {:noreply, apply_binding(socket, b)}
          _ -> {:noreply, reset_wallet(socket)}
        end

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
    socket =
      socket
      |> revoke_active_binding(:wallet_disconnected)
      |> reset_wallet()
      |> fail_close_permission_after_disconnect()

    {:noreply, socket}
  end

  def handle_event("wallet_connect:disconnect", _params, socket) do
    socket =
      socket
      |> revoke_active_binding(:operator_requested)
      |> reset_wallet()
      |> fail_close_permission_after_disconnect()

    {:noreply, socket}
  end

  def handle_event("wallet_connect:error", _params, socket) do
    {:noreply, reset_wallet(socket)}
  end

  # ── Permission ───────────────────────────────────────────────────────
  #
  # The install flow is driven by the `SessionPermissionInstall` JS hook
  # (`assets/js/hooks/session_permission_install.js`). On click, the
  # hook fetches the canonical envelope, walks the ZeroDev SDK, and
  # reports back through `pushEvent`. Phoenix only listens — it never
  # calls the bundler directly.

  # The bare `permission:install` event is left as a no-op: the JS hook
  # intercepts the click before it reaches the LiveView, but tests and
  # screen-readers may still fire it. Treat it as a hint to flip into
  # the awaiting state if the wallet looks ready.
  def handle_event("permission:install", _, socket) do
    if socket.assigns.wallet == :connected and
         is_struct(socket.assigns.wallet_binding, WalletBinding) do
      {:noreply,
       socket
       |> assign(:browser_install_state, :awaiting)
       |> assign(:install_failure_reason, nil)
       |> assign(:wrong_chain_id, nil)
       |> recompute_permission()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("session_permission_install:awaiting", _params, socket) do
    {:noreply,
     socket
     |> assign(:browser_install_state, :awaiting)
     |> assign(:install_failure_reason, nil)
     |> assign(:wrong_chain_id, nil)
     |> recompute_permission()}
  end

  def handle_event("session_permission_install:submitted", _params, socket) do
    {:noreply,
     socket
     |> assign(:browser_install_state, :submitted)
     |> assign(:install_failure_reason, nil)
     |> assign(:wrong_chain_id, nil)
     |> refresh_delegation()
     |> recompute_permission()}
  end

  def handle_event("session_permission_install:confirmed", _params, socket) do
    socket =
      socket
      |> assign(:browser_install_state, :confirmed)
      |> assign(:install_failure_reason, nil)
      |> assign(:wrong_chain_id, nil)
      |> refresh_delegation()
      |> recompute_permission()

    # If `recompute_permission/1` saw the worker already flipped the
    # row to :active (rare, but possible if the worker raced ahead of
    # the JS hook's `:confirmed` event) we don't need to poll. Otherwise
    # schedule the first attempt; subsequent attempts self-schedule via
    # `handle_info({:poll_install_status, _}, _)` until either
    # `:active` lands in the DB or we exhaust the attempt budget.
    if needs_install_polling?(socket) do
      Process.send_after(self(), {:poll_install_status, 0}, @install_poll_base_ms)
    end

    {:noreply, socket}
  end

  def handle_event("session_permission_install:failed", params, socket) do
    reason_atom = parse_install_failure_reason(Map.get(params, "reason"))

    {:noreply,
     socket
     |> assign(:browser_install_state, :failed)
     |> assign(:install_failure_reason, reason_atom)
     |> refresh_delegation()
     |> recompute_permission()}
  end

  def handle_event("session_permission_install:wrong_chain", params, socket) do
    chain_id = Map.get(params, "chain_id")

    {:noreply,
     socket
     |> assign(:browser_install_state, :wrong_chain)
     |> assign(:wrong_chain_id, chain_id)
     |> recompute_permission()}
  end

  def handle_event("permission:revoke", _, socket),
    do: {:noreply, assign(socket, :stop_open, true)}

  def handle_event("confirm_stop:cancel", _, socket),
    do: {:noreply, assign(socket, :stop_open, false)}

  def handle_event("confirm_stop:revoke", _, socket) do
    case LiveAuth.authorize_action(socket, :operator) do
      :ok ->
        do_confirm_stop_revoke(socket)

      {:error, {:insufficient_role, _}} ->
        # Defense-in-depth: the agent_alpha live_session already gates
        # mount on `:operator`+, but a future routing change or a
        # manually-pushed event mustn't escalate viewer-tier sockets.
        {:noreply,
         socket
         |> assign(:stop_open, false)
         |> put_flash(:error, "Operator role required to revoke.")}
    end
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

  # Defense-in-depth preconditions guard. The Run button is disabled
  # in render whenever `permission != :active`, but a stale browser
  # tab / scripted click / keyboard shortcut can still fire this
  # event. Re-check every gate before submitting so an out-of-sync
  # UI cannot bypass the role model, the active wallet binding, the
  # active delegation, or the binding↔delegation correspondence.
  def handle_event("intent:run", _, socket) do
    # P4's `with` guard already excludes any non-:active delegation state
    # (the `%Delegation{state: :active, ...}` pattern fails on :revoking,
    # :revoke_failed, :revoked, :expired, :install_failed). P5's separate
    # cond-clause revoke-blocking guard is therefore subsumed; this
    # single guard covers role + binding + delegation + binding↔SA + chain.
    with :ok <- LiveAuth.authorize_action(socket, :operator),
         %WalletBinding{} = binding <- socket.assigns[:wallet_binding],
         %Delegation{state: :active, smart_account_id: sa_id} <-
           socket.assigns[:delegation],
         ^sa_id <- SessionPermissions.compute_smart_account_id(binding),
         :base_sepolia <- intent_chain_check() do
      workspace_id = intent_workspace_id(socket)
      payload = intent_payload(socket.assigns.mode)

      case Bank.Intents.submit(payload, workspace_id: workspace_id, actor: :user) do
        {:ok, %{intent: intent}} ->
          RuntimePubSub.subscribe(RuntimePubSub.intent(intent.id))
          Process.send_after(self(), {:intent_timeout, intent.id}, @intent_timeout_ms)

          {:noreply,
           socket
           |> assign(:intent, :executing)
           |> assign(:active_intent_id, intent.id)
           |> assign(:last_result, nil)}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(:intent, :failed)
           |> assign(:last_result, %{
             state: "failed",
             reason: intent_format_error(reason),
             tx_hash: nil
           })}
      end
    else
      # Any precondition failure — silently no-op so a stale UI click
      # can't bypass the gates. Defense-in-depth on top of the role
      # model and the rendered button state.
      _ -> {:noreply, socket}
    end
  end

  def handle_event("intent:approve", _, socket) do
    with :ok <- LiveAuth.authorize_action(socket, :operator),
         %{decision_envelope_id: env_id} when is_binary(env_id) <-
           socket.assigns.last_result || %{} do
      user_id = intent_actor_id(socket)

      case Bank.Decisions.approve(env_id, actor_id: user_id) do
        {:ok, _envelope, {:dispatched, _plan}} ->
          # Execution events arrive via PubSub; UI flips on :execution_updated.
          {:noreply, socket}

        {:ok, _envelope, {:held, reason}} ->
          # Approval succeeded server-side, but dispatch is held —
          # surface that as an amber IntentResult so the UI never
          # implies success. The intent is no longer "needs-approval"
          # (the operator has approved) but it is also not executed.
          {:noreply,
           socket
           |> assign(:intent, :needs_approval)
           |> assign(:last_result, %{
             state: "held",
             reason: "Approved · awaiting dispatch (#{reason})",
             tx_hash: nil
           })}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Approve failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Operator role required to approve.")}

      _ ->
        {:noreply, socket}
    end
  end

  # ── Async transitions ────────────────────────────────────────────────

  @impl true
  def handle_info(%{topic: :security_events, payload: payload}, socket) do
    handle_security_event(payload, socket)
  end

  def handle_info(
        %{
          topic: :intent_lifecycle,
          event: :decision_updated,
          intent_id: intent_id,
          payload: payload
        },
        socket
      ) do
    if socket.assigns[:active_intent_id] == intent_id do
      handle_decision_updated(socket, payload)
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        %{
          topic: :intent_lifecycle,
          event: :execution_updated,
          intent_id: intent_id,
          payload: payload
        },
        socket
      ) do
    if socket.assigns[:active_intent_id] == intent_id do
      handle_execution_updated(socket, payload)
    else
      {:noreply, socket}
    end
  end

  # Other intent_lifecycle events (`:state_changed`, `:execution_requested`,
  # `:evaluation_deferred`) arrive on the same topic. The UI doesn't
  # need to react to them — `:decision_updated` and `:execution_updated`
  # already cover every IntentResult variant — but we have to swallow
  # them so the LiveView doesn't crash on unmatched messages.
  def handle_info(%{topic: :intent_lifecycle}, socket), do: {:noreply, socket}

  # Test-only shortcut: flip :permission to :active without setting up
  # a binding + delegation in the DB. The real install flow drives
  # :permission via `recompute_permission/1`; this clause lets the
  # test_intent_card test fixture exercise intent submission without
  # owning the wallet/install dance.
  #
  # NOTE: this only flips the `:permission` assign. The hardened
  # `intent:run` preconditions check the `:wallet_binding` and
  # `:delegation` assigns directly, so tests that exercise the
  # `intent:run` path must seed real DB rows and use
  # `:_test_reload_state` (below) instead of `:permission_signed`.
  def handle_info(:permission_signed, socket) do
    {:noreply, assign(socket, :permission, :active)}
  end

  # Test-only shortcut: re-read the wallet binding + delegation from
  # the DB and recompute the permission state. Tests seed the rows
  # AFTER `live(conn, "/")` (mount has already run by then), so they
  # need a way to make the LiveView pick the rows up without forcing
  # a full re-mount. Mirrors what `wallet_connect:verify` and
  # `session_permission_install:confirmed` would do on the real path.
  def handle_info(:_test_reload_state, socket) do
    {:noreply,
     socket
     |> load_wallet_binding()
     |> refresh_delegation()
     |> recompute_permission()}
  end

  # 30s spinner-timeout watchdog scheduled by `intent:run`. Only flip
  # to `:slow` if we're still waiting on the same intent — a real
  # decision/execution event that landed earlier would have advanced
  # `:intent` past `:executing`, so the watchdog becomes a silent
  # no-op. `:slow` is non-terminal: a late `:decision_updated` /
  # `:execution_updated` event will overwrite it via the existing
  # handlers.
  def handle_info({:intent_timeout, intent_id}, socket) do
    if socket.assigns[:active_intent_id] == intent_id and
         socket.assigns[:intent] == :executing do
      {:noreply,
       socket
       |> assign(:intent, :slow)
       |> assign(:last_result, %{state: "slow", reason: nil, tx_hash: nil})}
    else
      {:noreply, socket}
    end
  end

  # Install-status poll. Re-reads the delegation row from the DB and
  # recomputes `:permission`. Stops as soon as `:active` lands or
  # the attempt budget is exhausted. Runs in addition to (not in
  # place of) the security:events / audit:stream PubSub
  # subscriptions — see the @install_poll_attempts comment for the
  # three failure modes this backstops.
  def handle_info({:poll_install_status, attempt}, socket) do
    socket =
      socket
      |> refresh_delegation()
      |> recompute_permission()

    cond do
      socket.assigns[:permission] == :active ->
        # DB flipped to :active — UI is now caught up. Stop polling.
        {:noreply, socket}

      attempt >= @install_poll_attempts - 1 ->
        # Out of attempts. Leave the UI in :installing; the operator
        # can refresh manually or let security:events catch up if
        # the worker eventually completes.
        {:noreply, socket}

      true ->
        next = attempt + 1
        delay = install_poll_delay_ms(next)
        Process.send_after(self(), {:poll_install_status, next}, delay)
        {:noreply, socket}
    end
  end

  # ── audit:stream live tail (I4) ─────────────────────────────────────
  # Every successful Bank.Audit.append_event/1 broadcast lands here.
  # We re-fetch the row to enforce workspace scoping (the broadcast
  # payload doesn't carry workspace_id) and to access before_ref /
  # after_ref for the ActivityView mapping. Cross-workspace events
  # and admin-tier event types (auth.*, api_key.*) are skipped.
  def handle_info(%{topic: :audit_stream, event: :appended, payload: %{id: event_id}}, socket) do
    ws_id = activity_workspace_id(socket)

    case Repo.get(AuditEvent, event_id) do
      %AuditEvent{workspace_id: ^ws_id} = event ->
        if visible_audit_event?(event) do
          entry = ActivityView.render(event)
          activity = [entry | socket.assigns.activity] |> Enum.take(@activity_cap)
          {:noreply, assign(socket, :activity, activity)}
        else
          {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  # ── Intent helpers ────────────────────────────────────────────────────

  # Today the agent only submits to base-sepolia (sandbox-only). The
  # placeholder lets a future toggle flip the runtime onto mainnet
  # without touching the call site (return `{:error, :mainnet}` then).
  defp intent_chain_check, do: :base_sepolia

  # Always force `chain: "base-sepolia"` regardless of mode/settings.
  # Sandbox-only safety: this LiveView must never submit a mainnet
  # payload, even if a future mode-card change accidentally exposes a
  # chain field to the user.
  defp intent_payload("hold") do
    %{
      "agent_id" => "test-agent",
      "source" => "user",
      "idempotency_key" => "hold-#{System.unique_integer([:positive])}",
      "kind" => "transfer",
      "chain" => "base-sepolia",
      "asset" => "USDC",
      "amount" => "1.0",
      "target" => %{"raw_address" => "0x0000000000000000000000000000000000000000"}
    }
  end

  defp intent_payload("swap") do
    %{
      "agent_id" => "test-agent",
      "source" => "user",
      "idempotency_key" => "swap-#{System.unique_integer([:positive])}",
      "kind" => "swap",
      "chain" => "base-sepolia",
      "asset" => "USDC",
      "amount" => "10.0",
      "target" => %{"raw_address" => "0x0000000000000000000000000000000000000001"}
    }
  end

  defp intent_payload("earn") do
    %{
      "agent_id" => "test-agent",
      "source" => "user",
      "idempotency_key" => "earn-#{System.unique_integer([:positive])}",
      "kind" => "allocate_idle_capital",
      "chain" => "base-sepolia",
      "asset" => "USDC",
      "amount" => "25.0",
      "target" => %{"raw_address" => "0x0000000000000000000000000000000000000002"}
    }
  end

  defp intent_workspace_id(socket) do
    case socket.assigns[:current_scope] do
      %{workspace: %{id: id}} -> id
      _ -> nil
    end
  end

  defp intent_actor_id(socket) do
    case socket.assigns[:current_scope] do
      %{user: %{id: id}} -> id
      _ -> nil
    end
  end

  # Used in render/1 — only the test intent card cares about the
  # current user's role today, so the helper lives in the parent
  # LiveView rather than each card module re-deriving it.
  defp intent_user_role(assigns) do
    case assigns[:current_scope] do
      %{role: role} when is_atom(role) -> role
      _ -> :viewer
    end
  end

  defp intent_format_error({:idempotency_conflict, _}),
    do: "Intent rejected: same idempotency key, different payload."

  defp intent_format_error({:unsupported_chain, chain}),
    do: "Intent rejected: chain #{inspect(chain)} not supported."

  defp intent_format_error({:unsupported_asset, asset}),
    do: "Intent rejected: asset #{inspect(asset)} not supported."

  defp intent_format_error({:morpho_chain_not_supported, chain}),
    do: "Intent rejected: Morpho deposit not available on #{chain}."

  defp intent_format_error(:mainnet_disabled),
    do: "Intent rejected: this workspace cannot submit to mainnet."

  defp intent_format_error({:invalid, %Ecto.Changeset{}}),
    do: "Intent rejected: payload failed validation."

  defp intent_format_error({:invalid, reason}) when is_atom(reason),
    do: "Intent rejected: #{Atom.to_string(reason)}."

  defp intent_format_error({:invalid, reason}),
    do: "Intent rejected: #{inspect(reason)}."

  defp intent_format_error(reason), do: "Intent rejected: #{inspect(reason)}."

  defp intent_action_for("hold"), do: "No-op intent executed"
  defp intent_action_for("swap"), do: "Swap executed"
  defp intent_action_for("earn"), do: "Morpho deposit executed"
  defp intent_action_for(_), do: "Intent executed"

  defp intent_short_tx(nil), do: nil
  defp intent_short_tx([]), do: nil

  defp intent_short_tx([first | _]) when is_binary(first), do: intent_short_tx(first)

  defp intent_short_tx(hash) when is_binary(hash) do
    if String.length(hash) > 10 do
      String.slice(hash, 0, 6) <> "…" <> String.slice(hash, -4, 4)
    else
      hash
    end
  end

  defp intent_short_tx(_), do: nil

  defp intent_reason_first(reasons) when is_map(reasons) do
    case Map.get(reasons, "items") do
      [first | _] -> intent_reason_message(first)
      _ -> nil
    end
  end

  defp intent_reason_first(_), do: nil

  defp intent_reason_message(%{"message" => msg}) when is_binary(msg), do: msg
  defp intent_reason_message(%{message: msg}) when is_binary(msg), do: msg
  defp intent_reason_message(_), do: nil

  defp handle_decision_updated(socket, %{outcome: outcome} = payload) do
    case outcome do
      :auto_exec ->
        # Decision says auto-execute; execution events will follow on the
        # same topic. Keep the running spinner visible.
        {:noreply, socket}

      :hold ->
        {:noreply,
         socket
         |> assign(:intent, :blocked)
         |> assign(:last_result, %{
           state: "blocked",
           reason: intent_lookup_decision_reason(payload),
           tx_hash: nil
         })}

      :approval_required ->
        {:noreply,
         socket
         |> assign(:intent, :needs_approval)
         |> assign(:last_result, %{
           state: "needs-approval",
           reason: intent_lookup_decision_reason(payload),
           decision_envelope_id: payload[:decision_envelope_id],
           tx_hash: nil
         })}

      :block ->
        {:noreply,
         socket
         |> assign(:intent, :blocked)
         |> assign(:last_result, %{
           state: "blocked",
           reason: intent_lookup_decision_reason(payload),
           tx_hash: nil
         })}

      _ ->
        {:noreply, socket}
    end
  end

  defp handle_decision_updated(socket, _payload), do: {:noreply, socket}

  defp handle_execution_updated(socket, payload) do
    final = payload[:final_outcome]
    tx_refs = payload[:tx_refs] || []

    case final do
      :confirmed ->
        {:noreply,
         socket
         |> assign(:intent, :executed)
         |> assign(:last_result, %{
           state: "executed",
           action: intent_action_for(socket.assigns.mode),
           tx_hash: intent_short_tx(tx_refs)
         })}

      f when f in [:reverted, :aborted] ->
        {:noreply,
         socket
         |> assign(:intent, :failed)
         |> assign(:last_result, %{
           state: "failed",
           reason: "Execution #{Atom.to_string(f)}.",
           tx_hash: intent_short_tx(tx_refs)
         })}

      _ ->
        {:noreply, socket}
    end
  end

  # Pull the first `reasons` message off the persisted decision envelope
  # for human-readable copy on the IntentResult card. The PubSub
  # `:decision_updated` payload only carries the envelope id + outcome,
  # not the full reasons list, so we read the row by id. Falls back to a
  # generic copy when the lookup fails.
  defp intent_lookup_decision_reason(%{decision_envelope_id: env_id}) when is_binary(env_id) do
    case Bank.Decisions.get_envelope(env_id) do
      {:ok, %{reasons: reasons}} -> intent_reason_first(reasons)
      _ -> nil
    end
  end

  defp intent_lookup_decision_reason(_), do: nil

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
    |> refresh_balance(binding)
  end

  defp reset_wallet(socket) do
    socket
    |> assign(:wallet, :disconnected)
    |> assign(:address, nil)
    |> assign(:wallet_binding, nil)
    |> assign(:balance_usdc, nil)
  end

  # Read live USDC balance from Base Sepolia for the bound EOA. Best
  # effort: any RPC failure (timeout, misconfig, malformed response)
  # falls back to `nil`, which `format_usdc/1` renders as "— USDC".
  # We never surface RPC noise to the user — the wallet card simply
  # shows "—" until the next refresh succeeds.
  defp refresh_balance(socket, %WalletBinding{address: address}) when is_binary(address) do
    case Bank.Chains.BalanceReader.get_erc20_balance("base-sepolia", address, :usdc) do
      {:ok, %Decimal{} = balance} -> assign(socket, :balance_usdc, balance)
      {:error, _} -> assign(socket, :balance_usdc, nil)
    end
  end

  defp refresh_balance(socket, _), do: assign(socket, :balance_usdc, nil)

  # When the wallet disconnects (either auto via the hook's
  # `wallet_connect:disconnected` event or operator-initiated via
  # `wallet_connect:disconnect`), the DB delegation row is left
  # alone — the `:active` row is the back-end's truth and only
  # `Bank.Security.revoke_delegation/2` may flip it. But the agent
  # cannot run without a current wallet context, so the visible
  # permission state must fail-closed: we force `:permission` to
  # `:not_installed` and reset the install-state side channels so
  # the UI doesn't claim the agent is runnable. The next
  # `refresh_delegation` after a re-bind will re-read the row.
  defp fail_close_permission_after_disconnect(socket) do
    socket
    |> assign(:permission, :not_installed)
    |> assign(:browser_install_state, :idle)
    |> assign(:install_failure_reason, nil)
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

  # ── Activity helpers (I4) ────────────────────────────────────────────

  # Load the workspace's recent audit slice, transformed for the strip.
  # Empty list when no scope (anonymous test render).
  defp load_activity(socket) do
    case activity_workspace_id(socket) do
      nil ->
        []

      ws_id ->
        %{events: events} =
          Audit.list_events(%{workspace_id: ws_id}, limit: @activity_cap, order: :desc)

        events
        |> Enum.filter(&visible_audit_event?/1)
        |> ActivityView.render()
    end
  end

  defp activity_workspace_id(socket) do
    case socket.assigns[:current_scope] do
      %{workspace: %{id: id}} -> id
      _ -> nil
    end
  end

  defp visible_audit_event?(%AuditEvent{event_type: "auth." <> _}), do: false
  defp visible_audit_event?(%AuditEvent{event_type: "api_key." <> _}), do: false
  defp visible_audit_event?(%AuditEvent{}), do: true

  # ── Permission helpers (I2) ──────────────────────────────────────────

  defp do_confirm_stop_revoke(socket) do
    case socket.assigns.delegation do
      %Delegation{smart_account_id: sa_id} when is_binary(sa_id) ->
        scope = socket.assigns[:current_scope]
        actor_id = scope && scope.user && scope.user.id

        case Bank.Security.revoke_delegation(sa_id,
               reason: :operator_requested,
               actor: :user,
               actor_id: actor_id
             ) do
          {:ok, _job} ->
            {:noreply,
             socket
             |> assign(:stop_open, false)
             |> refresh_delegation()
             |> recompute_permission()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:stop_open, false)
             |> put_flash(:error, "Revoke failed: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, assign(socket, :stop_open, false)}
    end
  end

  # Re-load the active delegation for the bound wallet from the DB. If
  # multiple `:active` rows match the same binding's smart_account_id
  # (cannot happen on the happy path because of the partial-unique
  # index, but the directive demands fail-closed posture), set the
  # ambiguous flag and surface the banner.
  defp refresh_delegation(socket) do
    case socket.assigns[:wallet_binding] do
      %WalletBinding{} = binding ->
        ws_id = workspace_id_from_socket(socket)

        if is_binary(ws_id) do
          case find_active_delegation(ws_id, binding) do
            {:ok, delegation} ->
              socket
              |> assign(:delegation, delegation)
              |> assign(:permission_ambiguous?, false)

            {:error, :ambiguous} ->
              socket
              |> assign(:delegation, :ambiguous)
              |> assign(:permission_ambiguous?, true)
          end
        else
          socket
          |> assign(:delegation, nil)
          |> assign(:permission_ambiguous?, false)
        end

      _ ->
        socket
        |> assign(:delegation, nil)
        |> assign(:permission_ambiguous?, false)
    end
  end

  # Per the directive: filter `Bank.Delegations.list_active/1` to only
  # rows whose `smart_account_id` matches what we'd compute for this
  # binding. Multiple `:active` rows for the same binding are
  # ambiguous and must fail closed.
  @doc false
  def find_active_delegation(workspace_id, %WalletBinding{} = binding)
      when is_binary(workspace_id) do
    expected_sa = SessionPermissions.compute_smart_account_id(binding)

    Delegations.list_active(workspace_id: workspace_id)
    |> Enum.filter(&(&1.smart_account_id == expected_sa))
    |> case do
      [] ->
        {:ok, nil}

      [one] ->
        {:ok, one}

      many ->
        active_count = Enum.count(many, &(&1.state == :active))

        if active_count > 1 do
          {:error, :ambiguous}
        else
          sorted = Enum.sort_by(many, & &1.inserted_at, {:desc, NaiveDateTime})
          {:ok, hd(sorted)}
        end
    end
  end

  # Maps backend (delegation row + binding + browser-install state) to
  # the design's permission enum. The card renders off this single
  # value plus a few side-channel banner flags.
  @doc false
  def permission_state(binding, delegation, install_state \\ :idle)

  # Ambiguous (multiple :active rows for the same binding) — fail
  # closed regardless of binding presence.
  def permission_state(_binding, :ambiguous, _), do: :failed

  # No binding → not installed, no matter what the install state says.
  # The user must connect/verify a wallet first.
  def permission_state(nil, _, _), do: :not_installed

  # Binding present, no delegation row yet — the install state drives
  # the surface.
  def permission_state(_b, nil, :idle), do: :not_installed

  def permission_state(_b, nil, s)
      when s in [:awaiting, :submitted, :confirmed],
      do: :installing

  def permission_state(_b, nil, s)
      when s in [:user_rejected, :bundler_rejected, :reverted, :failed, :wrong_chain],
      do: :failed

  # Delegation row present — its state is the source of truth.
  def permission_state(_b, %Delegation{state: :pending}, _), do: :installing
  def permission_state(_b, %Delegation{state: :active}, _), do: :active
  def permission_state(_b, %Delegation{state: :revoking}, _), do: :installing
  def permission_state(_b, %Delegation{state: :revoke_failed}, _), do: :failed
  def permission_state(_b, %Delegation{state: :revoked}, _), do: :revoked
  def permission_state(_b, %Delegation{state: :expired}, _), do: :expired
  def permission_state(_b, %Delegation{state: :install_failed}, _), do: :failed

  defp recompute_permission(socket) do
    binding = socket.assigns[:wallet_binding]
    delegation = socket.assigns[:delegation]
    install_state = socket.assigns[:browser_install_state] || :idle

    perm = permission_state(binding, delegation, install_state)
    assign(socket, :permission, perm)
  end

  # Polling is only meaningful when the JS hook has reported
  # `:confirmed` (the BE has been told the userop landed) but the
  # delegation row hasn't yet flipped to `:active`. The JS hook
  # NEVER pushes `:confirmed` past `postConfirmedAttestation` — and
  # that POST returns ok ONLY when `BrowserInstall.record_attestation/3`
  # accepted the row write. So `:browser_install_state == :confirmed`
  # already implies "the BE persisted the attestation"; what we're
  # waiting for here is the on-chain verifier worker.
  @doc false
  def needs_install_polling?(socket) do
    socket.assigns[:browser_install_state] == :confirmed and
      socket.assigns[:permission] != :active
  end

  # Exponential backoff: 2s · 2^attempt, clamped to @install_poll_max_ms.
  # Attempts: 0 → 2s, 1 → 4s, 2 → 8s, 3 → 16s, 4 → 32s, 5 → 32s.
  @doc false
  def install_poll_delay_ms(attempt) when is_integer(attempt) and attempt >= 0 do
    raw = @install_poll_base_ms * round(:math.pow(2, attempt))
    min(raw, @install_poll_max_ms)
  end

  # `:ambiguous` is a sentinel we stash in the assign instead of a
  # struct; the card only knows how to render with `nil` or a
  # `%Delegation{}`. The banner already covers the ambiguous case via
  # the `ambiguous?` attr.
  defp delegation_for_card(:ambiguous), do: nil
  defp delegation_for_card(other), do: other

  defp workspace_id_from_socket(socket) do
    case socket.assigns[:current_scope] do
      %{workspace: %{id: id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp parse_install_failure_reason(reason) when is_atom(reason) do
    if reason in BrowserInstall.failure_categories(), do: reason, else: :unknown
  end

  defp parse_install_failure_reason(reason) when is_binary(reason) do
    try do
      atom = String.to_existing_atom(reason)
      if atom in BrowserInstall.failure_categories(), do: atom, else: :unknown
    rescue
      ArgumentError -> :unknown
    end
  end

  defp parse_install_failure_reason(_), do: :unknown

  # security:events fan-in. Only the delegation-related events touch
  # this card; pause/resume/etc. are owned elsewhere. Compare on
  # `smart_account_id` so an unrelated revoke in the workspace doesn't
  # noisily refresh this view.
  defp handle_security_event(%{event: event, payload: payload} = _msg, socket)
       when event in [
              :delegation_revoke_requested,
              :delegation_revoked,
              :delegation_state_changed
            ] do
    sa_id = Map.get(payload, :smart_account_id) || Map.get(payload, "smart_account_id")
    current_sa = current_smart_account_id(socket.assigns.delegation)

    cond do
      is_nil(sa_id) ->
        {:noreply, socket}

      current_sa == sa_id ->
        {:noreply, socket |> refresh_delegation() |> recompute_permission()}

      true ->
        {:noreply, socket}
    end
  end

  defp handle_security_event(_payload, socket), do: {:noreply, socket}

  defp current_smart_account_id(%Delegation{smart_account_id: id}), do: id
  defp current_smart_account_id(_), do: nil

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
      delegation={delegation_for_card(@delegation)}
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
        <.permission_card
          wallet={@wallet}
          permission={@permission}
          binding={@wallet_binding}
          delegation={delegation_for_card(@delegation)}
          ambiguous?={@permission_ambiguous?}
          install_failure_reason={@install_failure_reason}
          wrong_chain_id={@wrong_chain_id}
        />
        <.mode_card mode={@mode} settings={@settings} permission={@permission} />
        <.test_intent_card
          mode={@mode}
          intent={@intent}
          last_result={@last_result}
          permission={@permission}
          user_role={intent_user_role(assigns)}
        />
        <.activity_strip activity={@activity} />
        <.stop_card permission={@permission} delegation={delegation_for_card(@delegation)} />
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
          <span class="hint">
            {if @locked?, do: "Locked — install permission first", else: "Live"}
          </span>
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
          <input
            type="text"
            name="settings[slippage]"
            value={@settings["slippage"]}
            class="mono tnum"
          />
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
  attr :delegation, :any, default: nil

  defp stop_card(assigns) do
    # Defense-in-depth (P5): the design's permission enum collapses
    # `:revoking` → `:installing`, so naively gating on `:installing`
    # would re-enable Stop while a revoke is already in flight. Look
    # at the raw delegation row state directly so a half-revoked
    # row doesn't let the user double-click Stop.
    #
    # `:revoke_failed` is a deliberate exception: the domain says the
    # on-chain delegation may still be live and the operator must be
    # able to retry revoke. We special-case it via
    # `delegation_retry_revoke?/1` so the Stop CTA stays enabled even
    # though `permission == :failed` for that state.
    active? =
      delegation_retry_revoke?(assigns.delegation) or
        (assigns.permission in [:active, :installing] and
           not stop_blocked_by_delegation?(assigns.delegation))

    assigns = assign(assigns, :active?, active?)
    assigns = assign(assigns, :retry_revoke?, delegation_retry_revoke?(assigns.delegation))

    ~H"""
    <.card tone="danger">
      <div class="stop">
        <div>
          <div class="stop__eye ucase">06 — Emergency stop</div>
          <div class="serif stop__title">
            <%= if @retry_revoke? do %>
              Retry revoke
            <% else %>
              Stop the agent
            <% end %>
          </div>
          <div class="stop__sub">
            <%= cond do %>
              <% @retry_revoke? -> %>
                Last revoke attempt failed and the on-chain permission may still be live. Retrying re-submits the revoke userop.
              <% @active? -> %>
                Revokes permission immediately. In-flight intents will be blocked. You can reinstall later.
              <% true -> %>
                Revokes permission immediately. No agent permission is active right now — the agent already cannot move funds.
            <% end %>
          </div>
        </div>
        <button
          type="button"
          class={["btn btn--danger", not @active? && "is-disabled"]}
          disabled={not @active?}
          phx-click="permission:revoke"
        >
          <.cb_icon name="stop" size={14} />
          {if @retry_revoke?, do: "Retry revoke", else: "Revoke permission"}
        </button>
      </div>
    </.card>
    """
  end

  # See `AgentLayouts.stop_blocked_by_delegation?/1` for the rationale.
  # `:revoke_failed` is intentionally not blocked — the operator must
  # be able to retry. Stop remains gated for `:revoking` (already in
  # flight), `:revoked` / `:expired` (terminal — nothing left to do),
  # and `:install_failed` (no permission ever installed).
  defp stop_blocked_by_delegation?(%Delegation{state: state})
       when state in [:revoking, :revoked, :expired, :install_failed],
       do: true

  defp stop_blocked_by_delegation?(_), do: false

  defp delegation_retry_revoke?(%Delegation{state: :revoke_failed}), do: true
  defp delegation_retry_revoke?(_), do: false
end
