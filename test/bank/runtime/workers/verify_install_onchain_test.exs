defmodule Bank.Runtime.Workers.VerifyInstallOnchainTest do
  @moduledoc """
  Tests for `Bank.Runtime.Workers.VerifyInstallOnchain` (#474).

  The worker is the SOLE writer of the `:active` transition for
  browser-signed delegations. These tests pin:

    * happy path — verifier returns `:ok`, row flips to `:active`,
      `delegation.install_confirmed_onchain` audit fires.
    * forged on-chain state — verifier returns `:not_installed`,
      row flips to `:install_failed`, `delegation.install_failed`
      audit fires.
    * idempotent re-runs — second invocation on an already-`:active`
      row returns `:ok` without writing.
    * RPC misconfiguration — verifier returns `:rpc_not_configured`,
      row marked `:install_failed` on first attempt.
  """

  use Bank.DataCase, async: false

  alias Bank.Audit
  alias Bank.Chains.KernelVerifier
  alias Bank.Delegations.Delegation
  alias Bank.Repo
  alias Bank.Runtime.Workers.VerifyInstallOnchain
  alias Bank.SessionPermissions.Scope
  alias Bank.Workspaces

  @valid_userop_hash "0x" <> String.duplicate("a", 64)
  @valid_tx_hash "0x" <> String.duplicate("b", 64)
  @valid_permission_id <<0xDE, 0xAD, 0xBE, 0xEF>>
  @valid_validation_id <<0x02>> <> :binary.copy(<<0xCA, 0xFE>>, 10)
  @sa_address "0x000000000000000000000000000000000000a11c"

  setup do
    suffix = System.unique_integer([:positive])

    {:ok, workspace} =
      Workspaces.create_workspace(%{
        slug: "vw-ws-#{suffix}",
        name: "VW ws #{suffix}",
        mainnet_enabled: false
      })

    binding_id = Ecto.UUID.generate()

    {:ok, delegation} =
      %Delegation{}
      |> Delegation.changeset(%{
        smart_account_id: "sa_test_" <> Integer.to_string(suffix),
        delegation_id: @valid_userop_hash,
        state: :pending,
        chain: "base-sepolia",
        scope: Map.put(Scope.default(), "smart_account_address", @sa_address),
        workspace_id: workspace.id,
        root_validator_owner: "user",
        binding_id: binding_id,
        install_userop_hash: @valid_userop_hash,
        permission_id: @valid_permission_id,
        validation_id: @valid_validation_id,
        kernel_version: "v3.1",
        permission_package_version: "5.6.3",
        session_signer_address: "0x" <> String.duplicate("c", 40)
      })
      |> Repo.insert()

    original_kv = Application.get_env(:bank, KernelVerifier, [])
    original_w = Application.get_env(:bank, VerifyInstallOnchain, [])

    Application.put_env(
      :bank,
      VerifyInstallOnchain,
      smart_account_resolver: fn _delegation -> @sa_address end
    )

    on_exit(fn ->
      Application.put_env(:bank, KernelVerifier, original_kv)
      Application.put_env(:bank, VerifyInstallOnchain, original_w)
    end)

    %{workspace: workspace, delegation: delegation, binding_id: binding_id}
  end

  describe "perform/1 — happy path" do
    test "flips the row to :active and audits install_confirmed_onchain",
         %{delegation: delegation, binding_id: binding_id} do
      stub_verifier(:installed)

      assert :ok =
               perform_job(VerifyInstallOnchain, %{
                 "delegation_id" => delegation.id,
                 "binding_id" => binding_id,
                 "tx_hash" => @valid_tx_hash,
                 "block_number" => 123_456
               })

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :active
      assert reloaded.granted_at
      assert reloaded.installed_at_block == 123_456
      assert reloaded.install_tx_hash == @valid_tx_hash

      events = list_events(binding_id)
      assert Enum.any?(events, &(&1.event_type == "delegation.install_confirmed_onchain"))
    end
  end

  describe "perform/1 — failure paths" do
    test "verifier returns :not_installed → row marked :install_failed",
         %{delegation: delegation, binding_id: binding_id} do
      stub_verifier(:not_installed)

      assert :ok =
               perform_job(VerifyInstallOnchain, %{
                 "delegation_id" => delegation.id,
                 "binding_id" => binding_id
               })

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :install_failed

      events = list_events(binding_id)
      assert Enum.any?(events, &(&1.event_type == "delegation.install_failed"))
    end

    test "rpc_not_configured marks the row :install_failed on first attempt",
         %{delegation: delegation, binding_id: binding_id} do
      Application.put_env(:bank, KernelVerifier, [])

      assert :ok =
               perform_job(VerifyInstallOnchain, %{
                 "delegation_id" => delegation.id,
                 "binding_id" => binding_id
               })

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :install_failed
      assert reloaded.last_reason =~ "install_failed"
    end

    test "transient transport_error returns {:error, _} so Oban retries",
         %{delegation: delegation, binding_id: binding_id} do
      stub_verifier(:transport_error)

      assert {:error, :transport_error} =
               perform_job(VerifyInstallOnchain, %{
                 "delegation_id" => delegation.id,
                 "binding_id" => binding_id
               })

      reloaded = Repo.get!(Delegation, delegation.id)
      # Row stays :pending because the worker returned an error
      # (Oban will retry).
      assert reloaded.state == :pending
    end
  end

  describe "perform/1 — idempotency" do
    test "second run on an already-:active row returns :ok without writing",
         %{delegation: delegation, binding_id: binding_id} do
      stub_verifier(:installed)

      :ok =
        perform_job(VerifyInstallOnchain, %{
          "delegation_id" => delegation.id,
          "binding_id" => binding_id,
          "tx_hash" => @valid_tx_hash,
          "block_number" => 123
        })

      original_granted_at = Repo.get!(Delegation, delegation.id).granted_at

      :ok =
        perform_job(VerifyInstallOnchain, %{
          "delegation_id" => delegation.id,
          "binding_id" => binding_id
        })

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :active
      assert reloaded.granted_at == original_granted_at
    end

    test "missing delegation row → :cancel" do
      assert {:cancel, :delegation_not_found} =
               perform_job(VerifyInstallOnchain, %{
                 "delegation_id" => Ecto.UUID.generate()
               })
    end
  end

  # --- helpers ----------------------------------------------------------

  defp perform_job(worker, args) do
    job = %Oban.Job{
      args: args,
      attempt: 1,
      max_attempts: 5,
      worker: Atom.to_string(worker)
    }

    worker.perform(job)
  end

  defp stub_verifier(scenario) do
    rpc_fn =
      case scenario do
        :installed ->
          fn _url, %{"method" => method} ->
            case method do
              "eth_getCode" -> {:ok, "0x60806040"}
              "eth_call" -> {:ok, "0x" <> String.duplicate("a", 64)}
            end
          end

        :not_installed ->
          fn _url, %{"method" => method} ->
            case method do
              "eth_getCode" -> {:ok, "0x60806040"}
              "eth_call" -> {:ok, "0x" <> String.duplicate("0", 64)}
            end
          end

        :transport_error ->
          fn _url, _payload -> {:error, :transport_error} end
      end

    Application.put_env(
      :bank,
      KernelVerifier,
      rpc_url: "http://test.kernel.invalid",
      rpc_fn: rpc_fn
    )
  end

  defp list_events(correlation_id) do
    Audit.list_events(%{correlation_id: correlation_id}, limit: 20)
    |> Map.get(:events)
  end
end
