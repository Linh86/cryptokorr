defmodule BankWeb.API.V1.WalletBindingsInstallControllerTest do
  @moduledoc """
  Controller tests for the browser-signed install endpoints (#474):

    * `GET  /v1/wallet_bindings/:id/install_envelope`
    * `POST /v1/wallet_bindings/:id/install_attestation`
    * `GET  /v1/wallet_bindings/:id/install_status`

  Pins:

    * happy paths return 202 / 200 with the documented response
      shapes;
    * cross-workspace binding ids return 404;
    * missing / wrong-state binding refusals collapse to the
      documented 422 codes;
    * mainnet binding chain is rejected with 422 unsupported_chain;
    * a `confirmed` attestation enqueues the verifier worker but
      does NOT mark the row `:active` directly;
    * any failure status emits `delegation.install_failed` audit;
    * forged success (POSTing `confirmed` for a non-existent
      pending row) returns 422 invalid_attestation.
  """

  use BankWeb.ConnCase, async: false
  use Oban.Testing, repo: Bank.Repo

  setup :setup_api_key_operator

  alias Bank.Audit
  alias Bank.Delegations.Delegation
  alias Bank.Repo
  alias Bank.Runtime.Workers.VerifyInstallOnchain
  alias Bank.WalletBindings
  alias Bank.WalletBindings.{Signature, WalletBinding}

  import Ecto.Query

  @privkey <<1::256>>
  @valid_userop_hash "0x" <> String.duplicate("a", 64)
  @valid_tx_hash "0x" <> String.duplicate("b", 64)
  @valid_permission_id "0xdeadbeef"
  @valid_validation_id "0x02deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  setup %{workspace: workspace, current_user: user, conn: conn} do
    {:ok, pubkey} = ExSecp256k1.create_public_key(@privkey)
    {:ok, address} = Signature.address_from_pubkey(pubkey)

    binding = verified_binding(workspace.id, user.id, address)

    {:ok, conn: conn, workspace: workspace, binding: binding, address: address}
  end

  describe "GET /v1/wallet_bindings/:id/install_envelope" do
    test "returns the canonical envelope for a verified binding",
         %{conn: conn, binding: binding} do
      conn = get(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_envelope")
      body = json_response(conn, 200)

      assert body["binding_id"] == binding.id
      assert body["chain_id"] == 84_532
      assert body["smart_account_id"] == "sa_wb_" <> binding.id
      assert is_binary(body["scope_hash"]) and String.starts_with?(body["scope_hash"], "sha256:")
      assert is_map(body["scope"])
      assert is_binary(body["entry_point_address"])
      assert is_binary(body["human_readable_summary"])
    end

    test "returns 404 for a binding outside the caller's workspace",
         %{conn: conn} do
      other = foreign_workspace_binding()
      conn = get(conn, ~p"/v1/wallet_bindings/#{other.id}/install_envelope")
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "returns 404 for an unknown binding id", %{conn: conn} do
      conn = get(conn, ~p"/v1/wallet_bindings/#{Ecto.UUID.generate()}/install_envelope")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end

    test "returns 422 binding_not_verified for a pending binding",
         %{conn: conn, workspace: workspace, current_user: user, address: address} do
      pending = pending_binding(workspace.id, user.id, address)
      conn = get(conn, ~p"/v1/wallet_bindings/#{pending.id}/install_envelope")
      body = json_response(conn, 422)
      assert body["error"]["code"] == "binding_not_verified"
    end

    test "returns 422 unsupported_chain for a mainnet binding",
         %{conn: conn, workspace: workspace, current_user: user, address: address} do
      mainnet = mainnet_binding_fixture(workspace.id, user.id, address)
      conn = get(conn, ~p"/v1/wallet_bindings/#{mainnet.id}/install_envelope")
      body = json_response(conn, 422)
      assert body["error"]["code"] == "unsupported_chain"
    end
  end

  describe "POST /v1/wallet_bindings/:id/install_attestation" do
    test "submitted creates a :pending row + 202 verifying-shaped response",
         %{conn: conn, binding: binding} do
      conn =
        post(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      body = json_response(conn, 202)
      assert body["state"] == "submitted"
      assert is_binary(body["delegation_id"])

      [%Delegation{state: :pending} = row] =
        Repo.all(from d in Delegation, where: d.binding_id == ^binding.id)

      assert row.install_userop_hash == @valid_userop_hash
      assert row.root_validator_owner == "user"
    end

    test "confirmed enqueues VerifyInstallOnchain but does NOT mark :active",
         %{conn: conn, binding: binding} do
      _ =
        post(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      conn =
        post(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "confirmed",
          "install_userop_hash" => @valid_userop_hash,
          "tx_hash" => @valid_tx_hash,
          "block_number" => 99_999
        })

      body = json_response(conn, 202)
      assert body["state"] == "verifying"

      assert_enqueued(worker: VerifyInstallOnchain, args: %{"binding_id" => binding.id})

      [%Delegation{state: state}] =
        Repo.all(from d in Delegation, where: d.binding_id == ^binding.id)

      assert state == :pending,
             "row must remain :pending until the worker writes :active"
    end

    test "forged confirmed (no prior submitted) returns 422 invalid_attestation",
         %{conn: conn, binding: binding} do
      conn =
        post(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "confirmed",
          "install_userop_hash" => @valid_userop_hash,
          "tx_hash" => @valid_tx_hash,
          "block_number" => 12_345
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_attestation"
    end

    test "user_rejected emits delegation.install_failed (no row created)",
         %{conn: conn, binding: binding} do
      conn =
        post(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "user_rejected"
        })

      assert json_response(conn, 202)["state"] == "failed"

      events =
        Audit.list_events(%{correlation_id: binding.id}, limit: 20)
        |> Map.get(:events)

      assert Enum.any?(events, &(&1.event_type == "delegation.install_failed"))

      assert [] == Repo.all(from d in Delegation, where: d.binding_id == ^binding.id)
    end

    test "free-form bundler reason collapses to bundler_rejected",
         %{conn: conn, binding: binding} do
      conn =
        post(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "bundler_rejected",
          "reason" => "raw bundler error string we never persist"
        })

      assert json_response(conn, 202)["state"] == "failed"

      [event] =
        Audit.list_events(%{correlation_id: binding.id}, limit: 5)
        |> Map.get(:events)
        |> Enum.filter(&(&1.event_type == "delegation.install_failed"))

      assert event.after_ref["reason"] == "bundler_rejected"
      blob = inspect(event.after_ref)
      refute blob =~ "raw bundler error string"
    end

    test "rejects malformed status with 422", %{conn: conn, binding: binding} do
      conn =
        post(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "totally_invented"
        })

      assert json_response(conn, 422)["error"]["code"] == "invalid_status"
    end

    test "cross-workspace binding ids return 404", %{conn: conn} do
      other = foreign_workspace_binding()

      conn =
        post(conn, ~p"/v1/wallet_bindings/#{other.id}/install_attestation", %{
          "status" => "user_rejected"
        })

      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  describe "GET /v1/wallet_bindings/:id/install_status" do
    test "returns awaiting before any attestation lands",
         %{conn: conn, binding: binding} do
      conn = get(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_status")
      body = json_response(conn, 200)
      assert body["state"] == "awaiting"
      assert is_nil(body["delegation_id"])
    end

    test "returns submitted after a submitted attestation",
         %{conn: conn, binding: binding} do
      _ =
        post(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      conn = get(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_status")
      body = json_response(conn, 200)
      assert body["state"] == "submitted"
      assert is_binary(body["delegation_id"])
    end

    test "returns failed with last_reason after a terminal failure",
         %{conn: conn, binding: binding} do
      _ =
        post(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      _ =
        post(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "reverted",
          "install_userop_hash" => @valid_userop_hash,
          "reason" => "userop_reverted"
        })

      conn = get(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_status")
      body = json_response(conn, 200)
      assert body["state"] == "failed"
      assert body["last_reason"] =~ "install_failed"
    end

    test "cross-workspace binding ids return 404", %{conn: conn} do
      other = foreign_workspace_binding()
      conn = get(conn, ~p"/v1/wallet_bindings/#{other.id}/install_status")
      assert json_response(conn, 404)["error"]["code"] == "not_found"
    end
  end

  # --- helpers ----------------------------------------------------------

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

  defp foreign_workspace_binding do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "fw-#{suffix}",
        email: "fw-#{suffix}@example.com",
        name: "FW User"
      })

    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "fw-ws-#{suffix}",
        name: "FW ws #{suffix}",
        mainnet_enabled: false
      })

    {:ok, _} =
      Bank.Workspaces.create_membership(%{
        user_id: user.id,
        workspace_id: ws.id,
        role: :admin
      })

    other_privkey = <<2::256>>
    {:ok, pubkey} = ExSecp256k1.create_public_key(other_privkey)
    {:ok, address} = Signature.address_from_pubkey(pubkey)

    verified_binding_with_privkey(ws.id, user.id, address, other_privkey)
  end

  defp verified_binding_with_privkey(workspace_id, user_id, address, privkey) do
    {:ok, binding} =
      WalletBindings.issue_challenge(workspace_id, user_id, %{
        address: address,
        chain_id: 84_532
      })

    signature = sign_personal(binding.challenge_message, privkey)
    {:ok, verified} = WalletBindings.verify_and_bind(binding.id, signature)
    verified
  end

  defp sign_personal(message, privkey) do
    digest = Signature.eip191_hash(message)
    {:ok, {r, s, v}} = ExSecp256k1.sign(digest, privkey)
    "0x" <> Base.encode16(r <> s <> <<v + 27>>, case: :lower)
  end
end
