defmodule Bank.SessionPermissions.BrowserInstallTest do
  @moduledoc """
  Context tests for `Bank.SessionPermissions.BrowserInstall` (#474).

  Pins the design doc's load-bearing acceptance:

    * envelope is built canonically from the binding + scope and
      audits `delegation.install_envelope_issued`;
    * attestation honors a fixed-allowlist status enum;
    * `submitted` persists a `:pending` delegation row keyed by
      `(binding_id, install_userop_hash)`;
    * `confirmed` enqueues `Bank.Runtime.Workers.VerifyInstallOnchain`
      and emits `delegation.install_broadcast`;
    * `confirmed` does NOT mark the row `:active` directly;
    * any failure status emits `delegation.install_failed` with a
      category atom from `failure_categories/0`;
    * free-form upstream reasons collapse to the catch-all in
      `failure_categories/0`;
    * mainnet bindings + paused runtime/workspace are refused.
  """

  use Bank.DataCase, async: false
  import Ecto.Query

  alias Bank.Accounts
  alias Bank.Audit
  alias Bank.Delegations.Delegation
  alias Bank.Repo
  alias Bank.Security
  alias Bank.SessionPermissions.BrowserInstall
  alias Bank.WalletBindings
  alias Bank.WalletBindings.{Signature, WalletBinding}
  alias Bank.Workspaces

  @privkey <<1::256>>
  @valid_userop_hash "0x" <> String.duplicate("a", 64)
  @valid_tx_hash "0x" <> String.duplicate("b", 64)
  @valid_permission_id "0xdeadbeef"
  @valid_validation_id "0x02deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  setup do
    Security.PauseState.reset()

    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "bi-#{suffix}",
        email: "bi-#{suffix}@example.com",
        name: "BI Test"
      })

    {:ok, workspace} =
      Workspaces.create_workspace(%{
        slug: "bi-ws-#{suffix}",
        name: "BI ws #{suffix}",
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

  describe "build_envelope/2 — happy path" do
    test "returns a canonical envelope and audits install_envelope_issued",
         %{workspace: workspace, binding: binding} do
      assert {:ok, envelope} = BrowserInstall.build_envelope(workspace.id, binding)

      assert envelope.binding_id == binding.id
      assert envelope.workspace_id == workspace.id
      assert envelope.chain_id == 84_532
      assert envelope.smart_account_id == "sa_wb_" <> binding.id
      assert envelope.entry_point_address =~ ~r/^0x[0-9a-fA-F]{40}$/
      assert is_binary(envelope.scope_hash)
      assert String.starts_with?(envelope.scope_hash, "sha256:")
      assert is_map(envelope.scope)
      assert is_binary(envelope.human_readable_summary)

      events = list_events(binding.id)
      assert Enum.any?(events, &(&1.event_type == "delegation.install_envelope_issued"))
    end

    test "scope_hash is deterministic across re-fetches",
         %{workspace: workspace, binding: binding} do
      {:ok, e1} = BrowserInstall.build_envelope(workspace.id, binding)
      {:ok, e2} = BrowserInstall.build_envelope(workspace.id, binding)
      assert e1.scope_hash == e2.scope_hash
    end
  end

  describe "build_envelope/2 — refused" do
    test "rejects unverified binding with :binding_not_verified",
         %{workspace: workspace, user: user, address: address} do
      pending = pending_binding(workspace.id, user.id, address)

      assert {:error, :binding_not_verified} =
               BrowserInstall.build_envelope(workspace.id, pending)
    end

    test "rejects mainnet binding with :unsupported_chain",
         %{workspace: workspace, user: user, address: address} do
      mainnet = mainnet_binding_fixture(workspace.id, user.id, address)

      assert {:error, :unsupported_chain} =
               BrowserInstall.build_envelope(workspace.id, mainnet)
    end

    test "rejects when binding belongs to a different workspace",
         %{binding: binding} do
      other_workspace_id = Ecto.UUID.generate()

      assert {:error, :workspace_mismatch} =
               BrowserInstall.build_envelope(other_workspace_id, binding)
    end

    test "rejects when runtime is globally paused",
         %{workspace: workspace, binding: binding} do
      {:ok, _} = Security.pause(:global, reason: "test pause")

      assert {:error, :runtime_paused} =
               BrowserInstall.build_envelope(workspace.id, binding)
    end
  end

  describe "record_attestation/3 — submitted" do
    test "creates a :pending delegation row + emits install_signed_by_user",
         %{workspace: workspace, binding: binding} do
      {:ok, %{state: :submitted, delegation: delegation}} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      assert delegation.state == :pending
      assert delegation.binding_id == binding.id
      assert delegation.workspace_id == workspace.id
      assert delegation.root_validator_owner == "user"
      assert delegation.install_userop_hash == @valid_userop_hash
      assert byte_size(delegation.permission_id) == 4
      assert byte_size(delegation.validation_id) == 21

      events = list_events(binding.id)
      assert Enum.any?(events, &(&1.event_type == "delegation.install_signed_by_user"))
    end

    test "submitted enqueues PollInstallReceipt in the same transaction (#500 tab-close fix)",
         %{workspace: workspace, binding: binding} do
      {:ok, %{state: :submitted, delegation: delegation}} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      [%Oban.Job{args: args}] = all_poll_jobs()
      assert args["delegation_id"] == delegation.id
      assert args["binding_id"] == binding.id
      assert args["workspace_id"] == workspace.id
      assert args["install_userop_hash"] == @valid_userop_hash
      # Deadline is a future ISO 8601 instant — we don't pin the
      # exact value (clock-driven), just that it parses.
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(args["deadline_at"])
    end

    test "is idempotent on duplicate `submitted` for same binding+userop",
         %{workspace: workspace, binding: binding} do
      params = %{
        "status" => "submitted",
        "install_userop_hash" => @valid_userop_hash,
        "permission_id" => @valid_permission_id,
        "validation_id" => @valid_validation_id
      }

      {:ok, %{delegation: first}} =
        BrowserInstall.record_attestation(workspace.id, binding, params)

      {:ok, %{delegation: second}} =
        BrowserInstall.record_attestation(workspace.id, binding, params)

      assert first.id == second.id
    end

    test "rejects malformed userop_hash with {:invalid_attestation, _}",
         %{workspace: workspace, binding: binding} do
      assert {:error, {:invalid_attestation, :install_userop_hash_invalid}} =
               BrowserInstall.record_attestation(workspace.id, binding, %{
                 "status" => "submitted",
                 "install_userop_hash" => "not-hex",
                 "permission_id" => @valid_permission_id,
                 "validation_id" => @valid_validation_id
               })
    end

    test "rejects wrong-length validation_id",
         %{workspace: workspace, binding: binding} do
      assert {:error, {:invalid_attestation, :validation_id_invalid}} =
               BrowserInstall.record_attestation(workspace.id, binding, %{
                 "status" => "submitted",
                 "install_userop_hash" => @valid_userop_hash,
                 "permission_id" => @valid_permission_id,
                 "validation_id" => "0x1234"
               })
    end
  end

  describe "record_attestation/3 — confirmed" do
    test "enqueues VerifyInstallOnchain + emits install_broadcast; row stays :pending",
         %{workspace: workspace, binding: binding} do
      {:ok, _} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      {:ok, %{state: :verifying, delegation: row}} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "confirmed",
          "install_userop_hash" => @valid_userop_hash,
          "tx_hash" => @valid_tx_hash,
          "block_number" => 1234
        })

      assert row.state == :pending,
             "row must stay :pending until on-chain verification flips to :active"

      events = list_events(binding.id)
      assert Enum.any?(events, &(&1.event_type == "delegation.install_broadcast"))

      assert [%Oban.Job{worker: "Bank.Runtime.Workers.VerifyInstallOnchain", args: args}] =
               all_verify_jobs()

      assert args["delegation_id"] == row.id
      assert args["binding_id"] == binding.id
      assert args["tx_hash"] == @valid_tx_hash
      assert args["block_number"] == 1234
    end

    test "rejects `confirmed` without a prior `submitted` row",
         %{workspace: workspace, binding: binding} do
      assert {:error, {:invalid_attestation, :no_pending_install}} =
               BrowserInstall.record_attestation(workspace.id, binding, %{
                 "status" => "confirmed",
                 "install_userop_hash" => @valid_userop_hash,
                 "tx_hash" => @valid_tx_hash,
                 "block_number" => 1234
               })
    end
  end

  describe "record_attestation/3 — failure statuses" do
    test "user_rejected emits install_failed with :user_rejected (no row needed)",
         %{workspace: workspace, binding: binding} do
      {:ok, %{state: :failed, delegation: nil}} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "user_rejected"
        })

      events = list_events(binding.id)
      failed = Enum.find(events, &(&1.event_type == "delegation.install_failed"))
      assert failed
      assert failed.after_ref["reason"] == "user_rejected"
    end

    test "bundler_rejected with a free-form `reason` collapses to `bundler_rejected`",
         %{workspace: workspace, binding: binding} do
      {:ok, _} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "bundler_rejected",
          "reason" => "raw upstream bundler error string we should NOT persist"
        })

      events = list_events(binding.id)
      failed = Enum.find(events, &(&1.event_type == "delegation.install_failed"))
      assert failed.after_ref["reason"] == "bundler_rejected"

      blob = inspect(failed.after_ref)
      refute blob =~ "raw upstream bundler error string"
    end

    test "reverted on a pending row transitions it to :install_failed",
         %{workspace: workspace, binding: binding} do
      {:ok, %{delegation: row}} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      {:ok, %{state: :failed, delegation: failed_row}} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "reverted",
          "install_userop_hash" => @valid_userop_hash,
          "reason" => "userop_reverted"
        })

      assert failed_row.id == row.id
      assert failed_row.state == :install_failed
      assert failed_row.last_reason == "install_failed:userop_reverted"
    end
  end

  describe "status/2" do
    test "returns :awaiting when no install attestation has landed",
         %{workspace: workspace, binding: binding} do
      assert %{state: :awaiting, delegation: nil} = BrowserInstall.status(workspace.id, binding)
    end

    test "returns :submitted after a submitted attestation",
         %{workspace: workspace, binding: binding} do
      {:ok, _} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      assert %{state: :submitted} = BrowserInstall.status(workspace.id, binding)
    end

    test "returns :failed after a terminal failure",
         %{workspace: workspace, binding: binding} do
      {:ok, _} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      {:ok, _} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "reverted",
          "install_userop_hash" => @valid_userop_hash,
          "reason" => "userop_reverted"
        })

      assert %{state: :failed} = BrowserInstall.status(workspace.id, binding)
    end
  end

  describe "failure_categories/0 contract" do
    test "returns the fixed allowlist named in the design" do
      assert BrowserInstall.failure_categories() == [
               :user_rejected,
               :bundler_rejected,
               :bundler_unavailable,
               :chain_id_mismatch,
               :insufficient_funds,
               :userop_reverted,
               :attestation_timeout,
               :unknown
             ]
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

  defp all_verify_jobs do
    Repo.all(from(j in Oban.Job, where: j.worker == "Bank.Runtime.Workers.VerifyInstallOnchain"))
  end

  defp all_poll_jobs do
    Repo.all(from(j in Oban.Job, where: j.worker == "Bank.Runtime.Workers.PollInstallReceipt"))
  end
end
