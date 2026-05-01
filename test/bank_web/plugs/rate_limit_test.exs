defmodule BankWeb.Plugs.RateLimitTest do
  @moduledoc """
  Plug-level coverage for `BankWeb.Plugs.RateLimit` (#221, first
  slice).

  Each test overrides the `Bank.RateLimit` config to a low threshold
  so the limiter trips quickly without `Process.sleep/1`. Default
  test config (10_000 / 60s) is kept by the on_exit hook so other
  tests are unaffected.
  """

  use BankWeb.ConnCase, async: false

  alias Bank.APIKeys
  alias Bank.Audit
  alias Bank.RateLimit
  alias Bank.Workspaces

  setup do
    original = Application.get_env(:bank, Bank.RateLimit)

    # Merge with the env defaults so the auth-failure / workspace
    # keys stay populated; only the per-key threshold is lowered.
    Application.put_env(
      :bank,
      Bank.RateLimit,
      Keyword.merge(original,
        requests_per_window: 3,
        window_seconds: 60
      )
    )

    RateLimit.reset()

    on_exit(fn ->
      Application.put_env(:bank, Bank.RateLimit, original)
      RateLimit.reset()
    end)

    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "rl-#{suffix}",
        email: "rl-#{suffix}@example.com",
        name: "RL"
      })

    {:ok, ws} =
      Workspaces.create_workspace(%{slug: "rl-#{suffix}", name: "RL"})

    {:ok, _} =
      Workspaces.create_membership(%{user_id: user.id, workspace_id: ws.id, role: :admin})

    Process.put(:bank_test_workspace_id, ws.id)
    on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

    {:ok, key, raw} = APIKeys.create_key(ws, user, :viewer, "rl-key")

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)

    {:ok, conn: conn, workspace: ws, user: user, api_key: key, raw: raw}
  end

  describe "plug behavior end-to-end" do
    test "admits up to the limit, then 429s with Retry-After header",
         %{conn: conn} do
      # Hit a viewer-readable endpoint — counterparties index.
      for _ <- 1..3 do
        c = get(conn, ~p"/v1/counterparties")
        assert c.status == 200
      end

      c = get(conn, ~p"/v1/counterparties")
      assert c.status == 429

      assert %{"error" => %{"code" => "rate_limited"}} = json_response(c, 429)

      [retry_after] = Plug.Conn.get_resp_header(c, "retry-after")
      assert {n, ""} = Integer.parse(retry_after)
      assert n >= 1
      assert n <= 60
    end

    test "different api_keys do NOT share a bucket",
         %{conn: conn, workspace: ws, user: user} do
      # Burn the seeded key.
      for _ <- 1..3, do: get(conn, ~p"/v1/counterparties")
      assert get(conn, ~p"/v1/counterparties").status == 429

      # A different key in the same workspace gets its own budget.
      {:ok, _, raw_b} = APIKeys.create_key(ws, user, :viewer, "rl-key-b")

      conn_b =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw_b)

      assert get(conn_b, ~p"/v1/counterparties").status == 200
    end

    test "revoked key returns 401 (not 429) — auth plug wins",
         %{conn: conn, api_key: key, user: user} do
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      c = get(conn, ~p"/v1/counterparties")

      # The auth gate runs before rate limiting; revoked key cannot
      # be 429'd because it never reaches the rate-limit plug.
      assert c.status == 401
      assert %{"error" => %{"code" => "invalid_credentials"}} = json_response(c, 401)
    end

    test "missing-bearer (no current_scope) returns 401, not 429" do
      c =
        Phoenix.ConnTest.build_conn()
        |> get(~p"/v1/counterparties")

      assert c.status == 401
      assert %{"error" => %{"code" => "missing_authorization"}} = json_response(c, 401)
    end

    test "emits exactly one api_key.rate_limited audit event per window (dedupe)",
         %{conn: conn, api_key: key, workspace: ws} do
      # Burn budget.
      for _ <- 1..3, do: get(conn, ~p"/v1/counterparties")

      # Trip the limit 50 times in the same window.
      for _ <- 1..50, do: get(conn, ~p"/v1/counterparties")

      %{events: events} = Audit.list_events(%{event_type: "api_key.rate_limited"})
      events = Enum.filter(events, &(&1.subject_id == key.id))

      assert length(events) == 1, "expected exactly ONE audit row per (key, window)"

      [event] = events
      assert event.workspace_id == ws.id
      assert event.actor == :agent
      assert event.actor_id == key.id
      assert event.after_ref["limit"] == 3
      assert event.after_ref["retry_after_seconds"] >= 1
    end

    test "audit event JSON contains NO raw key, NO Authorization header, NO secret_hash",
         %{conn: conn, api_key: key, raw: raw_secret} do
      for _ <- 1..3, do: get(conn, ~p"/v1/counterparties")
      _ = get(conn, ~p"/v1/counterparties")

      %{events: events} = Audit.list_events(%{event_type: "api_key.rate_limited"})
      [event] = Enum.filter(events, &(&1.subject_id == key.id))

      sanitized = event |> Map.from_struct() |> Map.drop([:__meta__, :workspace])
      json = Jason.encode!(sanitized)

      refute json =~ raw_secret,
             "audit MUST NOT contain the raw bearer token"

      refute json =~ "secret_hash",
             "audit MUST NOT contain the field name secret_hash"

      refute json =~ "Bearer ",
             "audit MUST NOT contain the Authorization header"
    end

    test "rate-limited audit row carries scope: \"key\" by default",
         %{conn: conn, api_key: key} do
      for _ <- 1..3, do: get(conn, ~p"/v1/counterparties")
      _ = get(conn, ~p"/v1/counterparties")

      %{events: events} = Audit.list_events(%{event_type: "api_key.rate_limited"})
      [event] = Enum.filter(events, &(&1.subject_id == key.id))

      assert event.after_ref["scope"] == "key"
      assert event.after_ref["bucket_id"] == key.id
    end
  end

  # --- Per-workspace bucket (#221, third slice) -----------------------

  describe "per-workspace bucket" do
    setup do
      original = Application.get_env(:bank, Bank.RateLimit)

      # Per-key high (10) so the workspace bucket trips first
      # without per-key getting in the way.
      Application.put_env(
        :bank,
        Bank.RateLimit,
        Keyword.merge(original,
          requests_per_window: 10,
          window_seconds: 60,
          workspace_requests_per_window: 5,
          workspace_window_seconds: 60
        )
      )

      RateLimit.reset()

      on_exit(fn ->
        Application.put_env(:bank, Bank.RateLimit, original)
        RateLimit.reset()
      end)

      :ok
    end

    test "two keys in the SAME workspace share the workspace bucket",
         %{conn: conn, workspace: ws, user: user} do
      # Mint a second key in the same workspace.
      {:ok, _, raw_b} = APIKeys.create_key(ws, user, :viewer, "rl-shared-b")

      conn_b =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw_b)

      # Burn the workspace's 5-request budget across both keys
      # (3 from key A + 2 from key B = 5 total). Per-key budget is
      # 10, so neither key trips its own bucket here.
      for _ <- 1..3, do: assert(get(conn, ~p"/v1/counterparties").status == 200)
      for _ <- 1..2, do: assert(get(conn_b, ~p"/v1/counterparties").status == 200)

      # 6th request from EITHER key must 429 — workspace cap hit.
      assert get(conn, ~p"/v1/counterparties").status == 429
      assert get(conn_b, ~p"/v1/counterparties").status == 429
    end

    test "keys in DIFFERENT workspaces do NOT share the workspace bucket",
         %{conn: conn} do
      # Burn the seeded workspace's bucket.
      for _ <- 1..5, do: get(conn, ~p"/v1/counterparties")
      assert get(conn, ~p"/v1/counterparties").status == 429

      # A different workspace + key gets its own budget.
      suffix = System.unique_integer([:positive])

      {:ok, user_b} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "rl-other-#{suffix}",
          email: "rl-other-#{suffix}@example.com",
          name: "RL Other"
        })

      {:ok, ws_b} = Workspaces.create_workspace(%{slug: "rl-other-#{suffix}", name: "RL Other"})

      {:ok, _} =
        Workspaces.create_membership(%{
          user_id: user_b.id,
          workspace_id: ws_b.id,
          role: :admin
        })

      {:ok, _, raw_b} = APIKeys.create_key(ws_b, user_b, :viewer, "rl-other-key")

      conn_b =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw_b)

      assert get(conn_b, ~p"/v1/counterparties").status == 200
    end

    test "per-key 429 fires BEFORE workspace bucket increments",
         %{workspace: ws, user: user} do
      # Override config so per-key < workspace; a single noisy key
      # must trip its own bucket first and not pollute the workspace
      # bucket for quiet siblings.
      original = Application.get_env(:bank, Bank.RateLimit)

      Application.put_env(
        :bank,
        Bank.RateLimit,
        Keyword.merge(original,
          requests_per_window: 2,
          window_seconds: 60,
          workspace_requests_per_window: 5,
          workspace_window_seconds: 60
        )
      )

      RateLimit.reset()
      on_exit(fn -> Application.put_env(:bank, Bank.RateLimit, original) end)

      # Mint a noisy key + a quiet sibling.
      {:ok, _, raw_noisy} = APIKeys.create_key(ws, user, :viewer, "noisy")
      {:ok, _, raw_quiet} = APIKeys.create_key(ws, user, :viewer, "quiet")

      conn_noisy =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw_noisy)

      conn_quiet =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw_quiet)

      # Noisy key burns its budget (per-key=2) and starts 429ing.
      for _ <- 1..2, do: assert(get(conn_noisy, ~p"/v1/counterparties").status == 200)
      for _ <- 1..50, do: assert(get(conn_noisy, ~p"/v1/counterparties").status == 429)

      # The quiet sibling has full per-key budget (2) AND the
      # workspace bucket is NOT exhausted because the noisy key's
      # 429s never incremented it past 2.
      assert get(conn_quiet, ~p"/v1/counterparties").status == 200
      assert get(conn_quiet, ~p"/v1/counterparties").status == 200
    end

    test "missing/invalid auth still returns 401, never workspace 429",
         %{api_key: key, user: user} do
      # Even with the workspace bucket pre-burned, an unauth'd
      # request must 401 from VerifyAPIKey (which runs FIRST).
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      conn_revoked =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> "cb_aaaaaaaa")

      assert json_response(get(conn_revoked, ~p"/v1/counterparties"), 401)

      # Missing header: 401.
      assert json_response(get(Phoenix.ConnTest.build_conn(), ~p"/v1/counterparties"), 401)
    end

    test "workspace 429 emits a deduped api_key.rate_limited with scope: \"workspace\"",
         %{conn: conn, workspace: ws} do
      # Burn workspace budget plus a long burst of refused requests.
      for _ <- 1..5, do: get(conn, ~p"/v1/counterparties")
      for _ <- 1..50, do: get(conn, ~p"/v1/counterparties")

      %{events: events} = Audit.list_events(%{event_type: "api_key.rate_limited"})
      ws_events = Enum.filter(events, &(&1.after_ref["scope"] == "workspace"))

      assert length(ws_events) == 1, "expected exactly ONE workspace-scope audit row"

      [event] = ws_events
      assert event.workspace_id == ws.id
      assert event.after_ref["scope"] == "workspace"
      assert event.after_ref["bucket_id"] == ws.id
      assert event.after_ref["limit"] == 5
      assert event.after_ref["retry_after_seconds"] >= 1
    end

    test "workspace audit row contains NO raw bearer / Authorization / secret_hash",
         %{conn: conn, raw: raw_secret} do
      for _ <- 1..6, do: get(conn, ~p"/v1/counterparties")

      %{events: events} = Audit.list_events(%{event_type: "api_key.rate_limited"})
      ws_event = Enum.find(events, &(&1.after_ref["scope"] == "workspace"))
      assert ws_event

      sanitized = ws_event |> Map.from_struct() |> Map.drop([:__meta__, :workspace])
      json = Jason.encode!(sanitized)

      refute json =~ raw_secret
      refute json =~ "secret_hash"
      refute json =~ "Bearer "
    end

    test "successful 429 wire shape matches per-key 429",
         %{conn: conn} do
      for _ <- 1..5, do: get(conn, ~p"/v1/counterparties")

      c = get(conn, ~p"/v1/counterparties")
      assert c.status == 429
      assert %{"error" => %{"code" => "rate_limited"}} = json_response(c, 429)

      [retry_after] = Plug.Conn.get_resp_header(c, "retry-after")
      assert {n, ""} = Integer.parse(retry_after)
      assert n >= 1
      assert n <= 60
    end
  end
end
