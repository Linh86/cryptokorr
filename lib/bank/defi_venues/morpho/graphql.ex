defmodule Bank.DefiVenues.Morpho.GraphQL do
  @moduledoc """
  Pure GraphQL surface for the Morpho Blue API (#198).

  This module is split out from `Bank.DefiVenues.Morpho.Client`
  so the query-string and the response-parser can be exercised
  by tests without making any HTTP call. The HTTP boundary
  lives in the client.

  ## Schema version

  We pin a `@schema_version` literal that travels with every
  normalized snapshot. Bump it when the *normalized* shape this
  module emits changes in a backwards-incompatible way — the
  upstream Morpho schema evolving alone (e.g. new
  fields appearing in the response) does not require a bump as
  long as we still extract the same internal shape.
  """

  alias Bank.DefiVenues.Morpho.VaultSnapshot

  @schema_version "1"

  @source_name "morpho_blue_graphql"

  @doc """
  The literal GraphQL document string the client posts. Field
  selection mirrors the explicit normalization scope in the
  issue body. We deliberately request `listed` instead of
  `whitelisted` (the live API still returns the deprecated
  field with a warning; we follow the deprecation note).
  """
  @spec vault_by_address_query() :: String.t()
  def vault_by_address_query do
    """
    query VaultByAddress($chainId: Int!, $address: String!) {
      vaultByAddress(chainId: $chainId, address: $address) {
        address
        chain { id network }
        name
        symbol
        listed
        asset { address symbol decimals }
        state {
          apy
          netApy
          totalAssets
          fee
          timelock
          allocation {
            market {
              uniqueKey
              loanAsset { address }
              collateralAsset { address }
              oracleAddress
              irmAddress
              lltv
            }
            supplyCap
            suppliedAssets
            suppliedAssetsUsd
          }
        }
        warnings { type level }
        pendingCaps { market { uniqueKey } cap validAt }
        allocators { address }
        publicAllocatorConfig { address }
      }
    }
    """
  end

  @doc """
  Variables payload for `vault_by_address_query/0`.
  """
  @spec vault_by_address_variables(integer(), String.t()) :: %{required(String.t()) => term()}
  def vault_by_address_variables(chain_id, vault_address)
      when is_integer(chain_id) and is_binary(vault_address) do
    %{
      "chainId" => chain_id,
      "address" => vault_address
    }
  end

  @doc """
  Take the parsed JSON body Morpho returns and project a
  `%VaultSnapshot{}` from it (or a structured error).

  The response is expected to be a map of either:

    * `%{"data" => %{"vaultByAddress" => vault | nil}}` — the
      happy path. `nil` means the requested vault does not
      exist on the requested chain; we surface that as
      `{:error, :vault_not_found}`.
    * `%{"errors" => [...]}` — GraphQL-level errors;
      `{:error, {:graphql_error, [%{message, path}, ...]}}`.

  `fetched_at` is supplied by the caller (the client) so this
  function stays pure and deterministic in tests.
  """
  @spec normalize(map(), integer(), String.t(), DateTime.t(), iodata()) ::
          {:ok, VaultSnapshot.t()}
          | {:error,
             :vault_not_found
             | :malformed_payload
             | {:graphql_error, [map()]}}
  def normalize(body, chain_id, vault_address, fetched_at, raw_payload)
      when is_map(body) and is_integer(chain_id) and is_binary(vault_address) do
    cond do
      Map.has_key?(body, "errors") and is_list(body["errors"]) ->
        {:error, {:graphql_error, prune_graphql_errors(body["errors"])}}

      true ->
        case get_in(body, ["data", "vaultByAddress"]) do
          nil ->
            # The Morpho API returns `nil` (not an error) when the
            # vault does not exist on the requested chain.
            {:error, :vault_not_found}

          vault when is_map(vault) ->
            try do
              snapshot = build_snapshot(vault, chain_id, vault_address, fetched_at, raw_payload)
              {:ok, snapshot}
            rescue
              # Any unexpected shape (a missing `state`, a
              # non-list `allocation`, etc.) surfaces as a
              # structured `:malformed_payload` rather than a
              # crash. Specific issue-acceptance bullet:
              # "missing/renamed fields fail with structured
              # error or degraded metadata, not crashes."
              _ -> {:error, :malformed_payload}
            end
        end
    end
  end

  def normalize(_body, _chain_id, _vault_address, _fetched_at, _raw_payload),
    do: {:error, :malformed_payload}

  @doc """
  Build a stable `payload_hash` for any body. Used by the
  client to round-trip the `source` block in
  `%VaultSnapshot{}`.
  """
  @spec payload_hash(iodata()) :: String.t()
  def payload_hash(raw_payload) do
    :crypto.hash(:sha256, raw_payload) |> Base.encode16(case: :lower)
  end

  @doc "Schema-version sentinel for the `source` block."
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  @doc "Source-name sentinel for the `source` block."
  @spec source_name() :: String.t()
  def source_name, do: @source_name

  # --- internal --------------------------------------------------------

  defp build_snapshot(vault, chain_id, vault_address, fetched_at, raw_payload) do
    chain = vault["chain"] || %{}
    asset = vault["asset"] || %{}
    state_map = vault["state"] || %{}
    allocations_raw = state_map["allocation"] || []

    allocations =
      allocations_raw
      |> List.wrap()
      |> Enum.map(&normalize_allocation/1)

    warnings =
      (vault["warnings"] || [])
      |> List.wrap()
      |> Enum.map(&normalize_warning/1)

    pending_caps =
      (vault["pendingCaps"] || [])
      |> List.wrap()
      |> Enum.map(&normalize_pending_cap/1)

    allocators =
      (vault["allocators"] || [])
      |> List.wrap()
      |> Enum.map(&normalize_allocator/1)

    %VaultSnapshot{
      vault_address: vault["address"] || vault_address,
      name: vault["name"],
      symbol: vault["symbol"],
      chain_id: chain_id,
      network: chain["network"],
      listed: vault["listed"],
      deposit_asset: %{
        address: asset["address"],
        symbol: asset["symbol"],
        decimals: as_int(asset["decimals"])
      },
      state: %{
        apy: as_string(state_map["apy"]),
        net_apy: as_string(state_map["netApy"]),
        total_assets: as_string(state_map["totalAssets"]),
        fee: as_string(state_map["fee"]),
        timelock: as_int(state_map["timelock"])
      },
      allocations: allocations,
      warnings: warnings,
      pending_caps: pending_caps,
      allocators: allocators,
      source: %{
        fetched_at: fetched_at,
        source_name: @source_name,
        source_schema_version: @schema_version,
        # Preserve any upstream-stamped deprecation/warning notes
        # that travel alongside the body. The current
        # `vault.warnings` array is the supported channel — older
        # endpoints used a `Warning:` HTTP header that the issue
        # mentions ("whitelisted ... deprecation note"). We
        # surface that note when we see the deprecated field.
        source_warnings: build_source_warnings(vault),
        payload_hash: payload_hash(raw_payload)
      }
    }
  end

  defp normalize_allocation(%{} = a) do
    market = a["market"] || %{}
    loan = market["loanAsset"] || %{}
    coll = market["collateralAsset"] || %{}

    %{
      market_unique_key: as_string(market["uniqueKey"]),
      loan_asset: as_string(loan["address"]),
      collateral_asset: as_string(coll["address"]),
      oracle: as_string(market["oracleAddress"]),
      irm: as_string(market["irmAddress"]),
      lltv: as_int(market["lltv"]),
      supply_cap: as_string(a["supplyCap"]),
      supplied_assets: as_string(a["suppliedAssets"]),
      supplied_assets_usd: as_string(a["suppliedAssetsUsd"])
    }
  end

  defp normalize_allocation(_), do: nil

  defp normalize_warning(%{} = w) do
    %{
      raw_type: as_string(w["type"]) || "unknown",
      raw_level: as_string(w["level"])
    }
  end

  defp normalize_warning(_), do: nil

  defp normalize_pending_cap(%{} = pc) do
    market = pc["market"] || %{}

    %{
      market_unique_key: as_string(market["uniqueKey"]),
      cap: as_string(pc["cap"]),
      valid_at: as_string(pc["validAt"])
    }
  end

  defp normalize_pending_cap(_), do: nil

  defp normalize_allocator(%{"address" => addr}) when is_binary(addr),
    do: %{address: addr}

  defp normalize_allocator(_), do: %{address: nil}

  defp build_source_warnings(vault) do
    if Map.has_key?(vault, "whitelisted") do
      [
        "morpho deprecation: `whitelisted` is replaced by `listed`; client uses `listed`"
      ]
    else
      []
    end
  end

  defp as_int(nil), do: nil
  defp as_int(int) when is_integer(int), do: int

  defp as_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp as_int(_), do: nil

  defp as_string(nil), do: nil
  defp as_string(s) when is_binary(s), do: s
  defp as_string(n) when is_number(n), do: to_string(n)
  defp as_string(_), do: nil

  # GraphQL error objects can carry verbose `extensions` /
  # `locations` bags. Strip them down to `:message` + `:path`
  # so the structured error never carries surprise content
  # (and never accidentally surfaces an upstream stack trace
  # back into our logs).
  defp prune_graphql_errors(errors) do
    Enum.map(errors, fn
      %{} = err ->
        %{
          message: as_string(err["message"]) || "graphql_error",
          path: err["path"]
        }

      _ ->
        %{message: "graphql_error", path: nil}
    end)
  end
end
