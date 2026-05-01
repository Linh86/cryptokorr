defmodule BankWeb.Plugs.VerifyAPIKeyTest do
  @moduledoc """
  Plug-level coverage for `BankWeb.Plugs.VerifyAPIKey` (#218b).

  The integration tests in `BankWeb.APIV1AuthRBACTest` exercise
  the wire-level 401/403/200 contract end-to-end. These tests pin
  the `current_scope` shape directly so a future regression that
  drops, mistypes, or misrouts a field is caught at the plug
  boundary, not at whichever controller happens to read it first.
  """

  use Bank.DataCase, async: false

  import Plug.Conn
  import Phoenix.ConnTest

  alias Bank.APIKeys
  alias Bank.Workspaces
  alias BankWeb.Plugs.VerifyAPIKey

  @endpoint BankWeb.Endpoint

  defp build_conn_with_bearer(token) do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("authorization", "Bearer " <> token)
  end

  defp ws_user_key(role) do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "vk-#{suffix}",
        email: "vk-#{suffix}@example.com",
        name: "VK"
      })

    {:ok, ws} = Workspaces.create_workspace(%{slug: "vk-#{suffix}", name: "VK"})

    {:ok, _} =
      Workspaces.create_membership(%{user_id: user.id, workspace_id: ws.id, role: :admin})

    {:ok, key, raw} = APIKeys.create_key(ws, user, role, "vk-#{suffix}")

    {ws, user, key, raw}
  end

  describe "current_scope identity on success" do
    test "assigns current_scope with the key's workspace and role" do
      {ws, _user, key, raw} = ws_user_key(:operator)

      conn =
        raw
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      assert %{
               user: nil,
               workspace: workspace,
               membership: nil,
               role: :operator,
               api_key: api_key
             } = conn.assigns.current_scope

      assert workspace.id == ws.id
      assert api_key.id == key.id
      refute conn.halted
    end

    test "current_scope.workspace is the FULL preloaded workspace struct, not just the id" do
      {ws, _user, _key, raw} = ws_user_key(:viewer)

      conn =
        raw
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      # Downstream code (Subagent B's audit, future workspace-scoped
      # query layers) reads `.id`, `.slug`, `.name` off the struct.
      # Pin all three so a future change that switches to a slim
      # `%{id: ...}` map regresses loudly.
      assert %Bank.Workspaces.Workspace{} = conn.assigns.current_scope.workspace
      assert conn.assigns.current_scope.workspace.id == ws.id
      assert is_binary(conn.assigns.current_scope.workspace.slug)
      assert is_binary(conn.assigns.current_scope.workspace.name)
    end

    test "two requests with two different keys see two different workspaces" do
      {ws_a, _, _, raw_a} = ws_user_key(:viewer)
      {ws_b, _, _, raw_b} = ws_user_key(:viewer)
      refute ws_a.id == ws_b.id

      conn_a =
        raw_a |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      conn_b =
        raw_b |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      assert conn_a.assigns.current_scope.workspace.id == ws_a.id
      assert conn_b.assigns.current_scope.workspace.id == ws_b.id

      # And they are NOT cross-pollinated — a regression that
      # cached the workspace lookup globally would surface here.
      refute conn_a.assigns.current_scope.workspace.id ==
               conn_b.assigns.current_scope.workspace.id
    end

    test "role assigned to the key flows through verbatim" do
      for role <- [:viewer, :operator, :admin, :owner] do
        {_, _, _, raw} = ws_user_key(role)

        conn =
          raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

        assert conn.assigns.current_scope.role == role
      end
    end
  end

  describe "no leak on failed auth" do
    test "Authorization header value is NOT echoed in the response body" do
      raw = "cb_aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee"

      conn =
        raw
        |> build_conn_with_bearer()
        |> bypass_through(BankWeb.Router, [:api, :api_authenticated])
        |> get("/v1/intents/#{Ecto.UUID.generate()}")

      body = conn.resp_body || ""

      refute body =~ raw,
             "401 response body must not echo the rejected Authorization header"

      refute body =~ "aaaaaaaa",
             "401 response body must not partially leak the bearer token"
    end
  end

  describe "last_used_at touch (#218d)" do
    test "successful auth advances last_used_at on a fresh key" do
      {_ws, _user, key, raw} = ws_user_key(:operator)
      assert is_nil(key.last_used_at)

      conn =
        raw
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      refute conn.halted

      reloaded = Bank.Repo.get!(Bank.APIKeys.APIKey, key.id)
      assert %DateTime{} = reloaded.last_used_at
    end

    test "FAILED auth (revoked key) does NOT advance last_used_at" do
      {_ws, user, key, raw} = ws_user_key(:operator)

      # Stamp a fixed prior last_used_at, then revoke. A subsequent
      # request with the revoked key MUST NOT bump the stamp — the
      # column should still equal `prior_ts` after the call.
      prior_ts = ~U[2026-04-29 12:00:00.000000Z]

      Bank.Repo.update_all(
        Ecto.Query.from(k in Bank.APIKeys.APIKey, where: k.id == ^key.id),
        set: [last_used_at: prior_ts]
      )

      {:ok, _} = Bank.APIKeys.revoke_key(key, actor: user)

      conn =
        raw
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      assert conn.halted
      assert conn.status == 401

      reloaded = Bank.Repo.get!(Bank.APIKeys.APIKey, key.id)
      assert reloaded.last_used_at == prior_ts
    end

    test "FAILED auth (no header) does NOT touch any key" do
      # Negative control: no bearer means no key lookup, no
      # last_used_at write. Pin the empty-state by checking that
      # an unrelated key still has nil last_used_at after the
      # request runs.
      {_ws, _user, key, _raw} = ws_user_key(:operator)
      assert is_nil(key.last_used_at)

      conn =
        Phoenix.ConnTest.build_conn()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      assert conn.halted

      reloaded = Bank.Repo.get!(Bank.APIKeys.APIKey, key.id)
      assert is_nil(reloaded.last_used_at)
    end
  end

  describe "halts on every failure mode" do
    test "missing header halts" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      assert conn.halted
      assert conn.status == 401
      assert Jason.decode!(conn.resp_body) == %{"error" => %{"code" => "missing_authorization"}}
    end

    test "wrong scheme halts" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Basic abc")
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      assert conn.halted
      assert conn.status == 401

      assert Jason.decode!(conn.resp_body) ==
               %{"error" => %{"code" => "invalid_authorization_scheme"}}
    end

    test "valid scheme but bogus secret collapses every internal reason to a single 401 code" do
      # Tries each verify_key/1 failure path and asserts the wire
      # response is identical — the plug must NOT distinguish
      # `:not_found` from `:hash_mismatch` from `:revoked` from
      # `:expired` to a client.
      {_ws, user, key, raw} = ws_user_key(:operator)

      # 1. unknown prefix
      conn1 =
        "cb_aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee"
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      # 2. revoked
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      conn2 =
        raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      # 3. malformed
      conn3 =
        "garbage" |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      for conn <- [conn1, conn2, conn3] do
        assert conn.halted
        assert conn.status == 401

        assert Jason.decode!(conn.resp_body) ==
                 %{"error" => %{"code" => "invalid_credentials"}}
      end
    end
  end

  # --- api_key.denied audit emission (#222) -------------------------------

  describe "api_key.denied audit event" do
    setup do
      Bank.Audit.DedupeWindow.reset()
      :ok
    end

    test "missing header → reason=missing, subject=anonymous, no workspace" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      assert conn.status == 401

      [event] = list_denied_events()

      assert event.actor == :runtime
      assert event.actor_id == nil
      assert event.subject_type == "api_key"
      assert event.subject_id == "anonymous"
      assert event.workspace_id == nil
      assert event.after_ref["reason"] == "missing"
      assert event.after_ref["prefix"] == nil
    end

    test "wrong scheme → reason=missing" do
      _conn =
        Phoenix.ConnTest.build_conn()
        |> put_req_header("authorization", "Basic abc")
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      [event] = list_denied_events()
      assert event.after_ref["reason"] == "missing"
    end

    test "garbage non-prefixed bearer → reason=malformed" do
      _conn =
        "totally-not-a-cb-key"
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      [event] = list_denied_events()
      assert event.after_ref["reason"] == "malformed"
      assert event.after_ref["prefix"] == nil
      assert event.subject_id == "anonymous"
    end

    test "unknown prefix → reason=invalid_credentials, subject=prefix:..., prefix in after_ref" do
      _conn =
        "cb_aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee"
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      [event] = list_denied_events()
      assert event.after_ref["reason"] == "invalid_credentials"
      assert event.after_ref["prefix"] == "aaaaaaaa"
      assert event.subject_id == "prefix:aaaaaaaa"
      assert event.workspace_id == nil
    end

    test "hash mismatch → reason=invalid_credentials, key id stamped, workspace stamped" do
      {ws, _user, key, _raw} = ws_user_key(:operator)

      # Same prefix as the real key, but a different secret body —
      # the hash compare fails. We construct the wire token by
      # taking the prefix and appending random base32 padding.
      forged_body = key.prefix <> String.duplicate("a", 40)

      _conn =
        ("cb_" <> forged_body)
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      [event] = list_denied_events()
      assert event.after_ref["reason"] == "invalid_credentials"
      assert event.after_ref["prefix"] == key.prefix
      assert event.subject_id == key.id
      assert event.workspace_id == ws.id
    end

    test "revoked → reason=revoked, key id stamped, workspace stamped" do
      {ws, user, key, raw} = ws_user_key(:operator)
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      _conn =
        raw
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      [event] = list_denied_events()
      assert event.after_ref["reason"] == "revoked"
      assert event.after_ref["prefix"] == key.prefix
      assert event.subject_id == key.id
      assert event.workspace_id == ws.id
    end

    test "expired → reason=expired, key id stamped, workspace stamped" do
      suffix = System.unique_integer([:positive])

      {:ok, user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "vk-exp-#{suffix}",
          email: "vk-exp-#{suffix}@example.com",
          name: "VK Exp"
        })

      {:ok, ws} = Workspaces.create_workspace(%{slug: "vk-exp-#{suffix}", name: "VK Exp"})

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws.id, role: :admin})

      past = ~U[2000-01-01 00:00:00.000000Z]
      {:ok, key, raw} = APIKeys.create_key(ws, user, :operator, "exp", expires_at: past)

      _conn =
        raw
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      [event] = list_denied_events()
      assert event.after_ref["reason"] == "expired"
      assert event.after_ref["prefix"] == key.prefix
      assert event.subject_id == key.id
      assert event.workspace_id == ws.id
    end

    test "audit event JSON contains NO raw bearer, NO secret_hash, NO Authorization header" do
      {_ws, _user, _key, raw} = ws_user_key(:operator)

      # Make a hash-mismatch attempt by mangling the bearer.
      forged = String.replace(raw, "cb_", "cb_xx", global: false)

      _conn =
        forged
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      [event] = list_denied_events()

      sanitized = event |> Map.from_struct() |> Map.drop([:__meta__, :workspace])
      json = Jason.encode!(sanitized)

      refute json =~ raw, "audit MUST NOT contain the original bearer"
      refute json =~ forged, "audit MUST NOT contain the forged bearer"
      refute json =~ "secret_hash"
      refute json =~ "Bearer "
    end

    test "deduplicates within a window — repeated rejects emit ONE row per (key, reason)" do
      {_ws, _user, _key, raw} = ws_user_key(:operator)

      # Same forged token 50× in a row should produce exactly ONE
      # api_key.denied event (per the dedupe window).
      forged = String.replace(raw, "cb_", "cb_xx", global: false)

      for _ <- 1..50 do
        forged
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))
      end

      events = list_denied_events()
      assert length(events) == 1
    end

    test "missing-header bursts collapse to one anonymous event per window" do
      for _ <- 1..50 do
        Phoenix.ConnTest.build_conn()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))
      end

      events = list_denied_events()
      assert length(events) == 1
    end

    test "different reasons against the same key emit independently" do
      {_ws, user, key, raw} = ws_user_key(:operator)

      # 1. hash mismatch (same prefix, wrong secret)
      forged = String.replace(raw, "cb_", "cb_xx", global: false)

      _ =
        forged
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      # 2. revoked
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      _ = raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      events = list_denied_events()
      reasons = events |> Enum.map(& &1.after_ref["reason"]) |> Enum.sort()

      assert "invalid_credentials" in reasons
      assert "revoked" in reasons
    end
  end

  defp list_denied_events do
    %{events: events} = Bank.Audit.list_events(%{event_type: "api_key.denied"})
    events
  end
end
