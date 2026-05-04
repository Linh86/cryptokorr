defmodule Bank.Decisions.ReportMarkdownTest do
  @moduledoc """
  Tests for the deterministic Markdown renderer for
  `Bank.Decisions.Report` (#249).

  These tests intentionally operate on hand-built `%Report{}`
  structs (no database, no `Audit.replay/1`) so the renderer is
  exercised in isolation. The Report builder itself is covered
  by `Bank.Decisions.ReportTest` (#248 / #248 P2).

  Coverage:

    * snapshot-like stable fixture output (full report)
    * deterministic output across repeated renders
    * missing-evidence sections render labelled placeholders,
      not crashes
    * mainnet/testnet/live/stub labels appear in the chain-
      context section as expected
    * no safety overclaim verbs ("approved", "safe",
      "successful execution") appear anywhere in the output
    * no operator-supplied secrets from the
      `decision.reasons.items[]` redaction surface (#248 P2 /
      PR #360) leak into the rendered Markdown — including the
      defence-in-depth case where a future caller plants a
      `message`/`details` field on the redacted item
    * the renderer is read-only by construction — it depends on
      no Repo / Audit / adapter / broadcast / Oban / Ecto module
  """

  use ExUnit.Case, async: true

  alias Bank.Decisions.{Report, ReportMarkdown}

  # --- fixtures ----------------------------------------------------------

  # A fully-populated, deterministic report fixture. Every section
  # returns its happy-path shape so the snapshot test exercises
  # every renderer branch.
  defp full_report_fixture do
    %Report{
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
      trust_assessment: %{
        available: true,
        id: "trust-id-fixed-001",
        derived_trust: "trusted",
        confidence: "high",
        generated_at: "2026-04-15T11:55:00Z",
        generated_by: "runtime",
        contradictions_count: 0,
        supporting_assertion_ids: ["assert-1", "assert-2"],
        supporting_evidence_ids: ["evid-1"],
        current: true,
        supersedes_id: nil
      },
      simulation: %{
        available: true,
        id: "sim-id-fixed-001",
        provider: "tenderly",
        provider_trace_ref: "tnd-trace-XYZ",
        chain: "base-sepolia",
        asset: "usdc",
        status: "completed",
        generated_at: "2026-04-15T11:56:00Z",
        freshness_ttl_seconds: 60,
        estimated_gas: 21_000,
        expected_output: "9.95",
        slippage_exposure: "0.01",
        predicted_balance_change_count: 2,
        failure_condition_count: 0,
        current: true
      },
      screening_evidence: %{
        available: true,
        outcome: "passed",
        screened_address: "0xrecipientPublicAddr",
        screened_chain: "base-sepolia",
        winning_tier: "low",
        winning_source: "chainalysis-screening",
        winning_reason: "no_match",
        total_records: 0,
        record_count: 0,
        feed_health_count: 1
      },
      policy_snapshot: %{
        available: true,
        rule_count: 1,
        rules: [
          %{
            id: "rule-id-fixed-001",
            rule_type: "amount_limit",
            priority: 100,
            state: "enforced",
            version: 3,
            param_keys: ["max_per_tx"]
          }
        ]
      },
      decision_envelope: %{
        available: true,
        id: "dec-id-fixed-001",
        outcome: "auto_exec",
        risk_tier: "low",
        decided_at: "2026-04-15T12:00:01Z",
        decided_by: "runtime",
        state: "decided",
        current: true,
        supersedes_id: nil,
        approval_expires_at: nil,
        reasons: %{
          item_count: 2,
          items: ["policy.amount_limit ok", "trust=trusted"]
        },
        policy_snapshot_rule_ids: ["rule-id-fixed-001"]
      },
      approval: %{
        available: true,
        kind: "auto_exec",
        decided_by: "runtime",
        decided_at: "2026-04-15T12:00:01Z"
      },
      execution_plan: %{
        available: true,
        id: "plan-id-fixed-001",
        decision_id: "dec-id-fixed-001",
        chain: "base-sepolia",
        asset: "usdc",
        smart_account_id: "sa-fixed-001",
        execution_status: "confirmed",
        final_outcome: "confirmed",
        final_reason: nil,
        tx_refs: ["0xabcdef1234567890"],
        nonce: 7,
        adapter_ref: "adp-fixed-001",
        active: false
      },
      stablecoin_routes: [],
      flags: %{
        chain: "base-sepolia",
        mainnet?: false,
        testnet?: true,
        live?: true,
        stub?: false
      },
      residual_limitations: [],
      audit_trail: [
        %{
          id: "evt-1",
          ts: "2026-04-15T12:00:00Z",
          event_type: "intent.submitted",
          actor: "agent",
          actor_id: "agent-fixed-001",
          subject_type: "agent_intent",
          subject_id: "11111111-2222-3333-4444-555555555555",
          correlation_id: "11111111-2222-3333-4444-555555555555",
          workspace_id: "ws-77777777"
        },
        %{
          id: "evt-2",
          ts: "2026-04-15T12:00:01Z",
          event_type: "decision.decided",
          actor: "runtime",
          actor_id: nil,
          subject_type: "decision_envelope",
          subject_id: "dec-id-fixed-001",
          correlation_id: "11111111-2222-3333-4444-555555555555",
          workspace_id: "ws-77777777"
        }
      ]
    }
  end

  # A "no-decision-yet" fixture exercising every missing-evidence
  # branch: optional sections all carry `available: false` and
  # `residual_limitations` enumerates them in alphabetical order
  # (matching the Report builder's contract).
  defp empty_report_fixture do
    %Report{
      version: "1",
      generated_from: %{
        intent_id: "intent-empty-1",
        workspace_id: "ws-empty-1"
      },
      intent: %{
        id: "intent-empty-1",
        kind: "transfer",
        asset: "usdc",
        chain: "base",
        amount: "1.00",
        state: "submitted",
        idempotency_key: nil,
        submitted_at: "2026-04-15T12:00:00Z",
        target: %{kind: "unspecified"}
      },
      actor_source: %{
        agent_id: "agent-empty-1",
        source: "agent",
        workspace_id: "ws-empty-1"
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
        chain: "base",
        mainnet?: true,
        testnet?: false,
        live?: false,
        stub?: true
      },
      residual_limitations: [
        "no decision envelope recorded",
        "no execution plan recorded",
        "no simulation recorded",
        "no trust assessment recorded"
      ],
      audit_trail: []
    }
  end

  defp put_reasons(report, reasons) do
    %{report | decision_envelope: Map.put(report.decision_envelope, :reasons, reasons)}
  end

  # --- snapshot-style tests ---------------------------------------------

  describe "render/1 — populated report" do
    test "produces a well-formed Markdown document for a fully-populated report" do
      out = ReportMarkdown.render(full_report_fixture())

      # header
      assert out =~ "# Decision report"
      assert out =~ "Report version: `1`"
      assert out =~ "Intent: `11111111-2222-3333-4444-555555555555`"
      assert out =~ "Workspace: `ws-77777777`"

      # chain context — testnet + live
      assert out =~ "## Chain context"
      assert out =~ "Chain: `base-sepolia`"
      assert out =~ "Network: testnet"
      assert out =~ "Execution path: live"

      # intent table
      assert out =~ "## Intent"
      assert out =~ "| Kind | `transfer` |"
      assert out =~ "| Asset | `usdc` |"
      assert out =~ "| Amount | `9.95` |"
      assert out =~ "| State | `submitted` |"
      assert out =~ "| Idempotency key | `idem-key-fixed-1` |"
      assert out =~ "| Submitted at | `2026-04-15T12:00:00Z` |"
      assert out =~ "counterparty: cp-aaaaa…"
      assert out =~ "address_label: lbl-bbbb…"

      # actor / source
      assert out =~ "## Actor / source"
      assert out =~ "Agent: `agent-fixed-001`"
      assert out =~ "Source: `agent`"

      # trust
      assert out =~ "## Trust assessment"
      assert out =~ "Derived trust: `trusted`"
      assert out =~ "Confidence: `high`"
      assert out =~ "Contradictions: `0`"
      assert out =~ "Supporting assertions: `2`"
      assert out =~ "Supporting evidence: `1`"

      # simulation
      assert out =~ "## Simulation"
      assert out =~ "Provider: `tenderly`"
      assert out =~ "Provider trace ref: `tnd-trace-XYZ`"
      assert out =~ "Status: `completed`"
      assert out =~ "Estimated gas: `21000`"
      assert out =~ "Expected output: `9.95`"
      assert out =~ "Slippage exposure: `0.01`"
      assert out =~ "Predicted balance changes: `2`"
      assert out =~ "Failure conditions: `0`"

      # screening
      assert out =~ "## Screening evidence"
      assert out =~ "Outcome: `passed`"
      assert out =~ "Screened address: `0xrecipientPublicAddr`"
      assert out =~ "Winning tier: `low`"
      assert out =~ "Winning source: `chainalysis-screening`"

      # policy snapshot table
      assert out =~ "## Policy snapshot"
      assert out =~ "Total rules captured: `1`"
      assert out =~ "| Rule | Type | Priority | State | Version | Param keys |"
      assert out =~ "| `rule-id-…` | `amount_limit` | `100` | `enforced` | `3` | `max_per_tx` |"

      # decision envelope
      assert out =~ "## Decision envelope"
      assert out =~ "Outcome: `auto_exec`"
      assert out =~ "Risk tier: `low`"
      assert out =~ "State: `decided`"
      assert out =~ "Reasons:"
      assert out =~ "policy.amount_limit ok"
      assert out =~ "trust=trusted"

      # approval
      assert out =~ "## Approval / rejection"
      assert out =~ "Kind: `auto_exec`"

      # execution plan
      assert out =~ "## Execution plan"
      assert out =~ "Execution status: `confirmed`"
      assert out =~ "Final outcome: `confirmed`"
      assert out =~ "Adapter ref: `adp-fixed-001`"
      assert out =~ "Nonce: `7`"
      assert out =~ "Active: `false`"
      assert out =~ "Tx refs: `0xabcdef1234567890`"

      # stablecoin routes — none recorded
      assert out =~ "## Stablecoin route evidence"
      assert out =~ "_(none recorded)_"

      # audit trail table
      assert out =~ "## Audit trail"
      assert out =~ "Total events: `2`"
      assert out =~ "| Timestamp | Event type | Actor | Subject |"
      assert out =~ "intent.submitted"
      assert out =~ "decision.decided"
      assert out =~ "agent_intent#11111111…"

      # residual limitations — none populated
      assert out =~ "## Residual limitations"
      assert out =~ "_(none — every optional section was populated)_"

      # footer disclaimer (no overclaim)
      assert out =~ "replay-derived"
      assert out =~ "does not assert ongoing safety"
      assert out =~ "Operator-supplied free-text reasons"
    end

    test "is byte-for-byte deterministic for the same input" do
      report = full_report_fixture()
      first = ReportMarkdown.render(report)
      second = ReportMarkdown.render(report)
      assert first == second

      # And five repeats produce identical output.
      runs = for _ <- 1..5, do: ReportMarkdown.render(report)
      assert Enum.all?(runs, &(&1 == hd(runs)))
    end

    test "render/1 returns a binary, not iodata" do
      out = ReportMarkdown.render(full_report_fixture())
      assert is_binary(out)
    end
  end

  # --- missing evidence tests --------------------------------------------

  describe "render/1 — missing evidence is labelled, not hidden" do
    test "renders missing-section placeholders for every optional section" do
      out = ReportMarkdown.render(empty_report_fixture())

      # Every optional section is present as a labelled missing row,
      # NOT silently dropped.
      assert out =~ "## Trust assessment"
      assert out =~ "_(missing — no trust assessment recorded)_"

      assert out =~ "## Simulation"
      assert out =~ "_(missing — no simulation recorded)_"

      assert out =~ "## Screening evidence"
      assert out =~ "_(missing — no screening evidence recorded)_"

      assert out =~ "## Policy snapshot"
      assert out =~ "_(missing — no policy snapshot captured)_"

      assert out =~ "## Decision envelope"
      assert out =~ "_(missing — no decision envelope recorded)_"

      assert out =~ "## Approval / rejection"
      assert out =~ "_(missing — no approval/rejection recorded)_"

      assert out =~ "## Execution plan"
      assert out =~ "_(missing — no execution plan recorded)_"

      # Residual limitations enumerate them in their stored order.
      assert out =~ "## Residual limitations"
      assert out =~ "- no decision envelope recorded"
      assert out =~ "- no execution plan recorded"
      assert out =~ "- no simulation recorded"
      assert out =~ "- no trust assessment recorded"

      # Audit trail empty placeholder.
      assert out =~ "## Audit trail"
      assert out =~ "_(no audit events recorded)_"
    end

    test "still renders the required header / intent / chain context sections" do
      out = ReportMarkdown.render(empty_report_fixture())

      assert out =~ "# Decision report"
      assert out =~ "Intent: `intent-empty-1`"
      assert out =~ "## Chain context"
      assert out =~ "## Intent"
      assert out =~ "## Actor / source"
    end
  end

  # --- chain context label tests -----------------------------------------

  describe "render/1 — chain context labels" do
    test "labels mainnet chain as **mainnet** with broadcast warning" do
      report = %{
        full_report_fixture()
        | flags: %{
            chain: "base",
            mainnet?: true,
            testnet?: false,
            live?: true,
            stub?: false
          }
      }

      out = ReportMarkdown.render(report)
      assert out =~ "Network: **mainnet**"
      assert out =~ "chain-broadcast plans persist real funds"
      assert out =~ "Execution path: live"
    end

    test "labels testnet chain as testnet" do
      report = %{
        full_report_fixture()
        | flags: %{
            chain: "base-sepolia",
            mainnet?: false,
            testnet?: true,
            live?: false,
            stub?: true
          }
      }

      out = ReportMarkdown.render(report)
      assert out =~ "Network: testnet"
      refute out =~ "**mainnet**"
    end

    test "labels stub when no plan reached chain broadcast" do
      report = %{
        full_report_fixture()
        | flags: %{
            chain: "base-sepolia",
            mainnet?: false,
            testnet?: true,
            live?: false,
            stub?: true
          }
      }

      out = ReportMarkdown.render(report)
      assert out =~ "Execution path: stub"
      assert out =~ "no execution plan reached chain-broadcast state"
      refute out =~ "Execution path: live"
    end

    test "labels live when at least one plan reached chain broadcast" do
      out = ReportMarkdown.render(full_report_fixture())
      assert out =~ "Execution path: live"
      assert out =~ "at least one execution plan reached"
      refute out =~ "Execution path: stub"
    end
  end

  # --- no safety overclaim ----------------------------------------------

  describe "render/1 — no safety overclaim" do
    test "does not assert approval / safety / production-readiness claims" do
      out = ReportMarkdown.render(full_report_fixture())

      # Verbs / phrases that would imply the report is itself an
      # approval, safety, or production-readiness statement (rather
      # than a replay-derived evidence dump).
      forbidden = [
        "is approved",
        "is safe",
        "is production-ready",
        "successful execution",
        "guaranteed",
        "verified safe",
        "no risk",
        "safe to broadcast",
        "approved for production"
      ]

      for phrase <- forbidden do
        refute out =~ phrase, "renderer overclaims with phrase: #{inspect(phrase)}"
      end

      # The decision outcome string ("auto_exec") may still appear
      # because it IS data the report is summarising — but the
      # renderer must not editorialise over it.
      assert out =~ "Outcome: `auto_exec`"

      # And the footer must explicitly disclaim post-decision safety.
      assert out =~ "replay-derived"
      assert out =~ "does not assert ongoing safety"
    end
  end

  # --- secret hygiene ----------------------------------------------------

  describe "render/1 — secret hygiene (operator-supplied reasons, #248 P2)" do
    test "renders a redacted reason item as the safe code+actor summary only" do
      # Post-#360 redacted shape: the Report builder strips
      # `message`/`details` and exposes only `code` + `actor_id`
      # + `redacted: true`. The renderer must surface that fact
      # without inventing any other field.
      reasons = %{
        item_count: 1,
        items: [
          %{
            "code" => "operator_approved",
            "actor_id" => "operator-uuid-aaaa",
            "redacted" => true
          }
        ]
      }

      out = full_report_fixture() |> put_reasons(reasons) |> ReportMarkdown.render()

      assert out =~ "code: `operator_approved`"
      assert out =~ "actor: `operator…`"
      assert out =~ "operator-supplied body redacted"
    end

    test "ignores message/details fields if a future caller plants them on the item map" do
      # Defence in depth: even if a NEW caller bypasses the Report
      # builder's redactor and injects `message` / `details` directly
      # into the report struct, the renderer must NOT echo those
      # fields — it only reads `code`, `actor_id`, and `redacted`.
      planted_secret = "Bearer sk_test_PLANTED_PROBE"

      reasons = %{
        item_count: 1,
        items: [
          %{
            "code" => "operator_approved",
            "actor_id" => "operator-uuid-bbbb",
            "redacted" => true,
            # These should be invisible to the renderer.
            "message" => planted_secret,
            "details" => %{"raw_authorization" => planted_secret}
          }
        ]
      }

      out = full_report_fixture() |> put_reasons(reasons) |> ReportMarkdown.render()

      refute out =~ "Bearer "
      refute out =~ "sk_test_"
      refute out =~ "raw_authorization"

      # And the field key `message` itself must not appear as a
      # rendered key — the renderer must not surface the shape.
      refute out =~ "message: "
    end

    test "every secret marker from the #248 P2 acceptance list is absent from the redacted-item render" do
      # The Report builder already strips `message`/`details` so the
      # renderer cannot see the planted text. Belt-and-braces: prove
      # that even with the redacted-shape items in front of it, the
      # renderer's output contains none of the marker strings the
      # original review finding called out.
      reasons = %{
        item_count: 1,
        items: [
          %{
            "code" => "operator_approved",
            "actor_id" => "operator-uuid-cccc",
            "redacted" => true
          }
        ]
      }

      out = full_report_fixture() |> put_reasons(reasons) |> ReportMarkdown.render()

      refute out =~ "Bearer "
      refute out =~ "Authorization:"
      refute out =~ "BEGIN PRIVATE KEY"
      refute out =~ "private_key"
      refute out =~ "raw_authorization"
      refute out =~ "0xdeadbeef"
      refute out =~ ~r/sk_(test|live)_/
    end

    test "runtime-generated bare-string reasons render verbatim (backstop)" do
      # The redactor MUST NOT change behaviour for safe runtime-
      # generated labels (they are programmer-written, not operator
      # input).
      reasons = %{
        item_count: 2,
        items: ["policy.amount_limit ok", "trust=trusted"]
      }

      out = full_report_fixture() |> put_reasons(reasons) |> ReportMarkdown.render()

      assert out =~ "  - `policy.amount_limit ok`"
      assert out =~ "  - `trust=trusted`"
    end
  end

  # --- read-only by construction -----------------------------------------

  describe "render/1 — read-only by construction" do
    test "renderer module declares no Repo / Audit / adapter / broadcast / Oban / Ecto reference" do
      # Structural guarantee: the renderer is a pure function over a
      # struct. It must not reference any module that could mutate
      # rows, broadcast events, enqueue workers, talk to the chain
      # adapter, or read the database. If any of these tokens appear,
      # the renderer has acquired a side-effecting dependency.
      source = File.read!("lib/bank/decisions/report_markdown.ex")

      forbidden = [
        "Bank.Repo",
        "Bank.Audit",
        "Bank.Notifier",
        "Bank.Adapter",
        "Phoenix.PubSub",
        "Oban",
        "Ecto.Query",
        "Ecto.Repo",
        "Bank.Runtime"
      ]

      for token <- forbidden do
        refute source =~ token,
               "renderer module must not reference #{token} (would break read-only contract)"
      end
    end
  end
end
