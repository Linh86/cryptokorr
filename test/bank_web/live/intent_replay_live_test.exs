defmodule BankWeb.IntentReplayLiveTest do
  @moduledoc """
  LiveView tests for the per-intent replay page.
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user
  import Bank.Fixtures

  alias Bank.Security.PauseState

  setup do
    PauseState.reset()
    :ok
  end

  describe "mount — intent not found" do
    test "redirects to /audit with a flash error", %{conn: conn} do
      missing_id = Ecto.UUID.generate()

      assert {:error, {:live_redirect, %{to: "/audit", flash: flash}}} =
               live(conn, "/audit/replay/#{missing_id}")

      assert %{"error" => message} = flash
      assert message =~ "not found"
    end

    test "treats a sibling workspace's intent id as not_found", %{conn: conn} do
      # Logged-in user belongs to workspace A (per
      # `register_and_log_in_user`). Create a sibling workspace B
      # and an intent that lives only in B. Mounting
      # `/audit/replay/<intent_b_id>` must NOT render B's bundle —
      # `Audit.replay/1` itself does an unscoped `Repo.get` so the
      # LiveView has to gate via `Intents.get_in_workspace/2` first.
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "iso-replay-b-#{System.unique_integer([:positive])}",
          name: "Replay sibling",
          mainnet_enabled: true
        })

      cp_b = counterparty(workspace_id: ws_b.id)

      intent_b =
        agent_intent(workspace_id: ws_b.id, target_counterparty_id: cp_b.id)

      assert {:error, {:live_redirect, %{to: "/audit", flash: flash}}} =
               live(conn, "/audit/replay/#{intent_b.id}")

      assert %{"error" => message} = flash
      assert message =~ "not found"
    end

    test "redirects when intent_id is not a uuid", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/audit", flash: flash}}} =
               live(conn, "/audit/replay/not-a-uuid")

      assert %{"error" => message} = flash
      assert message =~ "not found"
    end
  end

  describe "intent with no children" do
    setup do
      intent = agent_intent()
      %{intent: intent}
    end

    test "renders intent summary section", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "Intent replay"
      assert html =~ ~s(id="replay-intent")
      assert html =~ to_string(intent.kind)
      assert html =~ intent.asset
      assert html =~ intent.chain
      assert html =~ Decimal.to_string(intent.amount)
    end

    test "shows empty stubs in each section", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "No audit events yet"
      assert html =~ "No trust assessments produced yet"
      assert html =~ "No simulation reports"
      assert html =~ "No decision envelopes written yet"
      assert html =~ "No execution plans"
      assert html =~ "No policy rules captured"
    end

    test "renders all six section cards", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ ~s(id="replay-intent")
      assert html =~ ~s(id="replay-audit")
      assert html =~ ~s(id="replay-trust")
      assert html =~ ~s(id="replay-simulations")
      assert html =~ ~s(id="replay-decisions")
      assert html =~ ~s(id="replay-plans")
      assert html =~ ~s(id="replay-policy")
    end
  end

  describe "intent with full bundle" do
    setup do
      intent = agent_intent()
      claim = trust_assessment(intent: intent, derived_trust: :trusted, current: true)
      sim = simulation_report(intent: intent, status: :completed, current: true)

      decision =
        decision_envelope(
          intent: intent,
          outcome: :auto_exec,
          risk_tier: :low,
          current: true,
          reasons: %{"items" => ["policy.amount_limit ok", "simulation passed"]}
        )

      plan =
        execution_plan(
          decision: decision,
          execution_status: :confirmed,
          final_outcome: :confirmed,
          tx_refs: ["0xabc1234567890def"]
        )

      audit_event(
        event_type: "intent.submitted",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id,
        actor: :agent
      )

      audit_event(
        event_type: "decision.decided",
        subject_type: "decision_envelope",
        subject_id: decision.id,
        correlation_id: intent.id,
        actor: :runtime
      )

      %{intent: intent, claim: claim, sim: sim, decision: decision, plan: plan}
    end

    test "renders trust assessment with derived level", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "trusted"
      assert html =~ "confidence:"
    end

    test "renders simulation with status and provider", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "completed"
      assert html =~ "tenderly"
    end

    test "renders decision with reasons", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "auto_exec"
      assert html =~ "policy.amount_limit ok"
      assert html =~ "simulation passed"
    end

    test "renders execution plan with final outcome and tx ref", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "confirmed"
      assert html =~ "final:"
      # Truncated tx ref
      assert html =~ "0xabc12345"
    end

    test "transfer plan does NOT render the swap detail block (#195)", %{
      conn: conn,
      intent: intent,
      plan: plan
    } do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      refute html =~ "replay-plan-swap-#{plan.id}"
      # Swap-plan-only marker copy from the per-plan detail block;
      # the page-level swap-routes card is allowed to render its
      # own empty state heading even on a transfer intent.
      refute html =~ "Quote-only until safety gate"
      refute html =~ "replay-plan-kind-#{plan.id}"
    end

    test "renders audit timeline with correlation slice", %{conn: conn, intent: intent} do
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "intent.submitted"
      assert html =~ "decision.decided"
    end
  end

  describe "navigation" do
    test "back link points to /audit", %{conn: conn} do
      intent = agent_intent()
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ ~s(href="/audit")
    end

    test "Audit nav item is active on replay page", %{conn: conn} do
      intent = agent_intent()
      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      # The sidebar's Audit link gets the active style.
      assert html =~ "bg-primary/10 text-primary"
    end
  end

  describe "decision report panel (#251)" do
    setup do
      intent = agent_intent(chain: "base")
      %{intent: intent}
    end

    test "renders the report panel with stable element ids and a download link to the #250 endpoint",
         %{conn: conn, intent: intent} do
      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      assert has_element?(view, "#decision-report-panel")
      assert has_element?(view, "#decision-report-flags")
      assert has_element?(view, "#decision-report-chain")
      assert has_element?(view, "#decision-report-network")
      assert has_element?(view, "#decision-report-broadcast")

      # The download link points at the browser-session controller
      # (#251 P2). It deliberately does NOT use the `/v1`
      # API-key-gated endpoint because a browser viewer would 401
      # there.
      assert has_element?(
               view,
               ~s(a#decision-report-download[href="/audit/replay/#{intent.id}/report"])
             )

      # Defence-in-depth: the link opens in a new tab so a download
      # cannot replace the operator's replay page; `noopener`
      # prevents the new tab from referencing window.opener.
      assert has_element?(view, "a#decision-report-download[target=\"_blank\"]")
      assert has_element?(view, "a#decision-report-download[rel=\"noopener\"]")
    end

    test "labels the network as testnet for base-sepolia and stub for an un-broadcast intent",
         %{conn: conn} do
      intent = agent_intent(chain: "base-sepolia")

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      assert has_element?(
               view,
               ~s(#decision-report-network[data-network="testnet"]),
               "Testnet"
             )

      assert has_element?(
               view,
               ~s(#decision-report-broadcast[data-broadcast="stub"]),
               "Stub / no broadcast"
             )

      assert has_element?(
               view,
               ~s(#decision-report-chain[data-chain="base-sepolia"])
             )
    end

    test "labels the network as mainnet when the intent is on a mainnet chain",
         %{conn: conn} do
      intent = agent_intent(chain: "base")

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      assert has_element?(
               view,
               ~s(#decision-report-network[data-network="mainnet"]),
               "Mainnet"
             )
    end

    test "cross-workspace mount still hides the panel (page redirects with 'not found')",
         %{conn: conn} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "iso-report-b-#{System.unique_integer([:positive])}",
          name: "Report sibling",
          mainnet_enabled: true
        })

      cp_b = counterparty(workspace_id: ws_b.id)
      intent_b = agent_intent(workspace_id: ws_b.id, target_counterparty_id: cp_b.id)

      assert {:error, {:live_redirect, %{to: "/audit", flash: flash}}} =
               live(conn, "/audit/replay/#{intent_b.id}")

      assert flash["error"] =~ "not found"
    end
  end

  describe "refresh" do
    test "refresh button reloads the bundle", %{conn: conn} do
      intent = agent_intent()
      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      # Add a new audit event after mount.
      audit_event(
        event_type: "intent.cancelled",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id,
        actor: :user
      )

      view |> element("button", "Refresh") |> render_click()

      html = render(view)
      assert html =~ "intent.cancelled"
    end
  end

  # --- Swap plan rendering (#195) ------------------------------------------

  describe "swap plan rendering (#195)" do
    setup do
      intent = agent_intent(kind: :swap, asset: "USDC", chain: "base-sepolia")

      decision = decision_envelope(intent: intent, current: true)

      %{intent: intent, decision: decision}
    end

    test "prepared swap plan shows kind badge, route, slippage, deadline, min-out",
         %{conn: conn, intent: intent, decision: decision} do
      plan = swap_execution_plan(decision: decision, intent_id: intent.id)

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      assert has_element?(view, "#replay-plan-kind-#{plan.id}", "swap")
      assert has_element?(view, "#replay-plan-swap-#{plan.id}")

      html = render(view)
      assert html =~ "Swap route"
      # Source/destination asset pair.
      assert html =~ "USDC → USDC"
      # Slippage / deadline / min-out / expected — all on plan.steps.
      assert html =~ "#{plan.steps["slippage_bps"]} bps"
      assert html =~ plan.steps["deadline"]
      assert html =~ plan.steps["minimum_output_amount"]
      assert html =~ plan.steps["expected_output_amount"]
      # Quote-only banner — :prepared not yet dispatched.
      assert html =~ "Quote-only until safety gate"
    end

    test "confirmed swap plan shows actual_output_amount and block_number, no quote-only banner",
         %{conn: conn, intent: intent, decision: decision} do
      plan =
        swap_execution_plan(
          decision: decision,
          intent_id: intent.id,
          execution_status: :confirmed,
          final_outcome: :confirmed,
          tx_refs: ["0xabc1234567890def"],
          active: false
        )

      # Receipt fields land via the callback path
      # (`ExecutionPlan.progress_changeset/2`), not the create
      # changeset — mirror that here so the fixture matches the
      # live shape.
      {:ok, plan} =
        plan
        |> Bank.Decisions.ExecutionPlan.progress_changeset(%{
          block_number: 42_424_242,
          actual_output_amount: Decimal.new("9.93")
        })
        |> Bank.Repo.update()

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      assert has_element?(view, "#replay-plan-swap-#{plan.id}")

      html = render(view)
      # Confirmed-status badge.
      assert html =~ "confirmed"
      assert html =~ "final:"
      # Actual output + block number on receipt.
      assert html =~ "9.93"
      assert html =~ "42424242"
      # Tx ref truncated.
      assert html =~ "0xabc12345"
      # No quote-only copy on a confirmed plan.
      refute html =~ "Quote-only until safety gate"
    end

    test "safety-blocked swap plan shows aborted state and the swap_safety reason",
         %{conn: conn, intent: intent, decision: decision} do
      plan =
        swap_execution_plan(
          decision: decision,
          intent_id: intent.id,
          execution_status: :aborted,
          final_outcome: :aborted,
          final_reason: "swap_safety:swap_deadline_expired",
          active: false
        )

      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "aborted"
      assert html =~ "swap_safety:swap_deadline_expired"
      # The swap detail block still renders so the operator can see
      # WHICH route was refused.
      assert html =~ "replay-plan-swap-#{plan.id}"
      assert html =~ plan.steps["route_provider"]
    end

    test "adapter-rejected swap plan surfaces the safe failure reason",
         %{conn: conn, intent: intent, decision: decision} do
      plan =
        swap_execution_plan(
          decision: decision,
          intent_id: intent.id,
          execution_status: :aborted,
          final_outcome: :aborted,
          final_reason: "adapter_rejected:422:validation_failed",
          active: false
        )

      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      assert html =~ "adapter_rejected:422:validation_failed"
      assert html =~ "replay-plan-swap-#{plan.id}"
    end

    test "secret hygiene — swap UI must not render raw calldata, spender, or token addresses",
         %{conn: conn, intent: intent, decision: decision} do
      plan = swap_execution_plan(decision: decision, intent_id: intent.id)

      {:ok, _view, html} = live(conn, "/audit/replay/#{intent.id}")

      # Calldata is the longest hex blob in plan.steps; the route_hash
      # is also hex but only 64 chars and gets truncated by short_hash/1.
      refute html =~ plan.steps["calldata"]
      # Spender / target contract are 0x addresses — keep them off
      # the operator UI even though they're persisted for dispatch.
      refute html =~ plan.steps["spender"]
      refute html =~ plan.steps["swap_target_contract"]
      refute html =~ plan.steps["source_token_address"]
      refute html =~ plan.steps["destination_token_address"]
      # No raw bearer / Authorization material can ever appear.
      refute html =~ "Bearer "
      refute html =~ "Authorization:"
    end

    test "swap UI copy never implies mainnet support",
         %{conn: conn, intent: intent, decision: decision} do
      plan = swap_execution_plan(decision: decision, intent_id: intent.id)

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      # Render the swap detail block in isolation and assert the
      # chain copy never mentions mainnet / Base mainnet / Ethereum.
      # The fixture is base-sepolia so any "ethereum" or "Mainnet"
      # would have to come from a UI label that hardcodes mainnet —
      # exactly what the acceptance criterion forbids.
      swap_block = render(element(view, "#replay-plan-swap-#{plan.id}"))

      refute swap_block =~ "ethereum"
      refute swap_block =~ ~r/\bmainnet\b/i
    end
  end

  # --- Morpho deposit risk-explanation evidence (#204) ---------------------

  describe "morpho evidence card (#204)" do
    @vault_address "0x" <> String.duplicate("a4", 20)
    @explanation %{
      "kind" => "morpho_vault_risk",
      "venue" => "morpho",
      "vault_address" => @vault_address,
      "vault_name" => "Demo USDC Vault",
      "chain_id" => 84_532,
      "loan_asset" => "USDC",
      "decision" => "approval_required",
      "risk_tier" => "moderate",
      "summary" => "Approval required because vault is not yet listed.",
      "primary_reasons" => [
        %{
          "code" => "vault_listed",
          "severity" => "approval",
          "message" => "Vault is not listed on Morpho yet."
        }
      ],
      "checks" => [],
      "market_allocations" => [],
      "source_refs" => []
    }

    test "morpho-less intent renders the section with an empty-state message",
         %{conn: conn} do
      intent = agent_intent()

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      assert has_element?(view, "#replay-morpho-evidence")

      block = render(element(view, "#replay-morpho-evidence"))
      assert block =~ "No Morpho evidence captured"
    end

    test "morpho.risk_explained event surfaces vault, decision, summary, primary reasons",
         %{conn: conn} do
      intent = morpho_deposit_intent(target_raw_address: @vault_address)

      audit_event(
        event_type: "morpho.risk_explained",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id,
        actor: :runtime,
        after_ref: %{
          "morpho_risk_explanation" => @explanation,
          "snapshot" => %{
            "id" => "snap_demo_001",
            "payload_hash" => String.duplicate("d", 64),
            "fetched_at" => "2027-01-01T00:00:00Z"
          },
          "policy_rule_ids" => [Ecto.UUID.generate()],
          "proposed_amount" => "1000"
        }
      )

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      assert has_element?(view, "#replay-morpho-evidence")

      block = render(element(view, "#replay-morpho-evidence"))
      assert block =~ "risk_explained"
      assert block =~ "approval_required"
      assert block =~ "moderate"
      assert block =~ @vault_address
      assert block =~ "Approval required because vault is not yet listed."
      assert block =~ "Vault is not listed on Morpho yet."
    end

    test "morpho.policy_blocked event surfaces vault, chain, and reason",
         %{conn: conn} do
      intent = morpho_deposit_intent(target_raw_address: @vault_address)

      audit_event(
        event_type: "morpho.policy_blocked",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id,
        actor: :runtime,
        after_ref: %{
          "vault_address" => @vault_address,
          "chain_id" => 84_532,
          "block_reason_codes" => ["vault_not_allowlisted"],
          "summary" => "Vault is not on the allowlist.",
          "policy_rule_ids" => [Ecto.UUID.generate()]
        }
      )

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      block = render(element(view, "#replay-morpho-evidence"))

      assert block =~ "policy_blocked"
      assert block =~ @vault_address
      assert block =~ "84532"
      assert block =~ "Vault is not on the allowlist."
    end

    test "morpho.snapshot_stale event highlights stale fields",
         %{conn: conn} do
      intent = morpho_deposit_intent(target_raw_address: @vault_address)

      audit_event(
        event_type: "morpho.snapshot_stale",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id,
        actor: :runtime,
        after_ref: %{
          "vault_address" => @vault_address,
          "chain_id" => 84_532,
          "fetched_at" => "2027-01-01T00:00:00Z",
          "stale_fields" => [
            %{"field" => "warnings", "state" => "expired"},
            %{"field" => "apy", "state" => "stale"}
          ]
        }
      )

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      block = render(element(view, "#replay-morpho-evidence"))

      assert block =~ "snapshot_stale"
      assert block =~ "warnings (expired)"
      assert block =~ "apy (stale)"
    end

    test "morpho.deposit_dispatched event surfaces snapshot identity and amount",
         %{conn: conn} do
      intent = morpho_deposit_intent(target_raw_address: @vault_address)

      audit_event(
        event_type: "morpho.deposit_dispatched",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id,
        actor: :runtime,
        after_ref: %{
          "vault_address" => @vault_address,
          "chain_id" => 84_532,
          "asset" => "USDC",
          "amount" => "1000",
          "receiver" => "0x" <> String.duplicate("be", 20),
          "snapshot_id" => "snap_dispatched_001",
          "snapshot_payload_hash" => String.duplicate("e", 64)
        }
      )

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      block = render(element(view, "#replay-morpho-evidence"))

      assert block =~ "deposit_dispatched"
      assert block =~ "1000 USDC"
    end

    test "secret hygiene — morpho evidence never renders raw payloads or auth headers",
         %{conn: conn} do
      intent = morpho_deposit_intent(target_raw_address: @vault_address)

      audit_event(
        event_type: "morpho.risk_explained",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id,
        actor: :runtime,
        after_ref: %{
          "morpho_risk_explanation" => @explanation,
          "snapshot" => %{"id" => "snap_secret_test"},
          "policy_rule_ids" => [],
          "proposed_amount" => "5"
        }
      )

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")
      block = render(element(view, "#replay-morpho-evidence"))

      refute block =~ "Bearer "
      refute block =~ "Authorization:"
      refute block =~ "private_key"
      # Allocations / source warnings are not surfaced in this card.
      refute block =~ "market_allocations"
      refute block =~ "source_warnings"
      # Mainnet-implying copy must never appear (MVP is sepolia-only).
      refute block =~ ~r/\bmainnet\b/i
    end

    test "non-morpho intent does NOT inject morpho events into the section",
         %{conn: conn} do
      intent = agent_intent()

      audit_event(
        event_type: "intent.submitted",
        subject_type: "agent_intent",
        subject_id: intent.id,
        correlation_id: intent.id,
        actor: :agent
      )

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      block = render(element(view, "#replay-morpho-evidence"))
      assert block =~ "No Morpho evidence captured"
      refute block =~ "risk_explained"
      refute block =~ "deposit_dispatched"
    end
  end

  describe "swap route evidence card" do
    test "intent without a swap plan renders the card with the empty-state copy",
         %{conn: conn} do
      intent = agent_intent()

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      assert has_element?(view, "#replay-swap-routes")
      block = render(element(view, "#replay-swap-routes"))
      assert block =~ "No swap route evidence captured"
      refute block =~ ~s(id="replay-swap-route-1")
    end

    test "swap intent with a confirmed plan surfaces route + execution outcome",
         %{conn: conn} do
      intent = agent_intent(kind: :swap, asset: "USDC", chain: "base-sepolia")
      decision = decision_envelope(intent: intent, current: true)

      plan =
        swap_execution_plan(
          decision: decision,
          intent_id: intent.id,
          execution_status: :confirmed,
          final_outcome: :confirmed,
          tx_refs: ["0xabc1234567890def"],
          active: false
        )

      {:ok, plan} =
        plan
        |> Bank.Decisions.ExecutionPlan.progress_changeset(%{
          block_number: 42_424_242,
          actual_output_amount: Decimal.new("9.93")
        })
        |> Bank.Repo.update()

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      assert has_element?(view, "#replay-swap-routes")
      assert has_element?(view, "#replay-swap-route-1")

      block = render(element(view, "#replay-swap-routes"))
      assert block =~ "confirmed"
      assert block =~ plan.steps["source_asset"]
      assert block =~ plan.steps["destination_asset"]
      assert block =~ plan.steps["expected_output_amount"]
      assert block =~ plan.steps["minimum_output_amount"]
      # actual_output_amount is rendered through swap_route_value/2
      # which reads the audit-projected map; 9.93 is the post-receipt
      # value Bank.Audit.swap_route_evidence/1 surfaces.
      assert block =~ "9.93"
      assert block =~ "42424242"
    end

    test "aborted swap plan surfaces the failure reason verbatim",
         %{conn: conn} do
      intent = agent_intent(kind: :swap, asset: "USDC", chain: "base-sepolia")
      decision = decision_envelope(intent: intent, current: true)

      _plan =
        swap_execution_plan(
          decision: decision,
          intent_id: intent.id,
          execution_status: :aborted,
          final_outcome: :aborted,
          final_reason: "swap_amount_invalid"
        )

      {:ok, view, _html} = live(conn, "/audit/replay/#{intent.id}")

      block = render(element(view, "#replay-swap-routes"))
      assert block =~ "aborted"
      assert block =~ "swap_amount_invalid"
    end
  end
end
