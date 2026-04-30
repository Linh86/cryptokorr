defmodule BankWeb.API.V1.APIKeyControllerTest do
  @moduledoc """
  End-to-end tests for `/v1/api_keys*` (#218c).

  Covers:
    * Auth gate (401 missing/invalid; non-admin → 403).
    * Workspace isolation (admin in WS-A cannot list/delete WS-B keys).
    * Creator-privilege enforcement (admin cannot mint owner; owner can).
    * Raw secret returned exactly once and never elsewhere.
    * Audit events emitted for create + revoke (relying on #218a builders).
  """

  use BankWeb.ConnCase, async: false

  alias Bank.APIKeys
  alias Bank.APIKeys.APIKey
  alias Bank.Audit
  alias Bank.Workspaces

  # Default file-level setup mints an admin API key for the test
  # workspace. Tests that need a non-admin caller create their own
  # keys explicitly.
  setup :setup_api_key_admin

  # --- GET /v1/api_keys -----------------------------------------------------

  describe "GET /v1/api_keys" do
    test "returns the workspace's keys, newest first, no raw secret leak",
         %{conn: conn, workspace: ws, current_user: user} do
      {:ok, k1, _raw1} = APIKeys.create_key(ws, user, :viewer, "k1")
      {:ok, k2, _raw2} = APIKeys.create_key(ws, user, :operator, "k2")

      conn = get(conn, ~p"/v1/api_keys")
      assert %{"data" => entries} = json_response(conn, 200)

      ids = Enum.map(entries, & &1["id"])
      assert k1.id in ids
      assert k2.id in ids

      # Public-fields-only response — no raw_key / secret_hash anywhere.
      json = Jason.encode!(entries)
      refute json =~ "raw_key"
      refute json =~ "secret_hash"
    end

    test "is workspace-scoped: cannot see another workspace's keys",
         %{conn: conn, workspace: ws_a, current_user: user_a} do
      # Other workspace + user, NOT visible from the conn-attached one.
      {:ok, ws_b} =
        Workspaces.create_workspace(%{slug: "isolate", name: "Other"})

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user_a.id, workspace_id: ws_b.id, role: :admin})

      {:ok, key_b, _raw} = APIKeys.create_key(ws_b, user_a, :operator, "from-b")
      {:ok, key_a, _raw} = APIKeys.create_key(ws_a, user_a, :operator, "from-a")

      conn = get(conn, ~p"/v1/api_keys")
      ids = Enum.map(json_response(conn, 200)["data"], & &1["id"])

      assert key_a.id in ids
      refute key_b.id in ids
    end

    test "401 missing_authorization without bearer", %{workspace: _ws} do
      conn = build_conn() |> get(~p"/v1/api_keys")
      assert %{"error" => %{"code" => "missing_authorization"}} = json_response(conn, 401)
    end

    test "403 insufficient_role for an operator key", %{workspace: ws, current_user: user} do
      {:ok, _op_key, op_raw} = APIKeys.create_key(ws, user, :operator, "operator-caller")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> op_raw)
        |> get(~p"/v1/api_keys")

      assert %{"error" => %{"code" => "insufficient_role"}, "required_role" => "admin"} =
               json_response(conn, 403)
    end

    test "200 for an owner key (role hierarchy admits owner above admin)" do
      {:ok, ws} = Workspaces.create_workspace(%{slug: "owner-ws", name: "Owner WS"})

      {:ok, owner} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "owner-1",
          email: "owner-1@example.com",
          name: "Owner"
        })

      {:ok, _} =
        Workspaces.create_membership(%{user_id: owner.id, workspace_id: ws.id, role: :owner})

      {:ok, _key, raw} = APIKeys.create_key(ws, owner, :owner, "owner-mgmt")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/v1/api_keys")

      assert %{"data" => _} = json_response(conn, 200)
    end
  end

  # --- POST /v1/api_keys ---------------------------------------------------

  describe "POST /v1/api_keys" do
    test "201 returns the entity + raw_key once", %{conn: conn, workspace: ws} do
      conn = post(conn, ~p"/v1/api_keys", %{"role" => "operator", "name" => "ci-runner"})
      body = json_response(conn, 201)

      assert %{"data" => entity, "raw_key" => raw_key} = body
      assert entity["role"] == "operator"
      assert entity["name"] == "ci-runner"
      assert String.starts_with?(raw_key, "cb_")

      # Persisted shape matches.
      assert {:ok, key} = APIKeys.get_key(entity["id"])
      assert key.workspace_id == ws.id
      assert key.role == :operator

      # The persisted secret_hash is SHA-256 of the secret body.
      "cb_" <> body_only = raw_key
      assert key.secret_hash == :crypto.hash(:sha256, body_only)

      # Re-fetching via index does NOT return the raw key.
      conn2 =
        get(
          build_conn() |> put_req_header("authorization", get_authorization(conn)),
          ~p"/v1/api_keys"
        )

      json = Jason.encode!(json_response(conn2, 200))
      refute json =~ raw_key
    end

    test "201 emits api_key.created audit event with workspace_id stamped",
         %{conn: conn, workspace: ws} do
      conn = post(conn, ~p"/v1/api_keys", %{"role" => "viewer", "name" => "audited"})
      assert %{"data" => %{"id" => id}} = json_response(conn, 201)

      %{events: events} = Audit.list_events(%{event_type: "api_key.created"})
      [event] = Enum.filter(events, &(&1.subject_id == id))

      assert event.workspace_id == ws.id
      assert event.subject_type == "api_key"

      # Audit MUST NOT include the raw secret.
      json = Jason.encode!(event.after_ref)
      refute json =~ "cb_"
    end

    test "audit actor_id is the calling key's created_by_user_id (not request body)" do
      # Pin the documented actor_id contract: when the request is
      # authenticated by an API key (machine caller), the audit
      # `actor_id` is the human who minted the *calling* key, NOT
      # the user who created some other API key in the workspace.
      # A regression that switched to `current_scope.user.id`
      # (always nil for API auth) or to a request-body field would
      # surface as a wrong actor here.
      {:ok, ws} = Workspaces.create_workspace(%{slug: "actor-pin", name: "Actor Pin"})

      {:ok, alice} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "alice-pin",
          email: "alice-pin@example.com",
          name: "Alice"
        })

      {:ok, bob} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "bob-pin",
          email: "bob-pin@example.com",
          name: "Bob"
        })

      {:ok, _} =
        Workspaces.create_membership(%{user_id: alice.id, workspace_id: ws.id, role: :admin})

      {:ok, _} =
        Workspaces.create_membership(%{user_id: bob.id, workspace_id: ws.id, role: :admin})

      # Calling key was created by Alice. Bob exists in the same
      # workspace but is NOT the audit actor for keys minted via
      # this calling key.
      {:ok, _, alice_raw} = APIKeys.create_key(ws, alice, :admin, "alice-mgmt")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> alice_raw)
        |> post(~p"/v1/api_keys", %{"role" => "viewer", "name" => "minted-via-alice"})

      assert %{"data" => %{"id" => new_key_id}} = json_response(conn, 201)

      %{events: events} = Audit.list_events(%{event_type: "api_key.created"})
      [event] = Enum.filter(events, &(&1.subject_id == new_key_id))

      assert event.actor_id == alice.id,
             "audit actor_id must be the calling key's created_by_user_id (Alice), not Bob"

      refute event.actor_id == bob.id
    end

    test "403 forbidden_role_above_creator when admin tries to mint owner",
         %{conn: conn} do
      conn = post(conn, ~p"/v1/api_keys", %{"role" => "owner", "name" => "too-strong"})

      assert %{"error" => %{"code" => "forbidden_role_above_creator"}} =
               json_response(conn, 403)
    end

    test "owner CAN mint an owner key" do
      {:ok, ws} = Workspaces.create_workspace(%{slug: "owner-mint", name: "Owner Mint"})

      {:ok, owner} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "owner-2",
          email: "owner-2@example.com",
          name: "Owner Two"
        })

      {:ok, _} =
        Workspaces.create_membership(%{user_id: owner.id, workspace_id: ws.id, role: :owner})

      {:ok, _key, raw} = APIKeys.create_key(ws, owner, :owner, "owner-bootstrap")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> post(~p"/v1/api_keys", %{"role" => "owner", "name" => "another-owner"})

      assert %{"data" => %{"role" => "owner"}, "raw_key" => raw_key} = json_response(conn, 201)
      assert String.starts_with?(raw_key, "cb_")
    end

    test "422 invalid_role on bogus role", %{conn: conn} do
      conn = post(conn, ~p"/v1/api_keys", %{"role" => "superuser", "name" => "x"})
      assert %{"error" => %{"code" => "invalid_role"}} = json_response(conn, 422)
    end

    test "422 invalid_name on empty name", %{conn: conn} do
      conn = post(conn, ~p"/v1/api_keys", %{"role" => "viewer", "name" => ""})
      assert %{"error" => %{"code" => "invalid_name"}} = json_response(conn, 422)
    end

    test "honors :expires_at iso8601 string", %{conn: conn} do
      ttl = "2027-01-01T00:00:00Z"

      conn =
        post(conn, ~p"/v1/api_keys", %{
          "role" => "viewer",
          "name" => "ttl",
          "expires_at" => ttl
        })

      assert %{"data" => %{"expires_at" => echoed}} = json_response(conn, 201)
      assert echoed =~ "2027-01-01"
    end

    test "422 on malformed expires_at", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/api_keys", %{
          "role" => "viewer",
          "name" => "bad-ttl",
          "expires_at" => "not-a-date"
        })

      assert %{"error" => %{"code" => "invalid_expires_at"}} = json_response(conn, 422)
    end
  end

  # --- DELETE /v1/api_keys/:id --------------------------------------------

  describe "DELETE /v1/api_keys/:id" do
    test "200 revokes the key and emits api_key.revoked audit event",
         %{conn: conn, workspace: ws, current_user: user} do
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :operator, "to-revoke")

      conn = delete(conn, ~p"/v1/api_keys/#{key.id}")
      assert %{"data" => %{"id" => id, "revoked_at" => ts}} = json_response(conn, 200)

      assert id == key.id
      assert is_binary(ts)

      reloaded = Bank.Repo.get!(APIKey, key.id)
      assert %DateTime{} = reloaded.revoked_at

      %{events: events} = Audit.list_events(%{event_type: "api_key.revoked"})
      assert Enum.any?(events, &(&1.subject_id == key.id))
    end

    test "404 when the id is unknown", %{conn: conn} do
      conn = delete(conn, ~p"/v1/api_keys/#{Ecto.UUID.generate()}")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "404 (NOT 403) when admin in WS-A targets a key in WS-B (workspace isolation)",
         %{conn: conn, current_user: user_a} do
      {:ok, ws_b} = Workspaces.create_workspace(%{slug: "del-iso", name: "Other"})

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user_a.id, workspace_id: ws_b.id, role: :admin})

      {:ok, key_b, _raw} = APIKeys.create_key(ws_b, user_a, :operator, "from-b")

      conn = delete(conn, ~p"/v1/api_keys/#{key_b.id}")

      # Cross-workspace reads must be indistinguishable from
      # not-found — leaking 403 would confirm the id exists in
      # another workspace.
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)

      # The key must still be live in WS-B.
      reloaded = Bank.Repo.get!(APIKey, key_b.id)
      assert is_nil(reloaded.revoked_at)
    end

    test "is idempotent on an already-revoked key",
         %{conn: conn, workspace: ws, current_user: user} do
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :operator, "dup-revoke")
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      conn = delete(conn, ~p"/v1/api_keys/#{key.id}")
      assert %{"data" => %{"id" => id}} = json_response(conn, 200)
      assert id == key.id

      # Only ONE api_key.revoked event despite two revoke paths.
      %{events: events} = Audit.list_events(%{event_type: "api_key.revoked"})
      events = Enum.filter(events, &(&1.subject_id == key.id))
      assert length(events) == 1
    end

    test "403 insufficient_role for an operator key",
         %{workspace: ws, current_user: user} do
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :operator, "to-attempt")
      {:ok, _, op_raw} = APIKeys.create_key(ws, user, :operator, "operator-attempt")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> op_raw)
        |> delete(~p"/v1/api_keys/#{key.id}")

      assert %{"error" => %{"code" => "insufficient_role"}} = json_response(conn, 403)
    end
  end

  # --- POST /v1/api_keys/:id/rotate ---------------------------------------

  describe "POST /v1/api_keys/:id/rotate" do
    test "201 returns the new entity + raw_key (shown once); old key revoked",
         %{conn: conn, workspace: ws, current_user: user} do
      {:ok, old, _old_raw} = APIKeys.create_key(ws, user, :operator, "ci-runner")

      conn = post(conn, ~p"/v1/api_keys/#{old.id}/rotate")
      body = json_response(conn, 201)

      assert %{"data" => entity, "raw_key" => raw_key} = body
      assert entity["id"] != old.id
      assert entity["role"] == "operator"
      assert entity["name"] == "ci-runner"
      assert String.starts_with?(raw_key, "cb_")

      # Old key is now revoked in the DB.
      reloaded_old = Bank.Repo.get!(APIKey, old.id)
      assert %DateTime{} = reloaded_old.revoked_at

      # New key is in the workspace.
      assert {:ok, new} = APIKeys.get_key(entity["id"])
      assert new.workspace_id == ws.id
      assert is_nil(new.revoked_at)
    end

    test "old raw key fails auth immediately after rotate (401)",
         %{conn: conn, workspace: ws, current_user: user} do
      {:ok, old, old_raw} = APIKeys.create_key(ws, user, :operator, "no-grace")

      _ = post(conn, ~p"/v1/api_keys/#{old.id}/rotate") |> json_response(201)

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> old_raw)
        |> get(~p"/v1/api_keys")

      assert %{"error" => %{"code" => "invalid_credentials"}} = json_response(conn2, 401)
    end

    test "new raw key authenticates and can list keys",
         %{conn: conn, workspace: ws, current_user: user} do
      {:ok, old, _old_raw} = APIKeys.create_key(ws, user, :admin, "swap-mgmt")

      body =
        conn
        |> post(~p"/v1/api_keys/#{old.id}/rotate")
        |> json_response(201)

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> body["raw_key"])
        |> get(~p"/v1/api_keys")

      assert %{"data" => _} = json_response(conn2, 200)
    end

    test "201 emits api_key.rotated audit event with workspace_id, no secret leak",
         %{conn: conn, workspace: ws, current_user: user} do
      {:ok, old, _} = APIKeys.create_key(ws, user, :viewer, "audited-rotate")

      body =
        conn
        |> post(~p"/v1/api_keys/#{old.id}/rotate")
        |> json_response(201)

      new_id = body["data"]["id"]

      %{events: events} = Audit.list_events(%{event_type: "api_key.rotated"})
      [event] = Enum.filter(events, &(&1.subject_id == new_id))

      assert event.workspace_id == ws.id
      assert event.before_ref["id"] == old.id
      assert event.after_ref["id"] == new_id

      sanitized = event |> Map.from_struct() |> Map.drop([:__meta__, :workspace])
      json = Jason.encode!(sanitized)

      refute json =~ "cb_"
      refute json =~ "secret_hash"
    end

    test "404 when id is unknown", %{conn: conn} do
      conn = post(conn, ~p"/v1/api_keys/#{Ecto.UUID.generate()}/rotate")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
    end

    test "404 (NOT 403) for cross-workspace rotation",
         %{conn: conn, current_user: user_a} do
      {:ok, ws_b} = Workspaces.create_workspace(%{slug: "rot-iso", name: "Other"})

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user_a.id, workspace_id: ws_b.id, role: :admin})

      {:ok, key_b, _} = APIKeys.create_key(ws_b, user_a, :operator, "from-b")

      conn = post(conn, ~p"/v1/api_keys/#{key_b.id}/rotate")
      assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)

      # WS-B's key is still untouched.
      reloaded = Bank.Repo.get!(APIKey, key_b.id)
      assert is_nil(reloaded.revoked_at)
    end

    test "422 already_revoked when target is already revoked",
         %{conn: conn, workspace: ws, current_user: user} do
      {:ok, key, _} = APIKeys.create_key(ws, user, :operator, "stale")
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      conn = post(conn, ~p"/v1/api_keys/#{key.id}/rotate")
      assert %{"error" => %{"code" => "already_revoked"}} = json_response(conn, 422)
    end

    test "401 missing_authorization without bearer", %{workspace: ws, current_user: user} do
      {:ok, key, _} = APIKeys.create_key(ws, user, :operator, "guarded")

      conn = build_conn() |> post(~p"/v1/api_keys/#{key.id}/rotate")
      assert %{"error" => %{"code" => "missing_authorization"}} = json_response(conn, 401)
    end

    test "403 insufficient_role for an operator key",
         %{workspace: ws, current_user: user} do
      {:ok, key, _} = APIKeys.create_key(ws, user, :operator, "target")
      {:ok, _, op_raw} = APIKeys.create_key(ws, user, :operator, "operator-attempt")

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> op_raw)
        |> post(~p"/v1/api_keys/#{key.id}/rotate")

      assert %{"error" => %{"code" => "insufficient_role"}} = json_response(conn, 403)
    end

    test "403 forbidden_role_above_creator when admin tries to rotate an owner key (#220 P2)",
         %{conn: conn, workspace: ws} do
      # The default admin caller (`setup_api_key_admin`) cannot mint
      # an owner key via create. Without parity on rotate, the same
      # admin could refresh an owner credential via this path —
      # closes that escalation chain.
      {:ok, owner_user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "owner-rotate",
          email: "owner-rotate@example.com",
          name: "Owner Rotate"
        })

      {:ok, _} =
        Workspaces.create_membership(%{
          user_id: owner_user.id,
          workspace_id: ws.id,
          role: :owner
        })

      {:ok, owner_key, _} = APIKeys.create_key(ws, owner_user, :owner, "owner-creds")

      conn = post(conn, ~p"/v1/api_keys/#{owner_key.id}/rotate")
      assert %{"error" => %{"code" => "forbidden_role_above_creator"}} = json_response(conn, 403)

      # Owner key must remain active — refused rotate cannot revoke
      # the old key.
      reloaded = Bank.Repo.get!(APIKey, owner_key.id)
      assert is_nil(reloaded.revoked_at)
    end
  end

  # --- POST /v1/api_keys (with expires_at via UI / body) --------------------

  describe "POST /v1/api_keys with expires_at (UI exposure backfill, #220)" do
    test "422 invalid_expires_at when expires_at is in the past (#220 P2)",
         %{conn: conn} do
      conn =
        post(conn, ~p"/v1/api_keys", %{
          "role" => "viewer",
          "name" => "past-ttl",
          "expires_at" => "2000-01-01T00:00:00Z"
        })

      assert %{"error" => %{"code" => "invalid_expires_at"}} = json_response(conn, 422)
    end

    test "honours an empty-string expires_at as nil (UI sends '')",
         %{conn: conn} do
      conn =
        post(conn, ~p"/v1/api_keys", %{
          "role" => "viewer",
          "name" => "no-ttl",
          "expires_at" => ""
        })

      assert %{"data" => %{"expires_at" => nil}} = json_response(conn, 201)
    end
  end

  # --- helpers --------------------------------------------------------------

  defp get_authorization(conn) do
    [header] = Plug.Conn.get_req_header(conn, "authorization")
    header
  end
end
