defmodule Bank.Chains.MainnetPreflightTest do
  use ExUnit.Case, async: true

  alias Bank.Chains.MainnetPreflight

  @rpc_url "http://localhost:9999/rpc"
  @bundler_url "http://localhost:9999/bundler"
  @sa "0x1111111111111111111111111111111111111111"
  @entrypoint "0x0000000071727De22E5E9d8BAf0edAc6f37da032"

  defp env(overrides \\ %{}) do
    Map.merge(
      %{
        "BASE_RPC_URL" => @rpc_url,
        "BUNDLER_RPC_URL" => @bundler_url,
        "BASE_CHAIN_ID" => "8453",
        "SMART_ACCOUNT_ADDRESS" => @sa
      },
      overrides
    )
  end

  defp ok_rpc do
    fn _url, payload ->
      case {payload["method"], payload["params"]} do
        {"eth_chainId", _} -> {:ok, "0x2105"}
        {"eth_getCode", [@entrypoint, _]} -> {:ok, "0x6080604052"}
        {"eth_getCode", _} -> {:ok, "0xabcdef"}
        {"eth_getBalance", _} -> {:ok, "0x1bc16d674ec80000"}
      end
    end
  end

  describe "happy path" do
    test "all checks pass with a healthy mainnet RPC" do
      result = MainnetPreflight.run(env: env(), rpc_fn: ok_rpc())

      assert result.status == :ok
      assert result.chain_id_expected == 8453
      assert result.entrypoint == @entrypoint

      for {_name, check} <- result.checks do
        assert check.status == :ok, "expected all :ok, got #{inspect(check)}"
      end
    end
  end

  describe "config presence" do
    test ":not_configured when every required env key is missing" do
      result = MainnetPreflight.run(env: %{}, rpc_fn: ok_rpc())

      assert result.status == :not_configured
      assert result.checks.config_present.status == :not_configured
      assert result.checks.config_present.detail =~ "config_missing:"
    end

    test ":not_configured when one specific key is missing — detail names which key" do
      missing_key = "BASE_CHAIN_ID"
      result = MainnetPreflight.run(env: env(%{missing_key => nil}), rpc_fn: ok_rpc())

      assert result.checks.config_present.detail == "config_missing:#{missing_key}"
    end

    test "empty string is treated as missing" do
      result = MainnetPreflight.run(env: env(%{"BASE_RPC_URL" => ""}), rpc_fn: ok_rpc())

      assert result.checks.config_present.status == :not_configured
      assert result.checks.config_present.detail == "config_missing:BASE_RPC_URL"
    end
  end

  describe "declared chain id" do
    test "rejects declared 84532 (Sepolia) when targeting mainnet" do
      result = MainnetPreflight.run(env: env(%{"BASE_CHAIN_ID" => "84532"}), rpc_fn: ok_rpc())

      assert result.status == :down
      assert result.checks.chain_id_declared.status == :down
      assert result.checks.chain_id_declared.detail == "chain_id_declared_mismatch"
    end

    test "rejects an unparseable BASE_CHAIN_ID" do
      result = MainnetPreflight.run(env: env(%{"BASE_CHAIN_ID" => "abc"}), rpc_fn: ok_rpc())
      assert result.checks.chain_id_declared.status == :down
      assert result.checks.chain_id_declared.detail == "chain_id_declared_mismatch"
    end

    test "accepts integer-typed BASE_CHAIN_ID == 8453" do
      result = MainnetPreflight.run(env: env(%{"BASE_CHAIN_ID" => 8453}), rpc_fn: ok_rpc())
      assert result.checks.chain_id_declared.status == :ok
    end
  end

  describe "RPC chain id" do
    test "rejects an RPC that returns a Sepolia chain id" do
      sepolia_rpc = fn _url, %{"method" => method} ->
        case method do
          "eth_chainId" -> {:ok, "0x14a34"}
          "eth_getCode" -> {:ok, "0x6080604052"}
          "eth_getBalance" -> {:ok, "0x1"}
        end
      end

      result = MainnetPreflight.run(env: env(), rpc_fn: sepolia_rpc)

      assert result.status == :down
      assert result.checks.chain_id_rpc.status == :down
      assert result.checks.chain_id_rpc.detail == "chain_id_rpc_mismatch"
    end

    test "lowercases hex before comparing (0X2105 still passes)" do
      mixed_case_rpc = fn _url, %{"method" => method} ->
        case method do
          "eth_chainId" -> {:ok, "0X2105"}
          "eth_getCode" -> {:ok, "0x6080604052"}
          "eth_getBalance" -> {:ok, "0x1"}
        end
      end

      result = MainnetPreflight.run(env: env(), rpc_fn: mixed_case_rpc)

      assert result.checks.chain_id_rpc.status == :ok
    end

    test "transport error surfaces as :down with fixed-allowlist detail" do
      flaky_rpc = fn _url, _payload -> {:error, :transport_error} end

      result = MainnetPreflight.run(env: env(), rpc_fn: flaky_rpc)

      assert result.checks.chain_id_rpc.status == :down
      assert result.checks.chain_id_rpc.detail == "transport_error"
    end

    test "5xx surfaces as :down with http_5xx" do
      err_rpc = fn _url, _payload -> {:error, :http_5xx} end

      result = MainnetPreflight.run(env: env(), rpc_fn: err_rpc)

      assert result.checks.chain_id_rpc.status == :down
      assert result.checks.chain_id_rpc.detail == "http_5xx"
    end

    test "rpc_check_raised maps to :unknown (not :down)" do
      raising_rpc = fn _url, _payload -> {:error, :rpc_check_raised} end

      result = MainnetPreflight.run(env: env(), rpc_fn: raising_rpc)

      assert result.checks.chain_id_rpc.status == :unknown
      assert result.checks.chain_id_rpc.detail == "rpc_check_raised"
    end
  end

  describe "entrypoint code" do
    test "rejects empty bytecode (entrypoint_missing)" do
      empty_entrypoint_rpc = fn _url, payload ->
        case {payload["method"], payload["params"]} do
          {"eth_chainId", _} -> {:ok, "0x2105"}
          {"eth_getCode", [@entrypoint, _]} -> {:ok, "0x"}
          {"eth_getCode", _} -> {:ok, "0xabcd"}
          {"eth_getBalance", _} -> {:ok, "0x1"}
        end
      end

      result = MainnetPreflight.run(env: env(), rpc_fn: empty_entrypoint_rpc)

      assert result.checks.entrypoint_code.status == :down
      assert result.checks.entrypoint_code.detail == "entrypoint_missing"
    end
  end

  describe "smart account checks" do
    test "smart_account_address_shape rejects an invalid 0x address" do
      result =
        MainnetPreflight.run(
          env: env(%{"SMART_ACCOUNT_ADDRESS" => "not-an-address"}),
          rpc_fn: ok_rpc()
        )

      assert result.checks.smart_account_address_shape.status == :down
      assert result.checks.smart_account_address_shape.detail == "smart_account_address_invalid"
    end

    test "smart_account_code reports :degraded (not :down) when SA is not deployed" do
      not_deployed_rpc = fn _url, payload ->
        case {payload["method"], payload["params"]} do
          {"eth_chainId", _} -> {:ok, "0x2105"}
          {"eth_getCode", [@entrypoint, _]} -> {:ok, "0x6080604052"}
          {"eth_getCode", _} -> {:ok, "0x"}
          {"eth_getBalance", _} -> {:ok, "0x0"}
        end
      end

      result = MainnetPreflight.run(env: env(), rpc_fn: not_deployed_rpc)

      assert result.checks.smart_account_code.status == :degraded
      assert result.checks.smart_account_code.detail == "smart_account_not_deployed"

      # Roll-up is :degraded — informational, not a hard failure.
      assert result.status == :degraded
    end

    test "smart_account_balance passes regardless of amount (zero balance is OK)" do
      zero_balance_rpc = fn _url, payload ->
        case payload["method"] do
          "eth_chainId" -> {:ok, "0x2105"}
          "eth_getCode" -> {:ok, "0xabcd"}
          "eth_getBalance" -> {:ok, "0x0"}
        end
      end

      result = MainnetPreflight.run(env: env(), rpc_fn: zero_balance_rpc)

      assert result.checks.smart_account_balance.status == :ok
    end
  end

  describe "bundler url shape" do
    test "rejects a non-http(s) bundler URL" do
      result =
        MainnetPreflight.run(
          env: env(%{"BUNDLER_RPC_URL" => "ftp://bundler"}),
          rpc_fn: ok_rpc()
        )

      assert result.checks.bundler_url_shape.status == :down
      assert result.checks.bundler_url_shape.detail == "bundler_url_invalid"
    end
  end

  describe "secret hygiene" do
    # Every error detail must come from the fixed allowlist
    # documented in the moduledoc. A future regression that
    # surfaces an `inspect/1`'d struct or a raw URL in the detail
    # field fails this test.
    test "every check detail is a short fixed-shape string (no inspect/1, no URL leak)" do
      flaky_rpc = fn _url, _payload -> {:error, :transport_error} end

      result =
        MainnetPreflight.run(
          env: env(%{"BASE_CHAIN_ID" => "84532", "BUNDLER_RPC_URL" => "ftp://x"}),
          rpc_fn: flaky_rpc
        )

      for {name, check} <- result.checks do
        detail = check.detail || ""

        # No raw URL ever ends up in detail.
        refute detail =~ ~r{https?://},
               "check #{name} leaked a URL in detail: #{inspect(detail)}"

        # No inspect/1 of a struct.
        refute detail =~ ~r/%[A-Z][A-Za-z.]+\{/,
               "check #{name} leaked an inspected struct in detail: #{inspect(detail)}"

        # No Authorization-style header.
        refute detail =~ ~r/authorization|bearer/i,
               "check #{name} leaked an auth header in detail: #{inspect(detail)}"

        # No private-key-shaped 32-byte hex blob.
        refute detail =~ ~r/0x[0-9a-fA-F]{64}/,
               "check #{name} leaked a 32-byte hex blob in detail: #{inspect(detail)}"
      end
    end
  end

  describe "no broadcast posture" do
    test "rpc_fn is never asked to dispatch a transaction (only read-only methods)" do
      observed = :counters.new(1, [])

      stub = fn _url, %{"method" => method} = payload ->
        :counters.add(observed, 1, 1)

        case method do
          method when method in ~w(eth_chainId eth_getCode eth_getBalance) ->
            send_to_test(method, payload)
            ok_rpc().(_url = "ignored", payload)

          _ ->
            flunk("rpc_fn called with non-read-only method: #{method}")
        end
      end

      _ = MainnetPreflight.run(env: env(), rpc_fn: stub)

      observed_count = :counters.get(observed, 1)
      assert observed_count >= 4, "expected ≥ 4 RPC calls, got #{observed_count}"
    end

    defp send_to_test(method, payload), do: send(self(), {:rpc, method, payload})
  end

  describe "Bank.Chains agreement" do
    test "the preflight's mainnet chain string is in Bank.Chains.mainnet_chains/0" do
      # `Bank.Chains.mainnet?/1` is the authoritative classifier.
      # If a future refactor drops "base" from that list, this
      # preflight's gate would lose its anchor and we'd notice via
      # this test.
      assert Bank.Chains.mainnet?("base")
      assert MainnetPreflight.base_mainnet_chain_id() == 8453
    end
  end
end
