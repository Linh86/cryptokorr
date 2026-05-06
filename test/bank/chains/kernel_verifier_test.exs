defmodule Bank.Chains.KernelVerifierTest do
  use ExUnit.Case, async: false

  alias Bank.Chains.KernelVerifier

  @sa "0x000000000000000000000000000000000000a11c"
  @validation_id "0x02deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
  @sepolia 84_532
  @mainnet 8_453

  setup do
    original = Application.get_env(:bank, KernelVerifier, [])

    Application.put_env(
      :bank,
      KernelVerifier,
      Keyword.put(original, :rpc_url, "http://test.kernel-verifier.invalid")
    )

    on_exit(fn -> Application.put_env(:bank, KernelVerifier, original) end)

    :ok
  end

  describe "verify/2 — happy path" do
    test "returns {:ok, evidence} when smart account is deployed and validation slot is non-zero" do
      stub =
        fn _url, payload ->
          case payload["method"] do
            "eth_getCode" -> {:ok, "0x60806040..."}
            "eth_call" -> {:ok, "0x" <> String.duplicate("a", 64)}
          end
        end

      assert {:ok, evidence} =
               KernelVerifier.verify(
                 %{
                   smart_account_address: @sa,
                   validation_id: @validation_id,
                   chain_id: @sepolia
                 },
                 rpc_fn: stub
               )

      assert evidence.smart_account_code_present == true
      assert evidence.validation_config_hex =~ ~r/^0x[0-9a-f]+$/
    end
  end

  describe "verify/2 — failure paths (fixed-allowlist atoms only)" do
    test "rejects mainnet chain_id with :chain_id_unsupported" do
      assert {:error, :chain_id_unsupported} =
               KernelVerifier.verify(%{
                 smart_account_address: @sa,
                 validation_id: @validation_id,
                 chain_id: @mainnet
               })
    end

    test "rejects malformed smart account address with :smart_account_address_invalid" do
      assert {:error, :smart_account_address_invalid} =
               KernelVerifier.verify(%{
                 smart_account_address: "not-an-address",
                 validation_id: @validation_id,
                 chain_id: @sepolia
               })
    end

    test "rejects wrong-length validation id with :validation_id_invalid" do
      assert {:error, :validation_id_invalid} =
               KernelVerifier.verify(%{
                 smart_account_address: @sa,
                 validation_id: "0x1234",
                 chain_id: @sepolia
               })
    end

    test "rejects an undeployed smart account (eth_getCode returns 0x) with :not_deployed" do
      stub = fn _url, %{"method" => "eth_getCode"} -> {:ok, "0x"} end

      assert {:error, :not_deployed} =
               KernelVerifier.verify(
                 %{
                   smart_account_address: @sa,
                   validation_id: @validation_id,
                   chain_id: @sepolia
                 },
                 rpc_fn: stub
               )
    end

    test "rejects an empty / all-zero validation slot with :not_installed" do
      stub =
        fn _url, payload ->
          case payload["method"] do
            "eth_getCode" -> {:ok, "0x60806040"}
            "eth_call" -> {:ok, "0x" <> String.duplicate("0", 64)}
          end
        end

      assert {:error, :not_installed} =
               KernelVerifier.verify(
                 %{
                   smart_account_address: @sa,
                   validation_id: @validation_id,
                   chain_id: @sepolia
                 },
                 rpc_fn: stub
               )
    end

    test "rejects transport errors with :transport_error" do
      stub = fn _url, _payload -> {:error, :transport_error} end

      assert {:error, :transport_error} =
               KernelVerifier.verify(
                 %{
                   smart_account_address: @sa,
                   validation_id: @validation_id,
                   chain_id: @sepolia
                 },
                 rpc_fn: stub
               )
    end

    test "returns :rpc_not_configured when no rpc_url is set" do
      Application.put_env(:bank, KernelVerifier, [])

      assert {:error, :rpc_not_configured} =
               KernelVerifier.verify(%{
                 smart_account_address: @sa,
                 validation_id: @validation_id,
                 chain_id: @sepolia
               })
    end
  end

  describe "secret hygiene" do
    test "evidence carries no Authorization / sk_/pk_ / credentialed-URL / PEM markers" do
      stub =
        fn _url, payload ->
          case payload["method"] do
            "eth_getCode" -> {:ok, "0x60806040"}
            "eth_call" -> {:ok, "0x" <> String.duplicate("a", 64)}
          end
        end

      {:ok, evidence} =
        KernelVerifier.verify(
          %{
            smart_account_address: @sa,
            validation_id: @validation_id,
            chain_id: @sepolia
          },
          rpc_fn: stub
        )

      blob = inspect(evidence)
      refute blob =~ ~r/Authorization\s*:\s*Bearer/i
      refute blob =~ ~r/\bsk_(live|test)_/
      refute blob =~ ~r/\bpk_(live|test)_/
      refute blob =~ ~r{://[^\s/@]+:[^\s/@]+@}
      refute blob =~ "PRIVATE KEY"
    end
  end
end
