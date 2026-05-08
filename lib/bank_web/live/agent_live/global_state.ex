defmodule BankWeb.AgentLive.GlobalState do
  @moduledoc """
  Shared cross-screen state helpers for the redesigned LiveViews
  (AgentLive, AgentActivityLive, AgentAdvancedLive).

  The TopBar wallet chip + Stop button and the NavRail permission
  pill must render identically on every screen, which means each
  LiveView mount needs to:

    1. Subscribe to `security:events` (delegation state transitions)
    2. Load the workspace's active wallet binding + delegation
    3. Derive the design's three-state wallet enum + six-state
       permission enum
    4. Carry `:stop_open` for the confirm-stop modal

  The Stop button + revoke flow are likewise shared. Centralising
  the helpers here keeps AgentLive's per-section mount minimal and
  prevents the activity / advanced screens drifting out of sync
  with the master state machine.
  """

  use Phoenix.Component

  alias Bank.Delegations
  alias Bank.SessionPermissions
  alias Bank.Security
  alias Bank.WalletBindings
  alias Bank.WalletBindings.WalletBinding
  alias BankWeb.LiveAuth

  @doc """
  Subscribe to the runtime's `security:events` PubSub topic. Call
  inside `mount/3` once `connected?(socket)` is true.
  """
  def subscribe do
    Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.security_events())
  end

  @doc """
  Populate the shared TopBar/NavRail assigns: `:wallet`, `:address`,
  `:wallet_binding`, `:delegation`, `:permission`, `:stop_open`.

  Idempotent via `assign_new/3` so per-card mount paths can re-run
  this without stomping values they already set.
  """
  def init(socket) do
    binding = active_wallet_binding(socket)
    delegation = active_delegation_for(socket, binding)

    socket
    |> assign_new(:wallet_binding, fn -> binding end)
    |> assign_new(:wallet, fn -> derive_wallet_state(binding) end)
    |> assign_new(:address, fn -> short_address(binding) end)
    |> assign_new(:delegation, fn -> delegation end)
    |> assign_new(:permission, fn -> derive_permission_state(delegation) end)
    |> assign_new(:stop_open, fn -> false end)
  end

  @doc """
  Re-load wallet binding + delegation from the DB and recompute the
  derived states. Called on every `security:events` PubSub message
  so the screen reflects the latest delegation transitions.
  """
  def refresh(socket) do
    binding = active_wallet_binding(socket)
    delegation = active_delegation_for(socket, binding)

    socket
    |> assign(:wallet_binding, binding)
    |> assign(:wallet, derive_wallet_state(binding))
    |> assign(:address, short_address(binding))
    |> assign(:delegation, delegation)
    |> assign(:permission, derive_permission_state(delegation))
  end

  @doc """
  Perform the revoke initiated from the confirm-stop modal. Returns
  the updated socket regardless of outcome — failures land in flash.

  Defense-in-depth role gate (P5): even though the agent_alpha
  live_session already gates mount on `:operator`+, re-check here so
  a future routing change or a manually-pushed event can't escalate
  a viewer-tier socket into a revoke.
  """
  def revoke(socket) do
    case LiveAuth.authorize_action(socket, :operator) do
      :ok ->
        do_revoke(socket)

      {:error, {:insufficient_role, _}} ->
        socket
        |> assign(:stop_open, false)
        |> Phoenix.LiveView.put_flash(:error, "Operator role required to revoke.")
    end
  end

  defp do_revoke(socket) do
    case socket.assigns[:delegation] do
      %{smart_account_id: sa_id} ->
        user_id = socket.assigns.current_scope.user.id

        case Security.revoke_delegation(sa_id,
               reason: :operator_requested,
               actor: :user,
               actor_id: user_id
             ) do
          {:ok, _job} ->
            socket |> assign(:stop_open, false) |> refresh()

          {:error, reason} ->
            socket
            |> assign(:stop_open, false)
            |> Phoenix.LiveView.put_flash(:error, "Revoke failed: #{inspect(reason)}")
        end

      _ ->
        assign(socket, :stop_open, false)
    end
  end

  # ── Internals ─────────────────────────────────────────────────────

  defp active_wallet_binding(socket) do
    case workspace_id(socket) do
      nil -> nil
      ws_id -> WalletBindings.get_active_binding(ws_id)
    end
  end

  defp active_delegation_for(_socket, nil), do: nil

  defp active_delegation_for(socket, %WalletBinding{} = binding) do
    case workspace_id(socket) do
      nil ->
        nil

      ws_id ->
        expected_sa = SessionPermissions.compute_smart_account_id(binding)

        Delegations.list_active(workspace_id: ws_id)
        |> Enum.filter(&(&1.smart_account_id == expected_sa))
        |> case do
          [] -> nil
          [one] -> one
          many -> Enum.sort_by(many, & &1.inserted_at, {:desc, DateTime}) |> hd()
        end
    end
  end

  defp workspace_id(socket) do
    case socket.assigns[:current_scope] do
      %{workspace: %{id: id}} -> id
      _ -> nil
    end
  end

  # nil binding → :disconnected. Verified + chain == 84_532 → :connected.
  # Verified + chain mismatch → :wrong_network. Anything else → :disconnected.
  defp derive_wallet_state(nil), do: :disconnected

  defp derive_wallet_state(%WalletBinding{revoked_at: r}) when not is_nil(r), do: :disconnected

  defp derive_wallet_state(%WalletBinding{verified_at: nil, expires_at: exp}) do
    if not is_nil(exp) and DateTime.compare(DateTime.utc_now(), exp) == :gt do
      :disconnected
    else
      :disconnected
    end
  end

  defp derive_wallet_state(%WalletBinding{chain_id: 84_532, verified_at: v}) when not is_nil(v),
    do: :connected

  defp derive_wallet_state(%WalletBinding{verified_at: v}) when not is_nil(v), do: :wrong_network

  defp derive_wallet_state(_), do: :disconnected

  defp short_address(%WalletBinding{address: "0x" <> _ = a}) when byte_size(a) == 42 do
    "0x" <> binary_part(a, 2, 4) <> "…" <> binary_part(a, 38, 4)
  end

  defp short_address(_), do: nil

  # No delegation row → not_installed. Otherwise map row state.
  defp derive_permission_state(nil), do: :not_installed
  defp derive_permission_state(%{state: :pending}), do: :installing
  defp derive_permission_state(%{state: :active}), do: :active
  defp derive_permission_state(%{state: :revoking}), do: :installing
  defp derive_permission_state(%{state: :revoke_failed}), do: :failed
  defp derive_permission_state(%{state: :revoked}), do: :revoked
  defp derive_permission_state(%{state: :expired}), do: :expired
  defp derive_permission_state(%{state: :install_failed}), do: :failed
  defp derive_permission_state(_), do: :not_installed
end
