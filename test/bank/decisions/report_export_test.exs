defmodule Bank.Decisions.ReportExportTest do
  @moduledoc """
  Tests for `Bank.Decisions.ReportExport.build/2` — the deterministic
  Markdown decision-report export artifact builder (#250).

  These tests operate on hand-built `%Report{}` structs so the
  builder is exercised in isolation. The Report data model is
  covered by `Bank.Decisions.ReportTest` (#248), and the Markdown
  renderer it composes by `Bank.Decisions.ReportMarkdownTest` (#249).

  Coverage:

    * artifact shape (filename + body + body_hash + generated_at +
      content_type + schema_version);
    * filename safety (only `[a-z0-9.\\-]+\\.md`, no operator-supplied
      content, no path separators);
    * metadata-block determinism (byte-stable for the same
      `(report, generated_at)` pair);
    * `body_sha256` is the SHA-256 of the rendered Markdown body
      (NOT the wrapped artifact) — so two artifacts produced at
      different generated-at instants for the same report carry
      identical hashes;
    * the Markdown body below the metadata block equals
      `Bank.Decisions.ReportMarkdown.render/1`'s output verbatim;
    * secret hygiene defence-in-depth — the builder cannot see any
      field the Report struct does not expose, so all the markers
      from #248 P2 / #249 P2 are absent from the artifact body;
    * unsafe id input cannot inject a path separator / quote /
      shell metacharacter into the filename.
  """

  use ExUnit.Case, async: true

  alias Bank.Decisions.{Report, ReportExport, ReportMarkdown}

  # --- fixtures ----------------------------------------------------------

  defp report_fixture(overrides \\ %{}) do
    base = %Report{
      version: "1",
      generated_from: %{
        intent_id: "11111111-2222-3333-4444-555555555555",
        workspace_id: "ws-77777777"
      },
      intent: %{
        id: "11111111-2222-3333-4444-555555555555",
        kind: "transfer",
        asset: "usdc",
        chain: "base-sepolia",
        amount: "9.95",
        state: "submitted",
        idempotency_key: "idem-key-fixed-1",
        submitted_at: "2026-04-15T12:00:00Z",
        target: %{
          kind: "counterparty",
          counterparty_id: "cp-aaaaaaaa-1111",
          address_label_id: "lbl-bbbbbbbb-2222"
        }
      },
      actor_source: %{
        agent_id: "agent-fixed-001",
        source: "agent",
        workspace_id: "ws-77777777"
      },
      trust_assessment: %{available: false, reason: "no trust assessment recorded"},
      simulation: %{available: false, reason: "no simulation recorded"},
      screening_evidence: %{available: false, reason: "no screening evidence recorded"},
      policy_snapshot: %{available: false, reason: "no policy snapshot captured"},
      decision_envelope: %{available: false, reason: "no decision envelope recorded"},
      approval: %{available: false, reason: "no approval/rejection recorded"},
      execution_plan: %{available: false, reason: "no execution plan recorded"},
      stablecoin_routes: [],
      flags: %{
        chain: "base-sepolia",
        mainnet?: false,
        testnet?: true,
        live?: false,
        stub?: true
      },
      residual_limitations: [],
      audit_trail: []
    }

    Map.merge(base, overrides)
  end

  defp fixed_at, do: ~U[2026-04-15 12:00:00.123456Z]

  # --- artifact shape ----------------------------------------------------

  describe "build/2 — artifact shape" do
    test "returns a map with the documented keys + media type" do
      artifact = ReportExport.build(report_fixture(), generated_at: fixed_at())

      assert is_binary(artifact.filename)
      assert is_binary(artifact.body)
      assert is_binary(artifact.body_hash)
      assert is_binary(artifact.generated_at)
      assert artifact.content_type == "text/markdown; charset=utf-8"
      assert artifact.schema_version == "1"
      assert artifact.content_type == ReportExport.media_type()
      assert artifact.schema_version == ReportExport.schema_version()
    end

    test "filename is restricted to safe characters and ends in .md" do
      artifact = ReportExport.build(report_fixture(), generated_at: fixed_at())

      # Only lowercase hex, dashes, and a single .md suffix.
      assert artifact.filename =~ ~r/^decision-report-[a-f0-9]+-[a-f0-9]+\.md$/

      # No path separators, quotes, or shell metacharacters can
      # ever appear from the filename builder.
      refute artifact.filename =~ ~r/[\/\\\s"';<>&|*?]/
    end

    test "filename includes both the intent id slice and the body-hash slice" do
      artifact = ReportExport.build(report_fixture(), generated_at: fixed_at())

      assert artifact.filename =~ "11111111"
      assert artifact.filename =~ String.slice(artifact.body_hash, 0, 12)
    end

    test "body_hash is the SHA-256 of the rendered Markdown body, not of the wrapped artifact" do
      report = report_fixture()
      md_body = ReportMarkdown.render(report)
      expected = :crypto.hash(:sha256, md_body) |> Base.encode16(case: :lower)

      artifact = ReportExport.build(report, generated_at: fixed_at())
      assert artifact.body_hash == expected
    end

    test "the artifact body contains the metadata header followed by the rendered Markdown" do
      report = report_fixture()
      md_body = ReportMarkdown.render(report)

      artifact = ReportExport.build(report, generated_at: fixed_at())

      assert String.starts_with?(artifact.body, "<!--")
      assert String.contains?(artifact.body, "decision-report-export")
      assert String.contains?(artifact.body, "schema_version: 1")
      assert String.contains?(artifact.body, "report_version: 1")
      assert String.contains?(artifact.body, "intent_id: 11111111-2222-3333-4444-555555555555")
      assert String.contains?(artifact.body, "workspace_id: ws-77777777")
      assert String.contains?(artifact.body, "generated_at: 2026-04-15T12:00:00.123456Z")
      assert String.contains?(artifact.body, "body_sha256: " <> artifact.body_hash)

      # And the Markdown body appears verbatim after the close of
      # the metadata comment.
      assert String.ends_with?(artifact.body, md_body)
    end
  end

  # --- determinism --------------------------------------------------------

  describe "build/2 — determinism" do
    test "same (report, generated_at) → byte-identical artifact body" do
      report = report_fixture()
      a = ReportExport.build(report, generated_at: fixed_at())
      b = ReportExport.build(report, generated_at: fixed_at())

      assert a == b
      assert a.body == b.body
      assert a.body_hash == b.body_hash
      assert a.filename == b.filename
    end

    test "body_hash + filename are identical even when generated_at differs (audit-cross-check)" do
      report = report_fixture()
      a = ReportExport.build(report, generated_at: ~U[2026-04-15 00:00:00Z])
      b = ReportExport.build(report, generated_at: ~U[2099-12-31 23:59:59Z])

      assert a.body_hash == b.body_hash, "body hash must depend only on the report content"
      assert a.filename == b.filename, "filename must depend only on the report content"

      # The wrapped body differs only in the generated_at line.
      refute a.body == b.body
    end

    test "accepts ISO8601 binary as generated_at" do
      report = report_fixture()
      a = ReportExport.build(report, generated_at: "2026-04-15T12:00:00Z")
      assert String.contains?(a.body, "generated_at: 2026-04-15T12:00:00Z")
    end

    test "omitting :generated_at falls back to DateTime.utc_now/0 (still well-formed)" do
      report = report_fixture()
      a = ReportExport.build(report)

      assert a.generated_at =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}.*Z$/

      # The Markdown body itself is independent of generated_at,
      # so its hash is still deterministic.
      assert a.body_hash == ReportExport.build(report).body_hash
    end
  end

  # --- secret hygiene -----------------------------------------------------

  describe "build/2 — secret hygiene (defence in depth)" do
    test "metadata block contains no operator-supplied free-text fields" do
      # Build a report whose decision_envelope has the post-#360
      # redacted reason shape — `code` + `actor_id` + `redacted: true`.
      # Even with operator-shaped data in front of it, the export
      # body must contain no marker the renderer doesn't surface.
      report = %{
        report_fixture()
        | decision_envelope: %{
            available: true,
            id: "dec-id-fixed-001",
            outcome: "auto_exec",
            risk_tier: "low",
            decided_at: "2026-04-15T12:00:01Z",
            decided_by: "user",
            state: "decided",
            current: true,
            supersedes_id: nil,
            approval_expires_at: nil,
            reasons: %{
              item_count: 1,
              items: [
                %{
                  "code" => "operator_approved",
                  "actor_id" => "operator-uuid-aaaa",
                  "redacted" => true
                }
              ]
            },
            policy_snapshot_rule_ids: []
          }
      }

      body = ReportExport.build(report, generated_at: fixed_at()).body

      # Markers from #248 P2 + #249 P2 acceptance lists.
      refute body =~ "Bearer "
      refute body =~ "Authorization:"
      refute body =~ "BEGIN PRIVATE KEY"
      refute body =~ "private_key"
      refute body =~ "raw_authorization"
      refute body =~ "0xdeadbeef"
      refute body =~ ~r/sk_(test|live)_/
    end

    test "filename and metadata expose only opaque ids — no operator strings" do
      # Plant secret-bearing strings into operator-controllable
      # report fields and prove none of them appear in the
      # filename or metadata header. Filename comes from intent UUID
      # + body hash only; metadata header from `generated_from` +
      # constants.
      planted_target_address = "Bearer sk_live_PLANTED_IN_RAW_ADDRESS"

      report = %{
        report_fixture()
        | intent: %{
            report_fixture().intent
            | target: %{kind: "raw_address", address: planted_target_address}
          }
      }

      artifact = ReportExport.build(report, generated_at: fixed_at())

      refute artifact.filename =~ "Bearer"
      refute artifact.filename =~ "sk_live"
      refute artifact.filename =~ "PLANTED"

      # The body itself echoes the target_address through the
      # renderer — that is renderer surface, not export surface.
      # The export's metadata header MUST NOT echo it.
      [metadata_block, _rest] = String.split(artifact.body, "-->", parts: 2)
      refute metadata_block =~ "Bearer "
      refute metadata_block =~ ~r/sk_(test|live)_/
      refute metadata_block =~ "PLANTED"
    end
  end

  # --- filename safety against non-UUID inputs ---------------------------

  describe "build/2 — filename safety against malformed intent ids" do
    test "non-UUID intent id is sanitised to safe slice" do
      # Belt-and-braces: the production code path goes through
      # Ecto.UUID.cast/1 in the controller so this can never happen
      # in real traffic. But if a future caller hands the builder a
      # pasted string, the filename must still be safe.
      planted = "../etc/passwd; rm -rf / `Bearer sk_live_LEAKED`"

      report = %{
        report_fixture()
        | generated_from: %{intent_id: planted, workspace_id: "ws-1"}
      }

      artifact = ReportExport.build(report, generated_at: fixed_at())

      assert artifact.filename =~ ~r/^decision-report-[a-f0-9-]+-[a-f0-9]+\.md$/
      refute artifact.filename =~ "/"
      refute artifact.filename =~ "rm"
      refute artifact.filename =~ "Bearer"
      refute artifact.filename =~ "sk_live"
    end

    test "nil or empty intent id yields a safe placeholder slice, not a crash" do
      for empty <- [nil, ""] do
        report = %{
          report_fixture()
          | generated_from: %{intent_id: empty, workspace_id: "ws-1"}
        }

        artifact = ReportExport.build(report, generated_at: fixed_at())
        assert artifact.filename =~ ~r/^decision-report-[a-z0-9-]+-[a-f0-9]+\.md$/
      end
    end
  end
end
