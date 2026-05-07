defmodule Bank.Runtime.Workers.VerifyInstallOnchain do
  @moduledoc """
  Browser-signed install on-chain verifier (#474).

  Triggered after the browser reports an `attestation { status:
  "confirmed" }` for a `:pending` delegation row. The worker
  reads the user's smart-account state via
  `Bank.Chains.KernelVerifier.verify/2`, asserts the
  `validation_id` Phoenix expected matches the on-chain reality,
  and either:

    * flips the delegation to `:active` and emits
      `delegation.install_confirmed_onchain` audit, or
    * marks the row `:install_failed` with a category atom from
      `Bank.SessionPermissions.BrowserInstall.failure_categories/0`
      and emits `delegation.install_failed`.

  Idempotent: a successful run that finds the row already
  `:active` returns `:ok`. Bounded retries (max 5) on transient
  RPC errors via Oban's exponential backoff. On exhaustion, the
  row is marked `:install_failed` with reason
  `:onchain_verification_unreachable` so the deployment surfaces
  as misconfigured rather than indefinitely pending.
  """

  use Oban.Worker,
    queue: :delegations_verify_install,
    max_attempts: 5,
    # Uniqueness is per-worker (`fields: [:worker, :args]`) so a
    # sibling worker that also keys on `delegation_id` (e.g.,
    # `Bank.Runtime.Workers.PollInstallReceipt` in #500) does not
    # accidentally satisfy this verifier's uniqueness check and
    # silently swallow the verifier's insert. The original
    # `fields: [:args]` was global; #500 introduced a second worker
    # with `delegation_id` in args which made the global scope
    # observably wrong.
    unique: [period: 60, fields: [:worker, :args], keys: [:delegation_id]]

  require Logger

  alias Bank.Audit
  alias Bank.Audit.Events
  alias Bank.Chains.KernelVerifier
  alias Bank.Delegations.Delegation
  alias Bank.Repo
  alias Bank.SessionPermissions.BrowserInstall

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"delegation_id" => delegation_id} = args,
        attempt: attempt,
        max_attempts: max_attempts
      }) do
    case Repo.get(Delegation, delegation_id) do
      nil ->
        {:cancel, :delegation_not_found}

      %Delegation{state: :active} ->
        :ok

      %Delegation{state: :install_failed} ->
        :ok

      %Delegation{state: :pending} = delegation ->
        verify_and_transition(delegation, args, attempt, max_attempts)

      %Delegation{state: state} ->
        {:cancel, {:wrong_state, state}}
    end
  end

  defp verify_and_transition(%Delegation{} = delegation, args, attempt, max_attempts) do
    smart_account_address = smart_account_address_for(delegation)
    validation_id_hex = "0x" <> Base.encode16(delegation.validation_id || <<>>, case: :lower)

    case KernelVerifier.verify(%{
           smart_account_address: smart_account_address,
           validation_id: validation_id_hex,
           chain_id: KernelVerifier.base_sepolia_chain_id()
         }) do
      {:ok, evidence} ->
        finalize_active(delegation, evidence, args)

      {:error, :rpc_not_configured} ->
        finalize_failed(delegation, :unknown, "onchain_verification_unreachable", args)

      {:error, :not_installed} ->
        finalize_failed(delegation, :unknown, "onchain_state_mismatch", args)

      {:error, :not_deployed} ->
        finalize_failed(delegation, :unknown, "smart_account_not_deployed", args)

      {:error, reason}
      when reason in [:transport_error, :rpc_error, :invalid_response, :unknown] ->
        if attempt >= max_attempts do
          finalize_failed(delegation, :unknown, "onchain_verification_unreachable", args)
        else
          {:error, reason}
        end

      {:error, reason} ->
        finalize_failed(delegation, :unknown, "onchain_verification_failed:#{reason}", args)
    end
  end

  defp finalize_active(%Delegation{} = delegation, evidence, args) do
    {:ok, updated} =
      delegation
      |> Delegation.changeset(%{
        state: :active,
        granted_at: DateTime.utc_now(),
        installed_at_block: parse_block_number(args, evidence),
        install_tx_hash: Map.get(args, "tx_hash") || delegation.install_tx_hash,
        last_reason: "browser_signed_install"
      })
      |> Repo.update()

    Audit.append_event(Events.delegation_install_confirmed_onchain(updated))

    :ok
  end

  defp finalize_failed(%Delegation{} = delegation, reason_atom, reason_string, args) do
    {:ok, updated} = BrowserInstall.mark_install_failed(delegation, reason_atom)

    Audit.append_event(
      Events.delegation_install_failed(%{
        binding_id: delegation.binding_id,
        delegation_id: delegation.id,
        smart_account_id: delegation.smart_account_id,
        install_userop_hash: delegation.install_userop_hash,
        workspace_id: delegation.workspace_id || Map.get(args, "workspace_id"),
        reason: reason_atom,
        subject_type: "delegation",
        subject_id: delegation.id
      })
    )

    Logger.warning(
      "Bank.Runtime.Workers.VerifyInstallOnchain marked delegation install_failed " <>
        "(delegation_id=#{updated.id} reason=#{reason_string})"
    )

    :ok
  end

  defp smart_account_address_for(%Delegation{} = delegation) do
    case Application.get_env(:bank, __MODULE__, []) |> Keyword.get(:smart_account_resolver) do
      fun when is_function(fun, 1) -> fun.(delegation)
      _ -> Map.get(delegation.scope || %{}, "smart_account_address")
    end
  end

  defp parse_block_number(args, evidence) do
    case Map.get(args, "block_number") do
      n when is_integer(n) and n > 0 -> n
      _ -> hex_to_integer(evidence[:block_number_hex])
    end
  end

  defp hex_to_integer("0x" <> hex) when is_binary(hex) and hex != "" do
    case Integer.parse(hex, 16) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp hex_to_integer(_), do: nil
end
