defmodule Bank.DefiVenues.Morpho.OnChainFactsTest do
  @moduledoc """
  Tests for `Bank.DefiVenues.Morpho.OnChainFacts` (#200). No live
  RPC. Every test injects an `:rpc_fn` that pattern-matches the
  ERC-4626 selector and returns a canned hex result.
  """

  use ExUnit.Case, async: true

  alias Bank.DefiVenues.Morpho.OnChainFacts
  alias Bank.DefiVenues.Morpho.OnChainVaultFacts

  @chain_id 84_532
  @vault "0x8eb67a509616cd6a7c1b3c8c21d48ff57df3d458"
  @asset "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
  @account "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  describe "read_facts/3 — happy path (#200)" do
    test "asset() + totalAssets() are returned and decoded" do
      rpc_fn = canned_rpc(%{asset: @asset, total_assets: 12_345_678_900_000})

      assert {:ok, %OnChainVaultFacts{} = facts} =
               OnChainFacts.read_facts(@chain_id, @vault,
                 rpc_fn: rpc_fn,
                 fetched_at: ~U[2026-04-29 12:00:00.000000Z]
               )

      assert facts.chain_id == @chain_id
      assert facts.vault_address == String.downcase(@vault)
      assert facts.asset == @asset
      assert facts.total_assets == "12345678900000"
      assert facts.fetched_at == ~U[2026-04-29 12:00:00.000000Z]
      assert facts.account == nil
      assert facts.max_deposit == nil
      assert facts.max_withdraw == nil
    end

    test "with :account, max_deposit + max_withdraw are read" do
      rpc_fn =
        canned_rpc(%{
          asset: @asset,
          total_assets: 1_000,
          max_deposit: 500,
          max_withdraw: 250
        })

      assert {:ok, facts} =
               OnChainFacts.read_facts(@chain_id, @vault,
                 rpc_fn: rpc_fn,
                 account: @account
               )

      assert facts.account == @account
      assert facts.max_deposit == "500"
      assert facts.max_withdraw == "250"
    end

    test "with :preview_shares, previewRedeem(shares) is read" do
      rpc_fn =
        canned_rpc(%{
          asset: @asset,
          total_assets: 1_000,
          preview_redeem: 99
        })

      assert {:ok, facts} =
               OnChainFacts.read_facts(@chain_id, @vault,
                 rpc_fn: rpc_fn,
                 preview_shares: 100
               )

      assert facts.preview_redeem == "99"
    end

    test "vault_address is lowercased" do
      rpc_fn = canned_rpc(%{asset: @asset, total_assets: 1})
      mixed = "0x8EB67A509616CD6A7C1B3C8C21D48FF57DF3D458"

      assert {:ok, facts} =
               OnChainFacts.read_facts(@chain_id, mixed, rpc_fn: rpc_fn)

      assert facts.vault_address == String.downcase(mixed)
    end
  end

  describe "read_facts/3 — chain id gating (#200)" do
    test "unsupported chain returns :unsupported_chain BEFORE any RPC call" do
      rpc_fn = fn _ -> raise "rpc must not be called" end

      assert {:error, :unsupported_chain} =
               OnChainFacts.read_facts(1, @vault, rpc_fn: rpc_fn)
    end

    test "supported_chains/0 stable list" do
      assert OnChainFacts.supported_chains() == %{84_532 => "base-sepolia"}
    end
  end

  describe "read_facts/3 — asset mismatch fails closed (#200)" do
    test "expected_asset matches on-chain asset → ok" do
      rpc_fn = canned_rpc(%{asset: @asset, total_assets: 1})

      assert {:ok, _facts} =
               OnChainFacts.read_facts(@chain_id, @vault,
                 rpc_fn: rpc_fn,
                 expected_asset: @asset
               )
    end

    test "expected_asset mismatch → :asset_mismatch" do
      other = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      rpc_fn = canned_rpc(%{asset: @asset, total_assets: 1})

      assert {:error, :asset_mismatch} =
               OnChainFacts.read_facts(@chain_id, @vault,
                 rpc_fn: rpc_fn,
                 expected_asset: other
               )
    end

    test "case-insensitive comparison" do
      checksum = "0xA0B86991C6218B36C1D19D4A2E9Eb0CE3606EB48"
      rpc_fn = canned_rpc(%{asset: String.downcase(checksum), total_assets: 1})

      assert {:ok, _} =
               OnChainFacts.read_facts(@chain_id, @vault,
                 rpc_fn: rpc_fn,
                 expected_asset: checksum
               )
    end
  end

  describe "read_facts/3 — RPC failures (#200)" do
    test "rpc_unavailable surfaces as :rpc_unavailable" do
      rpc_fn = fn _ -> {:error, "rpc_unavailable"} end

      assert {:error, :rpc_unavailable} =
               OnChainFacts.read_facts(@chain_id, @vault, rpc_fn: rpc_fn)
    end

    test "rpc_not_configured surfaces as :rpc_not_configured" do
      rpc_fn = fn _ -> {:error, "rpc_not_configured"} end

      assert {:error, :rpc_not_configured} =
               OnChainFacts.read_facts(@chain_id, @vault, rpc_fn: rpc_fn)
    end

    test "timeout surfaces as :timeout" do
      rpc_fn = fn _ -> {:error, "timeout"} end

      assert {:error, :timeout} =
               OnChainFacts.read_facts(@chain_id, @vault, rpc_fn: rpc_fn)
    end

    test "rpc_error_5xx surfaces as :rpc_error_5xx" do
      rpc_fn = fn _ -> {:error, "rpc_error_5xx"} end

      assert {:error, :rpc_error_5xx} =
               OnChainFacts.read_facts(@chain_id, @vault, rpc_fn: rpc_fn)
    end

    test "unknown error label collapses to :rpc_unavailable (no leak)" do
      rpc_fn = fn _ -> {:error, "https://[email protected] sk_live_AAAA"} end

      assert {:error, :rpc_unavailable} =
               OnChainFacts.read_facts(@chain_id, @vault, rpc_fn: rpc_fn)
    end

    test "non-binary response surfaces as :invalid_response" do
      rpc_fn = fn _ -> {:ok, %{"unexpected" => "shape"}} end

      assert {:error, :invalid_response} =
               OnChainFacts.read_facts(@chain_id, @vault, rpc_fn: rpc_fn)
    end

    test "malformed asset hex (wrong size) surfaces as :invalid_response" do
      rpc_fn = fn
        %{method: "eth_call", params: [%{"data" => "0x38d52e0f"}, "latest"]} ->
          {:ok, "0xdeadbeef"}

        _ ->
          {:ok, encode_uint256(0)}
      end

      assert {:error, :invalid_response} =
               OnChainFacts.read_facts(@chain_id, @vault, rpc_fn: rpc_fn)
    end
  end

  describe "read_facts/3 — input validation" do
    test "non-integer chain_id returns :invalid_args" do
      assert {:error, :invalid_args} =
               OnChainFacts.read_facts("84532", @vault, rpc_fn: fn _ -> {:ok, ""} end)
    end

    test "nil vault_address returns :invalid_args" do
      assert {:error, :invalid_args} =
               OnChainFacts.read_facts(@chain_id, nil, rpc_fn: fn _ -> {:ok, ""} end)
    end

    test "empty vault_address returns :invalid_args" do
      assert {:error, :invalid_args} =
               OnChainFacts.read_facts(@chain_id, "", rpc_fn: fn _ -> {:ok, ""} end)
    end

    test "non-hex vault_address returns :invalid_args" do
      assert {:error, :invalid_args} =
               OnChainFacts.read_facts(@chain_id, "not-an-address", rpc_fn: fn _ -> {:ok, ""} end)
    end

    test "wrong-length vault_address returns :invalid_args" do
      assert {:error, :invalid_args} =
               OnChainFacts.read_facts(@chain_id, "0xabcd", rpc_fn: fn _ -> {:ok, ""} end)
    end
  end

  describe "read_facts/3 — optional method graceful fallback" do
    test "maxDeposit revert (4xx) surfaces as :account_unavailable warning, not failure" do
      rpc_fn = fn
        %{method: "eth_call", params: [%{"data" => "0x38d52e0f"}, "latest"]} ->
          {:ok, encode_address(@asset)}

        %{method: "eth_call", params: [%{"data" => "0x01e1d114"}, "latest"]} ->
          {:ok, encode_uint256(1_000)}

        %{method: "eth_call", params: [%{"data" => "0x402d267d" <> _}, "latest"]} ->
          {:error, "rpc_error_4xx"}

        %{method: "eth_call", params: [%{"data" => "0xce96cb77" <> _}, "latest"]} ->
          {:ok, encode_uint256(250)}
      end

      assert {:ok, facts} =
               OnChainFacts.read_facts(@chain_id, @vault,
                 rpc_fn: rpc_fn,
                 account: @account
               )

      assert facts.max_deposit == nil
      assert facts.max_withdraw == "250"

      assert {:account_unavailable, :reverted} in facts.source_warnings
    end

    test "without :account, max_deposit / max_withdraw are flagged as :missing_field" do
      rpc_fn = canned_rpc(%{asset: @asset, total_assets: 1})

      assert {:ok, facts} =
               OnChainFacts.read_facts(@chain_id, @vault, rpc_fn: rpc_fn)

      assert {:missing_field, :max_deposit} in facts.source_warnings
      assert {:missing_field, :max_withdraw} in facts.source_warnings
      assert {:missing_field, :preview_redeem} in facts.source_warnings
    end
  end

  describe "read_facts/3 — eth_call shape (#200)" do
    test "issues eth_call to the vault address with the correct selector" do
      parent = self()

      rpc_fn = fn
        %{method: "eth_call", params: [%{"to" => _to, "data" => data}, "latest"]} = req ->
          send(parent, {:rpc, req})

          cond do
            data == "0x38d52e0f" ->
              {:ok, encode_address(@asset)}

            data == "0x01e1d114" ->
              {:ok, encode_uint256(1_000)}
          end
      end

      {:ok, _} = OnChainFacts.read_facts(@chain_id, @vault, rpc_fn: rpc_fn)

      assert_receive {:rpc, %{params: [%{"to" => to, "data" => "0x38d52e0f"}, "latest"]}}
      assert to == String.downcase(@vault)
      assert_receive {:rpc, %{params: [%{"to" => _, "data" => "0x01e1d114"}, "latest"]}}
    end

    test "selector + address arg encoding for maxDeposit" do
      parent = self()

      rpc_fn = fn
        %{method: "eth_call", params: [%{"data" => data}, "latest"]} = _req ->
          send(parent, {:data, data})

          cond do
            data == "0x38d52e0f" -> {:ok, encode_address(@asset)}
            data == "0x01e1d114" -> {:ok, encode_uint256(1_000)}
            String.starts_with?(data, "0x402d267d") -> {:ok, encode_uint256(500)}
            String.starts_with?(data, "0xce96cb77") -> {:ok, encode_uint256(250)}
          end
      end

      {:ok, _} =
        OnChainFacts.read_facts(@chain_id, @vault, rpc_fn: rpc_fn, account: @account)

      account_hex = String.replace(@account, "0x", "")

      expected_max_deposit_data =
        "0x402d267d" <> "000000000000000000000000" <> account_hex

      assert_received {:data, ^expected_max_deposit_data}
    end
  end

  # --- helpers ------------------------------------------------------

  # Builds an `:rpc_fn` that responds to the five allowed
  # ERC-4626 read selectors with the values supplied in `vals`.
  # Missing keys fall through and return :error so we exercise
  # the optional-field paths.
  defp canned_rpc(vals) do
    fn
      %{method: "eth_call", params: [%{"data" => "0x38d52e0f"}, "latest"]} ->
        case Map.get(vals, :asset) do
          nil -> {:error, "rpc_unavailable"}
          addr -> {:ok, encode_address(addr)}
        end

      %{method: "eth_call", params: [%{"data" => "0x01e1d114"}, "latest"]} ->
        case Map.get(vals, :total_assets) do
          nil -> {:error, "rpc_unavailable"}
          n -> {:ok, encode_uint256(n)}
        end

      %{method: "eth_call", params: [%{"data" => "0x402d267d" <> _}, "latest"]} ->
        case Map.get(vals, :max_deposit) do
          nil -> {:error, "rpc_unavailable"}
          n -> {:ok, encode_uint256(n)}
        end

      %{method: "eth_call", params: [%{"data" => "0xce96cb77" <> _}, "latest"]} ->
        case Map.get(vals, :max_withdraw) do
          nil -> {:error, "rpc_unavailable"}
          n -> {:ok, encode_uint256(n)}
        end

      %{method: "eth_call", params: [%{"data" => "0x4cdad506" <> _}, "latest"]} ->
        case Map.get(vals, :preview_redeem) do
          nil -> {:error, "rpc_unavailable"}
          n -> {:ok, encode_uint256(n)}
        end
    end
  end

  defp encode_address("0x" <> hex) when byte_size(hex) == 40 do
    "0x" <> String.duplicate("0", 24) <> String.downcase(hex)
  end

  defp encode_uint256(int) when is_integer(int) and int >= 0 do
    "0x" <> (int |> Integer.to_string(16) |> String.pad_leading(64, "0") |> String.downcase())
  end
end
