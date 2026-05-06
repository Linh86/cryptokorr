defmodule BankWeb.ControlLive do
  @moduledoc """
  Control tower landing page — connection and delegation status.

  This is the operator's first screen. It shows:

    * Whether the runtime is paused
    * The current smart-account delegation state
    * Whether execution is currently possible
    * Quick actions: refresh, revoke delegation
    * Next-step guidance based on the current state

  Real-time updates arrive through PubSub on `security:events`.
  The LiveView subscribes on mount and pushes state changes without
  polling.

  ## Design decisions

  **Browser wallet connect with EOA identity binding.** The page
  renders a wallet status region driven by the EIP-1193
  `WalletConnect` JS hook. After the operator connects on Base
  Sepolia, Phoenix issues a short-lived signed challenge
  (`Bank.WalletBindings`); the browser signs it with `personal_sign`
  and Phoenix verifies the signature recovers the connected EOA.
  The verified binding is the foundation the smart-account
  delegation install (#171) builds on. The hook never broadcasts
  transactions and never handles private keys — it only signs
  the server-issued message.

  **Multi-account aware.** Operators routinely run more than one
  smart account (e.g. production treasury plus a sandbox account).
  When there is at least one non-terminal delegation the page shows
  a selector row across every account and renders the delegation
  card + next-steps panel for whichever is currently selected. The
  first delegation is selected by default; selection persists in
  socket assigns and is preserved across PubSub refreshes when the
  account still exists.
  """

  use BankWeb, :live_view

  alias Bank.Delegations
  alias Bank.Security
  alias Bank.SessionPermissions
  alias Bank.WalletBindings

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.security_events())
    end

    socket =
      socket
      |> assign(page_title: "Connection")
      |> assign(wallet_status: :not_connected)
      |> assign(wallet_account: nil)
      |> assign(wallet_chain_id: nil)
      |> assign(wallet_error_message: nil)
      |> assign(wallet_failure_reason: nil)
      |> assign(wallet_binding: nil)
      # Browser-driven session permission install (#473) state
      # machine: idle → awaiting_signature → signing → submitted
      # → confirmed (or failed). Drives the
      # `session_permission_browser_install_card/1` UI states.
      |> assign(browser_install_state: :idle)
      |> assign(browser_install_failure_reason: nil)
      |> assign(browser_install_message: nil)
      |> load_wallet_binding()
      |> load_state()

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_state() |> put_flash(:info, "Status refreshed")}
  end

  def handle_event("select_account", %{"smart-account-id" => sa_id}, socket) do
    ids = Enum.map(socket.assigns.delegations, & &1.smart_account_id)

    if sa_id in ids do
      {:noreply, socket |> assign(:selected_smart_account_id, sa_id) |> refresh_selected()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("install_session_permission", _params, socket) do
    workspace_id = socket.assigns.current_scope.workspace.id

    case socket.assigns.wallet_binding do
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Connect and bind a wallet before installing a session permission."
         )}

      binding ->
        case SessionPermissions.request_install(workspace_id, binding) do
          {:ok, smart_account_id} ->
            {:noreply,
             socket
             |> load_state()
             |> put_flash(
               :info,
               "Session permission install requested for #{smart_account_id}. Awaiting adapter confirmation."
             )}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Install rejected: #{install_refusal_message(reason)}")}
        end
    end
  end

  def handle_event("revoke_delegation", %{"smart-account-id" => sa_id}, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      case Security.revoke_delegation(sa_id, reason: :operator_requested, actor: :user) do
        {:ok, _job} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(:info, "Delegation revoke submitted. Awaiting on-chain confirmation.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Revoke failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to revoke a delegation.")}
    end
  end

  def handle_event("pause_runtime", _params, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      case Security.pause(:global, reason: :operator_requested, actor: :user) do
        {:ok, _} ->
          {:noreply, socket |> load_state() |> put_flash(:info, "Runtime paused")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Pause failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to pause the runtime.")}
    end
  end

  def handle_event("resume_runtime", _params, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      case Security.resume(:global, actor: :user) do
        {:ok, _} ->
          {:noreply, socket |> load_state() |> put_flash(:info, "Runtime resumed")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Resume failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to resume the runtime.")}
    end
  end

  # --- Wallet connect events ----------------------------------------------
  #
  # The `WalletConnect` JS hook drives the connection + binding flow.
  # After the wallet exposes accounts on Base Sepolia, Phoenix issues a
  # signed challenge; the browser signs and pushes the signature back;
  # Phoenix verifies and stamps the binding. No private keys, no
  # broadcasts.

  def handle_event("wallet_connect:unavailable", _params, socket) do
    {:noreply, reset_wallet(socket, status: :not_installed)}
  end

  def handle_event("wallet_connect:connecting", _params, socket) do
    {:noreply,
     socket
     |> assign(wallet_status: :connecting)
     |> assign(wallet_error_message: nil)
     |> assign(wallet_failure_reason: nil)}
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
         |> assign(wallet_status: :awaiting_signature)
         |> assign(wallet_account: binding.address)
         |> assign(wallet_chain_id: binding.chain_id)
         |> assign(wallet_error_message: nil)
         |> assign(wallet_failure_reason: nil)
         |> push_event("wallet_connect:challenge", %{
           challenge_id: binding.id,
           message: binding.challenge_message,
           address: binding.address
         })}

      {:error, reason} when is_atom(reason) ->
        {:noreply,
         socket
         |> assign(wallet_status: :bind_failed)
         |> assign(wallet_account: account)
         |> assign(wallet_chain_id: chain_id)
         |> assign(wallet_failure_reason: reason)}

      {:error, %Ecto.Changeset{}} ->
        {:noreply,
         socket
         |> assign(wallet_status: :bind_failed)
         |> assign(wallet_account: account)
         |> assign(wallet_chain_id: chain_id)
         |> assign(wallet_failure_reason: :invalid_challenge)}
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
        {:noreply,
         socket
         |> assign(wallet_status: :bound)
         |> assign(wallet_account: binding.address)
         |> assign(wallet_chain_id: binding.chain_id)
         |> assign(wallet_binding: binding)
         |> assign(wallet_failure_reason: nil)
         |> assign(wallet_error_message: nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(wallet_status: :bind_failed)
         |> assign(wallet_failure_reason: bind_failure_reason(reason))}
    end
  end

  def handle_event(
        "wallet_connect:verify_error",
        %{"reason" => reason},
        socket
      ) do
    {:noreply,
     socket
     |> assign(wallet_status: :bind_failed)
     |> assign(wallet_failure_reason: :user_rejected)
     |> assign(wallet_error_message: reason)}
  end

  def handle_event(
        "wallet_connect:wrong_chain",
        %{"chain_id" => chain_id} = params,
        socket
      ) do
    {:noreply,
     socket
     |> assign(wallet_status: :wrong_chain)
     |> assign(wallet_account: Map.get(params, "account"))
     |> assign(wallet_chain_id: chain_id)
     |> assign(wallet_error_message: nil)
     |> assign(wallet_failure_reason: nil)}
  end

  def handle_event("wallet_connect:cancelled", _params, socket) do
    {:noreply, reset_wallet(socket)}
  end

  def handle_event("wallet_connect:disconnected", _params, socket) do
    socket = revoke_active_binding(socket, :wallet_disconnected)
    {:noreply, reset_wallet(socket)}
  end

  def handle_event("wallet_connect:disconnect", _params, socket) do
    socket = revoke_active_binding(socket, :operator_requested)
    {:noreply, reset_wallet(socket)}
  end

  def handle_event("wallet_connect:error", params, socket) do
    {:noreply,
     socket
     |> assign(wallet_status: :error)
     |> assign(wallet_error_message: Map.get(params, "message", "Unknown wallet error"))
     |> assign(wallet_failure_reason: nil)}
  end

  # --- Browser-driven session permission install (#473) ------------------
  #
  # The `SessionPermissionInstall` JS hook drives the browser-signed
  # install. After the operator clicks
  # `#session-permission-browser-install-btn`, the hook verifies the
  # wallet is on Base Sepolia and pushes
  # `session_permission_install:requested`. Phoenix responds with a
  # canonical scope-bound message via `push_event` — Phoenix is the
  # source of truth for the scope summary the operator consents to.
  # The hook signs that exact message via `personal_sign` and pushes
  # the signature back; Phoenix records the consent and transitions
  # to `:submitted`.
  #
  # The actual ZeroDev SDK + bundler integration (real UserOp
  # build/submit/poll) is deferred until #472's design note pins the
  # package set. For now the hook synthesizes the
  # `submitted → confirmed` transition so the operator-facing UI
  # states are exercisable end-to-end.

  def handle_event("session_permission_install:requested", _params, socket) do
    case socket.assigns.wallet_binding do
      nil ->
        {:noreply,
         socket
         |> assign(browser_install_state: :failed)
         |> assign(browser_install_failure_reason: :no_wallet_binding)
         |> assign(browser_install_message: nil)}

      binding ->
        message = browser_install_scope_message(binding)

        {:noreply,
         socket
         |> assign(browser_install_state: :awaiting_signature)
         |> assign(browser_install_failure_reason: nil)
         |> assign(browser_install_message: nil)
         |> push_event("session_permission_install:scope_message", %{
           message: message,
           address: binding.address
         })}
    end
  end

  def handle_event("session_permission_install:wrong_chain", params, socket) do
    {:noreply,
     socket
     |> assign(browser_install_state: :failed)
     |> assign(browser_install_failure_reason: :wrong_chain)
     |> assign(
       browser_install_message:
         "Wallet is on chain #{Map.get(params, "chain_id")}; switch to Base Sepolia (84532) and retry."
     )}
  end

  def handle_event("session_permission_install:signed", _params, socket) do
    # Operator signed the canonical scope message. Audit + replay
    # of the UserOp submission is the next slice (#472 / #474). For
    # now we transition to `:submitted` and let the hook's
    # synthesized confirmation drive the final state.
    {:noreply,
     socket
     |> assign(browser_install_state: :signing)
     |> push_event("session_permission_install:submitted", %{})}
  end

  def handle_event("session_permission_install:submitted", _params, socket) do
    {:noreply,
     socket
     |> assign(browser_install_state: :submitted)
     |> assign(browser_install_failure_reason: nil)
     |> assign(browser_install_message: nil)}
  end

  def handle_event("session_permission_install:confirmed", _params, socket) do
    {:noreply,
     socket
     |> assign(browser_install_state: :confirmed)
     |> assign(browser_install_failure_reason: nil)
     |> assign(browser_install_message: nil)}
  end

  def handle_event("session_permission_install:failed", params, socket) do
    reason = parse_install_failure_reason(Map.get(params, "reason"))

    {:noreply,
     socket
     |> assign(browser_install_state: :failed)
     |> assign(browser_install_failure_reason: reason)
     |> assign(browser_install_message: Map.get(params, "message"))}
  end

  defp parse_install_failure_reason(reason)
       when reason in [
              "user_rejected",
              "wrong_chain",
              "insufficient_gas",
              "bundler_rejected",
              "network_error",
              "no_provider",
              "invalid_scope_message"
            ],
       do: String.to_atom(reason)

  defp parse_install_failure_reason(_), do: :unknown_error

  # The scope-bound EIP-191 message the operator signs. Phoenix is
  # the source of truth for the canonical scope summary
  # (`Bank.SessionPermissions.Scope.default/0`); the message embeds
  # a structured, human-readable summary so the operator's wallet
  # prompt shows exactly what they're consenting to. The on-chain
  # validator does not yet encode these scopes (see Scope module
  # docs); the runtime decision pipeline enforces them per dispatch.
  defp browser_install_scope_message(binding) do
    scope = Bank.SessionPermissions.Scope.default()
    issued_at = DateTime.utc_now() |> DateTime.to_iso8601()

    allowed_lines =
      scope["allowed"]
      |> Enum.map(fn entry -> "  ALLOWED: #{entry["label"]}" end)
      |> Enum.join("\n")

    denied_lines =
      scope["denied"]
      |> Enum.map(fn entry -> "  DENIED:  #{entry["label"]}" end)
      |> Enum.join("\n")

    """
    CryptoBank session permission install consent

    Account:        #{binding.address}
    Chain:          Base Sepolia (#{scope["chain_id"]})
    Kernel version: #{scope["kernel_version"]}
    Scope version:  #{scope["version"]}
    Issued at:      #{issued_at}

    Allowed actions (each enforced by Phoenix runtime policy):
    #{allowed_lines}

    Explicitly denied actions:
    #{denied_lines}

    By signing, you authorise the listed actions under Phoenix policy.
    No mainnet, no arbitrary calldata, no unlimited approvals.
    """
  end

  # --- PubSub handlers ----------------------------------------------------

  @impl true
  def handle_info(%{topic: :security_events}, socket) do
    {:noreply, load_state(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Wallet helpers ------------------------------------------------------

  defp load_wallet_binding(socket) do
    workspace_id = socket.assigns.current_scope.workspace.id

    case WalletBindings.get_active_binding(workspace_id) do
      nil ->
        socket

      %_{} = binding ->
        socket
        |> assign(wallet_status: :bound)
        |> assign(wallet_account: binding.address)
        |> assign(wallet_chain_id: binding.chain_id)
        |> assign(wallet_binding: binding)
    end
  end

  defp reset_wallet(socket, opts \\ []) do
    status = Keyword.get(opts, :status, :not_connected)

    socket
    |> assign(wallet_status: status)
    |> assign(wallet_account: nil)
    |> assign(wallet_chain_id: nil)
    |> assign(wallet_error_message: nil)
    |> assign(wallet_failure_reason: nil)
    |> assign(wallet_binding: nil)
  end

  defp revoke_active_binding(socket, reason) do
    case socket.assigns.wallet_binding do
      nil ->
        socket

      %_{id: id} ->
        _ = WalletBindings.revoke_binding(id, reason)
        socket
    end
  end

  # Translate verify_and_bind error reasons into the small UI vocabulary
  # the wallet status card renders. The full reason set still lives in
  # the audit trail; the UI only needs to tell the operator what to
  # try next.
  defp bind_failure_reason(:not_found), do: :challenge_not_found
  defp bind_failure_reason(:already_verified), do: :already_verified
  defp bind_failure_reason(:revoked), do: :revoked
  defp bind_failure_reason(:expired), do: :expired
  defp bind_failure_reason(:address_mismatch), do: :address_mismatch
  defp bind_failure_reason(:malformed_signature), do: :malformed_signature
  defp bind_failure_reason(:invalid_signature), do: :invalid_signature
  defp bind_failure_reason(:invalid_recovery_id), do: :malformed_signature
  defp bind_failure_reason(:invalid_address), do: :malformed_signature
  defp bind_failure_reason(other) when is_atom(other), do: other
  defp bind_failure_reason(_), do: :unknown

  # --- State loading -------------------------------------------------------

  defp load_state(socket) do
    workspace_id = socket.assigns.current_scope.workspace.id
    delegations = Delegations.list_active(workspace_id: workspace_id)
    paused? = Security.paused?(:global)

    current = Map.get(socket.assigns, :selected_smart_account_id)
    ids = Enum.map(delegations, & &1.smart_account_id)

    selected_id =
      cond do
        current != nil and current in ids -> current
        delegations != [] -> hd(delegations).smart_account_id
        true -> nil
      end

    socket
    |> assign(:delegations, delegations)
    |> assign(:selected_smart_account_id, selected_id)
    |> assign(:paused, paused?)
    |> refresh_selected()
  end

  defp refresh_selected(socket) do
    selected =
      Enum.find(
        socket.assigns.delegations,
        &(&1.smart_account_id == socket.assigns.selected_smart_account_id)
      )

    execution_ready? =
      case selected do
        %{smart_account_id: sa_id, state: :active} -> Delegations.executable?(sa_id)
        _ -> false
      end

    socket
    |> assign(:selected_delegation, selected)
    |> assign(:execution_ready, execution_ready?)
  end

  # --- Render --------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_page={:connection}>
      <%!-- System status bar --%>
      <.system_status_bar paused={@paused} execution_ready={@execution_ready} />

      <%!-- Page header --%>
      <div class="mt-6 mb-8">
        <h1 id="page-title" class="text-2xl font-bold tracking-tight">Connection</h1>
        <p class="mt-1 text-sm text-base-content/60">
          Smart-account delegation and execution readiness
        </p>
      </div>

      <%!-- Account selector --%>
      <.account_selector
        :if={length(@delegations) > 1}
        delegations={@delegations}
        selected={@selected_smart_account_id}
      />

      <%!-- Main grid --%>
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- Left column: delegation card (spans 2) --%>
        <div class="lg:col-span-2 space-y-6">
          <.delegation_card delegation={@selected_delegation} paused={@paused} />
        </div>

        <%!-- Right column: status + actions --%>
        <div class="space-y-6">
          <.wallet_status_card
            status={@wallet_status}
            account={@wallet_account}
            chain_id={@wallet_chain_id}
            binding={@wallet_binding}
            error_message={@wallet_error_message}
            failure_reason={@wallet_failure_reason}
          />
          <.session_permission_card
            wallet_status={@wallet_status}
            binding={@wallet_binding}
            delegations={@delegations}
            paused={@paused}
          />
          <.session_permission_browser_install_card
            wallet_status={@wallet_status}
            install_state={@browser_install_state}
            failure_reason={@browser_install_failure_reason}
            failure_message={@browser_install_message}
          />
          <.next_steps_card
            delegation={@selected_delegation}
            paused={@paused}
            execution_ready={@execution_ready}
          />
          <.runtime_card paused={@paused} />
        </div>
      </div>

      <%!-- Architecture callout --%>
      <div id="architecture-info" class="mt-10 rounded-xl border border-base-300 bg-base-200/30 p-6">
        <h3 class="text-sm font-semibold text-base-content/80 mb-3">
          <.icon name="hero-shield-check" class="size-4 inline-block mr-1.5 -mt-0.5" />
          Non-custodial architecture
        </h3>
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-4 text-xs text-base-content/60 leading-relaxed">
          <div>
            <span class="font-medium text-base-content/70">Control plane</span>
            <p class="mt-1">
              Phoenix is the decision authority. It evaluates policy, manages approvals,
              and orchestrates execution. It never holds private keys.
            </p>
          </div>
          <div>
            <span class="font-medium text-base-content/70">Chain adapter</span>
            <p class="mt-1">
              A separate TypeScript service handles signing, broadcasting, and
              confirmation polling on Base. It reports outcomes back as callbacks.
            </p>
          </div>
          <div>
            <span class="font-medium text-base-content/70">On-chain guardrails</span>
            <p class="mt-1">
              Smart-account permission modules enforce spend limits, target restrictions,
              and revocable delegations — even if upstream systems fail.
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Component: system status bar ----------------------------------------

  attr :paused, :boolean, required: true
  attr :execution_ready, :boolean, required: true

  defp system_status_bar(assigns) do
    ~H"""
    <div id="system-status-bar" class="flex flex-wrap items-center gap-2">
      <div
        :if={@paused}
        id="pause-indicator"
        class="badge badge-warning gap-1.5 font-medium"
      >
        <.icon name="hero-pause-circle-solid" class="size-3.5" /> Runtime paused
      </div>
      <div
        :if={@execution_ready}
        id="execution-ready-indicator"
        class="badge badge-success gap-1.5 font-medium"
      >
        <.icon name="hero-check-circle-solid" class="size-3.5" /> Execution ready
      </div>
      <div
        :if={!@execution_ready && !@paused}
        id="execution-blocked-indicator"
        class="badge badge-ghost gap-1.5 font-medium"
      >
        <.icon name="hero-minus-circle-solid" class="size-3.5" /> Execution blocked
      </div>
    </div>
    """
  end

  # --- Component: account selector -----------------------------------------

  attr :delegations, :list, required: true
  attr :selected, :string, required: true

  defp account_selector(assigns) do
    ~H"""
    <div
      id="account-selector"
      class="mt-4 flex flex-wrap items-center gap-2 rounded-xl border border-base-300 bg-base-200/40 p-3"
    >
      <span class="text-xs uppercase tracking-wider text-base-content/50 mr-1">Account</span>
      <button
        :for={delegation <- @delegations}
        type="button"
        id={"account-tab-" <> delegation.smart_account_id}
        phx-click="select_account"
        phx-value-smart-account-id={delegation.smart_account_id}
        class={[
          "btn btn-xs gap-1.5 font-mono",
          if(delegation.smart_account_id == @selected,
            do: "btn-primary",
            else: "btn-ghost border border-base-300"
          )
        ]}
      >
        {short_id(delegation.smart_account_id)}
        <span class={["badge badge-xs", delegation_badge_class(delegation.state)]}>
          {delegation_label(delegation.state)}
        </span>
      </button>
    </div>
    """
  end

  # --- Component: delegation card ------------------------------------------

  attr :delegation, :map, required: true
  attr :paused, :boolean, required: true

  defp delegation_card(%{delegation: nil} = assigns) do
    ~H"""
    <div
      id="delegation-card"
      class="rounded-xl border-2 border-dashed border-base-300 bg-base-200/20 p-8"
    >
      <div class="flex flex-col items-center text-center">
        <div class="w-14 h-14 rounded-full bg-base-300/50 flex items-center justify-center mb-4">
          <.icon name="hero-link-slash" class="size-7 text-base-content/30" />
        </div>
        <h2 class="text-lg font-semibold text-base-content/70">No delegation connected</h2>
        <p class="mt-2 text-sm text-base-content/50 max-w-md">
          No smart account has an active delegation with this control plane.
          The adapter establishes delegations through the callback flow — this
          UI will reflect the state automatically once a delegation is granted.
        </p>
        <div class="mt-6">
          <.button phx-click="refresh" class="btn btn-primary btn-soft btn-sm gap-1.5">
            <.icon name="hero-arrow-path" class="size-3.5" /> Refresh status
          </.button>
        </div>
      </div>
    </div>
    """
  end

  defp delegation_card(assigns) do
    ~H"""
    <div id="delegation-card" class="rounded-xl border border-base-300 bg-base-100 shadow-sm">
      <%!-- Header --%>
      <div class="flex items-center justify-between px-6 py-4 border-b border-base-300">
        <div class="flex items-center gap-3">
          <div class={[
            "w-10 h-10 rounded-lg flex items-center justify-center",
            delegation_icon_bg(@delegation.state)
          ]}>
            <.icon name={delegation_icon(@delegation.state)} class="size-5" />
          </div>
          <div>
            <h2 class="font-semibold">Smart Account Delegation</h2>
            <p class="text-xs text-base-content/50 font-mono">
              {short_id(@delegation.smart_account_id)}
            </p>
          </div>
        </div>
        <.delegation_badge state={@delegation.state} />
      </div>

      <%!-- Details --%>
      <div class="px-6 py-5 space-y-4">
        <div class="grid grid-cols-2 gap-4">
          <.detail_item label="Chain" value="Base" />
          <.detail_item label="Asset" value="USDC" />
          <.detail_item label="Delegation ID" value={short_id(@delegation.delegation_id)} mono />
          <.detail_item
            label="Granted"
            value={format_datetime(@delegation.granted_at)}
          />
          <.detail_item
            :if={@delegation.expires_at}
            label="Expires"
            value={format_datetime(@delegation.expires_at)}
          />
          <.detail_item
            :if={@delegation.revoke_requested_at}
            label="Revoke requested"
            value={format_datetime(@delegation.revoke_requested_at)}
          />
          <.detail_item
            :if={@delegation.last_tx_hash}
            label="Tx hash"
            value={short_hash(@delegation.last_tx_hash)}
            mono
          />
          <.detail_item
            :if={@delegation.scope != %{}}
            label="Scope"
            value={inspect(@delegation.scope)}
          />
          <.detail_item
            :if={@delegation.state == :revoke_failed and @delegation.last_reason}
            label="Last failure"
            value={@delegation.last_reason}
          />
        </div>
        <div
          :if={@delegation.state == :revoke_failed and @delegation.last_reason}
          id="delegation-revoke-failure-banner"
          class="px-6 py-3 mt-1 border-t border-error/20 bg-error/5 text-xs text-error"
        >
          <.icon name="hero-exclamation-triangle" class="size-3.5 inline-block mr-1 -mt-0.5" />
          On-chain revoke failed: {@delegation.last_reason}. The delegation is still live; retry above.
        </div>
      </div>

      <%!-- Actions --%>
      <div class="flex items-center gap-3 px-6 py-4 border-t border-base-300 bg-base-200/20 rounded-b-xl">
        <.button phx-click="refresh" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
        </.button>
        <.button
          :if={@delegation.state in [:active, :pending]}
          id="revoke-btn"
          phx-click="revoke_delegation"
          phx-value-smart-account-id={@delegation.smart_account_id}
          data-confirm="Revoke this delegation? Execution will stop immediately. This cannot be undone from the API."
          class="btn btn-error btn-soft btn-sm gap-1.5"
        >
          <.icon name="hero-shield-exclamation" class="size-3.5" /> Revoke delegation
        </.button>
        <.button
          :if={@delegation.state == :revoke_failed}
          id="revoke-retry-btn"
          phx-click="revoke_delegation"
          phx-value-smart-account-id={@delegation.smart_account_id}
          data-confirm="Retry the revoke? The previous attempt failed on-chain and this delegation is still live."
          class="btn btn-error btn-soft btn-sm gap-1.5"
        >
          <.icon name="hero-arrow-path" class="size-3.5" /> Retry revoke
        </.button>
      </div>
    </div>
    """
  end

  # --- Component: detail item -----------------------------------------------

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false

  defp detail_item(assigns) do
    ~H"""
    <div>
      <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">{@label}</dt>
      <dd class={["text-sm", @mono && "font-mono text-base-content/80"]}>{@value}</dd>
    </div>
    """
  end

  # --- Component: delegation badge -----------------------------------------

  attr :state, :atom, required: true

  defp delegation_badge(assigns) do
    ~H"""
    <span
      id="delegation-state-badge"
      class={["badge font-medium", delegation_badge_class(@state)]}
    >
      {delegation_label(@state)}
    </span>
    """
  end

  # --- Component: next steps card ------------------------------------------

  attr :delegation, :map, required: true
  attr :paused, :boolean, required: true
  attr :execution_ready, :boolean, required: true

  defp next_steps_card(assigns) do
    ~H"""
    <div id="next-steps-card" class="rounded-xl border border-base-300 bg-base-100 shadow-sm p-5">
      <h3 class="text-sm font-semibold mb-3 flex items-center gap-1.5">
        <.icon name="hero-light-bulb" class="size-4 text-warning" /> Next steps
      </h3>
      <ul class="space-y-2.5 text-sm text-base-content/70">
        <.step_item
          :if={is_nil(@delegation)}
          status={:action}
          text="Connect a Base Sepolia wallet, verify the binding, then click Install session permission."
        />
        <.step_item
          :if={@delegation && @delegation.state == :pending}
          status={:waiting}
          text="Session permission install in flight — waiting for the adapter to confirm the on-chain grant."
        />
        <.step_item
          :if={@delegation && @delegation.state == :active && @paused}
          status={:action}
          text="Resume the runtime to enable execution"
        />
        <.step_item
          :if={@execution_ready}
          status={:done}
          text="Delegation active and execution ready"
        />
        <.step_item
          :if={@delegation && @delegation.state == :revoking}
          status={:waiting}
          text="Revocation in flight — awaiting on-chain confirmation"
        />
        <.step_item
          :if={@delegation && @delegation.state == :revoke_failed}
          status={:action}
          text="Previous revoke attempt failed on-chain — operator must retry to disable this delegation"
        />
        <.step_item
          :if={@execution_ready}
          status={:info}
          text="Intents submitted by agents will be evaluated and routed"
        />
      </ul>
    </div>
    """
  end

  attr :status, :atom, required: true
  attr :text, :string, required: true

  defp step_item(assigns) do
    ~H"""
    <li class="flex items-start gap-2">
      <.icon
        :if={@status == :action}
        name="hero-arrow-right-circle"
        class="size-4 mt-0.5 text-primary shrink-0"
      />
      <.icon
        :if={@status == :waiting}
        name="hero-clock"
        class="size-4 mt-0.5 text-warning shrink-0"
      />
      <.icon
        :if={@status == :done}
        name="hero-check-circle-solid"
        class="size-4 mt-0.5 text-success shrink-0"
      />
      <.icon
        :if={@status == :info}
        name="hero-information-circle"
        class="size-4 mt-0.5 text-base-content/40 shrink-0"
      />
      <span>{@text}</span>
    </li>
    """
  end

  # --- Component: wallet status card ---------------------------------------

  attr :status, :atom, required: true
  attr :account, :string, default: nil
  attr :chain_id, :integer, default: nil
  attr :binding, :map, default: nil
  attr :error_message, :string, default: nil
  attr :failure_reason, :atom, default: nil

  defp wallet_status_card(assigns) do
    ~H"""
    <div
      id="wallet-status-card"
      phx-hook="WalletConnect"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm p-5"
    >
      <h3 class="text-sm font-semibold mb-3 flex items-center gap-1.5">
        <.icon name="hero-wallet" class="size-4" /> Browser wallet
      </h3>

      <div id="wallet-status" class="space-y-3">
        <div
          :if={@status == :not_installed}
          id="wallet-status-not-installed"
          class="flex items-start gap-2 text-sm text-base-content/70"
        >
          <.icon name="hero-exclamation-triangle" class="size-4 mt-0.5 text-warning shrink-0" />
          <p>
            No browser wallet detected. Install MetaMask (or another EIP-1193 wallet) and reload this page.
          </p>
        </div>

        <div
          :if={@status == :connecting}
          id="wallet-status-connecting"
          class="flex items-center gap-2 text-sm text-base-content/70"
        >
          <.icon name="hero-arrow-path" class="size-4 animate-spin text-base-content/50" />
          <p>Connecting — confirm the prompt in your wallet…</p>
        </div>

        <div
          :if={@status == :awaiting_signature}
          id="wallet-status-awaiting-signature"
          class="space-y-2 text-sm"
        >
          <div class="flex items-center gap-2 text-base-content/70">
            <.icon name="hero-arrow-path" class="size-4 animate-spin text-base-content/50" />
            <span>Awaiting signature — confirm the binding message in your wallet…</span>
          </div>
          <div>
            <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
              Address
            </dt>
            <dd id="wallet-status-address" class="font-mono text-sm text-base-content/80 break-all">
              {@account}
            </dd>
          </div>
          <div>
            <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
              Chain
            </dt>
            <dd id="wallet-status-chain" class="text-sm text-base-content/80">
              {chain_label(@chain_id)}
            </dd>
          </div>
          <button
            id="wallet-disconnect-btn"
            type="button"
            phx-click="wallet_connect:disconnect"
            class="btn btn-ghost btn-xs gap-1.5"
          >
            <.icon name="hero-link-slash" class="size-3.5" /> Cancel
          </button>
        </div>

        <div
          :if={@status == :bound}
          id="wallet-status-bound"
          class="space-y-2 text-sm"
        >
          <div class="flex items-center gap-2">
            <.icon name="hero-check-badge-solid" class="size-4 text-success" />
            <span id="wallet-status-bound-label" class="font-medium text-success">
              Wallet identity bound
            </span>
          </div>
          <div>
            <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
              Address
            </dt>
            <dd id="wallet-status-address" class="font-mono text-sm text-base-content/80 break-all">
              {@account}
            </dd>
          </div>
          <div>
            <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
              Chain
            </dt>
            <dd id="wallet-status-chain" class="text-sm text-base-content/80">
              {chain_label(@chain_id)}
            </dd>
          </div>
          <div :if={@binding && @binding.verified_at}>
            <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
              Verified
            </dt>
            <dd id="wallet-status-verified-at" class="text-sm text-base-content/80">
              {format_datetime(@binding.verified_at)}
            </dd>
          </div>
          <button
            id="wallet-disconnect-btn"
            type="button"
            phx-click="wallet_connect:disconnect"
            class="btn btn-ghost btn-xs gap-1.5"
          >
            <.icon name="hero-link-slash" class="size-3.5" /> Disconnect
          </button>
        </div>

        <div
          :if={@status == :wrong_chain}
          id="wallet-status-wrong-chain"
          class="space-y-2 text-sm"
        >
          <div class="flex items-start gap-2 text-warning">
            <.icon name="hero-exclamation-triangle" class="size-4 mt-0.5 shrink-0" />
            <p class="text-base-content/80">
              Wallet is on chain id <span id="wallet-status-wrong-chain-id">{@chain_id}</span>. Switch to Base Sepolia (84532) to continue. Base mainnet (8453) is post-MVP.
            </p>
          </div>
          <p :if={@account} class="text-xs text-base-content/50 font-mono break-all">
            {@account}
          </p>
          <button
            id="wallet-disconnect-btn"
            type="button"
            phx-click="wallet_connect:disconnect"
            class="btn btn-ghost btn-xs gap-1.5"
          >
            <.icon name="hero-link-slash" class="size-3.5" /> Disconnect
          </button>
        </div>

        <div
          :if={@status == :bind_failed}
          id="wallet-status-bind-failed"
          class="space-y-2 text-sm"
        >
          <div class="flex items-start gap-2 text-error">
            <.icon name="hero-exclamation-circle" class="size-4 mt-0.5 shrink-0" />
            <p id="wallet-status-bind-failed-message" class="text-base-content/80">
              {bind_failure_message(@failure_reason)}
            </p>
          </div>
          <button
            id="wallet-connect-btn"
            type="button"
            class="btn btn-xs btn-outline"
          >
            Try again
          </button>
        </div>

        <div
          :if={@status == :error}
          id="wallet-status-error"
          class="space-y-2 text-sm"
        >
          <div class="flex items-start gap-2 text-error">
            <.icon name="hero-exclamation-circle" class="size-4 mt-0.5 shrink-0" />
            <p id="wallet-status-error-message" class="text-base-content/80">{@error_message}</p>
          </div>
          <button
            id="wallet-connect-btn"
            type="button"
            class="btn btn-xs btn-outline"
          >
            Try again
          </button>
        </div>

        <div
          :if={@status == :not_connected}
          id="wallet-status-disconnected"
          class="space-y-2 text-sm"
        >
          <p class="text-base-content/70">
            Connect a browser wallet to bind your EOA for the MVP. Base Sepolia (84532) is the only supported chain.
          </p>
          <button
            id="wallet-connect-btn"
            type="button"
            class="btn btn-primary btn-sm gap-1.5"
          >
            <.icon name="hero-wallet" class="size-3.5" /> Connect wallet
          </button>
        </div>
      </div>
    </div>
    """
  end

  # --- Component: session permission card ---------------------------------
  #
  # Renders the MVP scoped-session permission preview when the wallet
  # is bound and there is no live delegation row yet. The "Install"
  # button enqueues a `Bank.SessionPermissions.request_install/2` —
  # the existing delegation card takes over the UI once a row lands.

  attr :wallet_status, :atom, required: true
  attr :binding, :map, default: nil
  attr :delegations, :list, required: true
  attr :paused, :boolean, required: true

  defp session_permission_card(%{wallet_status: :bound, delegations: []} = assigns) do
    assigns = assign(assigns, :scope, Bank.SessionPermissions.Scope.default())

    ~H"""
    <div
      id="session-permission-card"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm p-5"
    >
      <h3 class="text-sm font-semibold mb-3 flex items-center gap-1.5">
        <.icon name="hero-shield-check" class="size-4" /> Session permission
      </h3>

      <p class="text-sm text-base-content/70">
        Install a scoped Kernel session permission for your bound EOA on Base Sepolia. Phoenix policy and the runtime decision pipeline gate every action below.
      </p>

      <div id="session-permission-summary" class="mt-3 space-y-3">
        <div>
          <h4 class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-1">
            Allowed
          </h4>
          <ul id="session-permission-allowed" class="space-y-1.5 text-sm">
            <li :for={action <- @scope["allowed"]} class="flex items-start gap-2">
              <.icon name="hero-check-circle" class="size-4 mt-0.5 text-success shrink-0" />
              <span>{action["label"]}</span>
            </li>
          </ul>
        </div>

        <div>
          <h4 class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-1">
            Explicitly denied
          </h4>
          <ul id="session-permission-denied" class="space-y-1.5 text-sm">
            <li :for={denied <- @scope["denied"]} class="flex items-start gap-2">
              <.icon name="hero-x-circle" class="size-4 mt-0.5 text-error shrink-0" />
              <span>{denied["label"]}</span>
            </li>
          </ul>
        </div>
      </div>

      <div class="mt-4 flex items-center gap-3">
        <button
          id="install-session-permission-btn"
          type="button"
          phx-click="install_session_permission"
          disabled={@paused}
          class="btn btn-primary btn-sm gap-1.5 disabled:opacity-50 disabled:cursor-not-allowed"
        >
          <.icon name="hero-key" class="size-3.5" /> Install session permission
        </button>
        <span :if={@paused} id="session-permission-paused-note" class="text-xs text-warning">
          Resume the runtime to install.
        </span>
      </div>
    </div>
    """
  end

  defp session_permission_card(%{wallet_status: :bound, delegations: delegations} = assigns)
       when is_list(delegations) do
    pending = Enum.find(delegations, &(&1.state == :pending))

    if pending do
      assigns =
        assigns
        |> assign(:scope, Bank.SessionPermissions.Scope.default())
        |> assign(:pending_delegation, pending)

      ~H"""
      <div
        id="session-permission-card"
        class="rounded-xl border border-base-300 bg-base-100 shadow-sm p-5"
      >
        <h3 class="text-sm font-semibold mb-3 flex items-center gap-1.5">
          <.icon name="hero-shield-check" class="size-4" /> Session permission
        </h3>

        <div
          id="session-permission-installing"
          class="space-y-2 text-sm"
        >
          <div class="flex items-center gap-2 text-base-content/70">
            <.icon name="hero-arrow-path" class="size-4 animate-spin text-base-content/50" />
            <span>
              Installing — awaiting adapter callback for smart account {short_id(
                @pending_delegation.smart_account_id
              )}.
            </span>
          </div>
          <p class="text-xs text-base-content/50">
            The control plane requested the install on Base Sepolia. The button will return once the adapter confirms or fails.
          </p>
        </div>
      </div>
      """
    else
      ~H"""
      <div :if={false} id="session-permission-card-hidden" />
      """
    end
  end

  defp session_permission_card(assigns) do
    ~H"""
    <div :if={false} id="session-permission-card-hidden" />
    """
  end

  # --- Component: browser-driven session permission install (#473) ---------
  #
  # Walks the operator through the five UI states the
  # `SessionPermissionInstall` JS hook drives:
  # idle → awaiting_signature → signing → submitted → confirmed,
  # with `failed` as the terminal error state. Stable DOM ids let
  # LiveView render tests + future operator E2E tests assert each
  # state without rebuilding the markup. Card only renders when
  # the wallet is bound (`#171`'s precondition); other wallet
  # states render an empty placeholder so the gridlayout stays
  # stable.

  attr :wallet_status, :atom, required: true
  attr :install_state, :atom, required: true
  attr :failure_reason, :atom, default: nil
  attr :failure_message, :string, default: nil

  defp session_permission_browser_install_card(%{wallet_status: :bound} = assigns) do
    ~H"""
    <div
      id="session-permission-install-card"
      phx-hook="SessionPermissionInstall"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm p-5"
    >
      <h3 class="text-sm font-semibold mb-3 flex items-center gap-1.5">
        <.icon name="hero-finger-print" class="size-4" /> Browser-signed install
      </h3>

      <p
        id="session-permission-install-tagline"
        class="text-sm text-base-content/70"
      >
        Sign the session permission install in your wallet. Phoenix never holds the signing key. Base Sepolia only.
      </p>

      <ul
        id="session-permission-install-safety"
        class="mt-3 space-y-1 text-xs text-base-content/60"
      >
        <li class="flex items-start gap-1.5">
          <.icon name="hero-check-circle" class="size-3.5 mt-0.5 text-success shrink-0" />
          <span>Base Sepolia only — Base mainnet (8453) refuses with a wrong-chain prompt.</span>
        </li>
        <li class="flex items-start gap-1.5">
          <.icon name="hero-check-circle" class="size-3.5 mt-0.5 text-success shrink-0" />
          <span>
            No unlimited approval — every approval is per-call and bounded by Phoenix policy.
          </span>
        </li>
        <li class="flex items-start gap-1.5">
          <.icon name="hero-check-circle" class="size-3.5 mt-0.5 text-success shrink-0" />
          <span>No arbitrary calldata — only the canonical scope summary is signed.</span>
        </li>
        <li class="flex items-start gap-1.5">
          <.icon name="hero-check-circle" class="size-3.5 mt-0.5 text-success shrink-0" />
          <span>No borrow / leverage / withdraw authority for the agent.</span>
        </li>
        <li class="flex items-start gap-1.5">
          <.icon name="hero-check-circle" class="size-3.5 mt-0.5 text-success shrink-0" />
          <span>
            Phoenix's canonical scope summary is shown in the wallet prompt before you sign.
          </span>
        </li>
      </ul>

      <div
        :if={@install_state == :idle}
        id="session-permission-install-idle"
        class="mt-4"
      >
        <button
          id="session-permission-browser-install-btn"
          type="button"
          class="btn btn-primary btn-sm gap-1.5"
        >
          <.icon name="hero-finger-print" class="size-3.5" /> Sign install in wallet
        </button>
      </div>

      <div
        :if={@install_state == :awaiting_signature}
        id="session-permission-install-awaiting-signature"
        class="mt-4 flex items-center gap-2 text-sm text-base-content/70"
      >
        <.icon name="hero-arrow-path" class="size-4 animate-spin text-base-content/50" />
        <span>Awaiting wallet signature — review the canonical scope summary in your wallet.</span>
      </div>

      <div
        :if={@install_state == :signing}
        id="session-permission-install-signing"
        class="mt-4 flex items-center gap-2 text-sm text-base-content/70"
      >
        <.icon name="hero-arrow-path" class="size-4 animate-spin text-base-content/50" />
        <span>Signature received — submitting install UserOperation.</span>
      </div>

      <div
        :if={@install_state == :submitted}
        id="session-permission-install-submitted"
        class="mt-4 flex items-center gap-2 text-sm text-base-content/70"
      >
        <.icon name="hero-arrow-path" class="size-4 animate-spin text-base-content/50" />
        <span>UserOperation submitted — awaiting bundler confirmation.</span>
      </div>

      <div
        :if={@install_state == :confirmed}
        id="session-permission-install-confirmed"
        class="mt-4 flex items-center gap-2 text-sm text-success"
      >
        <.icon name="hero-check-circle" class="size-4" />
        <span>Install confirmed. The session permission is active.</span>
      </div>

      <div
        :if={@install_state == :failed}
        id="session-permission-install-failed"
        class="mt-4 space-y-1 text-sm text-error"
      >
        <div class="flex items-center gap-2">
          <.icon name="hero-x-circle" class="size-4" />
          <span id="session-permission-install-failure-copy">
            {browser_install_failure_copy(@failure_reason)}
          </span>
        </div>
        <p
          :if={@failure_message}
          id="session-permission-install-failure-detail"
          class="text-xs text-error/70 ml-6"
        >
          {@failure_message}
        </p>
        <div class="ml-6 mt-2">
          <button
            id="session-permission-browser-install-btn"
            type="button"
            class="btn btn-outline btn-xs gap-1.5"
          >
            <.icon name="hero-arrow-path" class="size-3.5" /> Retry
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp session_permission_browser_install_card(assigns) do
    # Wallet not bound — render an empty placeholder. The card
    # appears only after the operator completes the wallet
    # connect + binding flow.
    ~H"""
    <div :if={false} id="session-permission-install-card-hidden" />
    """
  end

  # Fixed copy for each documented failure reason. Stable so
  # LiveView tests can pin per-reason assertions; also keeps the
  # operator-facing wording consistent across hook + LiveView.
  defp browser_install_failure_copy(:user_rejected),
    do: "You rejected the signature in your wallet."

  defp browser_install_failure_copy(:wrong_chain),
    do: "Wallet is on the wrong chain. Switch to Base Sepolia (84532) and retry."

  defp browser_install_failure_copy(:insufficient_gas),
    do: "Wallet reports insufficient gas / funds for the install UserOperation."

  defp browser_install_failure_copy(:bundler_rejected),
    do: "The bundler refused the install UserOperation. Check the runbook for next steps."

  defp browser_install_failure_copy(:network_error),
    do: "Network error talking to the wallet or bundler. Check your connection and retry."

  defp browser_install_failure_copy(:no_provider),
    do: "No wallet provider detected — install MetaMask or a compatible Base Sepolia wallet."

  defp browser_install_failure_copy(:invalid_scope_message),
    do: "Phoenix did not issue a valid scope message. Refresh and try again."

  defp browser_install_failure_copy(:no_wallet_binding),
    do: "Connect and bind your wallet before installing a session permission."

  defp browser_install_failure_copy(_),
    do: "An unexpected error occurred. Check the wallet console and retry."

  # --- Component: runtime card ---------------------------------------------

  attr :paused, :boolean, required: true

  defp runtime_card(assigns) do
    ~H"""
    <div id="runtime-card" class="rounded-xl border border-base-300 bg-base-100 shadow-sm p-5">
      <h3 class="text-sm font-semibold mb-3 flex items-center gap-1.5">
        <.icon name="hero-cog-6-tooth" class="size-4" /> Runtime
      </h3>
      <div class="flex items-center justify-between mb-4">
        <span class="text-sm text-base-content/60">Global status</span>
        <span :if={@paused} class="badge badge-warning badge-sm">Paused</span>
        <span :if={!@paused} class="badge badge-success badge-sm">Running</span>
      </div>
      <div class="flex gap-2">
        <.button
          :if={!@paused}
          id="pause-btn"
          phx-click="pause_runtime"
          data-confirm="Pause the runtime? New executions will be halted."
          class="btn btn-warning btn-soft btn-sm flex-1 gap-1.5"
        >
          <.icon name="hero-pause" class="size-3.5" /> Pause
        </.button>
        <.button
          :if={@paused}
          id="resume-btn"
          phx-click="resume_runtime"
          class="btn btn-success btn-soft btn-sm flex-1 gap-1.5"
        >
          <.icon name="hero-play" class="size-3.5" /> Resume
        </.button>
      </div>
    </div>
    """
  end

  # --- View helpers ---------------------------------------------------------

  defp delegation_badge_class(:active), do: "badge-success"
  defp delegation_badge_class(:pending), do: "badge-warning"
  defp delegation_badge_class(:revoking), do: "badge-error"
  defp delegation_badge_class(:revoke_failed), do: "badge-error"
  defp delegation_badge_class(_), do: "badge-ghost"

  defp delegation_label(:active), do: "Active"
  defp delegation_label(:pending), do: "Pending"
  defp delegation_label(:revoking), do: "Revoking"
  defp delegation_label(:revoke_failed), do: "Revoke failed"
  defp delegation_label(:revoked), do: "Revoked"
  defp delegation_label(:expired), do: "Expired"
  defp delegation_label(_), do: "Unknown"

  defp delegation_icon(:active), do: "hero-link-solid"
  defp delegation_icon(:pending), do: "hero-clock"
  defp delegation_icon(:revoking), do: "hero-shield-exclamation"
  defp delegation_icon(:revoke_failed), do: "hero-exclamation-triangle"
  defp delegation_icon(_), do: "hero-link-slash"

  defp delegation_icon_bg(:active), do: "bg-success/15 text-success"
  defp delegation_icon_bg(:pending), do: "bg-warning/15 text-warning"
  defp delegation_icon_bg(:revoking), do: "bg-error/15 text-error"
  defp delegation_icon_bg(:revoke_failed), do: "bg-error/15 text-error"
  defp delegation_icon_bg(_), do: "bg-base-300/50 text-base-content/40"

  defp short_id(nil), do: "-"
  defp short_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 8) <> "..."
  defp short_id(id), do: id

  defp chain_label(84_532), do: "Base Sepolia (84532)"
  defp chain_label(nil), do: "-"
  defp chain_label(id) when is_integer(id), do: "Chain #{id}"

  defp install_refusal_message(:workspace_mismatch),
    do: "Wallet binding belongs to a different workspace."

  defp install_refusal_message(:binding_not_verified),
    do: "Wallet binding is not yet verified."

  defp install_refusal_message(:binding_revoked),
    do: "Wallet binding has been revoked. Reconnect to start a fresh binding."

  defp install_refusal_message(:unsupported_chain),
    do: "Only Base Sepolia (84532) is supported for the MVP install."

  defp install_refusal_message(:runtime_paused),
    do: "Runtime is paused. Resume before installing a session permission."

  defp install_refusal_message(:workspace_paused),
    do: "Workspace agent keys are paused. Unpause before installing."

  defp install_refusal_message(:workspace_not_found),
    do: "Workspace not found."

  defp install_refusal_message({:already_pending, _}),
    do: "An install is already pending. Wait for the adapter callback before retrying."

  defp install_refusal_message({:already_active, _}),
    do: "An active delegation already exists. Revoke it first to install a new one."

  defp install_refusal_message(reason), do: "Install failed: #{inspect(reason)}"

  defp bind_failure_message(:expired),
    do: "Challenge expired. Click Connect wallet again to issue a fresh challenge."

  defp bind_failure_message(:address_mismatch),
    do: "The signature was produced by a different address. Reconnect the wallet you signed with."

  defp bind_failure_message(:malformed_signature),
    do:
      "Signature was malformed. Try connecting again — your wallet should produce a 65-byte secp256k1 signature."

  defp bind_failure_message(:invalid_signature),
    do: "Signature could not be recovered. Try connecting again."

  defp bind_failure_message(:already_verified),
    do: "Binding is already verified. Refresh the page to view it."

  defp bind_failure_message(:revoked),
    do: "This binding was revoked. Click Connect wallet to start a fresh one."

  defp bind_failure_message(:challenge_not_found),
    do: "Challenge expired or never issued. Click Connect wallet to retry."

  defp bind_failure_message(:user_rejected),
    do: "Wallet rejected the signing prompt. Click Connect wallet to try again."

  defp bind_failure_message(:invalid_challenge),
    do: "Challenge could not be issued. Confirm you are on Base Sepolia (84532) and try again."

  defp bind_failure_message(:chain_not_supported),
    do: "Only Base Sepolia (84532) is supported in the MVP."

  defp bind_failure_message(_),
    do: "Wallet binding failed. Click Connect wallet to retry."

  defp short_hash(nil), do: "-"
  defp short_hash(hash) when byte_size(hash) > 14, do: String.slice(hash, 0, 10) <> "..."
  defp short_hash(hash), do: hash

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  end
end
