defmodule Bank.Policies.PolicyDiffTest do
  @moduledoc """
  Unit tests for the tightening / expansion classifier the
  Advanced policy screen uses to decide whether a draft publish
  needs a fresh permission install.

  The classifier is safety-critical: a false "tightening" lets an
  admin silently expand the agent's on-chain authority. So every
  rule type has at least one positive (tightening) test, one
  negative (expansion) test, and one defensive test (unparseable
  params → expansion).
  """
  use ExUnit.Case, async: true

  alias Bank.Policies.{PolicyDiff, PolicyRule}

  defp rule(rule_type, params, opts \\ []) do
    %PolicyRule{
      id: Keyword.get(opts, :id, Ecto.UUID.generate()),
      rule_type: rule_type,
      params: params,
      scope: Keyword.get(opts, :scope, %{}),
      priority: Keyword.get(opts, :priority, 0),
      state: Keyword.get(opts, :state, :active),
      version: Keyword.get(opts, :version, 1)
    }
  end

  describe "added / removed rules" do
    test "adding a rule is tightening" do
      next = rule(:amount_limit, %{"max_per_tx" => "100"})

      diff = PolicyDiff.classify([], [next])

      assert diff.tightening |> Enum.map(& &1.kind) == [:added]
      assert diff.expansion == []
      refute diff.requires_permission_reinstall?
    end

    test "removing a rule is expansion" do
      prior = rule(:amount_limit, %{"max_per_tx" => "100"})

      diff = PolicyDiff.classify([prior], [])

      assert diff.expansion |> Enum.map(& &1.kind) == [:removed]
      assert diff.tightening == []
      assert diff.requires_permission_reinstall?
    end
  end

  describe "amount_limit" do
    test "lowering max_per_tx is tightening" do
      id = Ecto.UUID.generate()
      prior = rule(:amount_limit, %{"max_per_tx" => "100"}, id: id)
      next = rule(:amount_limit, %{"max_per_tx" => "50"}, id: id)

      diff = PolicyDiff.classify([prior], [next])

      assert [_] = diff.tightening
      assert diff.expansion == []
      refute diff.requires_permission_reinstall?
    end

    test "raising max_per_tx is expansion" do
      id = Ecto.UUID.generate()
      prior = rule(:amount_limit, %{"max_per_tx" => "100"}, id: id)
      next = rule(:amount_limit, %{"max_per_tx" => "1000"}, id: id)

      diff = PolicyDiff.classify([prior], [next])

      assert [_] = diff.expansion
      assert diff.tightening == []
      assert diff.requires_permission_reinstall?
    end

    test "unparseable max_per_tx defaults to expansion" do
      id = Ecto.UUID.generate()
      prior = rule(:amount_limit, %{"max_per_tx" => "100"}, id: id)
      next = rule(:amount_limit, %{"max_per_tx" => "not-a-number"}, id: id)

      diff = PolicyDiff.classify([prior], [next])

      assert diff.requires_permission_reinstall?
    end
  end

  describe "rolling_spend_cap" do
    test "lower cap with same window = tightening" do
      id = Ecto.UUID.generate()

      prior =
        rule(:rolling_spend_cap, %{"max_total" => "500", "window_hours" => 24}, id: id)

      next =
        rule(:rolling_spend_cap, %{"max_total" => "250", "window_hours" => 24}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      refute diff.requires_permission_reinstall?
      assert [_] = diff.tightening
    end

    test "longer window with same cap = expansion (looser average rate)" do
      id = Ecto.UUID.generate()

      prior =
        rule(:rolling_spend_cap, %{"max_total" => "500", "window_hours" => 24}, id: id)

      next =
        rule(:rolling_spend_cap, %{"max_total" => "500", "window_hours" => 168}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      assert diff.requires_permission_reinstall?
    end

    test "higher cap regardless of window = expansion" do
      id = Ecto.UUID.generate()

      prior =
        rule(:rolling_spend_cap, %{"max_total" => "500", "window_hours" => 24}, id: id)

      next =
        rule(:rolling_spend_cap, %{"max_total" => "1000", "window_hours" => 1}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      assert diff.requires_permission_reinstall?
    end
  end

  describe "slippage_ceiling" do
    test "lower max_bps = tightening" do
      id = Ecto.UUID.generate()
      prior = rule(:slippage_ceiling, %{"max_bps" => 100}, id: id)
      next = rule(:slippage_ceiling, %{"max_bps" => 50}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      refute diff.requires_permission_reinstall?
    end

    test "higher max_bps = expansion" do
      id = Ecto.UUID.generate()
      prior = rule(:slippage_ceiling, %{"max_bps" => 50}, id: id)
      next = rule(:slippage_ceiling, %{"max_bps" => 500}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      assert diff.requires_permission_reinstall?
    end
  end

  describe "allowed_asset / allowed_chain / allowed_router" do
    test "shrinking an allowlist is tightening" do
      id = Ecto.UUID.generate()
      prior = rule(:allowed_asset, %{"mode" => "allowlist", "assets" => ["USDC", "USDT"]}, id: id)
      next = rule(:allowed_asset, %{"mode" => "allowlist", "assets" => ["USDC"]}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      refute diff.requires_permission_reinstall?
    end

    test "growing an allowlist is expansion" do
      id = Ecto.UUID.generate()
      prior = rule(:allowed_chain, %{"mode" => "allowlist", "chains" => ["base"]}, id: id)

      next =
        rule(
          :allowed_chain,
          %{"mode" => "allowlist", "chains" => ["base", "base-sepolia"]},
          id: id
        )

      diff = PolicyDiff.classify([prior], [next])
      assert diff.requires_permission_reinstall?
    end

    test "flipping allowlist→denylist is expansion (intent flipped)" do
      id = Ecto.UUID.generate()
      prior = rule(:allowed_router, %{"mode" => "allowlist", "routers" => ["zerox"]}, id: id)
      next = rule(:allowed_router, %{"mode" => "denylist", "routers" => ["zerox"]}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      assert diff.requires_permission_reinstall?
    end

    test "growing a denylist is tightening (more entries blocked)" do
      id = Ecto.UUID.generate()
      prior = rule(:allowed_router, %{"mode" => "denylist", "routers" => ["badrouter1"]}, id: id)

      next =
        rule(
          :allowed_router,
          %{"mode" => "denylist", "routers" => ["badrouter1", "badrouter2"]},
          id: id
        )

      diff = PolicyDiff.classify([prior], [next])
      refute diff.requires_permission_reinstall?
    end

    test "shrinking a denylist is expansion (previously-blocked entry is now allowed)" do
      id = Ecto.UUID.generate()

      prior =
        rule(
          :allowed_router,
          %{"mode" => "denylist", "routers" => ["badrouter1", "badrouter2"]},
          id: id
        )

      next = rule(:allowed_router, %{"mode" => "denylist", "routers" => ["badrouter1"]}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      assert diff.requires_permission_reinstall?
    end

    test "unparseable allowlist defaults to expansion" do
      id = Ecto.UUID.generate()
      prior = rule(:allowed_asset, %{"mode" => "allowlist", "assets" => ["USDC"]}, id: id)
      next = rule(:allowed_asset, %{"mode" => "allowlist", "assets" => "not-a-list"}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      assert diff.requires_permission_reinstall?
    end
  end

  describe "autonomy_tier" do
    test "auto → manual is tightening" do
      id = Ecto.UUID.generate()
      prior = rule(:autonomy_tier, %{"tier" => "auto"}, id: id)
      next = rule(:autonomy_tier, %{"tier" => "manual"}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      refute diff.requires_permission_reinstall?
    end

    test "auto → block is tightening" do
      id = Ecto.UUID.generate()
      prior = rule(:autonomy_tier, %{"tier" => "auto"}, id: id)
      next = rule(:autonomy_tier, %{"tier" => "block"}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      refute diff.requires_permission_reinstall?
    end

    test "manual → auto is expansion" do
      id = Ecto.UUID.generate()
      prior = rule(:autonomy_tier, %{"tier" => "manual"}, id: id)
      next = rule(:autonomy_tier, %{"tier" => "auto"}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      assert diff.requires_permission_reinstall?
    end

    test "block → manual is expansion" do
      id = Ecto.UUID.generate()
      prior = rule(:autonomy_tier, %{"tier" => "block"}, id: id)
      next = rule(:autonomy_tier, %{"tier" => "manual"}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      assert diff.requires_permission_reinstall?
    end

    test "unparseable tier defaults to expansion" do
      id = Ecto.UUID.generate()
      prior = rule(:autonomy_tier, %{"tier" => "manual"}, id: id)
      next = rule(:autonomy_tier, %{"tier" => "haunted"}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      assert diff.requires_permission_reinstall?
    end
  end

  describe "time_window" do
    test "any change defaults to expansion (safe default)" do
      id = Ecto.UUID.generate()
      prior = rule(:time_window, %{"start_hhmm" => "09:00", "end_hhmm" => "17:00"}, id: id)
      next = rule(:time_window, %{"start_hhmm" => "08:00", "end_hhmm" => "17:00"}, id: id)

      diff = PolicyDiff.classify([prior], [next])
      assert diff.requires_permission_reinstall?
    end
  end

  describe "unchanged rules" do
    test "identical rule sets produce no changes" do
      id = Ecto.UUID.generate()
      r = rule(:amount_limit, %{"max_per_tx" => "100"}, id: id)

      diff = PolicyDiff.classify([r], [r])

      assert diff.tightening == []
      assert diff.expansion == []
      assert [_] = diff.unchanged
      refute diff.requires_permission_reinstall?
    end
  end

  describe "mixed tightening + expansion" do
    test "any single expansion flips requires_permission_reinstall?" do
      id1 = Ecto.UUID.generate()
      id2 = Ecto.UUID.generate()

      prior = [
        rule(:amount_limit, %{"max_per_tx" => "100"}, id: id1),
        rule(:slippage_ceiling, %{"max_bps" => 100}, id: id2)
      ]

      next = [
        # tightening
        rule(:amount_limit, %{"max_per_tx" => "50"}, id: id1),
        # expansion
        rule(:slippage_ceiling, %{"max_bps" => 500}, id: id2)
      ]

      diff = PolicyDiff.classify(prior, next)

      assert length(diff.tightening) == 1
      assert length(diff.expansion) == 1
      assert diff.requires_permission_reinstall?
    end
  end
end
