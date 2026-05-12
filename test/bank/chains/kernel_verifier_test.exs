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

  describe "validation_id_check config flag" do
    # Path A integration follow-up: the canonical Kernel v3.1
    # `validationConfig(bytes21)` selector (currently `0x91244e98`)
    # does NOT match the deployed kernel implementation on Base
    # Sepolia — every `eth_call` reverts. Until the integration
    # ticket pins the right selector, dev runs with
    # `validation_id_check: :skip`; production should stay on
    # `:enforce`. These tests pin both branches so the gate can't
    # silently flip.

    test "when :skip, verifier returns :ok without making the validationConfig RPC call" do
      Application.put_env(
        :bank,
        KernelVerifier,
        Keyword.merge(
          Application.get_env(:bank, KernelVerifier, []),
          rpc_url: "http://test.kernel-verifier.invalid",
          validation_id_check: :skip
        )
      )

      called_methods = :ets.new(:methods, [:public, :bag])

      stub = fn _url, payload ->
        :ets.insert(called_methods, {:m, payload["method"]})

        case payload["method"] do
          "eth_getCode" ->
            {:ok, "0x60806040"}

          # `eth_call` MUST NOT be invoked under :skip. If it is,
          # we crash the test loudly — proves we didn't fall back
          # to the broken selector path.
          "eth_call" ->
            flunk("eth_call invoked despite :validation_id_check, :skip")
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
      # Sanity: only eth_getCode was actually called.
      methods_called =
        :ets.tab2list(called_methods)
        |> Enum.map(fn {:m, m} -> m end)
        |> Enum.uniq()

      assert methods_called == ["eth_getCode"],
             "under :skip, only eth_getCode should be invoked; saw: #{inspect(methods_called)}"
    end

    test "when :enforce, verifier still drives the validationConfig RPC call" do
      Application.put_env(
        :bank,
        KernelVerifier,
        Keyword.merge(
          Application.get_env(:bank, KernelVerifier, []),
          rpc_url: "http://test.kernel-verifier.invalid",
          validation_id_check: :enforce
        )
      )

      called_methods = :ets.new(:methods_enforce, [:public, :bag])

      stub = fn _url, payload ->
        :ets.insert(called_methods, {:m, payload["method"]})

        case payload["method"] do
          "eth_getCode" -> {:ok, "0x60806040"}
          "eth_call" -> {:ok, "0x" <> String.duplicate("a", 64)}
        end
      end

      assert {:ok, _evidence} =
               KernelVerifier.verify(
                 %{
                   smart_account_address: @sa,
                   validation_id: @validation_id,
                   chain_id: @sepolia
                 },
                 rpc_fn: stub
               )

      methods_called =
        :ets.tab2list(called_methods)
        |> Enum.map(fn {:m, m} -> m end)
        |> Enum.uniq()
        |> Enum.sort()

      assert "eth_call" in methods_called,
             "under :enforce, validationConfig (eth_call) MUST be invoked"

      assert "eth_getCode" in methods_called
    end

    test ":skip still refuses an undeployed smart account (:not_deployed)" do
      # Pin that the deployment check is NOT bypassed by :skip. If
      # the SA isn't on chain, the install can't possibly have
      # succeeded — the verifier must still fail closed.
      Application.put_env(
        :bank,
        KernelVerifier,
        Keyword.merge(
          Application.get_env(:bank, KernelVerifier, []),
          rpc_url: "http://test.kernel-verifier.invalid",
          validation_id_check: :skip
        )
      )

      stub = fn _url, payload ->
        case payload["method"] do
          # 0x = no bytecode at the SA.
          "eth_getCode" -> {:ok, "0x"}
          "eth_call" -> flunk("eth_call should not run before deployment check passes")
        end
      end

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
