defmodule Bank.PoliciesTest do
  use Bank.DataCase, async: true

  alias Bank.Audit.AuditEvent
  alias Bank.Fixtures
  alias Bank.Policies
  alias Bank.Policies.{Evaluation, EvaluationInput, PolicyRule}

  # ---------------------------------------------------------------------
  # list / get / load_active_ruleset
  # ---------------------------------------------------------------------

  describe "list_rules/2" do
    test "returns rules ordered by inserted_at, cursorable" do
      a = Fixtures.policy_rule(rule_type: :amount_limit)

      b =
        Fixtures.policy_rule(
          rule_type: :allowed_asset,
          params: %{"mode" => "allowlist", "assets" => ["USDC"]}
        )

      c = Fixtures.policy_rule(rule_type: :autonomy_tier, params: %{"tier" => "auto"})

      %{entries: page1, next_cursor: cursor} = Policies.list_rules(%{}, limit: 2)
      assert length(page1) == 2
      assert cursor

      %{entries: page2, next_cursor: nil} = Policies.list_rules(%{}, limit: 2, cursor: cursor)

      ids = MapSet.new(Enum.map(page1 ++ page2, & &1.id))
      assert ids == MapSet.new([a.id, b.id, c.id])
    end

    test "filters by state and rule_type" do
      active = Fixtures.policy_rule(rule_type: :amount_limit, state: :active)
      draft = Fixtures.policy_rule(rule_type: :amount_limit, state: :draft)
      other = Fixtures.policy_rule(rule_type: :autonomy_tier, params: %{"tier" => "auto"})

      %{entries: actives} = Policies.list_rules(%{state: :active})

      assert MapSet.new(Enum.map(actives, & &1.id)) ==
               MapSet.new([active.id, other.id])

      %{entries: amounts} = Policies.list_rules(%{rule_type: :amount_limit})
      assert MapSet.new(Enum.map(amounts, & &1.id)) == MapSet.new([active.id, draft.id])
    end
  end

  describe "get_rule/1" do
    test "returns :not_found for unknown id" do
      assert {:error, :not_found} = Policies.get_rule(Ecto.UUID.generate())
    end

    test "returns the rule" do
      rule = Fixtures.policy_rule()
      assert {:ok, %PolicyRule{id: id}} = Policies.get_rule(rule.id)
      assert id == rule.id
    end
  end

  describe "load_active_ruleset/0" do
    test "returns active rules ordered by priority desc, then inserted_at asc" do
      _archived = Fixtures.policy_rule(state: :archived)
      low = Fixtures.policy_rule(priority: 1)
      high = Fixtures.policy_rule(priority: 10)
      mid = Fixtures.policy_rule(priority: 5)

      ids = Policies.load_active_ruleset() |> Enum.map(& &1.id)
      assert ids == [high.id, mid.id, low.id]
    end
  end

  # ---------------------------------------------------------------------
  # create / revise / archive
  # ---------------------------------------------------------------------

  describe "create_rule/2" do
    test "inserts with defaults and emits policy.created" do
      attrs = %{
        "rule_type" => "amount_limit",
        "params" => %{"max_per_tx" => "1000", "currency" => "USDC"},
        "created_by" => "user"
      }

      assert {:ok, rule} = Policies.create_rule(attrs)
      assert rule.rule_type == :amount_limit
      assert rule.state == :active
      assert rule.version == 1

      assert event =
               Repo.one(
                 from(e in AuditEvent,
                   where: e.event_type == "policy.created" and e.correlation_id == ^rule.id
                 )
               )

      assert event.subject_type == "policy_rule"
      assert event.subject_id == rule.id
      assert event.after_ref["id"] == rule.id
    end

    test "returns changeset on invalid params" do
      attrs = %{"rule_type" => "unknown_kind", "created_by" => "user"}
      assert {:error, %Ecto.Changeset{}} = Policies.create_rule(attrs)
    end
  end

  describe "revise_rule/3" do
    test "inserts a successor, flips prior to superseded, emits policy.revised" do
      prior =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100"},
          state: :active
        )

      {:ok, successor} =
        Policies.revise_rule(
          prior,
          %{params: %{"max_per_tx" => "250"}, created_by: :user},
          actor: :user,
          actor_id: "operator-42"
        )

      assert successor.rule_type == :amount_limit
      assert successor.version == 2
      assert successor.state == :active
      assert successor.supersedes_id == prior.id
      assert successor.params == %{"max_per_tx" => "250"}

      refetched_prior = Repo.get!(PolicyRule, prior.id)
      assert refetched_prior.state == :superseded

      assert Repo.one(
               from(e in AuditEvent,
                 where: e.event_type == "policy.revised" and e.correlation_id == ^successor.id
               )
             )
    end

    test "rejects revising a non-active rule" do
      superseded = Fixtures.policy_rule(state: :superseded)

      assert {:error, :not_active} =
               Policies.revise_rule(
                 superseded,
                 %{params: %{"max_per_tx" => "999"}, created_by: :user},
                 actor: :user,
                 actor_id: "op"
               )
    end
  end

  describe "archive_rule/2" do
    test "flips active to archived and emits policy.archived" do
      rule = Fixtures.policy_rule(state: :active)

      {:ok, archived} = Policies.archive_rule(rule, actor: :user, actor_id: "operator-7")
      assert archived.state == :archived

      assert Repo.one(
               from(e in AuditEvent,
                 where: e.event_type == "policy.archived" and e.correlation_id == ^rule.id
               )
             )
    end

    test "rejects archiving a non-active rule" do
      archived = Fixtures.policy_rule(state: :archived)
      assert {:error, :not_active} = Policies.archive_rule(archived, actor: :user, actor_id: "op")

      superseded = Fixtures.policy_rule(state: :superseded)

      assert {:error, :not_active} =
               Policies.archive_rule(superseded, actor: :user, actor_id: "op")
    end
  end

  # ---------------------------------------------------------------------
  # snapshot_applicable / evaluate — scoping + shape
  # ---------------------------------------------------------------------

  describe "snapshot_applicable/2" do
    test "returns only rules whose scope matches the candidate" do
      global =
        Fixtures.policy_rule(
          rule_type: :allowed_chain,
          params: %{"mode" => "allowlist", "chains" => ["base"]}
        )

      usdc_only =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "1000"},
          scope: %{"asset" => "USDC"}
        )

      base_only =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "500"},
          scope: %{"chain" => "base"}
        )

      weth_only =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "2"},
          scope: %{"asset" => "WETH"}
        )

      input = input_for(:transfer, "USDC", "base", "10")

      %{"rule_ids" => ids} = Policies.snapshot_applicable(input)
      assert global.id in ids
      assert usdc_only.id in ids
      assert base_only.id in ids
      refute weth_only.id in ids
    end

    test "counterparty-scoped rule only matches that counterparty" do
      cp = Fixtures.counterparty()
      other_cp = Fixtures.counterparty()

      rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "1000"},
          scope: %{"counterparty_id" => cp.id}
        )

      matching = input_for(:transfer, "USDC", "base", "10", target_counterparty_id: cp.id)

      non_matching =
        input_for(:transfer, "USDC", "base", "10", target_counterparty_id: other_cp.id)

      assert rule.id in Policies.snapshot_applicable(matching)["rule_ids"]
      refute rule.id in Policies.snapshot_applicable(non_matching)["rule_ids"]
    end
  end

  describe "evaluate/2 — result shape" do
    test "returns pass? = true with no violations when no rules match" do
      _unrelated = Fixtures.policy_rule(rule_type: :amount_limit, scope: %{"asset" => "WETH"})

      input = input_for(:transfer, "USDC", "base", "10")
      eval = Policies.evaluate(input)

      assert %Evaluation{pass?: true, violations: [], matched_rule_ids: []} = eval
      assert eval.snapshot_ref == %{"rule_ids" => []}
      assert eval.autonomy_tier == :auto
    end

    test "snapshot_ref matches the matched rule ids" do
      rule = Fixtures.policy_rule(rule_type: :amount_limit, params: %{"max_per_tx" => "1000"})

      input = input_for(:transfer, "USDC", "base", "10")
      eval = Policies.evaluate(input)

      assert eval.snapshot_ref == %{"rule_ids" => [rule.id]}
    end

    test "can be called with an AgentIntent directly" do
      cp = Fixtures.counterparty()
      intent = Fixtures.agent_intent(counterparty: cp, amount: Decimal.new("50"))
      _rule = Fixtures.policy_rule(rule_type: :amount_limit, params: %{"max_per_tx" => "100"})

      assert %Evaluation{pass?: true} = Policies.evaluate(intent)
    end
  end

  # ---------------------------------------------------------------------
  # Per-rule-type evaluation
  # ---------------------------------------------------------------------

  describe "amount_limit" do
    test "pass emits an amount_ceiling constraint" do
      _rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "500", "currency" => "USDC"}
        )

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "100"))

      assert eval.pass?
      assert Decimal.equal?(eval.constraints.amount_ceiling, Decimal.new("500"))
    end

    test "violation when amount exceeds max_per_tx" do
      rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100", "currency" => "USDC"}
        )

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "250"))

      refute eval.pass?
      assert [v] = eval.violations
      assert v.rule_id == rule.id
      assert v.rule_type == :amount_limit
      assert v.code == "amount_above_limit"
    end

    test "ignored when the rule's currency doesn't match" do
      _rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "100", "currency" => "WETH"}
        )

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "10000"))

      assert eval.pass?
      assert eval.constraints == %{}
    end
  end

  describe "rolling_spend_cap" do
    test "violation when projected spend exceeds cap" do
      cp = Fixtures.counterparty()

      _prior =
        Fixtures.agent_intent(
          counterparty: cp,
          amount: Decimal.new("800"),
          state: :executed
        )

      rule =
        Fixtures.policy_rule(
          rule_type: :rolling_spend_cap,
          params: %{"window_hours" => 24, "max_total" => "1000", "currency" => "USDC"}
        )

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "250"))

      refute eval.pass?
      assert [v] = eval.violations
      assert v.rule_id == rule.id
      assert v.code == "rolling_cap_exceeded"
    end

    test "pass when projected spend is within cap" do
      _prior =
        Fixtures.agent_intent(amount: Decimal.new("100"), state: :executed)

      _rule =
        Fixtures.policy_rule(
          rule_type: :rolling_spend_cap,
          params: %{"window_hours" => 24, "max_total" => "1000", "currency" => "USDC"}
        )

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "100"))
      assert eval.pass?
    end

    test "ignores intents outside the rolling window" do
      # Intent submitted 48h ago, but window is 24h — should not count.
      old_ts = DateTime.add(DateTime.utc_now(), -48 * 3600, :second)

      _old =
        Fixtures.agent_intent(
          amount: Decimal.new("9000"),
          state: :executed,
          submitted_at: old_ts
        )

      _rule =
        Fixtures.policy_rule(
          rule_type: :rolling_spend_cap,
          params: %{"window_hours" => 24, "max_total" => "1000", "currency" => "USDC"}
        )

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "100"))
      assert eval.pass?
    end

    test "excludes the candidate's own intent from the rolling total" do
      cp = Fixtures.counterparty()

      intent =
        Fixtures.agent_intent(
          counterparty: cp,
          amount: Decimal.new("900"),
          state: :executing
        )

      _rule =
        Fixtures.policy_rule(
          rule_type: :rolling_spend_cap,
          params: %{"window_hours" => 24, "max_total" => "1000", "currency" => "USDC"}
        )

      # Re-evaluating a 900 intent against a 1000 cap should pass,
      # because the candidate doesn't double-count itself.
      eval = Policies.evaluate(intent)
      assert eval.pass?
    end
  end

  describe "slippage_ceiling" do
    test "swap within ceiling passes and emits constraint" do
      _rule =
        Fixtures.policy_rule(
          rule_type: :slippage_ceiling,
          params: %{"max_bps" => 50}
        )

      eval = Policies.evaluate(input_for(:swap, "USDC", "base", "100", slippage_bps: 30))
      assert eval.pass?
      assert eval.constraints.max_slippage_bps == 50
    end

    test "swap exceeding ceiling fails" do
      _rule =
        Fixtures.policy_rule(rule_type: :slippage_ceiling, params: %{"max_bps" => 25})

      eval = Policies.evaluate(input_for(:swap, "USDC", "base", "100", slippage_bps: 100))
      refute eval.pass?
      assert [v] = eval.violations
      assert v.code == "slippage_above_ceiling"
    end

    test "swap without slippage fails the rule" do
      _rule =
        Fixtures.policy_rule(rule_type: :slippage_ceiling, params: %{"max_bps" => 50})

      eval = Policies.evaluate(input_for(:swap, "USDC", "base", "100"))
      refute eval.pass?
      assert [v] = eval.violations
      assert v.code == "missing_slippage"
    end

    test "transfer skips slippage rules entirely" do
      _rule =
        Fixtures.policy_rule(rule_type: :slippage_ceiling, params: %{"max_bps" => 50})

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "100"))
      assert eval.pass?
      # The rule still matched (no scope) but produced no violation
      # because slippage is swap-only.
      assert eval.matched_rule_ids != []
    end
  end

  describe "allowed_router" do
    test "swap with allowed router passes" do
      _rule =
        Fixtures.policy_rule(
          rule_type: :allowed_router,
          params: %{"mode" => "allowlist", "routers" => ["uniswap_v3", "cowswap"]}
        )

      eval =
        Policies.evaluate(
          input_for(:swap, "USDC", "base", "100", router: "uniswap_v3", slippage_bps: 10)
        )

      assert eval.pass?
      assert eval.constraints.allowed_routers == ["uniswap_v3", "cowswap"]
    end

    test "swap with disallowed router fails" do
      _rule =
        Fixtures.policy_rule(
          rule_type: :allowed_router,
          params: %{"mode" => "allowlist", "routers" => ["cowswap"]}
        )

      eval = Policies.evaluate(input_for(:swap, "USDC", "base", "100", router: "paraswap"))
      refute eval.pass?
      assert [v] = eval.violations
      assert v.code == "router_not_allowed"
    end

    test "swap with router on denylist fails" do
      _rule =
        Fixtures.policy_rule(
          rule_type: :allowed_router,
          params: %{"mode" => "denylist", "routers" => ["legacy_v1"]}
        )

      eval = Policies.evaluate(input_for(:swap, "USDC", "base", "100", router: "legacy_v1"))
      refute eval.pass?
      assert [v] = eval.violations
      assert v.code == "router_denied"
    end

    test "transfer skips router rules" do
      _rule =
        Fixtures.policy_rule(
          rule_type: :allowed_router,
          params: %{"mode" => "allowlist", "routers" => ["cowswap"]}
        )

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "100"))
      assert eval.pass?
    end
  end

  describe "allowed_asset" do
    test "asset allowlist passes the match" do
      _rule =
        Fixtures.policy_rule(
          rule_type: :allowed_asset,
          params: %{"mode" => "allowlist", "assets" => ["USDC", "WETH"]}
        )

      assert Policies.evaluate(input_for(:transfer, "USDC", "base", "10")).pass?
      refute Policies.evaluate(input_for(:transfer, "DAI", "base", "10")).pass?
    end

    test "asset denylist blocks listed assets" do
      _rule =
        Fixtures.policy_rule(
          rule_type: :allowed_asset,
          params: %{"mode" => "denylist", "assets" => ["DAI"]}
        )

      assert Policies.evaluate(input_for(:transfer, "USDC", "base", "10")).pass?

      eval = Policies.evaluate(input_for(:transfer, "DAI", "base", "10"))
      refute eval.pass?
      assert [%{code: "asset_denied"}] = eval.violations
    end
  end

  describe "allowed_chain" do
    test "chain allowlist / denylist" do
      _allow =
        Fixtures.policy_rule(
          rule_type: :allowed_chain,
          params: %{"mode" => "allowlist", "chains" => ["base"]}
        )

      assert Policies.evaluate(input_for(:transfer, "USDC", "base", "10")).pass?

      eval = Policies.evaluate(input_for(:transfer, "USDC", "arbitrum", "10"))
      refute eval.pass?
      assert [%{code: "chain_not_allowed"}] = eval.violations
    end
  end

  describe "autonomy_tier" do
    test ":auto does not constrain" do
      _rule = Fixtures.policy_rule(rule_type: :autonomy_tier, params: %{"tier" => "auto"})
      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "10"))
      assert eval.pass?
      assert eval.autonomy_tier == :auto
    end

    test ":manual sets autonomy_tier but does not violate" do
      _rule = Fixtures.policy_rule(rule_type: :autonomy_tier, params: %{"tier" => "manual"})
      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "10"))
      assert eval.pass?
      assert eval.autonomy_tier == :manual
    end

    test ":block emits a violation and sets tier to :block" do
      _rule = Fixtures.policy_rule(rule_type: :autonomy_tier, params: %{"tier" => "block"})
      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "10"))
      refute eval.pass?
      assert [v] = eval.violations
      assert v.code == "blocked_by_autonomy_tier"
      assert eval.autonomy_tier == :block
    end

    test "collapses to the most restrictive tier across multiple matching rules" do
      _auto = Fixtures.policy_rule(rule_type: :autonomy_tier, params: %{"tier" => "auto"})
      _manual = Fixtures.policy_rule(rule_type: :autonomy_tier, params: %{"tier" => "manual"})

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "10"))
      assert eval.autonomy_tier == :manual
    end
  end

  describe "time_window" do
    test "pass when candidate time is inside the UTC window" do
      _rule =
        Fixtures.policy_rule(
          rule_type: :time_window,
          params: %{
            "days_of_week" => [1, 2, 3, 4, 5, 6, 7],
            "start_hhmm" => "00:00",
            "end_hhmm" => "24:00",
            "timezone" => "UTC"
          }
        )

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "10"))
      assert eval.pass?
    end

    test "violation when outside the hours window" do
      _rule =
        Fixtures.policy_rule(
          rule_type: :time_window,
          params: %{
            "days_of_week" => [1, 2, 3, 4, 5, 6, 7],
            "start_hhmm" => "09:00",
            "end_hhmm" => "17:00",
            "timezone" => "UTC"
          }
        )

      # Monday 06:00 UTC — before the window.
      now = DateTime.from_naive!(~N[2026-04-13 06:00:00.000000], "Etc/UTC")

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "10"), now: now)
      refute eval.pass?
      assert [v] = eval.violations
      assert v.code == "outside_allowed_hours"
    end

    test "violation when outside the allowed days" do
      _rule =
        Fixtures.policy_rule(
          rule_type: :time_window,
          params: %{
            "days_of_week" => [1, 2, 3, 4, 5],
            "start_hhmm" => "00:00",
            "end_hhmm" => "24:00",
            "timezone" => "UTC"
          }
        )

      # Saturday 12:00 UTC.
      now = DateTime.from_naive!(~N[2026-04-11 12:00:00.000000], "Etc/UTC")

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "10"), now: now)
      refute eval.pass?
      assert [v] = eval.violations
      assert v.code == "outside_allowed_days"
    end
  end

  # ---------------------------------------------------------------------
  # Composition
  # ---------------------------------------------------------------------

  describe "composition" do
    test "violations accumulate across multiple rules, no short-circuit" do
      _amount =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "10"}
        )

      _asset =
        Fixtures.policy_rule(
          rule_type: :allowed_asset,
          params: %{"mode" => "allowlist", "assets" => ["WETH"]}
        )

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "100"))
      refute eval.pass?
      codes = Enum.map(eval.violations, & &1.code)
      assert "amount_above_limit" in codes
      assert "asset_not_allowed" in codes
    end

    test "constraints tighten across multiple matching rules of the same type" do
      _a =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "1000", "currency" => "USDC"}
        )

      _b =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "250", "currency" => "USDC"}
        )

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "100"))
      assert eval.pass?
      assert Decimal.equal?(eval.constraints.amount_ceiling, Decimal.new("250"))
    end
  end

  # #202: every Morpho rule type must be inert for v1 intent kinds
  # — folding into `Bank.DefiVenues.Morpho.PolicyInput` happens via
  # `Bank.Policies.Morpho.RulesCompiler`. The main evaluator should
  # NOT flag these rules as `unknown_rule_type` and NOT contribute
  # any violation or constraint to v1 intents.
  describe "Morpho rule types — non-DeFi evaluator skip (#202)" do
    test "every Morpho rule type is a no-op for a transfer intent" do
      morpho_types = Bank.Policies.PolicyRule.morpho_rule_types()

      assert length(morpho_types) == 16

      for rule_type <- morpho_types do
        # Insert one of each Morpho rule type into the workspace.
        _rule = Fixtures.policy_rule(rule_type: rule_type, params: %{})

        eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "100"))

        # Existing non-DeFi behaviour is not regressed: no
        # violations from the new rule types, no
        # `unknown_rule_type` flag, no constraint contribution.
        codes = Enum.map(eval.violations, & &1.code)

        refute "unknown_rule_type" in codes,
               "#{rule_type} should not be flagged as unknown_rule_type"

        refute Atom.to_string(rule_type) in codes,
               "#{rule_type} should not produce a violation against a v1 transfer intent"
      end
    end

    test "Morpho rules coexist with v1 rules without contaminating evaluation" do
      _amount =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max_per_tx" => "1000", "currency" => "USDC"}
        )

      _morpho_lltv =
        Fixtures.policy_rule(
          rule_type: :max_market_lltv,
          params: %{"max_lltv_bps" => 8600}
        )

      _morpho_incident =
        Fixtures.policy_rule(rule_type: :incident_hold, params: %{"active" => true})

      eval = Policies.evaluate(input_for(:transfer, "USDC", "base", "100"))

      assert eval.pass?
      assert Decimal.equal?(eval.constraints.amount_ceiling, Decimal.new("1000"))
      assert Enum.empty?(eval.violations)
    end
  end

  # ---------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------

  defp input_for(kind, asset, chain, amount, extras \\ []) do
    extras = Enum.into(extras, %{})

    base = %EvaluationInput{
      kind: kind,
      asset: asset,
      chain: chain,
      amount: Decimal.new(amount),
      target_counterparty_id: nil,
      target_address_label_id: nil,
      target_raw_address: nil,
      slippage_bps: nil,
      router: nil,
      intent_id: nil,
      submitted_at: DateTime.utc_now(),
      now: DateTime.utc_now()
    }

    Enum.reduce(extras, base, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end
end
