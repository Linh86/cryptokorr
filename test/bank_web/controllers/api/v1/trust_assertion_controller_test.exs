defmodule BankWeb.API.V1.TrustAssertionControllerTest do
  use BankWeb.ConnCase, async: true

  setup :setup_api_key_admin

  import Ecto.Query, only: [from: 2]

  alias Bank.Audit.AuditEvent
  alias Bank.Counterparties.{Counterparty, TrustAssertion}
  alias Bank.Fixtures
  alias Bank.Repo

  describe "POST /v1/trust_assertions" do
    test "issues a scoped assertion and preserves the scope", %{conn: conn} do
      cp = Fixtures.counterparty(current_trust_level: :unknown)

      conn =
        post(conn, ~p"/v1/trust_assertions", %{
          "subject" => %{"type" => "counterparty", "id" => cp.id},
          "level" => "trusted",
          "scope" => %{"asset" => "USDC", "amount_ceiling" => "500"},
          "rationale" => "vendor pilot"
        })

      body = json_response(conn, 201)
      assert body["data"]["level"] == "trusted"
      assert body["data"]["scope"] == %{"asset" => "USDC", "amount_ceiling" => "500"}
      # Scoped `trusted` is NOT coarse.
      assert body["data"]["coarse"] == false

      # And the broad cache should be untouched.
      assert Repo.get!(Counterparty, cp.id).current_trust_level == :unknown
    end

    test "unscoped `trusted` is flagged coarse and refreshes the cache", %{conn: conn} do
      cp = Fixtures.counterparty(current_trust_level: :unknown)

      conn =
        post(conn, ~p"/v1/trust_assertions", %{
          "subject" => %{"type" => "counterparty", "id" => cp.id},
          "level" => "trusted",
          "rationale" => "owner"
        })

      body = json_response(conn, 201)
      assert body["data"]["coarse"] == true
      assert body["data"]["scope"] == %{}

      assert Repo.get!(Counterparty, cp.id).current_trust_level == :trusted
      assert Repo.one(from(e in AuditEvent, where: e.event_type == "trust_assertion.issued"))
    end

    test "404 for unknown subject", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/trust_assertions", %{
          "subject" => %{"type" => "counterparty", "id" => Ecto.UUID.generate()},
          "level" => "sensitive"
        })

      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "422 for missing level", %{conn: conn} do
      cp = Fixtures.counterparty()

      conn =
        post(conn, ~p"/v1/trust_assertions", %{
          "subject" => %{"type" => "counterparty", "id" => cp.id}
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
      assert body["error"]["hint"] =~ "level"
    end

    test "422 for malformed subject", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/trust_assertions", %{
          "subject" => %{"type" => "bogus", "id" => Ecto.UUID.generate()},
          "level" => "trusted"
        })

      body = json_response(conn, 422)
      assert body["error"]["hint"] =~ "subject.type"
    end

    test "422 for malformed scope", %{conn: conn} do
      cp = Fixtures.counterparty()

      conn =
        post(conn, ~p"/v1/trust_assertions", %{
          "subject" => %{"type" => "counterparty", "id" => cp.id},
          "level" => "trusted",
          "scope" => "nope"
        })

      body = json_response(conn, 422)
      assert body["error"]["hint"] =~ "scope"
    end

    test "new broad assertion supersedes prior assertion on the same subject", %{conn: conn} do
      cp = Fixtures.counterparty()
      prior = Fixtures.trust_assertion(subject: cp, level: :trusted)

      _conn =
        post(conn, ~p"/v1/trust_assertions", %{
          "subject" => %{"type" => "counterparty", "id" => cp.id},
          "level" => "sensitive"
        })

      assert %TrustAssertion{superseded_at: %DateTime{}} = Repo.get!(TrustAssertion, prior.id)
    end
  end
end
