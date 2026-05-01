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

  defp list_auth_failure_limited_events do
    %{events: events} = Bank.Audit.list_events(%{event_type: "api_key.auth_failure_limited"})
    events
  end

  # --- Auth-failure lockout (#221, second slice) -------------------

  describe "auth-failure lockout" do
    setup do
      original = Application.get_env(:bank, Bank.RateLimit)

      # Tiny threshold so the test trips quickly without sleeping.
      Application.put_env(:bank, Bank.RateLimit,
        requests_per_window: 10_000,
        window_seconds: 60,
        auth_failure_per_window: 3,
        auth_failure_window_seconds: 300,
        auth_failure_enabled?: true
      )

      Bank.RateLimit.reset()
      Bank.Audit.DedupeWindow.reset()

      on_exit(fn ->
        Application.put_env(:bank, Bank.RateLimit, original)
        Bank.RateLimit.reset()
        Bank.Audit.DedupeWindow.reset()
      end)

      :ok
    end

    test "repeated bad secret for the same key → eventually 429 with Retry-After" do
      {_ws, _user, key, raw} = ws_user_key(:operator)

      # Forge a hash mismatch by swapping the suffix while keeping
      # the prefix valid so the row IS found and bucket-by-id
      # applies.
      forged_body = key.prefix <> String.duplicate("a", 40)
      forged = "cb_" <> forged_body

      # Attempts 1..3 are under the threshold of 3 → 401.
      for _ <- 1..3 do
        c = forged |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
        assert c.status == 401
      end

      # Attempt 4 trips the bucket → 429 with Retry-After.
      conn4 =
        forged |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      assert conn4.status == 429
      assert %{"error" => %{"code" => "rate_limited"}} = Jason.decode!(conn4.resp_body)

      [retry_after] = Plug.Conn.get_resp_header(conn4, "retry-after")
      assert {n, ""} = Integer.parse(retry_after)
      assert n >= 1
      assert n <= 300
    end

    test "different prefix is NOT affected by another prefix's lockout" do
      {ws_a, user_a, key_a, _raw_a} = ws_user_key(:operator)

      # Burn key_a's bucket.
      forged_a = "cb_" <> key_a.prefix <> String.duplicate("a", 40)

      for _ <- 1..4 do
        forged_a |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
      end

      # A different key in the same workspace gets its own bucket.
      {:ok, _, raw_b} = APIKeys.create_key(ws_a, user_a, :operator, "vk-b")

      # Successful auth on key_b: not affected by key_a's lockout.
      conn_ok =
        raw_b |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      refute conn_ok.halted
      assert is_map(conn_ok.assigns[:current_scope])
    end

    test "successful key NOT counted as a failure (no lockout from clean traffic)" do
      {_ws, _user, _key, raw} = ws_user_key(:operator)

      # Hammer 10 successful auths against the same key.
      for _ <- 1..10 do
        c = raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
        refute c.halted
      end

      # Bucket should remain empty — nothing to refuse, nothing
      # audited as auth_failure_limited.
      assert list_auth_failure_limited_events() == []
    end

    test "malformed bursts trip the IP bucket → 429" do
      # 4 garbage attempts from the same caller (test conn defaults
      # to 127.0.0.1) trip the IP-bucket lockout.
      for _ <- 1..3 do
        c =
          "garbage"
          |> build_conn_with_bearer()
          |> VerifyAPIKey.call(VerifyAPIKey.init([]))

        assert c.status == 401
      end

      conn4 =
        "garbage"
        |> build_conn_with_bearer()
        |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      assert conn4.status == 429
    end

    test "missing-header attempts are NOT subject to lockout" do
      # Even after 100 missing-header rejects, the response stays
      # 401 — this branch deliberately skips the lockout (random
      # crawlers / health checks / browsers should never lock out
      # an IP).
      for _ <- 1..100 do
        c = Phoenix.ConnTest.build_conn() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
        assert c.status == 401
        assert %{"error" => %{"code" => "missing_authorization"}} = Jason.decode!(c.resp_body)
      end

      # No auth_failure_limited events emitted.
      assert list_auth_failure_limited_events() == []
    end

    test "wrong-scheme attempts are NOT subject to lockout" do
      # Sibling branch to the missing-header path: a non-Bearer
      # Authorization header (Basic, Digest, opaque garbage)
      # short-circuits at `extract_bearer/1` and bypasses the
      # auth-failure bucket. Same false-positive rationale —
      # password managers, legacy clients, and browsers
      # occasionally emit non-Bearer headers and must not trigger
      # IP-level lockouts.
      for _ <- 1..100 do
        c =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("authorization", "Basic dXNlcjpwYXNz")
          |> VerifyAPIKey.call(VerifyAPIKey.init([]))

        assert c.status == 401

        assert %{"error" => %{"code" => "invalid_authorization_scheme"}} =
                 Jason.decode!(c.resp_body)
      end

      # No auth_failure_limited events emitted — wrong-scheme
      # attempts never enter the lockout path.
      assert list_auth_failure_limited_events() == []
    end

    test "revoked attempts count as auth failures" do
      {_ws, user, key, raw} = ws_user_key(:operator)
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      for _ <- 1..3 do
        c = raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
        assert c.status == 401
      end

      conn4 = raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
      assert conn4.status == 429
    end

    test "expired attempts count as auth failures" do
      suffix = System.unique_integer([:positive])

      {:ok, user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "afl-exp-#{suffix}",
          email: "afl-exp-#{suffix}@example.com",
          name: "AFL Exp"
        })

      {:ok, ws} = Workspaces.create_workspace(%{slug: "afl-exp-#{suffix}", name: "AFL"})

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws.id, role: :admin})

      past = ~U[2000-01-01 00:00:00.000000Z]
      {:ok, _key, raw} = APIKeys.create_key(ws, user, :operator, "exp", expires_at: past)

      for _ <- 1..3 do
        c = raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
        assert c.status == 401
      end

      conn4 = raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
      assert conn4.status == 429
    end

    test "emits exactly one api_key.auth_failure_limited per (bucket, lockout-window)" do
      {_ws, _user, key, _raw} = ws_user_key(:operator)
      forged = "cb_" <> key.prefix <> String.duplicate("a", 40)

      # 50 attempts in the same window → exactly one
      # auth_failure_limited row (the rest are 429-deduped).
      for _ <- 1..50 do
        forged |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
      end

      events = list_auth_failure_limited_events()

      assert length(events) == 1
      [event] = events
      assert event.actor == :runtime
      assert event.subject_id == key.id
      assert event.workspace_id == key.workspace_id
      assert event.after_ref["bucket_kind"] == "id"
      assert event.after_ref["bucket_id"] == key.id
      assert event.after_ref["limit"] == 3
      assert event.after_ref["retry_after_seconds"] >= 1
    end

    test "audit JSON contains NO raw bearer, NO Authorization header, NO secret_hash" do
      {_ws, _user, key, _raw} = ws_user_key(:operator)
      forged = "cb_" <> key.prefix <> String.duplicate("a", 40)

      for _ <- 1..4 do
        forged |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
      end

      [event] = list_auth_failure_limited_events()

      sanitized = event |> Map.from_struct() |> Map.drop([:__meta__, :workspace])
      json = Jason.encode!(sanitized)

      refute json =~ forged, "audit MUST NOT contain the forged bearer"
      refute json =~ "secret_hash"
      refute json =~ "Bearer "
    end

    test "denied + auth_failure_limited dedupe independently" do
      {_ws, _user, key, _raw} = ws_user_key(:operator)
      forged = "cb_" <> key.prefix <> String.duplicate("a", 40)

      # 4 attempts in the same minute → 1 denied row (60s dedupe)
      # + 1 auth_failure_limited row (300s dedupe). Even though
      # only attempts 4+ are 429, the denied event for the SAME
      # (key, reason) is already deduped from attempt 1.
      for _ <- 1..4 do
        forged |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
      end

      assert length(list_denied_events()) == 1
      assert length(list_auth_failure_limited_events()) == 1
    end

    test "lockout disabled via config short-circuits" do
      Application.put_env(:bank, Bank.RateLimit,
        requests_per_window: 10_000,
        window_seconds: 60,
        auth_failure_per_window: 3,
        auth_failure_window_seconds: 300,
        auth_failure_enabled?: false
      )

      {_ws, _user, key, _raw} = ws_user_key(:operator)
      forged = "cb_" <> key.prefix <> String.duplicate("a", 40)

      # 10 forged attempts — all stay at 401, never escalate to 429.
      for _ <- 1..10 do
        c = forged |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
        assert c.status == 401
      end

      assert list_auth_failure_limited_events() == []
    end
  end

  # --- Workspace agent-key pause (#231-a) ---------------------------------

  describe "workspace pause" do
    setup do
      Bank.Audit.DedupeWindow.reset()
      Bank.RateLimit.reset()
      :ok
    end

    test "paused workspace key returns 401 invalid_credentials (same wire as revoked)" do
      {ws, user, _key, raw} = ws_user_key(:operator)
      {:ok, :paused, _} = APIKeys.pause_workspace(ws, user)

      conn = raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      assert conn.halted
      assert conn.status == 401
      assert %{"error" => %{"code" => "invalid_credentials"}} = Jason.decode!(conn.resp_body)
    end

    test "unpaused workspace key continues to authenticate" do
      {_ws, _user, _key, raw} = ws_user_key(:operator)

      conn = raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      refute conn.halted
      assert is_map(conn.assigns[:current_scope])
    end

    test "pausing workspace A does not block workspace B's keys" do
      {ws_a, user_a, _key_a, _raw_a} = ws_user_key(:operator)
      {_ws_b, _user_b, _key_b, raw_b} = ws_user_key(:operator)

      {:ok, :paused, _} = APIKeys.pause_workspace(ws_a, user_a)

      conn = raw_b |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      refute conn.halted
      assert is_map(conn.assigns[:current_scope])
    end

    test "paused rejection emits api_key.denied with reason 'workspace_paused'" do
      {ws, user, key, raw} = ws_user_key(:operator)
      {:ok, :paused, _} = APIKeys.pause_workspace(ws, user)

      _conn = raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      [event] = list_denied_events()

      assert event.after_ref["reason"] == "workspace_paused"
      assert event.subject_id == key.id
      assert event.workspace_id == ws.id
    end

    test "paused rejection does NOT advance last_used_at" do
      {ws, user, key, raw} = ws_user_key(:operator)
      {:ok, :paused, _} = APIKeys.pause_workspace(ws, user)

      assert is_nil(key.last_used_at)
      _conn = raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))

      reloaded = Bank.Repo.get!(Bank.APIKeys.APIKey, key.id)
      assert is_nil(reloaded.last_used_at), "last_used_at must NOT advance on paused rejection"
    end

    test "paused rejection does NOT increment the auth-failure bucket" do
      original = Application.get_env(:bank, Bank.RateLimit)

      Application.put_env(
        :bank,
        Bank.RateLimit,
        Keyword.merge(original,
          auth_failure_per_window: 3,
          auth_failure_window_seconds: 300,
          auth_failure_enabled?: true
        )
      )

      Bank.RateLimit.reset()
      on_exit(fn -> Application.put_env(:bank, Bank.RateLimit, original) end)

      {ws, user, _key, raw} = ws_user_key(:operator)
      {:ok, :paused, _} = APIKeys.pause_workspace(ws, user)

      # 10 paused-rejection attempts must NEVER escalate to 429 —
      # workspace pause is operator overlay, not auth pressure.
      for _ <- 1..10 do
        conn = raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
        assert conn.status == 401
      end

      assert list_auth_failure_limited_events() == []
    end

    test "resume restores authentication" do
      {ws, user, _key, raw} = ws_user_key(:operator)
      {:ok, :paused, paused} = APIKeys.pause_workspace(ws, user)
      conn1 = raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
      assert conn1.status == 401

      {:ok, :resumed, _} = APIKeys.resume_workspace(paused, user)

      conn2 = raw |> build_conn_with_bearer() |> VerifyAPIKey.call(VerifyAPIKey.init([]))
      refute conn2.halted
      assert is_map(conn2.assigns[:current_scope])
    end
  end
end
