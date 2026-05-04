defmodule Bank.DefiVenues.Morpho.ClientTest do
  @moduledoc """
  Tests for `Bank.DefiVenues.Morpho.Client` (#198).

  No live network. Every test plugs a canned response into Req
  via `:req_options` `[plug: ...]`.
  """

  use ExUnit.Case, async: true

  alias Bank.DefiVenues.Morpho.Client
  alias Bank.DefiVenues.Morpho.GraphQL
  alias Bank.DefiVenues.Morpho.VaultSnapshot

  @chain_id 1
  @vault_address "0x8eb67a509616cd6a7c1b3c8c21d48ff57df3d458"

  describe "fetch_vault_by_address/3 — happy path (#198)" do
    test "successful response normalises into a VaultSnapshot" do
      plug = canned_plug(status: 200, body: wrap(vault_fixture()))

      assert {:ok, %VaultSnapshot{} = snap} =
               Client.fetch_vault_by_address(@chain_id, @vault_address,
                 req_options: [plug: plug],
                 fetched_at: ~U[2026-04-29 10:00:00.000000Z]
               )

      # vault identity
      assert snap.chain_id == 1
      assert snap.chain_network == "ethereum"
      assert snap.address == String.downcase(@vault_address)
      assert snap.name == "Steakhouse USDC"
      assert snap.symbol == "steakUSDC"
      assert snap.listed == true

      # deposit asset
      assert snap.asset_address == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
      assert snap.asset_symbol == "USDC"
      assert snap.asset_decimals == 6

      # vault state
      assert snap.apy == 0.058
      assert snap.net_apy == 0.052
      assert snap.total_assets == "12345678901234"
      assert snap.fee == "0.05"
      assert snap.timelock == 86_400

      # allocations preserved with raw stringified numerics
      [alloc | _] = snap.allocations
      assert alloc.market_unique_key =~ "0x"
      assert alloc.loan_asset_symbol == "USDC"
      assert alloc.collateral_asset_symbol == "wstETH"
      assert alloc.lltv == "0.86"
      assert alloc.supply_cap == "10000000000000"
      assert alloc.supply_assets == "4200000000000"
      assert alloc.supply_assets_usd == "4200000.00"
      assert alloc.oracle_address =~ "0x"
      assert alloc.irm_address =~ "0x"

      # pending caps + allocators
      [pc | _] = snap.pending_caps
      assert pc.market_unique_key =~ "0x"
      assert pc.supply_cap == "20000000000000"
      assert pc.valid_at == "1714400000"

      assert snap.allocators == ["0xaaaa000000000000000000000000000000000000"]

      assert snap.public_allocator_config == %{fee: "0", accrued_fee: "0"}

      # source envelope
      source = snap.source
      assert source.fetched_at == ~U[2026-04-29 10:00:00.000000Z]
      assert source.source_name == "morpho_api"
      assert source.source_schema_version == GraphQL.source_schema_version()
      assert is_binary(source.payload_hash)
      assert byte_size(source.payload_hash) == 64
      assert Regex.match?(~r/\A[0-9a-f]+\z/, source.payload_hash)
    end

    test "warnings array is preserved verbatim with type + level" do
      plug =
        canned_plug(
          status: 200,
          body: wrap(vault_fixture(extra_warnings: [%{"type" => "redirect", "level" => "RED"}]))
        )

      assert {:ok, snap} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, req_options: [plug: plug])

      assert Enum.any?(snap.warnings, &(&1.type == "redirect" and &1.level == "RED"))
      # The same warnings are also surfaced through source.warnings
      # so a downstream reader doesn't have to re-walk the snapshot
      # struct.
      assert snap.warnings == snap.source.warnings
    end

    test "deprecated `whitelisted` field surfaces as a field_warning" do
      plug = canned_plug(status: 200, body: wrap(vault_fixture(whitelisted: true)))

      assert {:ok, snap} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, req_options: [plug: plug])

      assert {:deprecated_field, "whitelisted"} in snap.source.field_warnings
    end
  end

  describe "fetch_vault_by_address/3 — payload hash stability" do
    test "same payload produces the same hash across calls" do
      payload = vault_fixture()

      hash1 = single_call_hash(payload)
      hash2 = single_call_hash(payload)

      assert hash1 == hash2
      assert byte_size(hash1) == 64
    end

    test "differing payloads produce differing hashes" do
      hash_a = single_call_hash(vault_fixture(name: "Vault A"))
      hash_b = single_call_hash(vault_fixture(name: "Vault B"))

      refute hash_a == hash_b
    end
  end

  describe "fetch_vault_by_address/3 — error handling" do
    test "GraphQL `errors` array returns :graphql_error" do
      plug =
        canned_plug(
          status: 200,
          body: %{
            "errors" => [%{"message" => "vault not found"}],
            "data" => nil
          }
        )

      assert {:error, :graphql_error} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, req_options: [plug: plug])
    end

    test "missing data.vaultByAddress returns :malformed_response" do
      plug =
        canned_plug(
          status: 200,
          body: %{"data" => %{"vaultByAddress" => nil}}
        )

      assert {:error, :malformed_response} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, req_options: [plug: plug])
    end

    test "missing top-level data returns :malformed_response" do
      plug = canned_plug(status: 200, body: %{"unrelated" => "shape"})

      assert {:error, :malformed_response} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, req_options: [plug: plug])
    end

    test "missing required `address` field returns :malformed_response" do
      vault = vault_fixture() |> drop_in("address")

      plug = canned_plug(status: 200, body: %{"data" => %{"vaultByAddress" => vault}})

      assert {:error, :malformed_response} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, req_options: [plug: plug])
    end

    test "missing optional `state.allocation` does not crash, marks field_warning" do
      vault =
        vault_fixture()
        |> update_in(["state"], fn s -> Map.delete(s, "allocation") end)

      plug = canned_plug(status: 200, body: %{"data" => %{"vaultByAddress" => vault}})

      assert {:ok, snap} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, req_options: [plug: plug])

      assert snap.allocations == []
      assert {:missing_field, "state.allocation"} in snap.source.field_warnings
    end

    test "HTTP 4xx returns :http_4xx" do
      plug = canned_plug(status: 404, body: %{"error" => "not found"})

      assert {:error, :http_4xx} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, req_options: [plug: plug])
    end

    test "HTTP 5xx returns :http_5xx" do
      plug = canned_plug(status: 502, body: %{"error" => "bad gateway"})

      assert {:error, :http_5xx} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, req_options: [plug: plug])
    end

    test "transport timeout returns :timeout" do
      plug = fn conn -> Req.Test.transport_error(conn, :timeout) end

      assert {:error, :timeout} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, req_options: [plug: plug])
    end

    test "transport econnrefused returns :unavailable" do
      plug = fn conn -> Req.Test.transport_error(conn, :econnrefused) end

      assert {:error, :unavailable} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, req_options: [plug: plug])
    end
  end

  describe "fetch_vault_by_address/3 — input validation" do
    test "non-integer chain_id returns :invalid_args" do
      assert {:error, :invalid_args} =
               Client.fetch_vault_by_address("ethereum", @vault_address)
    end

    test "non-binary address returns :invalid_args" do
      assert {:error, :invalid_args} = Client.fetch_vault_by_address(@chain_id, nil)
    end

    test "empty address returns :invalid_args" do
      assert {:error, :invalid_args} = Client.fetch_vault_by_address(@chain_id, "")
    end
  end

  describe "fetch_vault_by_address/3 — secret hygiene" do
    test "the request body sent to Req carries the GraphQL query and variables only" do
      parent = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:request_body, body})

        ok_response(conn, vault_fixture())
      end

      _ =
        Client.fetch_vault_by_address(@chain_id, @vault_address, req_options: [plug: plug])

      assert_received {:request_body, raw}, "expected the plug to capture a request body"
      decoded = Jason.decode!(raw)

      # The body is exactly the GraphQL.vault_by_address_body shape
      # — no extra fields, no Authorization, no token.
      assert is_binary(decoded["query"])
      assert decoded["variables"] == %{"chainId" => @chain_id, "address" => @vault_address}
      refute Map.has_key?(decoded, "authorization")
      refute Map.has_key?(decoded, "Authorization")
      refute decoded["query"] =~ "Bearer"
      refute decoded["query"] =~ "sk_live_"
    end
  end

  # --- helpers ----------------------------------------------------------

  defp single_call_hash(vault) do
    plug = canned_plug(status: 200, body: wrap(vault))

    {:ok, snap} =
      Client.fetch_vault_by_address(@chain_id, @vault_address, req_options: [plug: plug])

    snap.source.payload_hash
  end

  defp wrap(vault), do: %{"data" => %{"vaultByAddress" => vault}}

  defp canned_plug(opts) do
    status = Keyword.fetch!(opts, :status)
    body = Keyword.fetch!(opts, :body)

    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  defp ok_response(conn, vault) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(%{"data" => %{"vaultByAddress" => vault}}))
  end

  # `vault_fixture/1` opts:
  #   * `:extra_warnings` — list of additional warning maps to
  #     append to the default warning set.
  #   * `:whitelisted` — when truthy, includes a deprecated
  #     `whitelisted` field in the response.
  #   * `:name` — override the vault name (used by hash stability
  #     tests to produce a differing-but-valid payload).
  defp vault_fixture(opts \\ []) do
    extra_warnings = Keyword.get(opts, :extra_warnings, [])
    whitelisted = Keyword.get(opts, :whitelisted, nil)
    name = Keyword.get(opts, :name, "Steakhouse USDC")

    base = %{
      "address" => @vault_address,
      "name" => name,
      "symbol" => "steakUSDC",
      "listed" => true,
      "chain" => %{"id" => 1, "network" => "ethereum"},
      "asset" => %{
        "address" => "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        "symbol" => "USDC",
        "decimals" => 6
      },
      "state" => %{
        "apy" => 0.058,
        "netApy" => 0.052,
        "totalAssets" => "12345678901234",
        "fee" => "0.05",
        "timelock" => 86_400,
        "allocation" => [
          %{
            "market" => %{
              "uniqueKey" => "0x1111111111111111111111111111111111111111111111111111111111111111",
              "loanAsset" => %{
                "address" => "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
                "symbol" => "USDC",
                "decimals" => 6
              },
              "collateralAsset" => %{
                "address" => "0x7f39c581f595b53c5cb19bd0b3f8da6c935e2ca0",
                "symbol" => "wstETH",
                "decimals" => 18
              },
              "oracleAddress" => "0xoracle0000000000000000000000000000000001",
              "irmAddress" => "0xirm00000000000000000000000000000000000001",
              "lltv" => "0.86"
            },
            "supplyCap" => "10000000000000",
            "supplyAssets" => "4200000000000",
            "supplyAssetsUsd" => "4200000.00"
          }
        ]
      },
      "warnings" =>
        [
          %{"type" => "vault_listed", "level" => "INFO"}
        ] ++ extra_warnings,
      "pendingCaps" => [
        %{
          "market" => %{
            "uniqueKey" => "0x2222222222222222222222222222222222222222222222222222222222222222"
          },
          "supplyCap" => "20000000000000",
          "validAt" => "1714400000"
        }
      ],
      "allocators" => [%{"address" => "0xaaaa000000000000000000000000000000000000"}],
      "publicAllocatorConfig" => %{"fee" => "0", "accruedFee" => "0"},
      "historicalState" => %{
        "apy" => [%{"x" => 1, "y" => 0.05}],
        "netApy" => [%{"x" => 1, "y" => 0.045}]
      }
    }

    if whitelisted, do: Map.put(base, "whitelisted", true), else: base
  end

  defp drop_in(map, key), do: Map.delete(map, key)
end
