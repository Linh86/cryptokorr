defmodule BankWeb.DecisionReportDownloadControllerTest do
  @moduledoc """
  Browser-session-authenticated decision report download (#251 P2).

  These tests verify a logged-in browser viewer/operator can fetch
  the report Markdown from the operator console without supplying
  an `Authorization: Bearer` header — that is the bug the P2
  finding flagged on the original #251 PR.
  """

  use BankWeb.ConnCase, async: false

  setup :register_and_log_in_user
  import Bank.Fixtures

  describe "GET /audit/replay/:intent_id/report (#251 P2 browser download)" do
    test "logged-in viewer with workspace receives the Markdown attachment without an API key",
         %{conn: conn} do
      intent = agent_intent()

      conn = get(conn, ~p"/audit/replay/#{intent.id}/report")

      assert conn.status == 200

      assert {"content-type", "text/markdown; charset=utf-8"} =
               List.keyfind(conn.resp_headers, "content-type", 0)

      assert {"content-disposition", disposition} =
               List.keyfind(conn.resp_headers, "content-disposition", 0)

      assert disposition =~ ~s(attachment; filename=")
      assert disposition =~ ".md\""
      assert disposition =~ String.slice(intent.id, 0, 8)

      # Sanity: the body is non-empty Markdown carrying the
      # generated metadata block. We don't pin specific Markdown
      # text — that is covered by ReportMarkdownTest /
      # ReportExportTest. We DO pin that the report headers came
      # back, since they are the artifact's external contract.
      assert {"x-decision-report-hash", "sha256:" <> _} =
               List.keyfind(conn.resp_headers, "x-decision-report-hash", 0)

      assert {"x-decision-report-schema-version", _} =
               List.keyfind(conn.resp_headers, "x-decision-report-schema-version", 0)

      assert is_binary(conn.resp_body)
      assert byte_size(conn.resp_body) > 0
    end

    test "no Authorization header is required (browser session is sufficient)",
         %{conn: conn} do
      intent = agent_intent()

      # `register_and_log_in_user` only sets a session cookie.
      # Confirm there is no Authorization request header by
      # construction. If the route were on `/v1/...` (API-key
      # gate), this would 401.
      refute List.keyfind(conn.req_headers, "authorization", 0)

      conn = get(conn, ~p"/audit/replay/#{intent.id}/report")
      assert conn.status == 200
    end

    test "cross-workspace intent id redirects to /audit with a 'not found' flash",
         %{conn: conn} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "iso-rdl-#{System.unique_integer([:positive])}",
          name: "RDL sibling"
        })

      cp_b = counterparty(workspace_id: ws_b.id)
      intent_b = agent_intent(workspace_id: ws_b.id, target_counterparty_id: cp_b.id)

      conn = get(conn, ~p"/audit/replay/#{intent_b.id}/report")

      assert redirected_to(conn) == "/audit"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not found"
    end

    test "unknown intent id collapses to the same /audit redirect (no leak)",
         %{conn: conn} do
      missing_id = Ecto.UUID.generate()

      conn = get(conn, ~p"/audit/replay/#{missing_id}/report")

      assert redirected_to(conn) == "/audit"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not found"
    end

    test "non-uuid intent path still redirects safely instead of raising",
         %{conn: conn} do
      conn = get(conn, "/audit/replay/not-a-uuid/report")

      assert redirected_to(conn) == "/audit"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not found"
    end
  end

  describe "GET /audit/replay/:intent_id/report — anonymous / pending / unauthorized" do
    test "anonymous browser request redirects to /login" do
      intent = agent_intent()

      conn = build_conn() |> Plug.Test.init_test_session(%{})
      conn = get(conn, ~p"/audit/replay/#{intent.id}/report")

      assert redirected_to(conn) == "/login"
    end
  end
end
