defmodule Bank.Runtime.Workers.RevokeDelegation do
  @moduledoc """
  Dispatch a delegation revoke for a smart account.

  The actual revoke is an on-chain transaction routed through the
  TypeScript adapter, which isn't wired yet. What *is* useful to do
  today is make the request visible: a broadcast on `security:events`
  means the dashboard sees the revoke-initiation moment even before
  the adapter lands. The audit trail captures the same moment.

  The worker therefore:

    1. Logs the request with the smart-account id and reason.
    2. Broadcasts `{:delegation_revoke_requested, ...}` on
       `security:events`.
    3. Writes a runtime-scoped audit event (`security.revoke_requested`)
       so the event chain survives process restart and fans out on
       `audit:stream`.
    4. Cancels with `:adapter_pending`.

  Actually signing and broadcasting the revoke tx waits on the
  adapter.

  ## Retry posture

    * `{:cancel, :adapter_pending}` — expected. The broadcast and
      audit happen before the cancel return, so operators see the
      event exactly once per enqueue.
    * `{:error, reason}` — transient infrastructure (audit insert
      fails because the DB is down, etc.). Standard Oban retry.
  """

  use Oban.Worker,
    queue: :security_revoke,
    max_attempts: 5

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

    case Runtime.emit_audit(%{
           actor: :runtime,
           event_type: "security.revoke_requested",
           subject_type: "smart_account",
           subject_id: smart_account_id,
           correlation_id: nil,
           after_ref: %{reason: reason}
         }) do
      {:ok, _event} ->
        {:cancel, :adapter_pending}

      {:error, reason} ->
        Logger.error("RevokeDelegation: audit emit failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def perform(%Oban.Job{args: args}) do
    Logger.error("RevokeDelegation: malformed args: #{inspect(args)}")
    {:cancel, :malformed_args}
  end
end
