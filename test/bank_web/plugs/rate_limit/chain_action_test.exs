defmodule BankWeb.Plugs.RateLimit.ChainActionTest do
  @moduledoc """
  Coverage for `BankWeb.Plugs.RateLimit.ChainAction` (#221, fourth
  slice). Exercises the stricter per-key cap on
  `/v1/security/*` end-to-end through the router pipeline so the
  combined gate (auth → standard rate limit → role → chain-action
  cap) is verified.
  """

  use BankWeb.ConnCase, async: false

  alias Bank.APIKeys
  alias Bank.Audit
  alias Bank.RateLimit
  alias Bank.Workspaces

  setup do
    original = Application.get_env(:bank, Bank.RateLimit)

    # Tight chain-action cap; standard caps stay high so they don't
    # mask the chain-action trip.
    Application.put_env(
      :bank,
      Bank.RateLimit,
      Keyword.merge(original,
        chain_action_per_window: 2,
        chain_action_window_seconds: 60
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
        subject: "ca-#{suffix}",
        email: "ca-#{suffix}@example.com",
        name: "CA"
      })

    {:ok, ws} = Workspaces.create_workspace(%{slug: "ca-#{suffix}", name: "CA"})

    {:ok, _} =
      Workspaces.create_membership(%{user_id: user.id, workspace_id: ws.id, role: :admin})

    Process.put(:bank_test_workspace_id, ws.id)
    on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

    {:ok, key, raw} = APIKeys.create_key(ws, user, :admin, "ca-key")

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)

    {:ok, conn: conn, workspace: ws, user: user, api_key: key, raw: raw}
  end

  describe "POST /v1/security/pause cap" do
    test "admits up to chain-action limit, then 429s with Retry-After",
         %{conn: conn} do
      # 2 pause calls fit under chain_action_per_window=2.
      for _ <- 1..2 do
        c = post(conn, ~p"/v1/security/pause", %{"reason" => "smoke"})
        # Pause body returns 200 or 422 depending on prior state;
        # what we care about here is that the plug let it through.
        refute c.status == 429
      end

      c3 = post(conn, ~p"/v1/security/pause", %{"reason" => "smoke"})
      assert c3.status == 429
      assert %{"error" => %{"code" => "rate_limited"}} = json_response(c3, 429)

      [retry_after] = Plug.Conn.get_resp_header(c3, "retry-after")
      assert {n, ""} = Integer.parse(retry_after)
      assert n >= 1
      assert n <= 60
    end
  end

  describe "scope split" do
    test "non-chain-action admin routes are NOT subject to the chain-action cap",
         %{conn: conn} do
      # API key list is admin-tier but NOT chain-affecting. Even
      # firing past the chain-action cap (2/60s), this endpoint
      # must keep returning 200.
      for _ <- 1..10 do
        c = get(conn, ~p"/v1/api_keys")
        assert c.status == 200
      end
    end

    test "viewer-tier reads are not affected by chain-action cap",
         %{conn: conn} do
      for _ <- 1..10 do
        c = get(conn, ~p"/v1/counterparties")
        assert c.status == 200
      end
    end
  end

  describe "auth ordering" do
    test "missing auth still returns 401, never 429",
         %{conn: _conn} do
      anon = Phoenix.ConnTest.build_conn()
      c = post(anon, ~p"/v1/security/pause", %{"reason" => "smoke"})
      assert c.status == 401
      assert %{"error" => %{"code" => "missing_authorization"}} = json_response(c, 401)
    end

    test "non-admin (operator) returns 403, never 429",
         %{workspace: ws, user: user} do
      {:ok, _, op_raw} = APIKeys.create_key(ws, user, :operator, "op-key")

      op_conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> op_raw)

      c = post(op_conn, ~p"/v1/security/pause", %{"reason" => "smoke"})
      assert c.status == 403
      assert %{"error" => %{"code" => "insufficient_role"}} = json_response(c, 403)
    end
  end

  describe "audit event" do
    test "emits exactly ONE api_key.rate_limited row with scope: \"chain_action\" per (key, window)",
         %{conn: conn, api_key: key, workspace: ws} do
      # Burn the cap, then trip 50 more times — dedupe must
      # collapse to one row.
      for _ <- 1..2, do: post(conn, ~p"/v1/security/pause", %{"reason" => "smoke"})
      for _ <- 1..50, do: post(conn, ~p"/v1/security/pause", %{"reason" => "smoke"})

      %{events: events} = Audit.list_events(%{event_type: "api_key.rate_limited"})
      chain_events = Enum.filter(events, &(&1.after_ref["scope"] == "chain_action"))

      assert length(chain_events) == 1, "expected exactly ONE chain-action audit row"

      [event] = chain_events
      assert event.workspace_id == ws.id
      assert event.subject_id == key.id
      assert event.actor == :agent
      assert event.actor_id == key.id
      assert event.after_ref["bucket_id"] == key.id
      assert event.after_ref["limit"] == 2
      assert event.after_ref["retry_after_seconds"] >= 1
    end

    test "audit JSON contains NO raw bearer / Authorization / secret_hash",
         %{conn: conn, raw: raw_secret} do
      for _ <- 1..3, do: post(conn, ~p"/v1/security/pause", %{"reason" => "smoke"})

      %{events: events} = Audit.list_events(%{event_type: "api_key.rate_limited"})
      [event] = Enum.filter(events, &(&1.after_ref["scope"] == "chain_action"))

      sanitized = event |> Map.from_struct() |> Map.drop([:__meta__, :workspace])
      json = Jason.encode!(sanitized)

      refute json =~ raw_secret, "audit MUST NOT contain the raw bearer"
      refute json =~ "secret_hash"
      refute json =~ "Bearer "
    end
  end

  describe "config tolerance" do
    test "missing chain_action_per_window key short-circuits the cap" do
      # Drop the chain-action keys entirely — plug should treat
      # this as `:disabled` and let traffic through.
      original = Application.get_env(:bank, Bank.RateLimit)

      Application.put_env(
        :bank,
        Bank.RateLimit,
        original
        |> Keyword.delete(:chain_action_per_window)
        |> Keyword.delete(:chain_action_window_seconds)
      )

      RateLimit.reset()
      on_exit(fn -> Application.put_env(:bank, Bank.RateLimit, original) end)

      suffix = System.unique_integer([:positive])

      {:ok, user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "ca-disabled-#{suffix}",
          email: "ca-disabled-#{suffix}@example.com",
          name: "CA Disabled"
        })

      {:ok, ws} =
        Workspaces.create_workspace(%{slug: "ca-disabled-#{suffix}", name: "CA Disabled"})

      {:ok, _} =
        Workspaces.create_membership(%{
          user_id: user.id,
          workspace_id: ws.id,
          role: :admin
        })

      {:ok, _key, raw} = APIKeys.create_key(ws, user, :admin, "disabled")

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw)

      # 5 pause calls all pass — chain-action cap is disabled.
      for _ <- 1..5 do
        c = post(conn, ~p"/v1/security/pause", %{"reason" => "smoke"})
        refute c.status == 429
      end
    end
  end
end
