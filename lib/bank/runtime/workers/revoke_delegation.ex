defmodule Bank.Runtime.Workers.RevokeDelegation do
  @moduledoc """
  Dispatch an on-chain delegation revoke for a smart account.

  The actual revoke is an on-chain transaction routed through the
  TypeScript adapter. This worker owns the enqueue-side of that
  contract: record the operator intent, dispatch to the adapter, and
  let the adapter drive the `:granted → :revoking → :revoked` (or
  `:revoke_failed` on chain-level failure) lifecycle via
  `delegation.state_changed` callbacks. An operator may retry from
  `:revoke_failed` by re-enqueueing this worker.

  Sequence:

    1. Log the request with the smart-account id and reason.
    2. Broadcast `{:delegation_revoke_requested, ...}` on
       `security:events` so the control tower sees the request even
       before the adapter acknowledges.
    3. Write a runtime-scoped audit event (`security.revoke_requested`)
       so the event chain survives process restart and fans out on
       `audit:stream`.
    4. Call `Bank.AdapterClient.dispatch_revoke_delegation/1`.
    5. Map the adapter outcome onto Oban retry semantics.

  ## Retry posture

    * `{:ok, _}` — adapter accepted. Actual state transitions land via
      callback; this worker's job ends.
    * `{:error, :adapter_unavailable}` / `{:error, {:adapter_error, _, _}}`
      — transient. Returns `{:error, _}` so Oban retries with backoff.
    * `{:error, {:adapter_rejected, _, _}}` / `{:error, :invalid_response}`
      — deterministic failure. Returns `{:cancel, _}` to stop retrying;
      the operator must investigate.
    * `{:error, reason}` from audit insert — returned as `{:error, _}`
      for Oban retry.
  """

  use Oban.Worker,
    queue: :security_revoke,
    max_attempts: 5

  alias Bank.AdapterClient
  alias Bank.Runtime
  alias Bank.Runtime.Notifier

  require Logger

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"smart_account_id" => smart_account_id} = args}) do
    reason = Map.get(args, "reason", "unspecified")

    Logger.info(
      "RevokeDelegation: requested for smart_account #{smart_account_id} (reason=#{reason})"
    )

    Notifier.security_event(:delegation_revoke_requested, %{
      smart_account_id: smart_account_id,
      reason: reason
    })

    with {:ok, _event} <-
           Runtime.emit_audit(%{
             actor: :runtime,
             event_type: "security.revoke_requested",
             subject_type: "smart_account",
             subject_id: smart_account_id,
             correlation_id: nil,
             after_ref: %{reason: reason}
           }) do
      dispatch(smart_account_id, reason)
    else
      {:error, reason} ->
        Logger.error("RevokeDelegation: audit emit failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("RevokeDelegation: malformed args: #{inspect(args)}")
    {:cancel, :malformed_args}
  end

  defp dispatch(smart_account_id, reason) do
    case AdapterClient.dispatch_revoke_delegation(%{
           smart_account_id: smart_account_id,
           reason: reason
         }) do
      {:ok, %{accepted: true}} ->
        :ok

      {:error, :adapter_unavailable} ->
        Logger.warning(
          "RevokeDelegation: adapter unavailable for smart_account #{smart_account_id}; retrying via Oban"
        )

        {:error, :adapter_unavailable}

      {:error, {:adapter_error, status, _body}} ->
        Logger.warning(
          "RevokeDelegation: adapter #{status} for smart_account #{smart_account_id}; retrying via Oban"
        )

        {:error, {:adapter_error, status}}

      {:error, {:adapter_rejected, status, body}} ->
        Logger.error(
          "RevokeDelegation: adapter rejected smart_account #{smart_account_id} (HTTP #{status}): #{inspect(body)}"
        )

        {:cancel, {:adapter_rejected, status}}

      {:error, :invalid_response} ->
        Logger.error(
          "RevokeDelegation: adapter returned 2xx with unexpected body for smart_account #{smart_account_id}"
        )

        {:cancel, :invalid_response}
    end
  end
end
