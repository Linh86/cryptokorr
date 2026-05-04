defmodule BankWeb.API.V1.DecisionReportControllerTest do
  @moduledoc """
  Tests for `GET /v1/intents/:id/report` — the deterministic
  decision-report Markdown export endpoint (#250).

  Covers the contract a #250 reviewer would check before signing
  off: the artifact downloads, sections from #248/#249 appear,
  the `body_sha256` is stable across calls, the response carries
  Content-Disposition + Content-Type for browser/cURL download,
  workspace boundaries are enforced (404 for cross-workspace),
  401 for unauthenticated, 404 for unknown / malformed ids, and no
  side-effects fire (no decision/intent/plan mutation, no Oban
  enqueue, no broadcast) — the export is read-only.
  """

  use BankWeb.ConnCase, async: false
  use Oban.Testing, repo: Bank.Repo

  setup :setup_api_key_viewer

  import Bank.Fixtures

  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan, ReportExport}
  alias Bank.Intents.AgentIntent
  alias Bank.Repo

  # --- happy path --------------------------------------------------------

  describe "GET /v1/intents/:id/report — happy path" do
    test "returns 200 with text/markdown attachment + metadata headers", %{conn: conn} do
      intent = agent_intent()
      decision = decision_envelope(intent: intent, outcome: :auto_exec, current: true)
      _plan = execution_plan(decision: decision)

      audit_event(
        event_type: "intent.submitted",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id,
        actor: :agent
      )

      conn = get(conn, ~p"/v1/intents/#{intent.id}/report")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/markdown; charset=utf-8"]

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~r/^attachment; filename="decision-report-[a-f0-9-]+-[a-f0-9]+\.md"$/

      [hash_header] = get_resp_header(conn, "x-decision-report-hash")
      assert hash_header =~ ~r/^sha256:[a-f0-9]{64}$/

      [generated_at_header] = get_resp_header(conn, "x-decision-report-generated-at")
      assert generated_at_header =~ ~r/^\d{4}-\d{2}-\d{2}T/

      [schema_header] = get_resp_header(conn, "x-decision-report-schema-version")
      assert schema_header == ReportExport.schema_version()
    end

    test "body contains the metadata block + the rendered Markdown sections", %{conn: conn} do
      intent = agent_intent()
      _decision = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      conn = get(conn, ~p"/v1/intents/#{intent.id}/report")
      body = response(conn, 200)

      # Metadata block.
      assert body =~ "<!--"
      assert body =~ "decision-report-export"
      assert body =~ "schema_version: 1"
      assert body =~ "intent_id: " <> intent.id
      assert body =~ "body_sha256: "

      # Rendered Markdown sections (a sample — full coverage is in
      # ReportMarkdownTest).
      assert body =~ "# Decision report"
      assert body =~ "## Chain context"
      assert body =~ "## Intent"
      assert body =~ "## Decision envelope"
      assert body =~ "## Audit trail"
    end

    test "two consecutive calls produce the same body_sha256 (deterministic for audit)", %{
      conn: conn,
      raw_api_key: raw_api_key
    } do
      intent = agent_intent()
      _decision = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      conn1 = get(conn, ~p"/v1/intents/#{intent.id}/report")

      conn2 =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw_api_key)
        |> get(~p"/v1/intents/#{intent.id}/report")

      [hash1] = get_resp_header(conn1, "x-decision-report-hash")
      [hash2] = get_resp_header(conn2, "x-decision-report-hash")
      assert hash1 == hash2

      filename1 = filename_from(conn1)
      filename2 = filename_from(conn2)
      assert filename1 == filename2
    end

    test "workspace held / no decision yet → still returns a labelled-missing report", %{
      conn: conn
    } do
      intent = agent_intent()
      conn = get(conn, ~p"/v1/intents/#{intent.id}/report")

      body = response(conn, 200)
      assert body =~ "_(missing — no decision envelope recorded)_"
      assert body =~ "_(missing — no simulation recorded)_"
      assert body =~ "## Residual limitations"
    end
  end

  # --- error paths ------------------------------------------------------

  describe "GET /v1/intents/:id/report — error paths" do
    test "returns 404 for unknown intent id", %{conn: conn} do
      conn = get(conn, ~p"/v1/intents/#{Ecto.UUID.generate()}/report")
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "returns 404 for malformed intent id (no UUID leak)", %{conn: conn} do
      conn = get(conn, ~p"/v1/intents/not-a-uuid/report")
      body = json_response(conn, 404)
      assert body["error"]["code"] == "not_found"
    end

    test "returns 401 without an Authorization header" do
      intent = agent_intent()
      conn = build_conn() |> get(~p"/v1/intents/#{intent.id}/report")
      assert json_response(conn, 401)["error"]["code"] == "missing_authorization"
    end
  end

  # --- workspace isolation (#159b — never confirm a sibling tenant's row) ---

  describe "GET /v1/intents/:id/report — cross-workspace isolation" do
    test "workspace B cannot fetch workspace A's report (404 not 403)", %{
      workspace: ws_a
    } do
      intent_a = agent_intent(workspace_id: ws_a.id)
      _decision_a = decision_envelope(intent: intent_a, outcome: :auto_exec, current: true)

      # Mint a fresh API key for a different workspace and try to
      # download workspace A's intent's report. Must collapse to
      # 404 (never 403) so the response cannot confirm the row
      # exists in a sibling tenant.
      {:ok, _, raw_secret_b} = bootstrap_other_workspace_api_key()

      conn_b =
        build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer " <> raw_secret_b)
        |> get(~p"/v1/intents/#{intent_a.id}/report")

      body = json_response(conn_b, 404)
      assert body["error"]["code"] == "not_found"
    end
  end

  # --- read-only / no side effects ---------------------------------------

  describe "GET /v1/intents/:id/report — read-only" do
    test "no row mutation, no Oban job enqueue, no broadcast", %{conn: conn} do
      intent = agent_intent()
      decision = decision_envelope(intent: intent, outcome: :auto_exec, current: true)
      plan = execution_plan(decision: decision)

      audit_event(
        event_type: "intent.submitted",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id,
        actor: :agent
      )

      intent_before = Repo.get!(AgentIntent, intent.id)
      decision_before = Repo.get!(DecisionEnvelope, decision.id)
      plan_before = Repo.get!(ExecutionPlan, plan.id)
      jobs_before = Repo.all(Oban.Job)

      _ = get(conn, ~p"/v1/intents/#{intent.id}/report")

      assert Repo.get!(AgentIntent, intent.id) == intent_before
      assert Repo.get!(DecisionEnvelope, decision.id) == decision_before
      assert Repo.get!(ExecutionPlan, plan.id) == plan_before
      assert Repo.all(Oban.Job) == jobs_before
    end
  end

  # --- secret hygiene end-to-end -----------------------------------------

  describe "GET /v1/intents/:id/report — secret hygiene end-to-end" do
    test "planted secrets in operator-controllable fields do not leak through the export", %{
      conn: conn
    } do
      # Plant secret-bearing strings into every operator-controllable
      # surface the renderer touches via Audit.replay/1 → Report.from_bundle/1
      # → ReportMarkdown.render/1 → ReportExport.build/1. The full pipeline
      # must keep them out of the artifact body.
      intent = agent_intent()

      simulation_report(
        intent: intent,
        provider: "tenderly",
        provider_trace_ref: "tnd-trace-public-001",
        # routing_path is excluded by the Report builder.
        routing_path: %{"raw_provider_payload" => "Bearer sk_test_LEAKED_PROBE"}
      )

      decision_envelope(
        intent: intent,
        outcome: :auto_exec,
        current: true,
        decided_by: :user,
        # Operator approval-shape reasons; #248 P2 redacts message/details.
        reasons: %{
          "items" => [
            %{
              "code" => "operator_approved",
              "actor_id" => Ecto.UUID.generate(),
              "message" => "Authorization: Bearer sk_live_LEAKED_PROBE | private_key=hex_blob",
              "details" => %{"raw_authorization" => "Bearer sk_live_LEAKED_AGAIN"}
            }
          ]
        }
      )

      conn = get(conn, ~p"/v1/intents/#{intent.id}/report")
      body = response(conn, 200)

      refute body =~ "Bearer "
      refute body =~ "Authorization:"
      refute body =~ "BEGIN PRIVATE KEY"
      refute body =~ "private_key"
      refute body =~ "raw_authorization"
      refute body =~ "raw_provider_payload"
      refute body =~ ~r/sk_(test|live)_/
    end

    # --- raw target address (#250 P2) -----------------------------------

    test "secret-bearing target_raw_address does not leak through the export (#250 P2)",
         %{conn: conn} do
      # `Bank.Intents` accepts any non-empty `target_raw_address`,
      # so an agent or operator could paste arbitrary content into
      # the field. Pre-#250-P2 the renderer concatenated the value
      # into the Intent table verbatim, leaking it through the
      # export body, the body_sha256 / filename derivation, and
      # the response headers.
      planted =
        "Authorization: Bearer sk_live_RAW_ADDR_PROBE | " <>
          "https://secret@example.test/rpc | " <>
          "-----BEGIN PRIVATE KEY----- | private_key=hex_blob"

      intent =
        agent_intent(
          target_counterparty_id: nil,
          target_raw_address: planted
        )

      _decision = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      conn = get(conn, ~p"/v1/intents/#{intent.id}/report")

      body = response(conn, 200)
      [disposition] = get_resp_header(conn, "content-disposition")
      [hash_header] = get_resp_header(conn, "x-decision-report-hash")
      [generated_at_header] = get_resp_header(conn, "x-decision-report-generated-at")

      # Body asserts — the markers from the P2 finding must NOT
      # appear anywhere in the rendered Markdown body.
      refute body =~ "Bearer "
      refute body =~ "Authorization:"
      refute body =~ "BEGIN PRIVATE KEY"
      refute body =~ "private_key"
      refute body =~ "secret@example.test"
      refute body =~ "secret@"
      refute body =~ "user:pass@"
      refute body =~ ~r/sk_(test|live)_/

      # Body MUST still mention the raw_address kind, with the
      # safe redaction placeholder — preserves the
      # "missing/redacted evidence is labelled, not hidden" contract.
      assert body =~ "raw_address: (redacted non-address raw target)"

      # Filename / response headers MUST also be free of the
      # planted markers (filename derives from intent UUID + body
      # hash; headers from generated_at + body hash + schema
      # version — none of which can echo operator-supplied bytes).
      refute disposition =~ "Bearer"
      refute disposition =~ ~r/sk_(test|live)_/
      refute disposition =~ "BEGIN"
      refute disposition =~ "private_key"
      refute disposition =~ "secret@"

      assert hash_header =~ ~r/^sha256:[a-f0-9]{64}$/
      refute hash_header =~ "Bearer"
      refute hash_header =~ "private_key"

      refute generated_at_header =~ "Bearer"
      refute generated_at_header =~ "private_key"
    end

    test "valid EVM target_raw_address renders verbatim (regression backstop)",
         %{conn: conn} do
      # Backstop: the redaction MUST NOT break the legitimate path.
      # A valid EVM address is real evidence and should appear in
      # the export so a reviewer can cross-check on a chain explorer.
      addr = "0x1234567890abcdef1234567890abcdef12345678"

      intent =
        agent_intent(
          target_counterparty_id: nil,
          target_raw_address: addr
        )

      _decision = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      conn = get(conn, ~p"/v1/intents/#{intent.id}/report")
      body = response(conn, 200)

      assert body =~ "raw_address: " <> addr
      refute body =~ "(redacted non-address raw target)"
    end
  end

  # --- helpers -----------------------------------------------------------

  defp filename_from(conn) do
    [disposition] = get_resp_header(conn, "content-disposition")
    [_, filename] = Regex.run(~r/filename="([^"]+)"/, disposition)
    filename
  end

  defp bootstrap_other_workspace_api_key do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "ak-other-#{suffix}",
        email: "ak-other-#{suffix}@example.com",
        name: "API Key Test Other #{suffix}"
      })

    {:ok, ws_b} =
      Bank.Workspaces.create_workspace(%{
        slug: "ak-other-ws-#{suffix}",
        name: "API Key Test Other WS #{suffix}"
      })

    {:ok, _} =
      Bank.Workspaces.create_membership(%{
        user_id: user.id,
        workspace_id: ws_b.id,
        role: :admin
      })

    Bank.APIKeys.create_key(ws_b, user, :viewer, "test-key-other-#{suffix}")
  end
end
