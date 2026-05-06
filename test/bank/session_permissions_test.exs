defmodule Bank.SessionPermissionsTest do
  @moduledoc """
  Context tests for `Bank.SessionPermissions`.

  Pins #171 acceptance:

    * Active verified binding required.
    * Base Sepolia (84532) only.
    * Refuses while runtime or workspace is paused.
    * Idempotent: second install request while one is pending /
      active is rejected with structured `:already_pending` /
      `:already_active`.
    * Audit `session_permission.install_requested` carries
      binding id, smart-account id, address, chain id, and the
      scope summary — never a nonce, signature, or session key.
  """

  use Bank.DataCase, async: false

  alias Bank.Accounts
  alias Bank.Audit
  alias Bank.Delegations
  alias Bank.Security
  alias Bank.SessionPermissions
  alias Bank.SessionPermissions.Scope
  alias Bank.WalletBindings
  alias Bank.WalletBindings.Signature
  alias Bank.WalletBindings.WalletBinding
  alias Bank.Workspaces
  alias Bank.Workspaces.Workspace

  @privkey <<1::256>>

  setup do
    Security.PauseState.reset()

    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "sp-test-#{suffix}",
        email: "sp-test-#{suffix}@example.com",
        name: "SP Test"
      })

    {:ok, workspace} =
      Workspaces.create_workspace(%{
        slug: "sp-ws-#{suffix}",
        name: "SP ws #{suffix}",
        mainnet_enabled: false
      })

    {:ok, _} =
      Workspaces.create_membership(%{
        user_id: user.id,
        workspace_id: workspace.id,
        role: :admin
      })

    Process.put(:bank_test_workspace_id, workspace.id)
    on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

    {:ok, pubkey} = ExSecp256k1.create_public_key(@privkey)
    {:ok, address} = Signature.address_from_pubkey(pubkey)

    binding = verified_binding(workspace.id, user.id, address)

    %{user: user, workspace: workspace, address: address, binding: binding}
  end

  describe "request_install/2 — happy path" do
    test "accepts the install and returns a deterministic smart_account_id", %{
      workspace: workspace,
      binding: binding
    } do
      assert {:ok, sa_id} = SessionPermissions.request_install(workspace.id, binding)
      assert sa_id == "sa_wb_" <> binding.id
      assert sa_id == SessionPermissions.compute_smart_account_id(binding)
    end

    test "enqueues a GrantDelegation job + audits delegation.connect_requested", %{
      workspace: workspace,
      binding: binding
    } do
      {:ok, sa_id} = SessionPermissions.request_install(workspace.id, binding)

      assert [%Oban.Job{worker: "Bank.Runtime.Workers.GrantDelegation", args: args}] =
               all_grant_jobs()

      assert args["smart_account_id"] == sa_id
      assert args["chain_id"] == 84_532
      assert args["account"] == binding.address

      events = list_events(binding.id)

      assert Enum.any?(events, &(&1.event_type == "session_permission.install_requested"))
    end

    test "records the canonical scope summary on the audit after_ref", %{
      workspace: workspace,
      binding: binding
    } do
      {:ok, _sa_id} = SessionPermissions.request_install(workspace.id, binding)

      events = list_events(binding.id)
      event = Enum.find(events, &(&1.event_type == "session_permission.install_requested"))

      assert is_map(event.after_ref)
      assert event.after_ref["wallet_binding_id"] == binding.id
      assert event.after_ref["address"] == binding.address
      assert event.after_ref["chain_id"] == 84_532
      assert event.after_ref["scope_summary"]["version"] == "1"
      assert is_list(event.after_ref["scope_summary"]["allowed"])
      assert is_list(event.after_ref["scope_summary"]["denied"])

      # No nonces, no signatures, no session signer keys leak.
      payload = Jason.encode!(event.after_ref)
      refute payload =~ binding.nonce
      refute payload =~ "private_key"
      refute payload =~ "signature"
      refute payload =~ "session_signer_key"
    end
  end

  describe "request_install/2 — refusal paths" do
    test "rejects when binding belongs to a different workspace", %{
      binding: binding
    } do
      other_workspace_id = Ecto.UUID.generate()

      assert {:error, :workspace_mismatch} =
               SessionPermissions.request_install(other_workspace_id, binding)

      assert all_grant_jobs() == []
    end

    test "rejects when binding is not verified", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      pending = pending_binding(workspace.id, user.id, address)

      assert {:error, :binding_not_verified} =
               SessionPermissions.request_install(workspace.id, pending)
    end

    test "rejects when binding is revoked", %{
      workspace: workspace,
      binding: binding
    } do
      {:ok, revoked} = WalletBindings.revoke_binding(binding.id, :test_revoke)

      assert {:error, :binding_revoked} =
               SessionPermissions.request_install(workspace.id, revoked)
    end

    test "rejects when binding chain is not 84532 (Base mainnet)", %{
      workspace: workspace,
      user: user,
      address: address
    } do
      mainnet_binding = mainnet_binding_fixture(workspace.id, user.id, address)

      assert {:error, :unsupported_chain} =
               SessionPermissions.request_install(workspace.id, mainnet_binding)
    end

    test "rejects while runtime is globally paused", %{
      workspace: workspace,
      binding: binding
    } do
      {:ok, :paused} = Security.pause(:global)

      assert {:error, :runtime_paused} =
               SessionPermissions.request_install(workspace.id, binding)
    end

    test "rejects while workspace agent keys are paused", %{
      workspace: workspace,
      binding: binding
    } do
      now = DateTime.utc_now()

      Repo.update_all(
        from(w in Workspace, where: w.id == ^workspace.id),
        set: [
          agent_keys_paused_at: now,
          agent_keys_paused_reason: "test pause"
        ]
      )

      assert {:error, :workspace_paused} =
               SessionPermissions.request_install(workspace.id, binding)
    end

    test "rejects when a delegation install is already pending", %{
      workspace: workspace,
      binding: binding
    } do
      sa_id = SessionPermissions.compute_smart_account_id(binding)

      {:ok, _pending} =
        %Delegations.Delegation{}
        |> Delegations.Delegation.changeset(%{
          smart_account_id: sa_id,
          delegation_id: "del_pending_#{System.unique_integer([:positive])}",
          state: :pending,
          chain: "base",
          workspace_id: workspace.id
        })
        |> Repo.insert()

      assert {:error, {:already_pending, %Delegations.Delegation{}}} =
               SessionPermissions.request_install(workspace.id, binding)
    end

    test "rejects when an active delegation already exists for this binding", %{
      workspace: workspace,
      binding: binding
    } do
      sa_id = SessionPermissions.compute_smart_account_id(binding)

      {:ok, _} =
        Delegations.grant(sa_id, "del_active_#{System.unique_integer([:positive])}", %{
          workspace_id: workspace.id
        })

      assert {:error, {:already_active, %Delegations.Delegation{}}} =
               SessionPermissions.request_install(workspace.id, binding)
    end
  end

  describe "default_scope/0" do
    test "delegates to Scope.default/0" do
      assert SessionPermissions.default_scope() == Scope.default()
    end
  end

  # --- helpers -----------------------------------------------------------

  defp verified_binding(workspace_id, user_id, address) do
    {:ok, binding} =
      WalletBindings.issue_challenge(workspace_id, user_id, %{
        address: address,
        chain_id: 84_532
      })

    signature = sign_personal(binding.challenge_message, @privkey)
    {:ok, verified} = WalletBindings.verify_and_bind(binding.id, signature)
    verified
  end

  defp pending_binding(workspace_id, user_id, address) do
    {:ok, binding} =
      WalletBindings.issue_challenge(workspace_id, user_id, %{
        address: address,
        chain_id: 84_532
      })

    binding
  end

  # Bypass the chain validator at the changeset level by writing a
  # raw row with chain_id 8453. This simulates a stale binding that
  # somehow landed pre-#169 — `request_install/2` must still refuse
  # it at the context boundary.
  defp mainnet_binding_fixture(workspace_id, user_id, address) do
    nonce = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    now = DateTime.utc_now()
    expires = DateTime.add(now, 300, :second)

    {:ok, row} =
      Repo.insert(%WalletBinding{
        workspace_id: workspace_id,
        user_id: user_id,
        address: address,
        chain_id: 8453,
        nonce: nonce,
        challenge_message: "test mainnet binding",
        expires_at: expires,
        verified_at: now
      })

    row
  end

  defp sign_personal(message, privkey) do
    digest = Signature.eip191_hash(message)
    {:ok, {r, s, v}} = ExSecp256k1.sign(digest, privkey)
    "0x" <> Base.encode16(r <> s <> <<v + 27>>, case: :lower)
  end

  defp list_events(correlation_id) do
    Audit.list_events(%{correlation_id: correlation_id}, limit: 20)
    |> Map.get(:events)
  end

  defp all_grant_jobs do
    Repo.all(from(j in Oban.Job, where: j.worker == "Bank.Runtime.Workers.GrantDelegation"))
  end
end
