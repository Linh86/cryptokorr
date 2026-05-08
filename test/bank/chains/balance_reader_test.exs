defmodule Bank.Chains.BalanceReaderTest do
  use ExUnit.Case, async: true

  alias Bank.Chains.BalanceReader

  @account "0x7a2f3c8e9d1a5b4f6c2e8d9a1b3f5c7e8d2a4d31"
  @rpc_url "http://test-rpc.example.com/"

  setup do
    prev = Application.get_env(:bank, BalanceReader, [])

    Application.put_env(:bank, BalanceReader, Keyword.put(prev, :rpc_url, @rpc_url))
    on_exit(fn -> Application.put_env(:bank, BalanceReader, prev) end)
    :ok
  end

  describe "happy path" do
    test "decodes a non-zero uint256 hex result and scales by 6 decimals" do
      # 124.50 USDC = 124_500_000 raw (6 decimals) = 0x76BB820
      raw_hex = "0x" <> String.pad_leading("76bb820", 64, "0")

      rpc_fn = fn _url, payload ->
        # Verify the wire shape: balanceOf(address) selector + padded address
        params = payload["params"]
        [%{"to" => to, "data" => data}, "latest"] = params
        # Token contract: USDC Base Sepolia
        assert to == "0x036cbd53842c5426634e7929541ec2318f3dcf7e"
        # Selector + 64-char left-padded account hex
        assert String.starts_with?(data, "0x70a08231")
        assert String.length(data) == 2 + 8 + 64
        {:ok, raw_hex}
      end

      assert {:ok, balance} =
               BalanceReader.get_erc20_balance("base-sepolia", @account, :usdc, rpc_fn: rpc_fn)

      assert Decimal.equal?(balance, Decimal.new("124.500000"))
    end

    test "decodes 0x as zero balance" do
      rpc_fn = fn _, _ -> {:ok, "0x"} end

      assert {:ok, balance} =
               BalanceReader.get_erc20_balance("base-sepolia", @account, :usdc, rpc_fn: rpc_fn)

      assert Decimal.equal?(balance, Decimal.new("0"))
    end

    test "uppercase + mixed-case account is normalised to lowercase before query" do
      mixed = "0x7A2F3c8e9D1a5B4f6C2e8D9a1B3f5C7e8d2a4D31"

      rpc_fn = fn _url, payload ->
        [%{"data" => data}, _] = payload["params"]
        # Account hex is lowercased in the calldata
        assert String.contains?(data, "7a2f3c8e9d1a5b4f6c2e8d9a1b3f5c7e8d2a4d31")
        {:ok, "0x" <> String.pad_leading("0", 64, "0")}
      end

      assert {:ok, _} =
               BalanceReader.get_erc20_balance("base-sepolia", mixed, :usdc, rpc_fn: rpc_fn)
    end
  end

  describe "validation failures" do
    test "rejects unsupported chain (mainnet) without hitting RPC" do
      called? = self()

      rpc_fn = fn _, _ ->
        send(called?, :rpc_called)
        {:ok, "0x0"}
      end

      assert {:error, :chain_unsupported} =
               BalanceReader.get_erc20_balance("base", @account, :usdc, rpc_fn: rpc_fn)

      refute_received :rpc_called
    end

    test "rejects unknown token without hitting RPC" do
      assert {:error, :token_unsupported} =
               BalanceReader.get_erc20_balance("base-sepolia", @account, :weth,
                 rpc_fn: &fail_rpc/2
               )
    end

    test "rejects malformed account address without hitting RPC" do
      for bad <- ["0xnope", "abc", nil, "0x" <> String.duplicate("z", 40)] do
        assert {:error, :account_address_invalid} =
                 BalanceReader.get_erc20_balance("base-sepolia", bad, :usdc, rpc_fn: &fail_rpc/2)
      end
    end
  end

  describe "config + RPC error mapping" do
    test "missing :rpc_url returns :rpc_not_configured" do
      Application.put_env(:bank, BalanceReader, rpc_url: nil)

      assert {:error, :rpc_not_configured} =
               BalanceReader.get_erc20_balance("base-sepolia", @account, :usdc,
                 rpc_fn: &fail_rpc/2
               )
    end

    test "RPC :transport_error propagates as :transport_error" do
      rpc_fn = fn _, _ -> {:error, :transport_error} end

      assert {:error, :transport_error} =
               BalanceReader.get_erc20_balance("base-sepolia", @account, :usdc, rpc_fn: rpc_fn)
    end

    test "RPC :rpc_error propagates" do
      rpc_fn = fn _, _ -> {:error, :rpc_error} end

      assert {:error, :rpc_error} =
               BalanceReader.get_erc20_balance("base-sepolia", @account, :usdc, rpc_fn: rpc_fn)
    end

    test "non-string RPC result becomes :invalid_response" do
      rpc_fn = fn _, _ -> {:ok, 42} end

      assert {:error, :invalid_response} =
               BalanceReader.get_erc20_balance("base-sepolia", @account, :usdc, rpc_fn: rpc_fn)
    end

    test "malformed hex result becomes :invalid_response" do
      rpc_fn = fn _, _ -> {:ok, "not_hex"} end

      assert {:error, :invalid_response} =
               BalanceReader.get_erc20_balance("base-sepolia", @account, :usdc, rpc_fn: rpc_fn)
    end

    test "any other RPC error normalises to :unknown" do
      rpc_fn = fn _, _ -> {:error, :some_random_atom} end

      assert {:error, :unknown} =
               BalanceReader.get_erc20_balance("base-sepolia", @account, :usdc, rpc_fn: rpc_fn)
    end
  end

  defp fail_rpc(_url, _payload), do: flunk("RPC must not be called")
end
