defmodule Bank.AdapterClient do
  @moduledoc """
  Thin HTTP client for dispatching work to the TypeScript chain adapter.

  The adapter is a separate service at `{base_url}`; Phoenix dispatches
  a transfer via `POST {base_url}/dispatch/transfer` with a shared
  bearer secret (mTLS in production). On success the adapter returns
  `HTTP 202 {accepted: true, execution_plan_id}` and reports chain
  progress asynchronously via `POST /internal/adapter/callback` back
  into Phoenix.

  This module owns the three concerns of the outbound half of that
  contract:

    * Payload shaping (matches `priv/adapter/contract.md` v1).
    * Auth + timeouts.
    * A small, typed error surface callers can map onto retry or
      fail-closed semantics.

  It is intentionally narrow. There is no generic "dispatch any
  action" helper — each adapter action gets its own function so the
  request shape stays explicit at the call site.

  ## Error surface

    * `{:ok, %{accepted: true, execution_plan_id: id}}` — the adapter
      has accepted the dispatch and will report progress via callback.
    * `{:error, :adapter_unavailable}` — network/DNS/timeout. Caller
      should retry with backoff.
    * `{:error, {:adapter_rejected, status, body}}` — deterministic
      4xx rejection (validation, unsupported chain/asset). Caller
      should NOT retry.
    * `{:error, {:adapter_error, status, body}}` — 5xx. Retryable.
    * `{:error, :invalid_response}` — 2xx but response didn't match
      the expected shape. Treat as a contract bug; do not retry.
    * `{:error, {:target_not_resolvable, reason}}` — intent target
      could not be resolved to an address without operator help.

  ## Configuration

  Reads `:bank, Bank.AdapterClient` at dispatch time:

      config :bank, Bank.AdapterClient,
        base_url: "http://localhost:4100",
        auth_secret: "dev-secret",
        # Optional: extra options passed to Req (e.g. a test plug)
        req_options: []

  Tests override `:req_options` with `{Req.Test, Bank.AdapterClient}`
  and stub with `Req.Test.stub/2`.
  """

  require Logger

  import Ecto.Query

  alias Bank.Counterparties.AddressLabel
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Intents.AgentIntent
  alias Bank.Repo

  @contract_version 1
  @default_timeout_ms 5_000

  @type transfer_ok :: %{accepted: true, execution_plan_id: String.t()}
  @type transfer_error ::
          :adapter_unavailable
          | :invalid_response
          | {:adapter_rejected, pos_integer(), map() | String.t()}
          | {:adapter_error, pos_integer(), map() | String.t()}
          | {:target_not_resolvable, atom()}

  @doc """
  Dispatch a transfer execution plan to the adapter.

  The plan must carry `:chain`, `:asset`, `:smart_account_id`,
  `:signing_requirements`, and a valid `:intent_id`. The owning
  intent supplies the amount and target; the client resolves the
  target address from the intent's counterparty/label pointers.
  """
  @spec dispatch_transfer(ExecutionPlan.t(), keyword()) ::
          {:ok, transfer_ok()} | {:error, transfer_error()}
  def dispatch_transfer(%ExecutionPlan{} = plan, opts \\ []) do
    with {:ok, payload} <- build_transfer_payload(plan) do
      post("/dispatch/transfer", payload, opts)
    end
  end

  # --- Payload shaping ---------------------------------------------------

  defp build_transfer_payload(%ExecutionPlan{} = plan) do
    with {:ok, intent} <- fetch_intent(plan),
         {:ok, target} <- resolve_target(intent) do
      {:ok,
       %{
         contract_version: @contract_version,
         action: "transfer",
         execution_plan_id: plan.id,
         intent_id: plan.intent_id,
         smart_account_id: plan.smart_account_id,
         chain: plan.chain,
         asset: plan.asset,
         amount: decimal_to_string(intent.amount),
         target: target,
         signing_requirements: signing_requirements(plan),
         correlation_id: plan.intent_id,
         emitted_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  defp fetch_intent(%ExecutionPlan{intent: %AgentIntent{} = intent}), do: {:ok, intent}

  defp fetch_intent(%ExecutionPlan{intent_id: id}) when is_binary(id) do
    case Repo.get(AgentIntent, id) do
      %AgentIntent{} = intent -> {:ok, intent}
      nil -> {:error, {:target_not_resolvable, :intent_missing}}
    end
  end

  defp resolve_target(%AgentIntent{target_address_label_id: label_id})
       when is_binary(label_id) do
    case Repo.get(AddressLabel, label_id) do
      %AddressLabel{retired_at: nil} = label ->
        {:ok, %{address: label.address, counterparty_id: label.counterparty_id}}

      %AddressLabel{} ->
        {:error, {:target_not_resolvable, :label_retired}}

      nil ->
        {:error, {:target_not_resolvable, :label_missing}}
    end
  end

  defp resolve_target(%AgentIntent{
         target_counterparty_id: cp_id,
         chain: chain
       })
       when is_binary(cp_id) and is_binary(chain) do
    labels =
      Repo.all(
        from(l in AddressLabel,
          where:
            l.counterparty_id == ^cp_id and
              l.chain == ^chain and
              is_nil(l.retired_at),
          order_by: [asc: l.inserted_at]
        )
      )

    case labels do
      [label] -> {:ok, %{address: label.address, counterparty_id: label.counterparty_id}}
      [] -> {:error, {:target_not_resolvable, :no_label}}
      _ -> {:error, {:target_not_resolvable, :ambiguous_label}}
    end
  end

  defp resolve_target(%AgentIntent{target_raw_address: addr}) when is_binary(addr) do
    {:ok, %{address: addr, counterparty_id: nil}}
  end

  defp resolve_target(_) do
    {:error, {:target_not_resolvable, :missing_target}}
  end

  defp signing_requirements(%ExecutionPlan{signing_requirements: sr}) when is_map(sr), do: sr
  defp signing_requirements(_), do: %{}

  # --- HTTP --------------------------------------------------------------

  defp post(path, payload, opts) do
    config = Application.fetch_env!(:bank, __MODULE__)
    base_url = Keyword.fetch!(config, :base_url)
    secret = Keyword.fetch!(config, :auth_secret)
    extra_req_options = Keyword.get(config, :req_options, [])

    req_opts =
      [
        base_url: base_url,
        url: path,
        method: :post,
        headers: [
          {"authorization", "Bearer " <> secret},
          {"content-type", "application/json"}
        ],
        json: payload,
        receive_timeout: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
        retry: false
      ]
      |> Keyword.merge(extra_req_options)
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        parse_accepted(body)

      {:ok, %Req.Response{status: status, body: body}} when status in 400..499 ->
        {:error, {:adapter_rejected, status, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:adapter_error, status, body}}

      {:error, reason} ->
        Logger.warning("Bank.AdapterClient #{path} unavailable: #{inspect(reason)}")

        {:error, :adapter_unavailable}
    end
  end

  defp parse_accepted(%{"accepted" => true, "execution_plan_id" => id}) when is_binary(id) do
    {:ok, %{accepted: true, execution_plan_id: id}}
  end

  defp parse_accepted(body) do
    Logger.warning("Bank.AdapterClient: unexpected 2xx body: #{inspect(body)}")
    {:error, :invalid_response}
  end

  defp decimal_to_string(nil), do: nil

  defp decimal_to_string(%Decimal{} = d),
    do: d |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp decimal_to_string(other), do: to_string(other)
end
