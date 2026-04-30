defmodule BankWeb.API.V1.PolicyControllerTest do
  use BankWeb.ConnCase, async: true

  setup :setup_api_key_admin

  import Ecto.Query, only: [from: 2]

  alias Bank.Audit.AuditEvent
  alias Bank.Fixtures
  alias Bank.Policies.PolicyRule
  alias Bank.Repo

  describe "GET /v1/policies" do
    test "lists rules with paging envelope", %{conn: conn} do
      a = Fixtures.policy_rule(rule_type: :amount_limit)
      b = Fixtures.policy_rule(rule_type: :autonomy_tier, params: %{"tier" => "auto"})

      conn = get(conn, ~p"/v1/policies")
      body = json_response(conn, 200)

      assert %{"data" => data, "page" => %{"next_cursor" => nil}} = body
      ids = Enum.map(data, & &1["id"])
      assert a.id in ids
      assert b.id in ids
    end

    test "returns a cursor when the page is full", %{conn: conn, raw_api_key: raw} do
      Fixtures.policy_rule(rule_type: :amount_limit)
      Fixtures.policy_rule(rule_type: :amount_limit, params: %{"max_per_tx" => "200"})
      Fixtures.policy_rule(rule_type: :amount_limit, params: %{"max_per_tx" => "300"})

      conn = get(conn, ~p"/v1/policies?limit=2")
      body = json_response(conn, 200)

      assert length(body["data"]) == 2
      assert is_binary(body["page"]["next_cursor"])

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/v1/policies?limit=2&cursor=#{body["page"]["next_cursor"]}")

      assert %{"data" => rest} = json_response(conn2, 200)
      assert length(rest) == 1
    end

    test "filters by state", %{conn: conn} do
      active = Fixtures.policy_rule(state: :active)
      _archived = Fixtures.policy_rule(state: :archived)

      conn = get(conn, ~p"/v1/policies?state=active")
      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      assert active.id in ids
      assert length(body["data"]) == 1
    end

    test "filters by rule_type", %{conn: conn} do
      amount = Fixtures.policy_rule(rule_type: :amount_limit)

      _tier =
        Fixtures.policy_rule(rule_type: :autonomy_tier, params: %{"tier" => "auto"})

      conn = get(conn, ~p"/v1/policies?rule_type=amount_limit")
      body = json_response(conn, 200)
      assert [%{"id" => id}] = body["data"]
      assert id == amount.id
    end

    test "422 on unknown state", %{conn: conn} do
      conn = get(conn, ~p"/v1/policies?state=made_up")
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_query"
    end

    test "422 on unknown rule_type", %{conn: conn} do
      conn = get(conn, ~p"/v1/policies?rule_type=fancy")
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_query"
    end

    test "422 on non-integer limit", %{conn: conn} do
      conn = get(conn, ~p"/v1/policies?limit=nope")
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_query"
    end
  end

  describe "POST /v1/policies" do
    test "creates an active rule with defaults and emits policy.created", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/policies", %{
          "rule_type" => "amount_limit",
          "params" => %{"max_per_tx" => "1000", "currency" => "USDC"}
        })

      body = json_response(conn, 201)
      rule = body["data"]
      assert rule["rule_type"] == "amount_limit"
      assert rule["state"] == "active"
      assert rule["version"] == 1
      assert rule["supersedes_id"] == nil
      assert rule["params"]["max_per_tx"] == "1000"

      assert %PolicyRule{} = Repo.get(PolicyRule, rule["id"])

      assert Repo.one(
               from(e in AuditEvent,
                 where:
                   e.event_type == "policy.created" and
                     e.correlation_id == ^rule["id"]
               )
             )
    end

    test "422 on missing rule_type", %{conn: conn} do
      conn = post(conn, ~p"/v1/policies", %{"params" => %{}})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
    end

    test "422 on unknown rule_type", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/policies", %{
          "rule_type" => "thought_leadership",
          "params" => %{}
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
    end

    test "422 on invalid state", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/policies", %{
          "rule_type" => "amount_limit",
          "state" => "made_up"
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
    end
  end

  describe "POST /v1/policies/:id/revise" do
    test "writes a successor, prior becomes superseded, audit emitted", %{conn: conn} do
      prior =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100", "currency" => "USDC"}
        )

      conn =
        post(conn, ~p"/v1/policies/#{prior.id}/revise", %{
          "params" => %{"max_per_tx" => "250", "currency" => "USDC"}
        })

      body = json_response(conn, 201)
      successor = body["data"]

      assert successor["version"] == 2
      assert successor["state"] == "active"
      assert successor["supersedes_id"] == prior.id
      assert successor["params"]["max_per_tx"] == "250"

      refetched = Repo.get!(PolicyRule, prior.id)
      assert refetched.state == :superseded

      assert Repo.one(
               from(e in AuditEvent,
                 where:
                   e.event_type == "policy.revised" and
                     e.correlation_id == ^successor["id"]
               )
             )
    end

    test "409 when the target rule is not active", %{conn: conn} do
      superseded = Fixtures.policy_rule(state: :superseded)

      conn =
        post(conn, ~p"/v1/policies/#{superseded.id}/revise", %{
          "params" => %{"max_per_tx" => "500"}
        })

      body = json_response(conn, 409)
      assert body["error"]["code"] == "not_active"
    end

    test "404 on unknown id", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/policies/#{Ecto.UUID.generate()}/revise", %{
          "params" => %{"max_per_tx" => "500"}
        })

      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "422 on malformed id", %{conn: conn} do
      conn = post(conn, ~p"/v1/policies/not-a-uuid/revise", %{"params" => %{}})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_id"
    end
  end

  describe "POST /v1/policies/:id/archive" do
    test "archives an active rule and emits policy.archived", %{conn: conn} do
      rule = Fixtures.policy_rule(state: :active)

      conn = post(conn, ~p"/v1/policies/#{rule.id}/archive", %{})
      body = json_response(conn, 200)

      assert body["data"]["state"] == "archived"

      assert Repo.one(
               from(e in AuditEvent,
                 where:
                   e.event_type == "policy.archived" and
                     e.correlation_id == ^rule.id
               )
             )
    end

    test "409 when the rule is not active", %{conn: conn} do
      archived = Fixtures.policy_rule(state: :archived)
      conn = post(conn, ~p"/v1/policies/#{archived.id}/archive", %{})
      body = json_response(conn, 409)
      assert body["error"]["code"] == "not_active"
    end

    test "404 on unknown id", %{conn: conn} do
      conn = post(conn, ~p"/v1/policies/#{Ecto.UUID.generate()}/archive", %{})
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "422 on malformed id", %{conn: conn} do
      conn = post(conn, ~p"/v1/policies/not-a-uuid/archive", %{})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_id"
    end
  end
end
