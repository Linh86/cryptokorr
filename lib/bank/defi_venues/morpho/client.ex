defmodule Bank.DefiVenues.Morpho.Client do
  @moduledoc """
  HTTP client for the Morpho Blue GraphQL API (#198).

  Read-only ingestion only. This module:

    * does not broadcast or sign chain transactions,
    * does not enqueue Oban jobs,
    * does not write any DB row (persistence lands in #199),
    * does not log response bodies (operators pasting an API
      key into a header for later, the issue's "no API
      response body containing sensitive config is logged"
      acceptance bullet),
    * does not source `.env` — the GraphQL endpoint is
      configured via `Application.get_env/2`.

  ## Configuration

      config :bank, Bank.DefiVenues.Morpho.Client,
        base_url: "https://blue-api.morpho.org/graphql",
        receive_timeout_ms: 8_000,
        req_options: []

  Tests override `:req_options` with
  `[plug: {Req.Test, Bank.DefiVenues.Morpho.Client}]` so each
  test can `Req.Test.stub/2` a deterministic response without
  any real network call.

  ## Errors

  Returns `{:ok, %Bank.DefiVenues.Morpho.VaultSnapshot{}}` or
  `{:error, reason}` where `reason` is one of:

    * `:vault_not_found` — Morpho returned `data.vaultByAddress: null`.
    * `:malformed_payload` — body was not JSON, was not a map,
      or was missing required nested fields.
    * `{:graphql_error, [%{message, path}, ...]}` —
      response carried a non-empty `errors` array.
    * `:provider_unavailable` — transport failure or 5xx
      response from Morpho.
    * `:provider_timeout` — the request hit the receive
      timeout.
    * `{:provider_error, %{status: integer, body: term}}` —
      4xx response we cannot classify further.

  Errors NEVER carry the raw response body; the body is
  hashed into the snapshot's `:payload_hash` only.
  """

  require Logger

  alias Bank.DefiVenues.Morpho.GraphQL
  alias Bank.DefiVenues.Morpho.VaultSnapshot

  @default_base_url "https://blue-api.morpho.org/graphql"
  @default_receive_timeout_ms 8_000

  @type fetch_error ::
          :vault_not_found
          | :malformed_payload
          | {:graphql_error, [map()]}
          | :provider_unavailable
          | :provider_timeout
          | {:provider_error, %{status: pos_integer(), body: term()}}

  @doc """
  Fetch and normalize a single vault snapshot for `(chain_id, vault_address)`.

  ## Options

    * `:now_fn` — 0-arity function returning a `DateTime.t/0`;
      defaults to `&DateTime.utc_now/0`. Tests pass a deterministic
      stub to keep `source.fetched_at` stable.
    * `:req_options` — extra keyword list merged into the underlying
      `Req.request/1` call. The test config wires this to
      `[plug: {Req.Test, __MODULE__}]`.
  """
  @spec fetch_vault_by_address(integer(), String.t(), keyword()) ::
          {:ok, VaultSnapshot.t()} | {:error, fetch_error()}
  def fetch_vault_by_address(chain_id, vault_address, opts \\ [])

  def fetch_vault_by_address(chain_id, vault_address, _opts)
      when not is_integer(chain_id) or not is_binary(vault_address) or vault_address == "" do
    {:error, :malformed_payload}
  end

  def fetch_vault_by_address(chain_id, vault_address, opts) do
    config = Application.get_env(:bank, __MODULE__, [])
    base_url = Keyword.get(config, :base_url, @default_base_url)
    receive_timeout = Keyword.get(config, :receive_timeout_ms, @default_receive_timeout_ms)
    extra = Keyword.get(opts, :req_options, Keyword.get(config, :req_options, []))
    now_fn = Keyword.get(opts, :now_fn, &DateTime.utc_now/0)

    body = %{
      "query" => GraphQL.vault_by_address_query(),
      "variables" => GraphQL.vault_by_address_variables(chain_id, vault_address),
      "operationName" => "VaultByAddress"
    }

    req_opts =
      [
        url: base_url,
        method: :post,
        headers: [
          {"content-type", "application/json"},
          {"accept", "application/json"}
        ],
        json: body,
        receive_timeout: receive_timeout,
        retry: false
      ]
      |> Keyword.merge(extra)

    req_opts
    |> Req.request()
    |> classify_response(chain_id, vault_address, now_fn)
  rescue
    # `Req.request/1` itself can raise on a configuration error;
    # the issue mandates we never crash the caller.
    error ->
      Logger.warning(
        "Bank.DefiVenues.Morpho.Client: request raised " <>
          "(chain_id=#{chain_id} kind=#{inspect(error.__struct__)})"
      )

      {:error, :provider_unavailable}
  end

  # --- response classification ------------------------------------------

  defp classify_response({:ok, %Req.Response{status: 200, body: body}}, chain_id, addr, now_fn)
       when is_map(body) do
    fetched_at = now_fn.()
    raw_payload = encode_payload(body)
    GraphQL.normalize(body, chain_id, addr, fetched_at, raw_payload)
  end

  defp classify_response({:ok, %Req.Response{status: 200, body: _other}}, _c, _a, _n) do
    # 200 with a non-map body (HTML error page, plain text) is
    # malformed at the JSON layer for our purposes.
    {:error, :malformed_payload}
  end

  defp classify_response({:ok, %Req.Response{status: status}}, _c, _a, _n) when status >= 500 do
    Logger.warning("Bank.DefiVenues.Morpho.Client: upstream 5xx (status=#{status})")
    {:error, :provider_unavailable}
  end

  defp classify_response({:ok, %Req.Response{status: status, body: body}}, _c, _a, _n)
       when status in 400..499 do
    {:error, {:provider_error, %{status: status, body: pruned_body(body)}}}
  end

  defp classify_response({:ok, %Req.Response{status: status}}, _c, _a, _n) do
    {:error, {:provider_error, %{status: status, body: nil}}}
  end

  defp classify_response({:error, %Req.TransportError{reason: :timeout}}, _c, _a, _n),
    do: {:error, :provider_timeout}

  defp classify_response({:error, %{__struct__: Req.TransportError}}, _c, _a, _n),
    do: {:error, :provider_unavailable}

  defp classify_response({:error, _}, _c, _a, _n), do: {:error, :provider_unavailable}

  # Snapshot the raw body in a deterministic, stable shape for
  # the payload-hash. Two semantically-equal responses must hash
  # the same regardless of map-key insertion order.
  defp encode_payload(body) when is_map(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> encoded
      {:error, _} -> :erlang.term_to_binary(body)
    end
  end

  defp encode_payload(other), do: :erlang.term_to_binary(other)

  # 4xx error bodies can carry surprising content; we hash them
  # rather than re-export them to the caller. (`:provider_error`
  # is internal — operators see the status code, not the body.)
  defp pruned_body(body) when is_binary(body) do
    %{sha256: GraphQL.payload_hash(body), kind: :string}
  end

  defp pruned_body(body) when is_map(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> %{sha256: GraphQL.payload_hash(encoded), kind: :map}
      {:error, _} -> %{sha256: nil, kind: :map}
    end
  end

  defp pruned_body(_), do: %{sha256: nil, kind: :other}
end
