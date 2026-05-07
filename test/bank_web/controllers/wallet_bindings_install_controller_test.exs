defmodule BankWeb.WalletBindingsInstallControllerTest do
  @moduledoc """
  Controller tests for the browser-session-authenticated install
  endpoints (#500).

  These mirror the `/v1` API-key controller's contract:

    * `GET  /wallet_bindings/:id/install_envelope` — viewer+,
      session cookie auth.
    * `GET  /wallet_bindings/:id/install_status` — viewer+,
      session cookie auth.
    * `POST /wallet_bindings/:id/install_attestation` — operator+,
      CSRF-protected.

  Pinned invariants:

    * anonymous → 401 / CSRF refusal — no bypass;
    * authenticated viewer can GET envelope + status;
    * viewer is FORBIDDEN to POST attestation (operator+ required);
    * cross-workspace binding ids return 404;
    * `submitted` POST persists the row AND enqueues the receipt
      poller (#500's tab-close fix);
    * existing `/v1` API-key routes still work in the same suite
      (sanity);
    * full bundler URLs are NOT logged or persisted in audit
      details.
  """

  use BankWeb.ConnCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit
  alias Bank.Delegations.Delegation
  alias Bank.Repo
  alias Bank.Runtime.Workers.PollInstallReceipt
  alias Bank.WalletBindings
  alias Bank.WalletBindings.Signature

  import Ecto.Query

  @privkey <<3::256>>
  @valid_userop_hash "0x" <> String.duplicate("e", 64)
  @valid_permission_id "0xcafebabe"
  @valid_validation_id "0x02cafebabecafebabecafebabecafebabecafebabe"

  describe "auth posture — operator session" do
    setup :register_and_log_in_user
    setup :install_binding

    test "GET envelope returns 200 for an operator-session viewer",
         %{conn: conn, binding: binding} do
      conn = get(conn, ~p"/wallet_bindings/#{binding.id}/install_envelope")
      body = json_response(conn, 200)

      assert body["binding_id"] == binding.id
      assert body["chain_id"] == 84_532
      assert is_map(body["scope"])
      assert is_binary(body["scope_hash"])
    end

    test "GET status returns 200", %{conn: conn, binding: binding} do
      conn = get(conn, ~p"/wallet_bindings/#{binding.id}/install_status")
      body = json_response(conn, 200)
      assert body["state"] == "awaiting"
    end

    test "POST attestation `submitted` persists the row AND enqueues the receipt poller",
         %{conn: conn, binding: binding} do
      conn =
        post(conn, ~p"/wallet_bindings/#{binding.id}/install_attestation", %{
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

      assert_enqueued(
        worker: PollInstallReceipt,
        args: %{"delegation_id" => row.id, "install_userop_hash" => @valid_userop_hash}
      )
    end

    test "POST attestation `confirmed` enqueues VerifyInstallOnchain (browser fast-path)",
         %{conn: conn, binding: binding} do
      _ =
        post(conn, ~p"/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      conn =
        post(conn, ~p"/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "confirmed",
          "install_userop_hash" => @valid_userop_hash,
          "tx_hash" => "0x" <> String.duplicate("d", 64),
          "block_number" => 99_999
        })

      assert json_response(conn, 202)["state"] == "verifying"

      assert_enqueued(
        worker: Bank.Runtime.Workers.VerifyInstallOnchain,
        args: %{"binding_id" => binding.id, "tx_hash" => "0x" <> String.duplicate("d", 64)}
      )
    end

    test "POST attestation rejects a malformed status with 422",
         %{conn: conn, binding: binding} do
      conn =
        post(conn, ~p"/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "made_up_value"
        })

      assert json_response(conn, 422)["error"]["code"] == "invalid_status"
    end

    test "cross-workspace binding id returns 404 (no info disclosure)",
         %{conn: conn} do
      other = foreign_workspace_binding()

      assert json_response(get(conn, ~p"/wallet_bindings/#{other.id}/install_envelope"), 404)[
               "error"
             ]["code"] == "not_found"

      assert json_response(get(conn, ~p"/wallet_bindings/#{other.id}/install_status"), 404)[
               "error"
             ]["code"] == "not_found"

      assert json_response(
               post(conn, ~p"/wallet_bindings/#{other.id}/install_attestation", %{
                 "status" => "user_rejected"
               }),
               404
             )["error"]["code"] == "not_found"
    end

    test "audit rows do NOT contain the bundler URL (operator credential hygiene)",
         %{conn: conn, binding: binding} do
      _ =
        post(conn, ~p"/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      _ =
        post(conn, ~p"/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "confirmed",
          "install_userop_hash" => @valid_userop_hash,
          "tx_hash" => "0x" <> String.duplicate("c", 64),
          "block_number" => 1
        })

      events =
        Audit.list_events(%{correlation_id: binding.id}, limit: 20)
        |> Map.get(:events)

      blob = inspect(events)
      refute blob =~ "api.example.com"
      refute blob =~ "https://"
    end
  end

  describe "auth posture — viewer" do
    setup :register_and_log_in_user_as_viewer
    setup :install_binding

    test "viewer can GET envelope + status", %{conn: conn, binding: binding} do
      assert json_response(get(conn, ~p"/wallet_bindings/#{binding.id}/install_envelope"), 200)
      assert json_response(get(conn, ~p"/wallet_bindings/#{binding.id}/install_status"), 200)
    end

    test "viewer is FORBIDDEN to POST attestation (operator+ required)",
         %{conn: conn, binding: binding} do
      conn =
        post(conn, ~p"/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      assert json_response(conn, 403)["error"]["code"] == "forbidden"
    end
  end

  describe "auth posture — anonymous" do
    setup :install_anonymous_binding

    test "GET envelope returns 401 with no session cookie", %{binding: binding} do
      conn = build_conn()
      conn = get(conn, ~p"/wallet_bindings/#{binding.id}/install_envelope")
      assert json_response(conn, 401)["error"]["code"] == "unauthenticated"
    end

    test "POST attestation is rejected without a session cookie", %{binding: binding} do
      # Without the session cookie, Plug.CSRFProtection raises
      # before `require_role` can return 401. The important
      # invariant is "no anonymous attestation acceptance" — any
      # documented rejection (CSRF-raised, 401, or 403) is fine.
      conn = build_conn()

      result =
        try do
          response =
            post(conn, ~p"/wallet_bindings/#{binding.id}/install_attestation", %{
              "status" => "submitted",
              "install_userop_hash" => @valid_userop_hash,
              "permission_id" => @valid_permission_id,
              "validation_id" => @valid_validation_id
            })

          {:response, response.status}
        rescue
          err -> {:raised, err.__struct__}
        end

      case result do
        {:raised, Plug.CSRFProtection.InvalidCSRFTokenError} -> :ok
        {:response, status} when status in [401, 403, 422] -> :ok
        other -> flunk("anonymous POST was not rejected: #{inspect(other)}")
      end
    end
  end

  describe "/v1 API-key routes still work (sanity)" do
    setup :setup_api_key_operator
    setup :install_binding

    test "GET /v1/wallet_bindings/:id/install_envelope still 200", %{conn: conn, binding: binding} do
      assert json_response(get(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_envelope"), 200)
    end

    test "POST /v1/wallet_bindings/:id/install_attestation still 202",
         %{conn: conn, binding: binding} do
      conn =
        post(conn, ~p"/v1/wallet_bindings/#{binding.id}/install_attestation", %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      assert json_response(conn, 202)["state"] == "submitted"
    end
  end

  # --- helpers ----------------------------------------------------------

  defp install_binding(%{workspace: workspace, current_user: user}) do
    {:ok, pubkey} = ExSecp256k1.create_public_key(@privkey)
    {:ok, address} = Signature.address_from_pubkey(pubkey)
    binding = verified_binding_with_privkey(workspace.id, user.id, address, @privkey)
    {:ok, binding: binding}
  end

  defp install_anonymous_binding(_context) do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "anon-#{suffix}",
        email: "anon-#{suffix}@example.com",
        name: "Anon"
      })

    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "anon-ws-#{suffix}",
        name: "Anon ws #{suffix}",
        mainnet_enabled: false
      })

    {:ok, _} =
      Bank.Workspaces.create_membership(%{user_id: user.id, workspace_id: ws.id, role: :admin})

    {:ok, pubkey} = ExSecp256k1.create_public_key(@privkey)
    {:ok, address} = Signature.address_from_pubkey(pubkey)
    binding = verified_binding_with_privkey(ws.id, user.id, address, @privkey)

    {:ok, binding: binding}
  end

  defp verified_binding_with_privkey(workspace_id, user_id, address, privkey) do
    {:ok, binding} =
      WalletBindings.issue_challenge(workspace_id, user_id, %{
        address: address,
        chain_id: 84_532
      })

    digest = Signature.eip191_hash(binding.challenge_message)
    {:ok, {r, s, v}} = ExSecp256k1.sign(digest, privkey)
    sig = "0x" <> Base.encode16(r <> s <> <<v + 27>>, case: :lower)
    {:ok, verified} = WalletBindings.verify_and_bind(binding.id, sig)
    verified
  end

  defp foreign_workspace_binding do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "wb-fw-#{suffix}",
        email: "wb-fw-#{suffix}@example.com",
        name: "WB FW User"
      })

    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "wb-fw-ws-#{suffix}",
        name: "WB FW ws #{suffix}",
        mainnet_enabled: false
      })

    {:ok, _} =
      Bank.Workspaces.create_membership(%{
        user_id: user.id,
        workspace_id: ws.id,
        role: :admin
      })

    other_privkey = <<5::256>>
    {:ok, pubkey} = ExSecp256k1.create_public_key(other_privkey)
    {:ok, address} = Signature.address_from_pubkey(pubkey)
    verified_binding_with_privkey(ws.id, user.id, address, other_privkey)
  end
end
