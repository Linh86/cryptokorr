defmodule Bank.Delegations.ProvisioningTest do
  use ExUnit.Case, async: true

  alias Bank.Delegations.Provisioning

  @operator_key "0x" <> String.duplicate("11", 32)
  @signer "0x" <> String.duplicate("22", 20)
  @factory "0x" <> String.duplicate("33", 20)
  @smart_account "0x" <> String.duplicate("55", 20)

  defp deploy_env(overrides \\ %{}) do
    Map.merge(
      %{
        "OPERATOR_PRIVATE_KEY" => @operator_key,
        "DELEGATION_SIGNER_PUBKEY" => @signer,
        "BASE_RPC_URL" => "https://sepolia.base.org",
        "BUNDLER_RPC_URL" => "https://bundler.example/base-sepolia",
        "KERNEL_FACTORY_ADDRESS" => @factory,
        "BASE_CHAIN_ID" => "84532"
      },
      overrides
    )
  end

  describe "preflight/2" do
    test "reports missing inputs without pretending provisioning succeeded" do
      checked = Provisioning.preflight(%{}, :deploy)

      assert checked.status == :blocked
      # The runtime is sentinel-era and stays that way until the
      # ZeroDev SDK integration ships — preflight never claims a
      # ready mode based on env presence.
      assert checked.mode == :awaiting_zerodev_integration
      assert Enum.any?(checked.problems, &(&1.key == "OPERATOR_PRIVATE_KEY"))
      # PERMISSION_VALIDATOR_ADDRESS was removed from required envs
      # (it never had a valid value in ZeroDev's model). The check
      # below pins that no problem references it any more.
      refute Enum.any?(checked.problems, &(&1.key == "PERMISSION_VALIDATOR_ADDRESS"))
    end

    test "redacts private key shaped values" do
      checked = Provisioning.preflight(deploy_env(), :deploy)

      assert checked.status == :ready
      assert checked.mode == :awaiting_zerodev_integration
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
    test "returns a command plan only after preflight is ready" do
      assert {:ok, plan} = Provisioning.plan(deploy_env(), :deploy)
      assert plan.phase == :deploy
      assert "npx tsx provision-kernel.ts" in plan.commands
      # The handoff message now points at the corrected ZeroDev
      # integration doc instead of the wrong-model #83 receipt.
      assert plan.next_issue =~ "zerodev-permissions-integration"

      assert {:error, checked} = Provisioning.plan(%{}, :deploy)
      assert checked.status == :blocked
    end
  end

  describe "validate_receipt/1" do
    test "refuses to validate any receipt and points to the integration doc" do
      # The previous receipt validator pinned a wrong model
      # (`permission_validator_address`, `validator_bytecode_keccak256`).
      # Until the corrected receipt shape is decided alongside the
      # ZeroDev SDK integration, this function is a deferred-blocker
      # gate.
      assert {:error, [problem]} =
               Provisioning.validate_receipt(%{"chain_id" => "84532"})

      assert problem.key == "receipt"
      assert problem.severity == :invalid
      assert problem.detail =~ "zerodev-permissions-integration"
    end

    test "validate_receipt_file still surfaces IO and JSON errors before deferral" do
      missing = tmp_path("missing-receipt.json")
      malformed = tmp_path("malformed-receipt.json")
      array = tmp_path("array-receipt.json")
      ok_shape = tmp_path("ok-shape-receipt.json")

      File.write!(malformed, "{not json")
      File.write!(array, "[]")
      File.write!(ok_shape, Jason.encode!(%{"chain_id" => "84532"}))

      assert {:error, {:read_failed, :enoent}} = Provisioning.validate_receipt_file(missing)

      assert {:error, {:decode_failed, %Jason.DecodeError{}}} =
               Provisioning.validate_receipt_file(malformed)

      assert {:error, [%{key: "receipt", severity: :invalid}]} =
               Provisioning.validate_receipt_file(array)

      # Well-formed JSON object still gets the deferred-blocker error
      # — there is nothing to validate against until the ZeroDev
      # integration lands.
      assert {:error, [%{key: "receipt", severity: :invalid, detail: detail}]} =
               Provisioning.validate_receipt_file(ok_shape)

      assert detail =~ "zerodev-permissions-integration"
    after
      cleanup_tmp("missing-receipt.json")
      cleanup_tmp("malformed-receipt.json")
      cleanup_tmp("array-receipt.json")
      cleanup_tmp("ok-shape-receipt.json")
    end
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
