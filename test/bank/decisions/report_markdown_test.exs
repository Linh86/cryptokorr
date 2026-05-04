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

  # --- final_reason secret hygiene (#249 P2) ----------------------------

  describe "render/1 — execution_plan.final_reason secret hygiene (#249 P2)" do
    # `Bank.Decisions.apply_execution_callback/1` for
    # `execution.reverted` / `execution.aborted` writes the adapter
    # callback's `params["reason"]` straight into
    # `execution_plans.final_reason` (lib/bank/decisions.ex:1841,1855).
    # That field can therefore carry pasted Authorization headers,
    # tokenized RPC URLs, PEM markers, `sk_(test|live)_…` tokens, or
    # 0x-prefixed key handles. Pre-fix the renderer echoed the value
    # verbatim — pre-fix #249 P2 review finding.

    defp put_final_reason(report, reason) do
      %{
        report
        | execution_plan: Map.put(report.execution_plan, :final_reason, reason)
      }
    end

    test "allowlisted runtime atom reasons render verbatim" do
      for safe <-
            ~w(runtime_paused chain_paused delegation_not_active operator_requested sandbox_seed) do
        out = full_report_fixture() |> put_final_reason(safe) |> ReportMarkdown.render()

        assert out =~ "Final reason: `" <> safe <> "`",
               "renderer dropped safe runtime atom reason: #{safe}"
      end
    end

    test "allowlisted target_not_resolvable causes render verbatim" do
      for cause <-
            ~w(intent_missing label_retired label_missing no_label ambiguous_label missing_target) do
        reason = "target_not_resolvable:" <> cause

        out = full_report_fixture() |> put_final_reason(reason) |> ReportMarkdown.render()

        assert out =~ "Final reason: `" <> reason <> "`",
               "renderer dropped safe target_not_resolvable cause: #{cause}"
      end
    end

    test "unknown target_not_resolvable cause is redacted (default-deny on suffix)" do
      out =
        full_report_fixture()
        |> put_final_reason("target_not_resolvable:unrecognised_future_cause")
        |> ReportMarkdown.render()

      assert out =~ "Final reason: `(redacted free-text reason)`"
      refute out =~ "unrecognised_future_cause"
    end

    test "adapter_rejected:<status>:<summary> renders status only, summary dropped" do
      # `lib/bank/runtime/workers/run_execution.ex` summarises up to
      # 80 chars of the adapter response body into the suffix. A
      # poisoned adapter could put pasted secrets there. Drop the
      # whole summary regardless of content; render only the status.
      planted_summary = "Bearer sk_live_HIDDEN | private_key=hex | 0xdeadbeef"
      reason = "adapter_rejected:422:" <> planted_summary

      out = full_report_fixture() |> put_final_reason(reason) |> ReportMarkdown.render()

      assert out =~ "Final reason: `adapter_rejected:422`"
      refute out =~ "Bearer "
      refute out =~ ~r/sk_(test|live)_/
      refute out =~ "private_key"
      refute out =~ "0xdeadbeef"
      refute out =~ "Final reason: `adapter_rejected:422:"
    end

    test "adapter_rejected with no numeric status is redacted" do
      out =
        full_report_fixture()
        |> put_final_reason("adapter_rejected:NaN:body")
        |> ReportMarkdown.render()

      assert out =~ "Final reason: `(redacted free-text reason)`"
      refute out =~ "adapter_rejected:NaN"
    end

    test "adapter_rejected:<status> with no summary still renders" do
      out =
        full_report_fixture()
        |> put_final_reason("adapter_rejected:500")
        |> ReportMarkdown.render()

      assert out =~ "Final reason: `adapter_rejected:500`"
    end

    test "operator/provider free-text reason is redacted, even without secret markers" do
      # `params["reason"]` from an adapter callback can be any
      # string. Pre-fix the renderer echoed it verbatim. Post-fix it
      # falls through to `(redacted free-text reason)`.
      out =
        full_report_fixture()
        |> put_final_reason("simulation mismatch on chain")
        |> ReportMarkdown.render()

      assert out =~ "Final reason: `(redacted free-text reason)`"
      refute out =~ "simulation mismatch on chain"
    end

    test "secret-bearing adapter callback final_reason does not leak (regression for #249 P2-1)" do
      # The exact secret-marker family the review finding called out:
      # Authorization header, Bearer sk_live_..., RPC URL with
      # embedded credentials, PEM marker, `private_key`,
      # `0xdeadbeef`-style key handle. Plant them all into one
      # poisoned `params["reason"]` body and prove the renderer's
      # output contains none of them.
      planted =
        "Authorization: Bearer sk_live_LEAKED_PROBE | " <>
          "Bearer sk_live_REPEAT | " <>
          "https://secret@example.test/rpc | " <>
          "-----BEGIN PRIVATE KEY----- | " <>
          "private_key=hex_blob | " <>
          "0xdeadbeefcafebabe1234567890abcdef12345678"

      out = full_report_fixture() |> put_final_reason(planted) |> ReportMarkdown.render()

      assert out =~ "Final reason: `(redacted free-text reason)`"
      refute out =~ "Bearer "
      refute out =~ "Authorization:"
      refute out =~ "BEGIN PRIVATE KEY"
      refute out =~ "private_key"
      refute out =~ "https://secret@example.test"
      refute out =~ "0xdeadbeef"
      refute out =~ ~r/sk_(test|live)_/
    end

    test "nil and empty final_reason render as (none)" do
      for empty <- [nil, ""] do
        out = full_report_fixture() |> put_final_reason(empty) |> ReportMarkdown.render()
        assert out =~ "Final reason: `(none)`"
      end
    end

    test "non-binary final_reason values are defensively redacted" do
      # Defence-in-depth: if someone ever puts a non-string into the
      # report struct's `:final_reason` field, the renderer must not
      # crash and must not echo the value through `to_string/1`.
      out =
        full_report_fixture()
        |> put_final_reason(%{"raw_authorization" => "Bearer sk_live_LEAKED"})
        |> ReportMarkdown.render()

      assert out =~ "Final reason: `(redacted free-text reason)`"
      refute out =~ "Bearer "
      refute out =~ "raw_authorization"
      refute out =~ ~r/sk_(test|live)_/
    end
  end

  # --- stablecoin route real-shape rendering (#249 P2) ------------------

  describe "render/1 — stablecoin_route_evidence real-shape rendering (#249 P2)" do
    # `Bank.Stablecoins.IntentRouting.build_evidence/1` produces the
    # real route map shape, written into the audit row's `after_ref`
    # and pulled back by `Bank.Audit.replay/1` into
    # `bundle.stablecoin_route_evidence`. Pre-fix the renderer only
    # recognised invented `from`/`to`/`via`/`stablecoin` keys, so
    # every real route was rendered as `_(route entry has no
    # recognised summary keys)_`. Post-fix an allowlisted scalar
    # subset of the actual shape is rendered, with raw nested
    # structures (`quote_request`, `legs`, `selector_metadata`,
    # `policy_reasons`, human-readable `reason`) excluded.

    # Mirrors the actual return shape of
    # `Bank.Stablecoins.IntentRouting.build_evidence/1`'s
    # `:stablecoin_route` value, with string keys (the shape that
    # comes back from the DB after a JSON round-trip).
    defp real_route_evidence_string_keys do
      %{
        "decision" => "auto_exec",
        "execution_state" => "requires_adapter",
        "reason_code" => "stablecoin_route_allowed",
        "reason" => "Route allowed by policy.",
        "policy_decision" => "allowed",
        "policy_reasons" => [
          %{"rule" => "amount_limit", "detail" => "ok", "severity" => "info"}
        ],
        "score" => 0.92,
        "fee_summary" => %{
          "gas_fee" => "0.05",
          "protocol_fee" => "0.10",
          "bridge_fee" => nil,
          "cryptobank_fee" => "0.45",
          "total_fee" => "0.60",
          "output_impact_pct" => "0.05"
        },
        "route_kind" => "swap",
        "provider" => "fake-provider",
        "input_amount" => "100.000000",
        "output_amount" => "99.400000",
        "eta_seconds" => 12,
        "expires_at" => "2026-04-15T12:30:00Z",
        "quoted_at" => "2026-04-15T12:00:00Z",
        "quote_request" => %{
          "source_chain" => "base-sepolia",
          "source_asset" => "usdc",
          "dest_chain" => "ethereum-sepolia",
          "dest_asset" => "usdc",
          "amount" => "100.000000",
          "slippage_bps" => 50,
          "route_kind" => "swap"
        },
        "legs" => [
          %{
            "step" => 1,
            "kind" => "swap",
            "source_chain" => "base-sepolia",
            "source_asset" => "usdc",
            "dest_chain" => "ethereum-sepolia",
            "dest_asset" => "usdc",
            "input_amount" => "100.000000",
            "output_amount" => "99.400000",
            "protocol" => "fake-pool",
            "pool_address" => "0xpool0000000000000000000000000000000fake"
          }
        ],
        "selector_metadata" => %{
          "considered" => 3,
          "errors" => [
            %{"provider" => "stub-broken", "error" => "Bearer sk_live_HIDDEN_IN_ERROR"}
          ]
        },
        "evaluated_at" => "2026-04-15T12:00:01Z"
      }
    end

    defp atomise_top_level(map) do
      Map.new(map, fn {k, v} -> {String.to_atom(k), v} end)
    end

    defp put_routes(report, routes) do
      %{report | stablecoin_routes: routes}
    end

    test "renders allowlisted scalar fields from the real route shape (string-keyed)" do
      out =
        full_report_fixture()
        |> put_routes([real_route_evidence_string_keys()])
        |> ReportMarkdown.render()

      # Header + count.
      assert out =~ "## Stablecoin route evidence"
      assert out =~ "Captured route evaluations: `1`"

      # Allowlisted scalar fields appear as bullets.
      assert out =~ "- decision: `auto_exec`"
      assert out =~ "- execution_state: `requires_adapter`"
      assert out =~ "- reason_code: `stablecoin_route_allowed`"
      assert out =~ "- policy_decision: `allowed`"
      assert out =~ "- provider: `fake-provider`"
      assert out =~ "- route_kind: `swap`"
      assert out =~ "- input_amount: `100.000000`"
      assert out =~ "- output_amount: `99.400000`"
      assert out =~ "- score: `0.92`"
      assert out =~ "- eta_seconds: `12`"
      assert out =~ "- quoted_at: `2026-04-15T12:00:00Z`"
      assert out =~ "- evaluated_at: `2026-04-15T12:00:01Z`"
      assert out =~ "- expires_at: `2026-04-15T12:30:00Z`"

      # fee_summary subsection with allowlisted fee keys.
      assert out =~ "fee_summary:"
      assert out =~ "- total_fee: `0.60`"
      assert out =~ "- gas_fee: `0.05`"
      assert out =~ "- protocol_fee: `0.10`"
      assert out =~ "- cryptobank_fee: `0.45`"
      assert out =~ "- output_impact_pct: `0.05`"
    end

    test "renders allowlisted scalar fields from the real route shape (atom-keyed)" do
      # The in-memory shape from build_evidence/1 is atom-keyed
      # before JSON round-trip. The renderer must accept either
      # shape so a reader of an in-memory bundle (no DB round-trip)
      # gets the same render as a reader of a replayed bundle.
      atom_keyed = atomise_top_level(real_route_evidence_string_keys())

      out =
        full_report_fixture()
        |> put_routes([atom_keyed])
        |> ReportMarkdown.render()

      assert out =~ "- decision: `auto_exec`"
      assert out =~ "- execution_state: `requires_adapter`"
      assert out =~ "- provider: `fake-provider`"
      assert out =~ "- input_amount: `100.000000`"
    end

    test "does NOT render raw nested route shapes (#249 P2 hard allowlist)" do
      # `quote_request`, `legs`, `selector_metadata`, `policy_reasons`
      # and the human-readable `reason` field are NOT in the
      # allowlist. They must not appear in the output even if a
      # caller hands them to the renderer.
      out =
        full_report_fixture()
        |> put_routes([real_route_evidence_string_keys()])
        |> ReportMarkdown.render()

      refute out =~ "quote_request"
      refute out =~ "selector_metadata"
      refute out =~ "policy_reasons"

      # The `legs` key name itself must not appear, and neither
      # should the leg's pool_address / protocol details.
      refute out =~ "- legs"
      refute out =~ "0xpool0000"
      refute out =~ "fake-pool"

      # The free-text `reason` field is excluded; only the
      # programmer-set `reason_code` is rendered.
      refute out =~ "Route allowed by policy."

      # The selector_metadata.errors list may carry a provider
      # error string echoed from a third-party — never render it.
      refute out =~ "Bearer "
      refute out =~ "sk_live_HIDDEN_IN_ERROR"
    end

    test "secret-bearing nested values do not leak (regression for #249 P2-2)" do
      # Even if a future caller plants a secret string into a
      # nested key the renderer never reads, prove the output
      # carries none of it. This is the structural defence: the
      # renderer can ONLY render allowlisted top-level scalar
      # leaves, not nested values.
      poisoned =
        real_route_evidence_string_keys()
        |> Map.put("quote_request", %{
          "raw_authorization" => "Bearer sk_test_LEAKED_QR",
          "rpc_url" => "https://secret@example.test/rpc"
        })
        |> Map.put("legs", [
          %{"private_key_pem" => "-----BEGIN PRIVATE KEY-----"}
        ])
        |> Map.put("selector_metadata", %{
          "errors" => [%{"error" => "0xdeadbeefcafebabe1234567890abcdef12345678"}]
        })
        |> Map.put("policy_reasons", [
          %{"detail" => "Authorization: Bearer sk_live_PLANTED"}
        ])

      out = full_report_fixture() |> put_routes([poisoned]) |> ReportMarkdown.render()

      refute out =~ "Bearer "
      refute out =~ "Authorization:"
      refute out =~ "BEGIN PRIVATE KEY"
      refute out =~ "private_key"
      refute out =~ "raw_authorization"
      refute out =~ "rpc_url"
      refute out =~ "https://secret@example.test"
      refute out =~ "0xdeadbeef"
      refute out =~ ~r/sk_(test|live)_/
    end

    test "multiple route evaluations are rendered in input order (deterministic)" do
      first = Map.put(real_route_evidence_string_keys(), "provider", "first-provider")
      second = Map.put(real_route_evidence_string_keys(), "provider", "second-provider")

      report = put_routes(full_report_fixture(), [first, second])
      out = ReportMarkdown.render(report)

      assert out =~ "Captured route evaluations: `2`"

      first_pos = :binary.match(out, "first-provider") |> elem(0)
      second_pos = :binary.match(out, "second-provider") |> elem(0)
      assert first_pos < second_pos, "renderer reordered route evaluations"

      # And the render is byte-stable across repeats.
      assert ReportMarkdown.render(report) == ReportMarkdown.render(report)
    end

    test "a route map with no allowlisted keys renders the labelled placeholder" do
      out =
        full_report_fixture()
        |> put_routes([%{"unknown_key" => "value", "another" => 1}])
        |> ReportMarkdown.render()

      assert out =~ "_(route entry has no allowlisted fields)_"
      refute out =~ "unknown_key"
      refute out =~ "another"
    end

    test "missing fee_summary subsection is silently skipped (deterministic)" do
      no_fees = Map.delete(real_route_evidence_string_keys(), "fee_summary")

      out = full_report_fixture() |> put_routes([no_fees]) |> ReportMarkdown.render()

      assert out =~ "- decision: `auto_exec`"
      refute out =~ "fee_summary:"
    end

    test "fee_summary with no allowlisted keys is silently skipped" do
      route =
        Map.put(real_route_evidence_string_keys(), "fee_summary", %{
          "private_key" => "BEGIN PRIVATE KEY",
          "raw_authorization" => "Bearer sk_live_LEAKED"
        })

      out = full_report_fixture() |> put_routes([route]) |> ReportMarkdown.render()

      refute out =~ "fee_summary:"
      refute out =~ "private_key"
      refute out =~ "Bearer "
      refute out =~ "raw_authorization"
    end
  end
end
