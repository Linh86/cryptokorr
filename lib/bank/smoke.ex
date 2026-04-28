defmodule Bank.Smoke do
  @moduledoc """
  Repeatable smoke checks against a running adapter and a funded Base
  smart account.

  These are *not* unit tests — they hit real infrastructure, spend real
  gas, and therefore live outside `mix test`. They're meant to be run
  by an operator before a demo or a partner session to confirm the
  dispatch + callback wiring is healthy end-to-end.

  Two flows are covered:

    * `run_transfer/1` — submit a tiny transfer intent, drive it through
      dispatch, wait for the adapter to emit `execution.confirmed`, and
      return the final plan.
    * `run_revoke/1` — dispatch a delegation revoke for the given smart
      account and wait for the adapter to callback with
      `delegation.state_changed{state: "revoked"}`.

  Each function returns `{:ok, detail}` on PASS or `{:error, reason}` on
  FAIL. The corresponding Mix tasks (`mix bank.smoke.transfer`,
  `mix bank.smoke.revoke`) wrap these and exit with status 0 / 1 so CI
  or a deploy script can key off the exit code.

  ## Preconditions

    * Phoenix can reach the adapter at `ADAPTER_BASE_URL`.
    * `ADAPTER_DISPATCH_SECRET` is set to the same value the adapter
      expects on inbound `/dispatch/*`.
    * `ADAPTER_CALLBACK_SECRET` is set to the same value the adapter
      uses on outbound `/internal/adapter/callback`.
    * The adapter is configured against a funded smart account on the
      target chain (Base Sepolia for staging).
    * `Bank.AdapterClient` config in the current runtime points at that
      adapter. In staging `config/runtime.exs` picks these up from env.

  See `docs/smoke-tests.md` for the full runbook.
  """

  require Logger

  alias Bank.Counterparties.{AddressLabel, Counterparty}
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Delegations
  alias Bank.Delegations.Delegation
  alias Bank.Intents.AgentIntent
  alias Bank.Repo
  alias Bank.Runtime

  @default_poll_ms 2_000
  @default_timeout_ms 180_000

  @type transfer_opts :: [
          smart_account_id: String.t(),
          delegation_id: String.t(),
          target_address: String.t(),
          chain: String.t(),
          asset: String.t(),
          amount: String.t(),
          timeout_ms: pos_integer()
        ]

  @type revoke_opts :: [
          smart_account_id: String.t(),
          reason: String.t(),
          timeout_ms: pos_integer()
        ]

  @doc """
  Run the transfer smoke path. Creates the minimal records needed, then
  drives dispatch via `Bank.AdapterClient.dispatch_transfer/1` and
  polls the plan until it reaches a terminal execution status.

  Returns `{:ok, plan}` on confirmed execution, `{:error, reason}`
  otherwise.
  """
  @spec run_transfer(transfer_opts()) :: {:ok, ExecutionPlan.t()} | {:error, term()}
  def run_transfer(opts) do
    with {:ok, chain} <- fetch(opts, :chain, "base"),
         {:ok, asset} <- fetch(opts, :asset, "USDC"),
         {:ok, smart_account_id} <- fetch_required(opts, :smart_account_id),
         {:ok, delegation_id} <- fetch_required(opts, :delegation_id),
         {:ok, target_address} <- fetch_required(opts, :target_address),
         {:ok, amount_str} <- fetch(opts, :amount, "1"),
         {:ok, amount} <- parse_decimal(amount_str),
         :ok <- ensure_delegation(smart_account_id, delegation_id, chain),
         {:ok, counterparty} <- ensure_counterparty("Smoke target"),
         {:ok, label} <- ensure_address_label(counterparty, chain, target_address),
         {:ok, intent} <- create_smoke_intent(counterparty, label, chain, asset, amount),
         {:ok, decision} <- create_decision(intent),
         {:ok, plan} <- create_plan(decision, smart_account_id, chain, asset, delegation_id) do
      Logger.info("Bank.Smoke: dispatching transfer plan #{plan.id}")

      case Bank.AdapterClient.dispatch_transfer(Repo.preload(plan, :intent)) do
        {:ok, %{accepted: true}} ->
          await_terminal_plan(plan.id, Keyword.get(opts, :timeout_ms, @default_timeout_ms))

        {:error, reason} ->
          {:error, {:dispatch_failed, reason}}
      end
    end
  end

  @doc """
  Run the revoke smoke path. Expects an active delegation for
  `smart_account_id`; dispatches the revoke to the adapter and waits
  for the delegation row to reach `:revoked`.
  """
  @spec run_revoke(revoke_opts()) :: {:ok, Delegation.t()} | {:error, term()}
  def run_revoke(opts) do
    with {:ok, smart_account_id} <- fetch_required(opts, :smart_account_id),
         {:ok, reason} <- fetch(opts, :reason, "smoke_test"),
         %Delegation{state: state, delegation_id: delegation_id}
         when state in [:active, :pending] and is_binary(delegation_id) <-
           Delegations.get(smart_account_id) || {:error, :no_delegation} do
      Logger.info(
        "Bank.Smoke: dispatching revoke for #{smart_account_id} (delegation_id=#{delegation_id})"
      )

      # `dispatch_revoke_delegation/2` requires `delegation_id` so
      # the adapter can target the right authority record. For rows
      # with `permission` artifacts (cryptographic path, live since
      # PR #132 closed #58 / #31) the adapter feeds
      # `permission.validation_id` to `Kernel.uninstallValidation`;
      # legacy sentinel rows just echo the id into the callback.
      case Bank.AdapterClient.dispatch_revoke_delegation(%{
             smart_account_id: smart_account_id,
             delegation_id: delegation_id,
             reason: reason
           }) do
        {:ok, %{accepted: true}} ->
          await_revoked(smart_account_id, Keyword.get(opts, :timeout_ms, @default_timeout_ms))

        {:error, reason} ->
          {:error, {:dispatch_failed, reason}}
      end
    else
      {:error, :no_delegation} -> {:error, :no_active_delegation}
      %Delegation{state: state} -> {:error, {:delegation_not_active, state}}
      other -> other
    end
  end

  # --- Setup helpers -----------------------------------------------------

  defp ensure_delegation(smart_account_id, delegation_id, chain) do
    case Delegations.get(smart_account_id) do
      %Delegation{state: :active} ->
        :ok

      %Delegation{state: state} ->
        {:error, {:delegation_not_active, state}}

      nil ->
        {:ok, _} =
          %Delegation{}
          |> Delegation.changeset(%{
            smart_account_id: smart_account_id,
            delegation_id: delegation_id,
            state: :active,
            chain: chain,
            granted_at: DateTime.utc_now()
          })
          |> Repo.insert()

        :ok
    end
  end

  defp ensure_counterparty(name) do
    case Repo.get_by(Counterparty, name: name) do
      %Counterparty{} = cp ->
        {:ok, cp}

      nil ->
        %Counterparty{}
        |> Counterparty.changeset(%{
          name: name,
          created_by: :user,
          current_trust_level: :trusted
        })
        |> Repo.insert()
    end
  end

  defp ensure_address_label(counterparty, chain, address) do
    import Ecto.Query

    existing =
      Repo.one(
        from l in AddressLabel,
          where:
            l.counterparty_id == ^counterparty.id and
              l.chain == ^chain and
              l.address == ^address and
              is_nil(l.retired_at),
          limit: 1
      )

    case existing do
      %AddressLabel{} = label ->
        {:ok, label}

      nil ->
        %AddressLabel{}
        |> AddressLabel.changeset(%{
          counterparty_id: counterparty.id,
          chain: chain,
          address: address,
          role: :payout
        })
        |> Repo.insert()
    end
  end

  defp create_smoke_intent(counterparty, label, chain, asset, amount) do
    stamp = System.unique_integer([:positive])

    %AgentIntent{}
    |> AgentIntent.changeset(%{
      agent_id: "smoke-#{stamp}",
      source: :agent,
      idempotency_key: "smoke-idem-#{stamp}",
      payload_hash: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
      kind: :transfer,
      asset: asset,
      chain: chain,
      amount: amount,
      target_counterparty_id: counterparty.id,
      target_address_label_id: label.id,
      submitted_at: DateTime.utc_now(),
      state: :decided
    })
    |> Repo.insert()
  end

  defp create_decision(intent) do
    %DecisionEnvelope{}
    |> DecisionEnvelope.changeset(%{
      intent_id: intent.id,
      outcome: :auto_exec,
      risk_tier: :low,
      decided_at: DateTime.utc_now(),
      decided_by: :runtime,
      state: :decided,
      current: true
    })
    |> Repo.insert()
  end

  defp create_plan(decision, smart_account_id, chain, asset, delegation_id) do
    %ExecutionPlan{}
    |> ExecutionPlan.changeset(%{
      decision_id: decision.id,
      intent_id: decision.intent_id,
      chain: chain,
      asset: asset,
      smart_account_id: smart_account_id,
      execution_status: :prepared,
      signing_requirements: %{"delegation_id" => delegation_id, "scope" => %{}}
    })
    |> Repo.insert()
  end

  # --- Polling -----------------------------------------------------------

  defp await_terminal_plan(plan_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_plan(plan_id, deadline)
  end

  defp do_await_plan(plan_id, deadline) do
    case Repo.get(ExecutionPlan, plan_id) do
      %ExecutionPlan{execution_status: :confirmed} = plan ->
        {:ok, plan}

      %ExecutionPlan{execution_status: :reverted} = plan ->
        {:error, {:reverted, plan.final_reason}}

      %ExecutionPlan{execution_status: :aborted} = plan ->
        {:error, {:aborted, plan.final_reason}}

      %ExecutionPlan{} = plan ->
        maybe_continue(
          plan_id,
          deadline,
          fn -> do_await_plan(plan_id, deadline) end,
          {:timeout, plan.execution_status}
        )

      nil ->
        {:error, :plan_missing}
    end
  end

  defp await_revoked(smart_account_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Runtime
    |> maybe_runtime_kicker(smart_account_id)

    do_await_revoked(smart_account_id, deadline)
  end

  defp do_await_revoked(smart_account_id, deadline) do
    case Delegations.get(smart_account_id) do
      %Delegation{state: :revoked} = d ->
        {:ok, d}

      # A terminal failure of the revoke attempt: the chain-level
      # attempt did not complete (send rejected, confirmation timeout,
      # sentinel reverted). The smoke run should surface this instead
      # of hanging until the polling deadline.
      %Delegation{state: :revoke_failed} = d ->
        {:error, {:revoke_failed, d.last_reason}}

      %Delegation{} = d ->
        maybe_continue(
          smart_account_id,
          deadline,
          fn -> do_await_revoked(smart_account_id, deadline) end,
          {:timeout, d.state}
        )

      nil ->
        {:error, :delegation_missing}
    end
  end

  defp maybe_continue(_id, deadline, continue, timeout_tuple) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, timeout_tuple}
    else
      Process.sleep(@default_poll_ms)
      continue.()
    end
  end

  defp maybe_runtime_kicker(_runtime, _id), do: :ok

  # --- Parsing -----------------------------------------------------------

  defp fetch(opts, key, default) do
    case Keyword.get(opts, key) do
      nil -> {:ok, default}
      value -> {:ok, value}
    end
  end

  defp fetch_required(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, {:missing_required, key}}
      "" -> {:error, {:missing_required, key}}
      value -> {:ok, value}
    end
  end

  defp parse_decimal(str) when is_binary(str) do
    case Decimal.parse(str) do
      {d, ""} -> {:ok, d}
      _ -> {:error, {:invalid_amount, str}}
    end
  end
end
