defmodule Bank.Delegations.ProvisioningTest do
  use ExUnit.Case, async: true

  alias Bank.Delegations.Provisioning

  @operator_key "0x" <> String.duplicate("11", 32)
  @signer "0x" <> String.duplicate("22", 20)
  @factory "0x" <> String.duplicate("33", 20)
  @validator "0x" <> String.duplicate("44", 20)
  @smart_account "0x" <> String.duplicate("55", 20)
  @bytecode_hash "0x" <> String.duplicate("ab", 32)

  defp deploy_env(overrides \\ %{}) do
    Map.merge(
      %{
        "OPERATOR_PRIVATE_KEY" => @operator_key,
        "DELEGATION_SIGNER_PUBKEY" => @signer,
        "BASE_RPC_URL" => "https://sepolia.base.org",
        "BUNDLER_RPC_URL" => "https://bundler.example/base-sepolia",
        "KERNEL_FACTORY_ADDRESS" => @factory,
        "PERMISSION_VALIDATOR_ADDRESS" => @validator,
        "BASE_CHAIN_ID" => "84532"
      },
      overrides
    )
  end

  describe "preflight/2" do
    test "reports missing inputs without pretending provisioning succeeded" do
      checked = Provisioning.preflight(%{}, :deploy)

      assert checked.status == :blocked
      assert checked.mode == :sentinel_era
      assert Enum.any?(checked.problems, &(&1.key == "OPERATOR_PRIVATE_KEY"))
      assert Enum.any?(checked.problems, &(&1.key == "PERMISSION_VALIDATOR_ADDRESS"))
    end

    test "redacts private key shaped values" do
      checked = Provisioning.preflight(deploy_env(), :deploy)

      assert checked.status == :ready
      assert checked.mode == :kernel_provisioning_ready
      assert checked.redacted_env["OPERATOR_PRIVATE_KEY"] == "0x1111...1111"
      refute checked.redacted_env["OPERATOR_PRIVATE_KEY"] == @operator_key
    end

    test "rejects placeholders and malformed chain id" do
      checked =
        Provisioning.preflight(
          deploy_env(%{
            "KERNEL_FACTORY_ADDRESS" => "0x_factory_placeholder",
            "BASE_CHAIN_ID" => "1"
          }),
          :deploy
        )

      assert checked.status == :blocked

      assert Enum.any?(
               checked.problems,
               &(&1.key == "KERNEL_FACTORY_ADDRESS" and &1.severity == :placeholder)
             )

      assert Enum.any?(checked.problems, &(&1.key == "BASE_CHAIN_ID"))
    end

    test "install and verify phases require SMART_ACCOUNT_ADDRESS" do
      install = Provisioning.preflight(deploy_env(), :install)
      verify = Provisioning.preflight(deploy_env(), :verify)

      assert install.status == :blocked
      assert verify.status == :blocked
      assert Enum.any?(install.problems, &(&1.key == "SMART_ACCOUNT_ADDRESS"))
      assert Enum.any?(verify.problems, &(&1.key == "SMART_ACCOUNT_ADDRESS"))

      ready =
        Provisioning.preflight(deploy_env(%{"SMART_ACCOUNT_ADDRESS" => @smart_account}), :verify)

      assert ready.status == :ready
    end
  end

  describe "plan/2" do
    test "returns command plan only after preflight is ready" do
      assert {:ok, plan} = Provisioning.plan(deploy_env(), :deploy)
      assert plan.phase == :deploy
      assert "npx tsx provision-kernel.ts" in plan.commands
      assert plan.next_issue =~ "#83"

      assert {:error, checked} = Provisioning.plan(%{}, :deploy)
      assert checked.status == :blocked
    end
  end

  describe "validate_receipt/1" do
    test "builds #83 handoff from a complete deployment receipt" do
      receipt = %{
        "chain_id" => "84532",
        "smart_account_address" => @smart_account,
        "permission_validator_address" => @validator,
        "kernel_factory_address" => @factory,
        "permission_validator_bytecode_keccak256" => @bytecode_hash,
        "vendor_source" => "https://docs.zerodev.app/",
        "chain_explorer_url" => "https://sepolia.basescan.org/address/#{@validator}"
      }

      assert {:ok, handoff} = Provisioning.validate_receipt(receipt)
      assert handoff.chain_id == 84532
      assert handoff.permission_validator_address == @validator
      assert handoff.deployed_bytecode_keccak256 == @bytecode_hash
      assert handoff.artifact_source_required == true
      assert handoff.next_issue == "#83"
    end

    test "rejects incomplete receipts so #83 cannot pin from guesswork" do
      assert {:error, problems} =
               Provisioning.validate_receipt(%{
                 chain_id: 84532,
                 smart_account_address: @smart_account
               })

      assert Enum.any?(problems, &(&1.key == "permission_validator_address"))
      assert Enum.any?(problems, &(&1.key == "validator_bytecode_keccak256"))
      assert Enum.any?(problems, &(&1.key == "vendor_source"))
    end

    test "validates receipt files emitted by the adapter verify script" do
      path = tmp_path("kernel-receipt.json")

      File.write!(path, Jason.encode!(complete_receipt()))

      assert {:ok, handoff} = Provisioning.validate_receipt_file(path)
      assert handoff.chain_id == 84532
      assert handoff.next_issue == "#83"
    after
      cleanup_tmp("kernel-receipt.json")
    end

    test "rejects missing, malformed, and non-object receipt files" do
      missing = tmp_path("missing-receipt.json")
      malformed = tmp_path("malformed-receipt.json")
      array = tmp_path("array-receipt.json")

      File.write!(malformed, "{not json")
      File.write!(array, "[]")

      assert {:error, {:read_failed, :enoent}} = Provisioning.validate_receipt_file(missing)

      assert {:error, {:decode_failed, %Jason.DecodeError{}}} =
               Provisioning.validate_receipt_file(malformed)

      assert {:error, [%{key: "receipt", severity: :invalid}]} =
               Provisioning.validate_receipt_file(array)
    after
      cleanup_tmp("missing-receipt.json")
      cleanup_tmp("malformed-receipt.json")
      cleanup_tmp("array-receipt.json")
    end
  end

  describe "permission_id?/1" do
    test "accepts only lowercase bytes32 hex permission ids" do
      assert Provisioning.permission_id?("0x" <> String.duplicate("ab", 32))
      refute Provisioning.permission_id?("0x" <> String.duplicate("AB", 32))
      refute Provisioning.permission_id?("del_primary")
      refute Provisioning.permission_id?("0x" <> String.duplicate("ab", 20))
    end
  end

  defp complete_receipt do
    %{
      "chain_id" => "84532",
      "smart_account_address" => @smart_account,
      "permission_validator_address" => @validator,
      "kernel_factory_address" => @factory,
      "permission_validator_bytecode_keccak256" => @bytecode_hash,
      "vendor_source" => "https://docs.zerodev.app/",
      "chain_explorer_url" => "https://sepolia.basescan.org/address/#{@validator}"
    }
  end

  defp tmp_path(name) do
    Path.join(System.tmp_dir!(), "bank-provisioning-test-#{name}")
  end

  defp cleanup_tmp(name) do
    tmp_path(name)
    |> File.rm()
    |> case do
      :ok -> :ok
      {:error, :enoent} -> :ok
    end
  end
end
