defmodule Bank.Stablecoins.RegistryTest do
  use ExUnit.Case, async: true

  alias Bank.Stablecoins.Registry

  describe "chains/0 and assets/0" do
    test "lists all supported chains" do
      chains = Registry.chains()
      assert "ethereum" in chains
      assert "base" in chains
      assert "arbitrum" in chains
      assert "optimism" in chains
      assert "polygon" in chains
      assert "solana" in chains
      assert length(chains) == 6
    end

    test "lists all supported assets" do
      assets = Registry.assets()
      assert "USDC" in assets
      assert "USDT" in assets
      assert length(assets) == 2
    end
  end

  describe "supported_chain?/1 and supported_asset?/1" do
    test "recognises supported chains" do
      assert Registry.supported_chain?("ethereum")
      assert Registry.supported_chain?("base")
      assert Registry.supported_chain?("solana")
    end

    test "rejects unsupported chains" do
      refute Registry.supported_chain?("bsc")
      refute Registry.supported_chain?("avalanche")
      refute Registry.supported_chain?("Bitcoin")
    end

    test "recognises supported assets" do
      assert Registry.supported_asset?("USDC")
      assert Registry.supported_asset?("USDT")
    end

    test "rejects unsupported assets" do
      refute Registry.supported_asset?("DAI")
      refute Registry.supported_asset?("WETH")
      refute Registry.supported_asset?("usdc")
    end
  end

  describe "resolve/2 — canonical resolution" do
    test "resolves USDC on ethereum" do
      assert {:ok, token} = Registry.resolve("ethereum", "USDC")
      assert token.chain == "ethereum"
      assert token.asset == "USDC"
      assert token.address == "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
      assert token.decimals == 6
      assert token.standard == :erc20
      assert token.status == :active
      assert token.issuer == "Circle"
      assert token.canonical
      assert token.variant == :native
    end

    test "resolves approval-only bridged USDT on base" do
      assert {:ok, token} = Registry.resolve("base", "USDT")
      assert token.chain == "base"
      assert token.asset == "USDT"
      assert token.standard == :erc20
      assert token.issuer == "Tether"
      assert token.status == :approval_only
      refute token.canonical
      assert token.variant == :bridged
      assert token.notes =~ "Bridged USDT"
    end

    test "resolves USDC on solana" do
      assert {:ok, token} = Registry.resolve("solana", "USDC")
      assert token.chain == "solana"
      assert token.address == "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
      assert token.standard == :spl_token
      assert token.decimals == 6
    end

    test "resolves USDT on solana" do
      assert {:ok, token} = Registry.resolve("solana", "USDT")
      assert token.address == "Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB"
      assert token.standard == :spl_token
    end

    test "resolves all chain+asset combinations" do
      for chain <- Registry.chains(), asset <- Registry.assets() do
        assert {:ok, token} = Registry.resolve(chain, asset),
               "expected #{chain}/#{asset} to resolve"

        assert token.chain == chain
        assert token.asset == asset
        assert token.decimals == 6
        assert token.status in [:active, :approval_only]
      end
    end

    test "returns :unsupported_chain for unknown chain" do
      assert {:error, :unsupported_chain} = Registry.resolve("bsc", "USDC")
    end

    test "returns :unsupported_asset for unknown asset" do
      assert {:error, :unsupported_asset} = Registry.resolve("ethereum", "DAI")
    end
  end

  describe "resolve_by_address/2 — token-address resolution" do
    test "resolves EVM token by exact address" do
      assert {:ok, token} =
               Registry.resolve_by_address(
                 "ethereum",
                 "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
               )

      assert token.asset == "USDC"
      assert token.chain == "ethereum"
    end

    test "EVM lookup is case-insensitive" do
      assert {:ok, token} =
               Registry.resolve_by_address(
                 "ethereum",
                 "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
               )

      assert token.asset == "USDC"

      assert {:ok, token2} =
               Registry.resolve_by_address(
                 "ethereum",
                 "0xA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48"
               )

      assert token2.asset == "USDC"
    end

    test "resolves Solana mint by exact address" do
      assert {:ok, token} =
               Registry.resolve_by_address(
                 "solana",
                 "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v"
               )

      assert token.asset == "USDC"
      assert token.standard == :spl_token
    end

    test "Solana mint is case-sensitive" do
      assert {:error, :unknown_token} =
               Registry.resolve_by_address(
                 "solana",
                 "epjfwdd5aufqssqem2qn1xzybapc8g4weggkzwytdt1v"
               )
    end

    test "returns :unsupported_chain for unknown chain" do
      assert {:error, :unsupported_chain} =
               Registry.resolve_by_address("bsc", "0x1234")
    end

    test "returns :unknown_token for unrecognised address" do
      assert {:error, :unknown_token} =
               Registry.resolve_by_address(
                 "ethereum",
                 "0x0000000000000000000000000000000000000000"
               )
    end
  end

  describe "for_chain/1 and for_asset/1" do
    test "lists tokens for a specific chain" do
      tokens = Registry.for_chain("base")
      assert length(tokens) == 2
      assert Enum.all?(tokens, &(&1.chain == "base"))
    end

    test "lists tokens for a specific asset" do
      tokens = Registry.for_asset("USDC")
      assert length(tokens) == 6
      assert Enum.all?(tokens, &(&1.asset == "USDC"))
    end

    test "returns empty for unsupported chain" do
      assert Registry.for_chain("bsc") == []
    end
  end

  describe "all/0" do
    test "returns all registered tokens" do
      all = Registry.all()
      assert length(all) == 12
    end
  end

  describe "token shape" do
    test "every token has required fields" do
      for token <- Registry.all() do
        assert is_binary(token.chain)
        assert is_binary(token.asset)
        assert is_binary(token.address)
        assert is_integer(token.decimals) and token.decimals >= 0
        assert is_binary(token.name)
        assert token.standard in [:erc20, :spl_token]
        assert token.status in [:active, :approval_only, :blocked]
        assert is_binary(token.issuer)
        assert is_boolean(token.canonical)
        assert token.variant in [:native, :bridged]
        assert is_binary(token.notes) and token.notes != ""
      end
    end

    test "canonical-vs-bridged distinction is explicit" do
      native = Enum.filter(Registry.all(), & &1.canonical)
      bridged = Enum.reject(Registry.all(), & &1.canonical)

      assert length(native) == 8
      assert length(bridged) == 4
      assert Enum.all?(native, &(&1.variant == :native))
      assert Enum.all?(bridged, &(&1.variant == :bridged))
      assert Enum.all?(bridged, &(&1.status == :approval_only))
    end

    test "USDC entries are canonical active tokens on every supported chain" do
      assert Registry.for_asset("USDC") |> length() == 6

      assert Enum.all?(Registry.for_asset("USDC"), fn token ->
               token.canonical and token.status == :active and token.issuer == "Circle"
             end)
    end

    test "EVM tokens use :erc20 standard" do
      evm_tokens = Enum.filter(Registry.all(), &(&1.chain != "solana"))
      assert Enum.all?(evm_tokens, &(&1.standard == :erc20))
    end

    test "Solana tokens use :spl_token standard" do
      sol_tokens = Enum.filter(Registry.all(), &(&1.chain == "solana"))
      assert Enum.all?(sol_tokens, &(&1.standard == :spl_token))
    end
  end
end
