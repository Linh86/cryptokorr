defmodule BankWeb.API.V1.ScreeningControllerTest do
  use BankWeb.ConnCase, async: true

  setup :setup_api_key_admin

  alias Bank.WalletScreening

  describe "GET /v1/screening/:chain/:address" do
    test "returns screening evidence for a matching address", %{conn: conn} do
      address = "0xScreeningEndpoint001"

      {:ok, _record} =
        WalletScreening.upsert_record(%{
          chain: "ethereum",
          address: address,
          control_tier: :hard_block,
          source: "ofac",
          source_record_id: "screening-endpoint-ofac-001",
          category: "sanctions",
          reason: "OFAC endpoint evidence",
          evidence_uri: "https://ofac.test/screening-endpoint"
        })

      conn = get(conn, ~p"/v1/screening/ethereum/#{address}")
      body = json_response(conn, 200)

      assert body["data"]["outcome"] == "block"
      assert body["data"]["winning_tier"] == "hard_block"
      assert body["data"]["winning_source"] == "ofac"
      assert [%{"control_tier" => "hard_block", "source" => "ofac"}] = body["data"]["records"]
    end

    test "returns clean evidence for an address with no records", %{conn: conn} do
      conn = get(conn, ~p"/v1/screening/ethereum/0xNoScreeningEndpointHit")
      body = json_response(conn, 200)

      assert body["data"]["outcome"] == "clean"
      assert body["data"]["winning_tier"] == nil
      assert body["data"]["records"] == []
    end
  end
end
