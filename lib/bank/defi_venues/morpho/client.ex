defmodule Bank.DefiVenues.Morpho.Client do
  @moduledoc """
  Morpho Blue API GraphQL client (#198).

  Read-only ingestion groundwork for `morpho_risk_explanation` —
  fetches a Morpho Vault snapshot by `(chain_id, vault_address)`
  and normalises it into `Bank.DefiVenues.Morpho.VaultSnapshot`.

  This module **never**:

    * dispatches a chain transaction,
    * signs a payload,
    * mutates DB rows (Phase 1 is pure read; persistence lands
      in #199),
    * calls `Bank.AdapterClient`,
    * sources `.env` directly (configuration goes through
      `Application.get_env(:bank, __MODULE__, [])`).

  ## Configuration

      config :bank, Bank.DefiVenues.Morpho.Client,
        endpoint: "https://blue-api.morpho.org/graphql",
        # Optional: extra Req options (timeouts, plug stubs, etc.)
        req_options: []

  ## Public API

      fetch_vault_by_address(chain_id, vault_address, opts)

  Returns:

    * `{:ok, %VaultSnapshot{}}` — successful fetch + normalisation
    * `{:error, :graphql_error}` — GraphQL response carried an
      `errors` array
    * `{:error, :http_4xx}` / `{:error, :http_5xx}` — non-2xx HTTP
    * `{:error, :timeout}` — `%Req.TransportError{reason: :timeout}`
      or atom `:timeout`
    * `{:error, :unavailable}` — any other transport failure
    * `{:error, :malformed_response}` — JSON shape did not carry
      a `data.vaultByAddress` map, or an essential field is
      missing/non-binary
    * `{:error, :invalid_args}` — caller passed nil / bad types

  ## Secret hygiene

  This module never logs the response body, the GraphQL query
  variables (the address is workspace-public but body content
  could carry warning metadata that mirrors policy rules), or
  the raw `Req.TransportError` struct (which can carry TLS
  material in `reason`). Sanitised log lines collapse the
  underlying reason to a fixed enum.

  ## Test injection

  Tests pass `:req_options` with a `:plug` stub so no live HTTP
  is made. See `test/bank/defi_venues/morpho/client_test.exs`.
  """

  require Logger

  alias Bank.DefiVenues.Morpho.GraphQL
  alias Bank.DefiVenues.Morpho.VaultSnapshot

  @default_endpoint "https://blue-api.morpho.org/graphql"
  @default_timeout_ms 5_000
  @source_name "morpho_api"

  @type fetch_result ::
          {:ok, VaultSnapshot.t()}
          | {:error,
             :graphql_error
             | :http_4xx
             | :http_5xx
             | :timeout
             | :unavailable
             | :malformed_response
             | :invalid_args}

  @doc """
  Fetch a Morpho vault snapshot by `(chain_id, vault_address)`.

  ## Args

    * `chain_id` — integer EVM chain id (1 = mainnet, 8453 = base,
      84532 = base-sepolia, etc.).
    * `vault_address` — checksum-or-lowercase 0x-prefixed 20-byte
      hex string. The Morpho API normalises case server-side.
    * `opts` — keyword:
      * `:req_options` — extra options merged into the underlying
        `Req.request/1` call. Tests use this to plug a canned
        response.
      * `:fetched_at` — clock override for deterministic
        snapshots in tests.

  Returns `{:ok, %VaultSnapshot{}}` on success or one of the
  documented error tuples otherwise.
  """
  @spec fetch_vault_by_address(integer() | nil, String.t() | nil, keyword()) :: fetch_result()
  def fetch_vault_by_address(chain_id, vault_address, opts \\ [])

  def fetch_vault_by_address(chain_id, _vault_address, _opts) when not is_integer(chain_id),
    do: {:error, :invalid_args}

  def fetch_vault_by_address(_chain_id, vault_address, _opts)
      when not is_binary(vault_address) or vault_address == "",
      do: {:error, :invalid_args}

  def fetch_vault_by_address(chain_id, vault_address, opts) do
    config = Application.get_env(:bank, __MODULE__, [])
    endpoint = Keyword.get(config, :endpoint, @default_endpoint)
    extra_config = Keyword.get(config, :req_options, [])
    extra_call = Keyword.get(opts, :req_options, [])
    fetched_at = Keyword.get(opts, :fetched_at, DateTime.utc_now())

    body = GraphQL.vault_by_address_body(chain_id, vault_address)

    req_opts =
      [
        url: endpoint,
        method: :post,
        headers: [{"content-type", "application/json"}],
        json: body,
        receive_timeout: @default_timeout_ms,
        retry: false
      ]
      |> Keyword.merge(extra_config)
      |> Keyword.merge(extra_call)

    case Req.request(req_opts) do
      {:ok, %Req.Response{status: status, body: response_body}}
      when status in 200..299 ->
        handle_response_body(response_body, chain_id, vault_address, fetched_at)

      {:ok, %Req.Response{status: status}} when status in 400..499 ->
        Logger.warning("Bank.DefiVenues.Morpho.Client: HTTP #{status} fetching vaultByAddress")

        {:error, :http_4xx}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("Bank.DefiVenues.Morpho.Client: HTTP #{status} fetching vaultByAddress")

        {:error, :http_5xx}

      {:error, reason} ->
        # Sanitised: only the reason kind. `inspect(reason)` would
        # carry the request URL + TLS material.
        Logger.warning(
          "Bank.DefiVenues.Morpho.Client: morpho api unavailable " <>
            "(category=#{reason_category(reason)})"
        )

        case reason do
          %Req.TransportError{reason: :timeout} -> {:error, :timeout}
          :timeout -> {:error, :timeout}
          _ -> {:error, :unavailable}
        end
    end
  end

  # --- response handling -------------------------------------------------

  defp handle_response_body(body, chain_id, vault_address, fetched_at) when is_map(body) do
    cond do
      Map.has_key?(body, "errors") and is_list(body["errors"]) and body["errors"] != [] ->
        Logger.warning("Bank.DefiVenues.Morpho.Client: GraphQL error fetching vaultByAddress")

        {:error, :graphql_error}

      not is_map(body["data"]) ->
        {:error, :malformed_response}

      not is_map(body["data"]["vaultByAddress"]) ->
        {:error, :malformed_response}

      true ->
        normalise(body, body["data"]["vaultByAddress"], chain_id, vault_address, fetched_at)
    end
  end

  defp handle_response_body(_body, _chain_id, _vault_address, _fetched_at),
    do: {:error, :malformed_response}

  defp normalise(envelope, vault, chain_id, vault_address, fetched_at) when is_map(vault) do
    {address, addr_warnings} = take_required_string(vault, "address")

    case address do
      nil ->
        {:error, :malformed_response}

      _ ->
        chain = vault["chain"] || %{}
        asset = vault["asset"] || %{}
        state = vault["state"] || %{}

        {allocations, alloc_warnings} = normalise_allocations(state["allocation"])
        {warnings, warn_field_warnings} = normalise_warnings(vault["warnings"])
        {pending_caps, pc_warnings} = normalise_pending_caps(vault["pendingCaps"])
        {allocators, allocator_warnings} = normalise_allocators(vault["allocators"])

        public_allocator_config =
          case vault["publicAllocatorConfig"] do
            %{} = pac ->
              %{
                fee: stringify(pac["fee"]),
                accrued_fee: stringify(pac["accruedFee"])
              }

            _ ->
              nil
          end

        deprecation_warnings = collect_deprecation_warnings(vault)

        field_warnings =
          [
            addr_warnings,
            alloc_warnings,
            warn_field_warnings,
            pc_warnings,
            allocator_warnings,
            deprecation_warnings
          ]
          |> List.flatten()

        snapshot = %VaultSnapshot{
          chain_id: integer_or(chain["id"], chain_id),
          chain_network: stringify(chain["network"]),
          address: String.downcase(address),
          name: stringify(vault["name"]),
          symbol: stringify(vault["symbol"]),
          listed: boolean_or_nil(vault["listed"]),
          asset_address: stringify(asset["address"]),
          asset_symbol: stringify(asset["symbol"]),
          asset_decimals: integer_or(asset["decimals"], nil),
          apy: float_or_nil(state["apy"]),
          net_apy: float_or_nil(state["netApy"]),
          total_assets: stringify(state["totalAssets"]),
          fee: stringify(state["fee"]),
          timelock: integer_or(state["timelock"], nil),
          allocations: allocations,
          warnings: warnings,
          pending_caps: pending_caps,
          allocators: allocators,
          public_allocator_config: public_allocator_config,
          source: %{
            fetched_at: fetched_at,
            source_name: @source_name,
            source_schema_version: GraphQL.source_schema_version(),
            payload_hash: payload_hash(envelope),
            warnings: warnings,
            field_warnings: field_warnings
          }
        }

        {:ok, snapshot}
    end
  rescue
    err ->
      # Last-resort: a malformed nested shape that didn't trip a
      # narrower clause. Sanitised — never log the body.
      Logger.warning(
        "Bank.DefiVenues.Morpho.Client: normalise raised #{inspect(err.__struct__)}: " <>
          "#{Exception.message(err)}; treating as malformed_response " <>
          "(vault=#{redact_address(vault_address)})"
      )

      {:error, :malformed_response}
  end

  defp normalise_allocations(nil), do: {[], [{:missing_field, "state.allocation"}]}

  defp normalise_allocations(list) when is_list(list) do
    allocations =
      Enum.map(list, fn alloc ->
        market = alloc["market"] || %{}
        loan = market["loanAsset"] || %{}
        coll = market["collateralAsset"] || %{}

        %{
          market_unique_key: stringify(market["uniqueKey"]),
          loan_asset_address: stringify(loan["address"]),
          loan_asset_symbol: stringify(loan["symbol"]),
          loan_asset_decimals: integer_or(loan["decimals"], nil),
          collateral_asset_address: stringify(coll["address"]),
          collateral_asset_symbol: stringify(coll["symbol"]),
          collateral_asset_decimals: integer_or(coll["decimals"], nil),
          oracle_address: stringify(market["oracleAddress"]),
          irm_address: stringify(market["irmAddress"]),
          lltv: stringify(market["lltv"]),
          supply_cap: stringify(alloc["supplyCap"]),
          supply_assets: stringify(alloc["supplyAssets"]),
          supply_assets_usd: stringify(alloc["supplyAssetsUsd"])
        }
      end)

    {allocations, []}
  end

  defp normalise_allocations(_), do: {[], [{:missing_field, "state.allocation"}]}

  defp normalise_warnings(nil), do: {[], [{:missing_field, "warnings"}]}

  defp normalise_warnings(list) when is_list(list) do
    warnings =
      Enum.map(list, fn w ->
        %{type: stringify(w["type"]), level: stringify(w["level"])}
      end)

    {warnings, []}
  end

  defp normalise_warnings(_), do: {[], [{:missing_field, "warnings"}]}

  defp normalise_pending_caps(nil), do: {[], [{:missing_field, "pendingCaps"}]}

  defp normalise_pending_caps(list) when is_list(list) do
    caps =
      Enum.map(list, fn cap ->
        market = cap["market"] || %{}

        %{
          market_unique_key: stringify(market["uniqueKey"]),
          supply_cap: stringify(cap["supplyCap"]),
          valid_at: stringify(cap["validAt"])
        }
      end)

    {caps, []}
  end

  defp normalise_pending_caps(_), do: {[], [{:missing_field, "pendingCaps"}]}

  defp normalise_allocators(nil), do: {[], [{:missing_field, "allocators"}]}

  defp normalise_allocators(list) when is_list(list) do
    addresses =
      list
      |> Enum.map(&stringify(&1["address"]))
      |> Enum.reject(&is_nil/1)

    {addresses, []}
  end

  defp normalise_allocators(_), do: {[], [{:missing_field, "allocators"}]}

  # `whitelisted` was deprecated in favour of `listed` per the
  # 2026-04-29 live API check (docs/morpho-risk-explanation.md
  # lines 94-95). If a response still includes `whitelisted` we
  # surface it as a `field_warning` so an operator can spot a
  # source-side regression before it reaches the risk engine.
  defp collect_deprecation_warnings(vault) do
    deprecated =
      ~w(whitelisted)
      |> Enum.filter(&Map.has_key?(vault, &1))
      |> Enum.map(&{:deprecated_field, &1})

    deprecated
  end

  # --- helpers -----------------------------------------------------------

  defp take_required_string(map, key) do
    case map[key] do
      v when is_binary(v) and v != "" -> {v, []}
      _ -> {nil, [{:missing_field, key}]}
    end
  end

  defp stringify(nil), do: nil
  defp stringify(v) when is_binary(v), do: v
  defp stringify(v) when is_number(v), do: to_string(v)
  defp stringify(_), do: nil

  defp integer_or(nil, default), do: default
  defp integer_or(v, _) when is_integer(v), do: v

  defp integer_or(v, default) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> default
    end
  end

  defp integer_or(_, default), do: default

  defp float_or_nil(nil), do: nil
  defp float_or_nil(v) when is_float(v), do: v
  defp float_or_nil(v) when is_integer(v), do: v * 1.0

  defp float_or_nil(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end

  defp float_or_nil(_), do: nil

  defp boolean_or_nil(true), do: true
  defp boolean_or_nil(false), do: false
  defp boolean_or_nil(_), do: nil

  defp payload_hash(body) when is_map(body) do
    # Hash a deterministic JSON encoding of the response envelope.
    # Re-encoding (instead of capturing raw bytes) means two pretty-
    # vs-minified responses with identical semantics produce the
    # same hash — that's the stability guarantee #198 asks for.
    encoded = Jason.encode!(body)
    digest = :crypto.hash(:sha256, encoded)
    Base.encode16(digest, case: :lower)
  end

  defp payload_hash(_), do: ""

  defp reason_category(%Req.TransportError{reason: :timeout}), do: :timeout
  defp reason_category(%Req.TransportError{reason: :econnrefused}), do: :econnrefused
  defp reason_category(%Req.TransportError{reason: :nxdomain}), do: :nxdomain
  defp reason_category(%Req.TransportError{}), do: :transport_error
  defp reason_category(:timeout), do: :timeout
  defp reason_category(:econnrefused), do: :econnrefused
  defp reason_category(:nxdomain), do: :nxdomain
  defp reason_category(_), do: :transport_error

  # Used only in sanitised log lines — the address is public, but
  # truncating it keeps log lines short and avoids accidental
  # operator confusion with checksum / lowercase variants.
  defp redact_address(addr) when is_binary(addr) and byte_size(addr) > 10 do
    String.slice(addr, 0, 8) <> "…"
  end

  defp redact_address(_), do: "?"
end
