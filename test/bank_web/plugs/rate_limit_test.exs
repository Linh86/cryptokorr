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

    # Tiny threshold so the test fires (limit + 1) requests inline.
    Application.put_env(:bank, Bank.RateLimit,
      requests_per_window: 3,
      window_seconds: 60
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
  end
end
