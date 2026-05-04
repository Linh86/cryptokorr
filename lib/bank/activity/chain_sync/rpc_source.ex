defmodule Bank.Activity.ChainSync.RpcSource do
  @moduledoc """
  JSON-RPC source for `Bank.Activity.ChainSync` (#245).

  Default implementation backing the `:rpc_fn` opt on
  `Bank.Activity.ChainSync.sync_address/4`. Tests inject their
  own `:rpc_fn` and never hit this module — see the moduledoc on
  `Bank.Activity.ChainSync` for the test contract.

  ## Configuration

  Reads `Application.get_env(:bank, __MODULE__, [])`:

      config :bank, Bank.Activity.ChainSync.RpcSource,
        base_url: "https://sepolia.base.org",
        # Optional: extra Req options (timeouts, plug stub, mTLS).
        req_options: []

  When `:base_url` is missing or nil — the v0.1 default in dev /
  test / staging without an indexer endpoint — every call returns
  `{:error, "rpc_not_configured"}` so the cursor records a fixed
  sanitized failure label and the next sync attempt retries
  cleanly.

  ## Secret hygiene

  This module NEVER:

    * logs the configured `:base_url` (which can carry tokenized
      RPC userinfo or query string),
    * logs the request payload,
    * logs the raw `Req` error struct,
    * leaks `Authorization` headers.

  The only outward signal is the fixed-label return tuple
  consumed by `Bank.Activity.ChainSync`.
  """

  require Logger

  @default_timeout_ms 5_000

  @typedoc "Single JSON-RPC request shape."
  @type request :: %{required(:method) => String.t(), required(:params) => list()}

  @typedoc "Source result. `:error` carries a fixed-shape label, never a raw struct."
  @type result :: {:ok, term()} | {:error, String.t()}

  @doc """
  Issue a single JSON-RPC `method` + `params` against the
  configured `:base_url`. Returns the decoded `result` field on
  success, a fixed-shape error label otherwise.

  Production-safe default: when no `:base_url` is configured,
  returns `{:error, "rpc_not_configured"}` immediately without
  touching the network.
  """
  @spec call(request()) :: result()
  def call(%{method: method, params: params}) when is_binary(method) and is_list(params) do
    config = Application.get_env(:bank, __MODULE__, [])
    base_url = Keyword.get(config, :base_url)
    extra = Keyword.get(config, :req_options, [])

    if is_nil(base_url) or base_url == "" do
      {:error, "rpc_not_configured"}
    else
      do_call(base_url, method, params, extra)
    end
  end

  defp do_call(base_url, method, params, extra) do
    body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    req_opts =
      [
        base_url: base_url,
        url: "/",
        method: :post,
        headers: [{"content-type", "application/json"}],
        json: body,
        receive_timeout: @default_timeout_ms,
        retry: false
      ]
      |> Keyword.merge(extra)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: %{"result" => result}}}
      when status in 200..299 ->
        {:ok, result}

      {:ok, %Req.Response{status: status, body: %{"error" => _}}} when status in 200..299 ->
        Logger.warning(
          "Bank.Activity.ChainSync.RpcSource: RPC returned application error (method=#{method})"
        )

        {:error, "invalid_response"}

      {:ok, %Req.Response{status: status}} when status in 400..499 ->
        Logger.warning("Bank.Activity.ChainSync.RpcSource: RPC #{status} (method=#{method})")

        {:error, "rpc_error_4xx"}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Bank.Activity.ChainSync.RpcSource: RPC #{status} (method=#{method})")

        {:error, "rpc_error_5xx"}

      {:error, reason} ->
        # Sanitized log: only the reason kind. `inspect(reason)`
        # would carry the request URL (with embedded RPC userinfo /
        # tokens) and TLS material.
        Logger.warning(
          "Bank.Activity.ChainSync.RpcSource: RPC unavailable " <>
            "(category=#{reason_category(reason)} method=#{method})"
        )

        case reason do
          %Req.TransportError{reason: :timeout} -> {:error, "timeout"}
          :timeout -> {:error, "timeout"}
          _ -> {:error, "rpc_unavailable"}
        end
    end
  end

  defp reason_category(%Req.TransportError{reason: :timeout}), do: :timeout
  defp reason_category(%Req.TransportError{reason: :econnrefused}), do: :econnrefused
  defp reason_category(%Req.TransportError{reason: :nxdomain}), do: :nxdomain
  defp reason_category(%Req.TransportError{}), do: :transport_error
  defp reason_category(:timeout), do: :timeout
  defp reason_category(:econnrefused), do: :econnrefused
  defp reason_category(:nxdomain), do: :nxdomain
  defp reason_category(_), do: :transport_error
end
