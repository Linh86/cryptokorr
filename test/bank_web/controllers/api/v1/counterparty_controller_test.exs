defmodule BankWeb.API.V1.CounterpartyControllerTest do
  use BankWeb.ConnCase, async: true

  setup :setup_api_key_admin

  import Ecto.Query, only: [from: 2]

  alias Bank.Audit.AuditEvent
  alias Bank.Counterparties.{AddressLabel, EvidenceArtifact}
  alias Bank.Fixtures
  alias Bank.Repo
  alias Bank.WalletScreening

  describe "GET /v1/counterparties" do
    test "lists counterparties with paging metadata", %{conn: conn} do
      a = Fixtures.counterparty(name: "Alpha")
      b = Fixtures.counterparty(name: "Bravo")

      conn = get(conn, ~p"/v1/counterparties")
      body = json_response(conn, 200)

      assert body["page"] == %{"next_cursor" => nil}
      ids = Enum.map(body["data"], & &1["id"])
      assert a.id in ids
      assert b.id in ids
    end

    test "filters by q + active", %{conn: conn, raw_api_key: raw} do
      _match = Fixtures.counterparty(name: "Payroll Inc")
      _miss = Fixtures.counterparty(name: "Unrelated", active: false)

      conn = get(conn, ~p"/v1/counterparties?q=payroll")
      assert %{"data" => [cp]} = json_response(conn, 200)
      assert cp["name"] == "Payroll Inc"

      conn2 =
        build_conn()
        |> put_req_header("authorization", "Bearer " <> raw)
        |> get(~p"/v1/counterparties?active=false")

      assert %{"data" => [cp]} = json_response(conn2, 200)
      assert cp["active"] == false
    end

    test "422 on invalid limit", %{conn: conn} do
      conn = get(conn, ~p"/v1/counterparties?limit=abc")
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_query"
    end

    test "422 on invalid active", %{conn: conn} do
      conn = get(conn, ~p"/v1/counterparties?active=maybe")
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_query"
    end
  end

  describe "POST /v1/counterparties" do
    test "creates and returns the preloaded counterparty + audit", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/counterparties", %{
          "name" => "Contoso",
          "ownership_context" => "vendor",
          "notes" => "net-30"
        })

      body = json_response(conn, 201)
      cp = body["data"]
      assert cp["name"] == "Contoso"
      assert cp["ownership_context"] == "vendor"
      assert cp["active"] == true
      assert cp["active_address_labels"] == []
      assert cp["effective_trust_assertions"] == []
      assert cp["evidence"] == []

      assert Repo.one(from(e in AuditEvent, where: e.event_type == "counterparty.created"))
    end

    test "422 on missing name", %{conn: conn} do
      conn = post(conn, ~p"/v1/counterparties", %{})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
      assert body["error"]["details"]["name"]
    end
  end

  describe "PATCH /v1/counterparties/:id" do
    test "updates mutable fields", %{conn: conn} do
      cp = Fixtures.counterparty()
      conn = patch(conn, ~p"/v1/counterparties/#{cp.id}", %{"name" => "Renamed"})

      body = json_response(conn, 200)
      assert body["data"]["name"] == "Renamed"
    end

    test "sets active=false to archive, emits counterparty.archived", %{conn: conn} do
      cp = Fixtures.counterparty()
      conn = patch(conn, ~p"/v1/counterparties/#{cp.id}", %{"active" => false})

      body = json_response(conn, 200)
      assert body["data"]["active"] == false
      assert Repo.one(from(e in AuditEvent, where: e.event_type == "counterparty.archived"))
    end

    test "404 for unknown id", %{conn: conn} do
      conn = patch(conn, ~p"/v1/counterparties/#{Ecto.UUID.generate()}", %{"name" => "x"})
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "422 for malformed id", %{conn: conn} do
      conn = patch(conn, ~p"/v1/counterparties/not-a-uuid", %{"name" => "x"})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_id"
    end
  end

  describe "POST /v1/counterparties/:id/addresses" do
    test "creates an address label", %{conn: conn} do
      cp = Fixtures.counterparty()

      conn =
        post(conn, ~p"/v1/counterparties/#{cp.id}/addresses", %{
          "chain" => "base",
          "address" => "0x1111",
          "alias" => "main",
          "role" => "payout",
          "verified" => true
        })

      body = json_response(conn, 201)
      assert body["data"]["chain"] == "base"
      assert body["data"]["counterparty_id"] == cp.id
      assert body["data"]["role"] == "payout"

      label_id = body["data"]["id"]
      assert %AddressLabel{} = Repo.get(AddressLabel, label_id)
    end

    test "returns screening evidence on attached address labels", %{conn: conn} do
      cp = Fixtures.counterparty()
      address = "0xCounterpartyScreening001"

      {:ok, _record} =
        WalletScreening.upsert_record(%{
          chain: "base",
          address: address,
          control_tier: :context,
          source: "graphsense",
          source_record_id: "cp-gs-001",
          category: "exchange",
          reason: "GraphSense: counterparty evidence"
        })

      conn =
        post(conn, ~p"/v1/counterparties/#{cp.id}/addresses", %{
          "chain" => "base",
          "address" => address,
          "role" => "payout"
        })

      body = json_response(conn, 201)
      evidence = body["data"]["screening_evidence"]

      assert evidence["outcome"] == "clean"
      assert evidence["winning_tier"] == "context"
      assert [%{"control_tier" => "context", "source" => "graphsense"}] = evidence["records"]
    end

    test "409 on duplicate active (chain, address)", %{conn: conn} do
      cp = Fixtures.counterparty()
      _first = Fixtures.address_label(counterparty: cp, chain: "base", address: "0xDEAD")

      conn =
        post(conn, ~p"/v1/counterparties/#{cp.id}/addresses", %{
          "chain" => "base",
          "address" => "0xDEAD"
        })

      body = json_response(conn, 409)
      assert body["error"]["code"] == "address_already_labelled"
    end

    test "409 when counterparty is archived", %{conn: conn} do
      cp = Fixtures.counterparty(active: false)

      conn =
        post(conn, ~p"/v1/counterparties/#{cp.id}/addresses", %{
          "chain" => "base",
          "address" => "0xFFFF"
        })

      body = json_response(conn, 409)
      assert body["error"]["code"] == "counterparty_archived"
    end

    test "404 on unknown counterparty", %{conn: conn} do
      conn =
        post(conn, ~p"/v1/counterparties/#{Ecto.UUID.generate()}/addresses", %{
          "chain" => "base",
          "address" => "0x1"
        })

      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end
  end

  describe "POST /v1/counterparties/:id/evidence" do
    test "pins manual evidence", %{conn: conn} do
      cp = Fixtures.counterparty()

      conn =
        post(conn, ~p"/v1/counterparties/#{cp.id}/evidence", %{
          "kind" => "user_note",
          "content_uri" => "mem://reason",
          "source" => "ops"
        })

      body = json_response(conn, 201)
      assert body["data"]["kind"] == "user_note"
      assert body["data"]["subject_type"] == "counterparty"
      assert body["data"]["subject_id"] == cp.id
      assert body["data"]["payload_hash"]

      assert %EvidenceArtifact{} = Repo.get(EvidenceArtifact, body["data"]["id"])
    end

    test "409 on archived counterparty", %{conn: conn} do
      cp = Fixtures.counterparty(active: false)

      conn =
        post(conn, ~p"/v1/counterparties/#{cp.id}/evidence", %{
          "kind" => "user_note",
          "content_uri" => "mem://x"
        })

      body = json_response(conn, 409)
      assert body["error"]["code"] == "counterparty_archived"
    end

    test "422 on invalid kind", %{conn: conn} do
      cp = Fixtures.counterparty()

      conn =
        post(conn, ~p"/v1/counterparties/#{cp.id}/evidence", %{
          "kind" => "made_up",
          "content_uri" => "mem://x"
        })

      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_body"
    end
  end
end
