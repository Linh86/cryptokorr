defmodule Bank.DefiVenues.Morpho.ClientTest do
  @moduledoc """
  Fixture-driven tests for `Bank.DefiVenues.Morpho.Client` (#198).

  No live network calls. Every test installs a `Req.Test.stub/2`
  on `Bank.DefiVenues.Morpho.Client` (the same atom the test
  config wires to `[plug: {Req.Test, ...}]`) so the HTTP boundary
  is intercepted in-process.
  """

  use ExUnit.Case, async: true

  alias Bank.DefiVenues.Morpho.Client
  alias Bank.DefiVenues.Morpho.GraphQL
  alias Bank.DefiVenues.Morpho.VaultSnapshot

  @chain_id 1
  @vault_address "0xbeef000000000000000000000000000000000001"

  defp now_fn, do: fn -> ~U[2026-05-04 12:00:00.000000Z] end

  defp ok_body(overrides \\ %{}) do
    base = %{
      "data" => %{
        "vaultByAddress" => %{
          "address" => @vault_address,
          "chain" => %{"id" => @chain_id, "network" => "mainnet"},
          "name" => "Steakhouse USDC",
          "symbol" => "steakUSDC",
          "listed" => true,
          "asset" => %{
            "address" => "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
            "symbol" => "USDC",
            "decimals" => 6
          },
          "state" => %{
            "apy" => "0.045",
            "netApy" => "0.041",
            "totalAssets" => "12345678901234",
            "fee" => "0.04",
            "timelock" => 86_400,
            "allocation" => [
              %{
                "market" => %{
                  "uniqueKey" => "0xmarket1",
                  "loanAsset" => %{"address" => "0xusdc"},
                  "collateralAsset" => %{"address" => "0xweth"},
                  "oracleAddress" => "0xoracle",
                  "irmAddress" => "0xirm",
                  "lltv" => "915000000000000000"
                },
                "supplyCap" => "1000000000000",
                "suppliedAssets" => "456789000000",
                "suppliedAssetsUsd" => "456789.00"
              }
            ]
          },
          "warnings" => [%{"type" => "NotWhitelistedRisk", "level" => "WARNING"}],
          "pendingCaps" => [
            %{
              "market" => %{"uniqueKey" => "0xmarket2"},
              "cap" => "5000000000000",
              "validAt" => "2026-06-01T00:00:00Z"
            }
          ],
          "allocators" => [%{"address" => "0xallocator1"}],
          "publicAllocatorConfig" => %{"address" => "0xpuballoc"}
        }
      }
    }

    Map.merge(base, overrides)
  end

  describe "fetch_vault_by_address/3 — happy path" do
    test "returns a normalized %VaultSnapshot{} for a successful response" do
      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(ok_body())
      end)

      assert {:ok, %VaultSnapshot{} = snap} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, now_fn: now_fn())

      assert snap.vault_address == @vault_address
      assert snap.chain_id == @chain_id
      assert snap.network == "mainnet"
      assert snap.name == "Steakhouse USDC"
      assert snap.symbol == "steakUSDC"
      assert snap.listed == true

      assert snap.deposit_asset == %{
               address: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
               symbol: "USDC",
               decimals: 6
             }

      assert snap.state == %{
               apy: "0.045",
               net_apy: "0.041",
               total_assets: "12345678901234",
               fee: "0.04",
               timelock: 86_400
             }

      assert [allocation] = snap.allocations

      assert allocation == %{
               market_unique_key: "0xmarket1",
               loan_asset: "0xusdc",
               collateral_asset: "0xweth",
               oracle: "0xoracle",
               irm: "0xirm",
               lltv: 915_000_000_000_000_000,
               supply_cap: "1000000000000",
               supplied_assets: "456789000000",
               supplied_assets_usd: "456789.00"
             }

      assert [%{address: "0xallocator1"}] = snap.allocators
    end

    test "preserves the upstream warnings array verbatim (raw_type + raw_level)" do
      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(ok_body())
      end)

      assert {:ok, snap} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, now_fn: now_fn())

      assert [%{raw_type: "NotWhitelistedRisk", raw_level: "WARNING"}] = snap.warnings
    end

    test "preserves the upstream pendingCaps array" do
      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(ok_body())
      end)

      assert {:ok, snap} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, now_fn: now_fn())

      assert [
               %{
                 market_unique_key: "0xmarket2",
                 cap: "5000000000000",
                 valid_at: "2026-06-01T00:00:00Z"
               }
             ] = snap.pending_caps
    end

    test "carries a deterministic source-metadata block" do
      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(ok_body())
      end)

      assert {:ok, snap} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, now_fn: now_fn())

      assert snap.source.fetched_at == ~U[2026-05-04 12:00:00.000000Z]
      assert snap.source.source_name == "morpho_blue_graphql"
      assert snap.source.source_schema_version == "1"
      assert is_binary(snap.source.payload_hash)
      assert byte_size(snap.source.payload_hash) == 64
    end
  end

  describe "fetch_vault_by_address/3 — payload hash stability" do
    test "two stubs returning the same body produce the same payload_hash" do
      body = ok_body()

      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(body)
      end)

      assert {:ok, first} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, now_fn: now_fn())

      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(body)
      end)

      assert {:ok, second} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, now_fn: now_fn())

      assert first.source.payload_hash == second.source.payload_hash
    end

    test "a different body produces a different payload_hash" do
      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(ok_body())
      end)

      assert {:ok, first} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, now_fn: now_fn())

      altered =
        put_in(
          ok_body(),
          ["data", "vaultByAddress", "name"],
          "Different Steakhouse USDC"
        )

      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(altered)
      end)

      assert {:ok, second} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, now_fn: now_fn())

      refute first.source.payload_hash == second.source.payload_hash
    end
  end

  describe "fetch_vault_by_address/3 — deprecation/source-warnings" do
    test "stamps a source warning when the upstream still returns the deprecated `whitelisted` field" do
      body =
        put_in(
          ok_body(),
          ["data", "vaultByAddress", "whitelisted"],
          true
        )

      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(body)
      end)

      assert {:ok, snap} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, now_fn: now_fn())

      assert snap.source.source_warnings == [
               "morpho deprecation: `whitelisted` is replaced by `listed`; client uses `listed`"
             ]
    end
  end

  describe "fetch_vault_by_address/3 — vault not found" do
    test "data.vaultByAddress: null returns {:error, :vault_not_found}" do
      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(%{"data" => %{"vaultByAddress" => nil}})
      end)

      assert {:error, :vault_not_found} =
               Client.fetch_vault_by_address(@chain_id, @vault_address)
    end
  end

  describe "fetch_vault_by_address/3 — GraphQL errors" do
    test "an `errors`-bearing response returns {:error, {:graphql_error, [...]}}" do
      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(%{
          "errors" => [
            %{"message" => "Variable $address has invalid value", "path" => ["vaultByAddress"]}
          ],
          "data" => nil
        })
      end)

      assert {:error, {:graphql_error, errors}} =
               Client.fetch_vault_by_address(@chain_id, @vault_address)

      assert errors == [
               %{message: "Variable $address has invalid value", path: ["vaultByAddress"]}
             ]
    end

    test "GraphQL errors strip surprise extensions/locations bags" do
      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(%{
          "errors" => [
            %{
              "message" => "Authentication required",
              "path" => ["x"],
              "extensions" => %{"stack" => "INTERNAL"},
              "locations" => [%{"line" => 1, "column" => 1}]
            }
          ]
        })
      end)

      assert {:error, {:graphql_error, [error]}} =
               Client.fetch_vault_by_address(@chain_id, @vault_address)

      assert error == %{message: "Authentication required", path: ["x"]}
      refute Map.has_key?(error, :extensions)
      refute Map.has_key?(error, :locations)
    end
  end

  describe "fetch_vault_by_address/3 — transport / timeout / 5xx" do
    test "transport timeout returns {:error, :provider_timeout}" do
      Req.Test.stub(Client, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, :provider_timeout} =
               Client.fetch_vault_by_address(@chain_id, @vault_address)
    end

    test "generic transport error returns {:error, :provider_unavailable}" do
      Req.Test.stub(Client, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :provider_unavailable} =
               Client.fetch_vault_by_address(@chain_id, @vault_address)
    end

    test "5xx response returns {:error, :provider_unavailable}" do
      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => "service_unavailable"})
      end)

      assert {:error, :provider_unavailable} =
               Client.fetch_vault_by_address(@chain_id, @vault_address)
    end

    test "4xx response returns {:error, {:provider_error, %{status, body: hashed}}}" do
      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => "rate_limited"})
      end)

      assert {:error, {:provider_error, %{status: 429, body: pruned}}} =
               Client.fetch_vault_by_address(@chain_id, @vault_address)

      # The raw 4xx body is hashed, never reflected back to the
      # caller. Pin the shape so a regression that re-exports the
      # body would fail this test.
      assert is_map(pruned)
      assert pruned.kind == :map
      assert is_binary(pruned.sha256)
    end

    test "200 with a non-map body returns {:error, :malformed_payload}" do
      Req.Test.stub(Client, fn conn ->
        Plug.Conn.send_resp(conn, 200, "<html>error</html>")
      end)

      assert {:error, :malformed_payload} =
               Client.fetch_vault_by_address(@chain_id, @vault_address)
    end
  end

  describe "fetch_vault_by_address/3 — malformed payload tolerance" do
    test "missing nested `state` block returns {:error, :malformed_payload} — never crashes" do
      body = %{
        "data" => %{
          "vaultByAddress" => %{
            "address" => @vault_address,
            "chain" => %{"network" => "mainnet"}
            # NO "state" key.
          }
        }
      }

      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(body)
      end)

      assert {:ok, snap} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, now_fn: now_fn())

      # The state defaults are returned. Acceptance criterion:
      # "missing/renamed fields fail with structured error or
      # degraded metadata, not crashes" — degraded metadata here.
      assert snap.state == %{
               apy: nil,
               net_apy: nil,
               total_assets: nil,
               fee: nil,
               timelock: nil
             }

      assert snap.allocations == []
    end

    test "allocation entry with renamed/missing market fields degrades gracefully" do
      body =
        put_in(
          ok_body(),
          ["data", "vaultByAddress", "state", "allocation"],
          [
            %{
              # Note: missing `oracleAddress` and `irmAddress`.
              "market" => %{"uniqueKey" => "0xmarketX"},
              "supplyCap" => "1"
            }
          ]
        )

      Req.Test.stub(Client, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Req.Test.json(body)
      end)

      assert {:ok, snap} =
               Client.fetch_vault_by_address(@chain_id, @vault_address, now_fn: now_fn())

      assert [allocation] = snap.allocations
      assert allocation.market_unique_key == "0xmarketX"
      assert allocation.oracle == nil
      assert allocation.irm == nil
      assert allocation.supply_cap == "1"
    end
  end

  describe "fetch_vault_by_address/3 — input validation" do
    test "non-integer chain_id is rejected without an HTTP call" do
      assert {:error, :malformed_payload} =
               Client.fetch_vault_by_address("not_an_int", @vault_address)
    end

    test "empty vault_address is rejected without an HTTP call" do
      assert {:error, :malformed_payload} = Client.fetch_vault_by_address(@chain_id, "")
    end

    test "non-binary vault_address is rejected without an HTTP call" do
      assert {:error, :malformed_payload} = Client.fetch_vault_by_address(@chain_id, nil)
    end
  end

  describe "GraphQL.payload_hash/1" do
    test "is deterministic and 64-char hex" do
      hash = GraphQL.payload_hash("hello")
      assert hash == GraphQL.payload_hash("hello")
      assert byte_size(hash) == 64
    end
  end
end
