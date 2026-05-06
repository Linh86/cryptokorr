defmodule Bank.SessionPermissions do
  @moduledoc """
  Context: browser-driven scoped ZeroDev session permission install
  for the MVP (#171).

  Sits between the wallet identity binding (#169) and the existing
  delegation install flow (#58 / `Bank.Delegations.request_connect/1`).
  The browser doesn't sign the permission install UserOp itself yet —
  the wagmi/viem + ZeroDev SDK adoption that would unlock that is
  tracked under `docs/wallet-connect.md` follow-ups. This context is
  the safe Phoenix-side boundary that:

    1. Gates the install on a verified `Bank.WalletBindings`
       binding for the workspace.
    2. Pins the chain to Base Sepolia (84532) for the MVP.
    3. Refuses to install while the runtime is paused.
    4. Stamps the canonical `Bank.SessionPermissions.Scope` summary
       on the delegation row's `scope` JSON column so the operator
       can audit what the agent was authorized to do.
    5. Audits `session_permission.install_requested` with
       `wallet_binding_id` + `smart_account_id` + scope summary —
       no nonces, no signatures, no private keys.

  After this context dispatches, the existing
  `Bank.Runtime.Workers.GrantDelegation` worker + adapter callback
  flow takes over: the adapter installs the permission plugin
  server-side using `OPERATOR_PRIVATE_KEY` and emits
  `delegation.state_changed{state: \"granted\"}`. Phoenix
  persists permission artifacts as it does today.
  """

  alias Bank.Audit
  alias Bank.Delegations
  alias Bank.Delegations.Delegation
  alias Bank.Repo
  alias Bank.Security
  alias Bank.SessionPermissions.Scope
  alias Bank.WalletBindings.WalletBinding
  alias Bank.Workspaces.Workspace

  @doc "The canonical MVP scope. Identical to `Scope.default/0`."
  defdelegate default_scope, to: Scope, as: :default

  @typedoc "Reasons the install request can be refused."
  @type refusal ::
          :workspace_mismatch
          | :binding_not_verified
          | :binding_revoked
          | :unsupported_chain
          | :runtime_paused
          | :workspace_paused
          | {:already_pending, Delegation.t()}
          | {:already_active, Delegation.t()}

  @doc """
  Request an install of the MVP scoped session permission for
  `binding`. The binding must be verified and belong to
  `workspace_id`.

  Returns `{:ok, smart_account_id}` once the audit event is
  written and the GrantDelegation worker is enqueued. The
  synchronous response is acceptance of the request, not
  confirmation of an active delegation — observe the existing
  `delegation.state_changed` callback path for that.

  Returns `{:error, refusal()}` when the call is refused for one
  of the structured reasons.
  """
  @spec request_install(Ecto.UUID.t(), WalletBinding.t()) ::
          {:ok, String.t()} | {:error, refusal() | term()}
  def request_install(workspace_id, %WalletBinding{} = binding) do
    request_install(workspace_id, binding, Scope.default())
  end

  @spec request_install(Ecto.UUID.t(), WalletBinding.t(), map()) ::
          {:ok, String.t()} | {:error, refusal() | term()}
  def request_install(workspace_id, %WalletBinding{} = binding, scope)
      when is_binary(workspace_id) and is_map(scope) do
    with :ok <- check_binding(workspace_id, binding),
         :ok <- check_runtime_unpaused(),
         :ok <- check_workspace_unpaused(workspace_id) do
      smart_account_id = compute_smart_account_id(binding)

      case Delegations.get(smart_account_id) do
        %Delegation{state: state} = existing when state in [:pending] ->
          {:error, {:already_pending, existing}}

        %Delegation{state: state} = existing
        when state in [:active, :revoking, :revoke_failed] ->
          {:error, {:already_active, existing}}

        _ ->
          do_request(workspace_id, binding, smart_account_id, scope)
      end
    end
  end

  @doc """
  The deterministic Phoenix-side smart-account identifier this
  context will use for `binding`. Exposed so the LiveView can
  show the operator the same identifier the audit trail will
  carry.
  """
  @spec compute_smart_account_id(WalletBinding.t()) :: String.t()
  def compute_smart_account_id(%WalletBinding{id: id}) do
    "sa_wb_" <> id
  end

  # --- internals ---------------------------------------------------------

  defp check_binding(workspace_id, %WalletBinding{} = binding) do
    cond do
      binding.workspace_id != workspace_id ->
        {:error, :workspace_mismatch}

      binding.revoked_at != nil ->
        {:error, :binding_revoked}

      binding.verified_at == nil ->
        {:error, :binding_not_verified}

      binding.chain_id != Scope.chain_id() ->
        {:error, :unsupported_chain}

      true ->
        :ok
    end
  end

  defp check_runtime_unpaused do
    if Security.paused?(:global), do: {:error, :runtime_paused}, else: :ok
  end

  defp check_workspace_unpaused(workspace_id) do
    case Repo.get(Workspace, workspace_id) do
      %Workspace{} = ws ->
        if Workspace.agent_keys_paused?(ws),
          do: {:error, :workspace_paused},
          else: :ok

      nil ->
        {:error, :workspace_not_found}
    end
  end

  defp do_request(workspace_id, binding, smart_account_id, scope) do
    with {:ok, _event} <- emit_audit(workspace_id, binding, smart_account_id, scope),
         {:ok, :accepted} <-
           Delegations.request_connect(%{
             "smart_account_id" => smart_account_id,
             "chain_id" => binding.chain_id,
             "account" => binding.address,
             "scope" => scope
           }) do
      {:ok, smart_account_id}
    end
  end

  defp emit_audit(workspace_id, binding, smart_account_id, scope) do
    Audit.append_event(%{
      actor: :user,
      actor_id: binding.user_id,
      event_type: "session_permission.install_requested",
      subject_type: "wallet_binding",
      subject_id: binding.id,
      correlation_id: binding.id,
      workspace_id: workspace_id,
      after_ref: %{
        wallet_binding_id: binding.id,
        smart_account_id: smart_account_id,
        address: binding.address,
        chain_id: binding.chain_id,
        scope_version: scope["version"] || "1",
        scope_summary: redacted_scope(scope)
      }
    })
  end

  # The scope is fully public — there is nothing to redact today.
  # Centralizing the "what's safe to put in audit" decision here
  # keeps a single seam for any future redaction work.
  defp redacted_scope(scope) when is_map(scope) do
    Map.take(scope, ["version", "kernel_version", "chain_id", "allowed", "denied"])
  end
end
