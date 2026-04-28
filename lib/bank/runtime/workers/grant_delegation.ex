defmodule Bank.Runtime.Workers.GrantDelegation do
  @moduledoc """
  Dispatch a browser-initiated delegation grant to the adapter (#58
  grant flow).

  The actual on-chain install (build a `PermissionPlugin`, install
  it on the Kernel account via a sudo-signed UserOp, serialize the
  resulting account, emit `granted` callback) lives entirely on the
  adapter. This worker owns the enqueue-side: record the audit
  event, dispatch to the adapter, and let the adapter drive the
  `granted` lifecycle via `delegation.state_changed` callbacks back
  through `Bank.Delegations.apply_callback/1`.

  Phoenix never holds a session signing key. The worker carries the
  browser-supplied `delegation_payload` (opaque to Phoenix) so the
  audit chain anchors the user's signed intent, and threads
  `smart_account_id`, `chain_id`, and `account` for the adapter's
  install routine.

  Sequence:

    1. Validate args (smart_account_id, chain_id, account).
    2. Write a runtime-scoped audit event
       (`security.grant_requested`).
    3. Call `Bank.AdapterClient.dispatch_grant_delegation/2`.
    4. Map adapter outcome onto Oban retry semantics — same shape
       the revoke worker uses.

  Once the adapter's `granted` callback returns, the existing
  `apply_callback/1` path persists the artifact columns
  (`permission_blob`, `permission_id`, `validation_id`,
  `kernel_version`, `permission_package_version`,
  `installed_at_block`, `install_tx_hash`,
  `session_signer_address`) and the row becomes
  `cryptographically_revocable?/1`.
  """

  use Oban.Worker,
    queue: :delegations_grant,
    max_attempts: 5

  alias Bank.AdapterClient
  alias Bank.Runtime

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{
        args:
          %{
            "smart_account_id" => smart_account_id,
            "chain_id" => chain_id,
            "account" => account
          } = args
      })
      when is_binary(smart_account_id) and is_integer(chain_id) and is_binary(account) do
    Logger.info(
      "GrantDelegation: requested for smart_account #{smart_account_id} (chain_id=#{chain_id}, account=#{account})"
    )

    delegation_payload = Map.get(args, "delegation_payload")
    scope = Map.get(args, "scope", %{})
    correlation_id = Map.get(args, "correlation_id")

    with {:ok, _event} <-
           Runtime.emit_audit(%{
             actor: :runtime,
             event_type: "security.grant_requested",
             subject_type: "smart_account",
             subject_id: smart_account_id,
             correlation_id: correlation_id,
             after_ref: %{
               chain_id: chain_id,
               account: account,
               scope: scope
             }
           }) do
      dispatch(%{
        smart_account_id: smart_account_id,
        chain_id: chain_id,
        account: account,
        scope: scope,
        delegation_payload: delegation_payload,
        correlation_id: correlation_id
      })
    else
      {:error, reason} ->
        Logger.error("GrantDelegation: audit emit failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("GrantDelegation: malformed args: #{inspect(args)}")
    {:cancel, :malformed_args}
  end

  defp dispatch(args) do
    case AdapterClient.dispatch_grant_delegation(args) do
      {:ok, %{accepted: true}} ->
        :ok

      {:error, :adapter_unavailable} ->
        Logger.warning(
          "GrantDelegation: adapter unavailable for smart_account #{args.smart_account_id}; retrying via Oban"
        )

        {:error, :adapter_unavailable}

      {:error, {:adapter_error, status, _body}} ->
        Logger.warning(
          "GrantDelegation: adapter #{status} for smart_account #{args.smart_account_id}; retrying via Oban"
        )

        {:error, {:adapter_error, status}}

      {:error, {:adapter_rejected, status, body}} ->
        Logger.error(
          "GrantDelegation: adapter rejected smart_account #{args.smart_account_id} (HTTP #{status}): #{inspect(body)}"
        )

        {:cancel, {:adapter_rejected, status}}

      {:error, :invalid_response} ->
        Logger.error(
          "GrantDelegation: adapter returned 2xx with unexpected body for smart_account #{args.smart_account_id}"
        )

        {:cancel, :invalid_response}
    end
  end
end
