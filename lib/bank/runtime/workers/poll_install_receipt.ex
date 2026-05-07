defmodule Bank.Runtime.Workers.PollInstallReceipt do
  @moduledoc """
  Server-side bundler-receipt poller for browser-signed installs
  (#500).

  When the browser POSTs `attestation { status: "submitted" }`,
  `Bank.SessionPermissions.BrowserInstall.record_attestation/3`
  persists a `:pending` delegation row keyed on
  `(binding_id, install_userop_hash)` and enqueues this worker in
  the same `Repo.transaction/1`.

  The worker is the ONLY way a `:pending` row anchored to a real
  bundler-accepted UserOp gets carried to a verdict if the browser
  tab closes between `submitted` and `confirmed`. The browser's
  eventual `confirmed` POST is a fast-path optimisation; this
  poller is the safety net.

  ## What it does on each run

    1. Loads the row. If `:active` or `:install_failed`, returns
       `:ok` (idempotent — handles the fast-path race).
    2. Checks the configured wall-clock deadline. Past deadline →
       marks `:install_failed { reason: :attestation_timeout }`,
       audits `delegation.install_failed`, returns `:ok`.
    3. Calls `eth_getUserOperationReceipt` against the bundler URL
       Phoenix recorded on the row's binding (the same
       `bundler_rpc_url` baked into the install envelope).
    4. **Null receipt** (UserOp not yet included) → returns
       `{:snooze, delay}` so Oban reschedules without burning
       attempts.
    5. **Receipt with `success: true`** → audits
       `delegation.install_broadcast` with the on-chain `tx_hash`
       and `block_number` from the receipt, then enqueues
       `Bank.Runtime.Workers.VerifyInstallOnchain` with the same
       args. The verifier remains the SOLE writer of the `:active`
       transition. Returns `:ok`.
    6. **Receipt with `success: false`** (UserOp reverted on
       chain) → marks `:install_failed { reason: :userop_reverted }`,
       audits `delegation.install_failed`, returns `:ok`.
    7. **Bundler 5xx / network error** → returns
       `{:error, :bundler_error}` so Oban retries via standard
       backoff. After `max_attempts`, marks
       `:install_failed { reason: :bundler_unavailable }` and
       audits.

  ## Idempotency contract with the browser's `confirmed` POST

  Both code paths route through the same effect: enqueue
  `VerifyInstallOnchain` once. The verifier's existing
  `unique: [period: 60, fields: [:args], keys: [:delegation_id]]`
  clause deduplicates concurrent enqueues. This worker also checks
  the row state before any side effect, so a row already-`:active`
  (browser fast-path won) becomes a no-op.

  ## Bundler URL hygiene

  The bundler URL is treated as an operator credential. It is
  NEVER logged in full. Failure logs use only `Logger.warning`
  with the row id and a short failure category. The URL itself
  comes from the row's binding via the canonical envelope so
  this worker does not have to (and does not) re-read app config.

  ## Configuration

      config :bank, Bank.Runtime.Workers.PollInstallReceipt,
        rpc_fn: nil,
        deadline_ms: 300_000,
        snooze_seconds: 5

  Tests inject `:rpc_fn` (a 2-arity function `(url, payload) ->
  {:ok, term()} | {:error, atom()}`) to avoid live network. The
  default is the same `Req.post`-based driver
  `Bank.Chains.KernelVerifier` uses.
  """

  use Oban.Worker,
    queue: :delegations_poll_install_receipt,
    max_attempts: 8,
    # Uniqueness is per-worker (`fields: [:worker, :args]`) — see
    # the matching note on `Bank.Runtime.Workers.VerifyInstallOnchain`.
    # Two pollers for the same `delegation_id` within 60s is the
    # duplicate `submitted` POST race; the unique conflict makes
    # that a no-op.
    unique: [period: 60, fields: [:worker, :args], keys: [:delegation_id]]

  require Logger

  alias Bank.Audit
  alias Bank.Audit.Events
  alias Bank.Delegations.Delegation
  alias Bank.Repo
  alias Bank.Runtime.Workers.VerifyInstallOnchain
  alias Bank.SessionPermissions.BrowserInstall

  @rpc_timeout_ms 8_000
  @default_deadline_ms 300_000
  @default_snooze_seconds 5

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
        if past_deadline?(args) do
          finalize_failed(delegation, :attestation_timeout, args)
        else
          poll_receipt(delegation, args, attempt, max_attempts)
        end

      %Delegation{state: state} ->
        {:cancel, {:wrong_state, state}}
    end
  end

  defp poll_receipt(%Delegation{} = delegation, args, attempt, max_attempts) do
    bundler_url = Map.get(args, "bundler_rpc_url")
    userop_hash = Map.get(args, "install_userop_hash") || delegation.install_userop_hash

    cond do
      not is_binary(bundler_url) or bundler_url == "" ->
        # Configuration regression: the row was enqueued without a
        # bundler URL. Fail closed rather than retry forever.
        finalize_failed(delegation, :bundler_unavailable, args)

      not is_binary(userop_hash) or userop_hash == "" ->
        finalize_failed(delegation, :unknown, args)

      true ->
        rpc_fn = configured_rpc_fn()

        case rpc_fn.(bundler_url, jsonrpc("eth_getUserOperationReceipt", [userop_hash])) do
          {:ok, nil} ->
            {:snooze, snooze_seconds()}

          {:ok, %{} = receipt} ->
            handle_receipt(delegation, receipt, args)

          {:error, :rpc_error} ->
            # JSON-RPC error envelope from a 2xx — bundler refused
            # the request as malformed. Treat as terminal failure
            # (the userop hash isn't recognized or is malformed).
            finalize_failed(delegation, :bundler_unavailable, args)

          {:error, reason}
          when reason in [:transport_error, :invalid_response, :unknown] ->
            if attempt >= max_attempts do
              finalize_failed(delegation, :bundler_unavailable, args)
            else
              {:error, reason}
            end

          {:error, reason} ->
            if attempt >= max_attempts do
              finalize_failed(delegation, :bundler_unavailable, args)
            else
              {:error, reason}
            end
        end
    end
  end

  defp handle_receipt(%Delegation{} = delegation, receipt, args) do
    case receipt_outcome(receipt) do
      {:ok, tx_hash, block_number} ->
        Audit.append_event(
          Events.delegation_install_broadcast(delegation, %{
            tx_hash: tx_hash,
            block_number: block_number
          })
        )

        {:ok, _job} =
          VerifyInstallOnchain.new(%{
            "delegation_id" => delegation.id,
            "binding_id" => delegation.binding_id,
            "workspace_id" => delegation.workspace_id || Map.get(args, "workspace_id"),
            "tx_hash" => tx_hash,
            "block_number" => block_number
          })
          |> Oban.insert()

        :ok

      :reverted ->
        finalize_failed(delegation, :userop_reverted, args)

      :unknown_shape ->
        # Receipt body present but did not match the documented
        # shape. Surface as bundler_unavailable rather than
        # retrying — the row deserves a verdict either way.
        finalize_failed(delegation, :bundler_unavailable, args)
    end
  end

  defp finalize_failed(%Delegation{} = delegation, reason_atom, args)
       when is_atom(reason_atom) do
    {:ok, transitioned} = BrowserInstall.mark_install_failed(delegation, reason_atom)

    Audit.append_event(
      Events.delegation_install_failed(%{
        binding_id: transitioned.binding_id,
        delegation_id: transitioned.id,
        smart_account_id: transitioned.smart_account_id,
        install_userop_hash: transitioned.install_userop_hash,
        workspace_id: transitioned.workspace_id || Map.get(args, "workspace_id"),
        reason: reason_atom,
        subject_type: "delegation",
        subject_id: transitioned.id
      })
    )

    Logger.warning(
      "Bank.Runtime.Workers.PollInstallReceipt marked delegation install_failed " <>
        "(delegation_id=#{transitioned.id} reason=#{reason_atom})"
    )

    :ok
  end

  # --- receipt parsing --------------------------------------------------

  # ZeroDev / EIP-4337 `eth_getUserOperationReceipt` returns:
  #
  #   { "userOpHash": "0x...",
  #     "success": true | false,
  #     "receipt": {
  #       "transactionHash": "0x...",
  #       "blockNumber": "0x...",
  #       ...
  #     },
  #     ... }
  #
  # We pull `success`, `receipt.transactionHash`, and
  # `receipt.blockNumber` (decoded from hex) — that's what
  # `VerifyInstallOnchain` consumes downstream.
  defp receipt_outcome(receipt) when is_map(receipt) do
    success = Map.get(receipt, "success")
    tx_receipt = Map.get(receipt, "receipt") || %{}
    tx_hash = Map.get(tx_receipt, "transactionHash")
    block_hex = Map.get(tx_receipt, "blockNumber")

    cond do
      success == false ->
        :reverted

      success == true and is_binary(tx_hash) and is_binary(block_hex) ->
        case hex_to_integer(block_hex) do
          n when is_integer(n) and n > 0 -> {:ok, String.downcase(tx_hash), n}
          _ -> :unknown_shape
        end

      true ->
        :unknown_shape
    end
  end

  defp receipt_outcome(_), do: :unknown_shape

  defp hex_to_integer("0x" <> hex) when is_binary(hex) and hex != "" do
    case Integer.parse(hex, 16) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp hex_to_integer(_), do: nil

  # --- deadline / snooze ------------------------------------------------

  defp past_deadline?(args) do
    case Map.get(args, "deadline_at") do
      iso when is_binary(iso) ->
        case DateTime.from_iso8601(iso) do
          {:ok, dt, _} -> DateTime.compare(DateTime.utc_now(), dt) == :gt
          _ -> false
        end

      _ ->
        false
    end
  end

  @doc """
  Returns the wall-clock deadline `(now + deadline_ms)` as an
  ISO 8601 string. Used by callers (`BrowserInstall`) so each
  enqueued poller carries its own deadline.
  """
  @spec deadline_at_iso(integer()) :: String.t()
  def deadline_at_iso(now_ms \\ System.os_time(:millisecond)) do
    deadline_ms = configured_deadline_ms()

    DateTime.from_unix!(now_ms + deadline_ms, :millisecond)
    |> DateTime.to_iso8601()
  end

  defp snooze_seconds do
    Application.get_env(:bank, __MODULE__, [])
    |> Keyword.get(:snooze_seconds, @default_snooze_seconds)
  end

  defp configured_deadline_ms do
    Application.get_env(:bank, __MODULE__, [])
    |> Keyword.get(:deadline_ms, @default_deadline_ms)
  end

  # --- RPC driver -------------------------------------------------------

  defp configured_rpc_fn do
    case Application.get_env(:bank, __MODULE__, []) |> Keyword.get(:rpc_fn) do
      fun when is_function(fun, 2) -> fun
      _ -> &default_rpc/2
    end
  end

  defp jsonrpc(method, params) do
    %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => method,
      "params" => params
    }
  end

  @doc false
  @spec default_rpc(String.t(), map()) :: {:ok, term()} | {:error, atom()}
  def default_rpc(url, payload) do
    response =
      Req.post(
        url: url,
        json: payload,
        retry: false,
        receive_timeout: @rpc_timeout_ms
      )

    case response do
      {:ok, %Req.Response{status: status, body: %{"result" => result}}}
      when status >= 200 and status < 300 ->
        {:ok, result}

      {:ok, %Req.Response{status: status, body: %{"error" => _}}}
      when status >= 200 and status < 300 ->
        {:error, :rpc_error}

      {:ok, %Req.Response{status: status}} when status >= 500 ->
        {:error, :transport_error}

      {:ok, %Req.Response{status: status}} when status >= 400 ->
        {:error, :transport_error}

      {:ok, %Req.Response{}} ->
        {:error, :invalid_response}

      {:error, %{__struct__: Req.TransportError}} ->
        {:error, :transport_error}

      {:error, _} ->
        {:error, :transport_error}
    end
  rescue
    _ -> {:error, :unknown}
  catch
    :exit, _ -> {:error, :unknown}
  end
end
