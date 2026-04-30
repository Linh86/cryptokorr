defmodule BankWeb.API.V1.AddressLabelControllerTest do
  use BankWeb.ConnCase, async: true

  setup :setup_api_key_admin

  import Ecto.Query, only: [from: 2]

  alias Bank.Audit.AuditEvent
  alias Bank.Fixtures
  alias Bank.Repo

  describe "PATCH /v1/address_labels/:id" do
    test "updates alias / role / verified", %{conn: conn} do
      label = Fixtures.address_label()

      conn =
        patch(conn, ~p"/v1/address_labels/#{label.id}", %{
          "alias" => "hot wallet",
          "role" => "contract",
          "verified" => true
        })

      body = json_response(conn, 200)
      assert body["data"]["alias"] == "hot wallet"
      assert body["data"]["role"] == "contract"
      assert body["data"]["verified"] == true
      assert body["data"]["retired_at"] == nil

      assert Repo.one(from(e in AuditEvent, where: e.event_type == "address_label.updated"))
    end

    test "retired: true retires the label and emits the retirement event", %{conn: conn} do
      label = Fixtures.address_label()

      conn = patch(conn, ~p"/v1/address_labels/#{label.id}", %{"retired" => true})
      body = json_response(conn, 200)
      assert body["data"]["retired_at"]

      assert Repo.one(from(e in AuditEvent, where: e.event_type == "address_label.retired"))
    end

    test "409 when editing an already-retired label", %{conn: conn} do
      label = Fixtures.address_label(retired_at: DateTime.utc_now())

      conn = patch(conn, ~p"/v1/address_labels/#{label.id}", %{"alias" => "too late"})
      body = json_response(conn, 409)
      assert body["error"]["code"] == "already_retired"
    end

    test "404 for unknown id", %{conn: conn} do
      conn = patch(conn, ~p"/v1/address_labels/#{Ecto.UUID.generate()}", %{"alias" => "x"})
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "422 on malformed id", %{conn: conn} do
      conn = patch(conn, ~p"/v1/address_labels/not-a-uuid", %{"alias" => "x"})
      body = json_response(conn, 422)
      assert body["error"]["code"] == "invalid_id"
    end
  end
end
