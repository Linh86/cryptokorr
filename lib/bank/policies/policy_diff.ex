defmodule Bank.Policies.PolicyDiff do
  @moduledoc """
  Classify the difference between two `Bank.Policies.PolicyRule`
  sets (the prior published rule set vs a draft or next-published
  rule set) as a tightening or expansion of the agent's authority.

  This is the safety layer behind the Advanced policy screen's
  "requires fresh permission install" banner (#agent-advanced).
  The Phoenix decision-engine gate enforces every published rule
  on every dispatch, but the on-chain delegation's authority is
  pinned at install time. A publish that *expands* that authority
  must not silently take effect — the operator has to re-install
  the permission so the on-chain validator covers the broader
  scope.

  ## Why "default to expansion"

  The classifier is intentionally conservative: any change it
  cannot positively prove is tightening is reported as
  expansion. New rule types or unparseable params land in
  expansion automatically, so a future rule-type addition that
  forgets to extend this module cannot accidentally widen the
  agent's authority through the silent-passthrough branch.

  ## Public surface

      classify(prior_rules, next_rules) :: %{
        tightening: [change],
        expansion:  [change],
        unchanged:  [PolicyRule],
        requires_permission_reinstall?: boolean
      }

  See `Bank.Policies.Versions.diff_against_published/1` for the
  caller that hydrates the rule lists from the version's
  `rule_ids` jsonb.
  """

  alias Bank.Policies.PolicyRule

  @type change :: %{
          required(:kind) => :added | :removed | :modified,
          required(:rule_type) => atom(),
          required(:rule_id) => Ecto.UUID.t(),
          required(:prior) => PolicyRule.t() | nil,
          required(:next) => PolicyRule.t() | nil,
          required(:direction) => :tightening | :expansion,
          required(:reason) => String.t()
        }

  @type t :: %{
          required(:tightening) => [change()],
          required(:expansion) => [change()],
          required(:unchanged) => [PolicyRule.t()],
          required(:requires_permission_reinstall?) => boolean()
        }

  @doc """
  Classify the transition from `prior_rules` to `next_rules`.

  See module doc for the safe-by-default semantics.
  """
  @spec classify([PolicyRule.t()], [PolicyRule.t()]) :: t()
  def classify(prior_rules, next_rules)
      when is_list(prior_rules) and is_list(next_rules) do
    prior_by_id = Map.new(prior_rules, &{&1.id, &1})
    next_by_id = Map.new(next_rules, &{&1.id, &1})

    removed_ids = Map.keys(prior_by_id) -- Map.keys(next_by_id)
    added_ids = Map.keys(next_by_id) -- Map.keys(prior_by_id)
    shared_ids = Map.keys(next_by_id) -- added_ids

    # ── id-matched shared pairs (true updates of the same row) ──

    shared_changes =
      shared_ids
      |> Enum.map(fn id ->
        prior = Map.fetch!(prior_by_id, id)
        next = Map.fetch!(next_by_id, id)
        {id, prior, next}
      end)

    {id_modified, id_unchanged} =
      Enum.split_with(shared_changes, fn {_id, p, n} -> rules_differ?(p, n) end)

    # ── fingerprint-matched pairs (logical revisions w/ new ids) ──
    #
    # `BankWeb.PolicyBuilderLive` revises a rule by inserting a new
    # `:draft` row (new uuid) and swapping the id in the draft's
    # `rule_ids` list. Treating "remove old id + add new id" as
    # remove+add would classify every legitimate amount-cap edit as
    # expansion. We pair removed-side and added-side rules by their
    # logical fingerprint `(rule_type, scope, priority)` so an edit
    # of "the same logical rule" is reported as a modification with
    # the correct tightening/expansion direction.

    removed_rules = Enum.map(removed_ids, &Map.fetch!(prior_by_id, &1))
    added_rules = Enum.map(added_ids, &Map.fetch!(next_by_id, &1))

    {paired_changes, true_removed, true_added} = pair_by_fingerprint(removed_rules, added_rules)

    modified_changes =
      Enum.map(id_modified, fn {id, prior, next} ->
        {direction, reason} = classify_modification(prior, next)

        %{
          kind: :modified,
          rule_type: next.rule_type,
          rule_id: id,
          prior: prior,
          next: next,
          direction: direction,
          reason: reason
        }
      end) ++
        Enum.map(paired_changes, fn {prior, next} ->
          {direction, reason} = classify_modification(prior, next)

          %{
            kind: :modified,
            rule_type: next.rule_type,
            rule_id: next.id,
            prior: prior,
            next: next,
            direction: direction,
            reason: reason
          }
        end)

    removed_changes =
      Enum.map(true_removed, fn rule ->
        %{
          kind: :removed,
          rule_type: rule.rule_type,
          rule_id: rule.id,
          prior: rule,
          next: nil,
          direction: :expansion,
          reason: "rule was removed; dropping a constraint expands the agent's authority"
        }
      end)

    added_changes =
      Enum.map(true_added, fn rule ->
        %{
          kind: :added,
          rule_type: rule.rule_type,
          rule_id: rule.id,
          prior: nil,
          next: rule,
          direction: :tightening,
          reason: "rule was added; new constraints tighten the agent's authority"
        }
      end)

    unchanged_rules = Enum.map(id_unchanged, fn {_id, _p, n} -> n end)

    all_changes = removed_changes ++ added_changes ++ modified_changes

    {tightening, expansion} = Enum.split_with(all_changes, &(&1.direction == :tightening))

    %{
      tightening: tightening,
      expansion: expansion,
      unchanged: unchanged_rules,
      requires_permission_reinstall?: expansion != []
    }
  end

  # Greedy pair-up by `(rule_type, scope, priority)` fingerprint.
  # If multiple removed rules share a fingerprint with multiple
  # added rules, we pair them in insertion order — the residual
  # tail on either side falls through to the true added/removed
  # buckets. That is conservative: an unpaired removal is still
  # "expansion" and an unpaired addition is still "tightening".
  defp pair_by_fingerprint(removed, added) do
    do_pair(removed, added, [], [])
  end

  defp do_pair([], added, pairs, removed_acc),
    do: {Enum.reverse(pairs), Enum.reverse(removed_acc), added}

  defp do_pair([r | rest_removed], added, pairs, removed_acc) do
    case Enum.split_with(added, fn a -> fingerprint(a) == fingerprint(r) end) do
      {[match | rest_matches], others} ->
        do_pair(rest_removed, rest_matches ++ others, [{r, match} | pairs], removed_acc)

      {[], _} ->
        do_pair(rest_removed, added, pairs, [r | removed_acc])
    end
  end

  defp fingerprint(%PolicyRule{rule_type: rt, scope: scope, priority: prio}) do
    {rt, normalise(scope), prio}
  end

  # Rule fields we consider for the "did this rule change?" check.
  # Scope/params/priority/state are the operator-meaningful axes.
  defp rules_differ?(%PolicyRule{} = a, %PolicyRule{} = b) do
    normalise(a.scope) != normalise(b.scope) or
      normalise(a.params) != normalise(b.params) or
      a.priority != b.priority or
      a.rule_type != b.rule_type
  end

  defp normalise(nil), do: %{}
  defp normalise(%{} = m), do: m

  # ---------------------------------------------------------------
  # Per-rule-type modification classifier.
  #
  # Each clause MUST return a `{:tightening | :expansion, reason}`
  # tuple. If a clause cannot prove tightening, it MUST return
  # `:expansion` — see module doc.
  # ---------------------------------------------------------------

  defp classify_modification(
         %PolicyRule{rule_type: :amount_limit} = prior,
         %PolicyRule{rule_type: :amount_limit} = next
       ) do
    classify_decimal_param(prior, next, "max_per_tx", "max amount per intent")
  end

  defp classify_modification(
         %PolicyRule{rule_type: :rolling_spend_cap} = prior,
         %PolicyRule{rule_type: :rolling_spend_cap} = next
       ) do
    cap_direction = compare_decimal_param(prior.params, next.params, "max_total")
    win_direction = compare_integer_param(prior.params, next.params, "window_hours")

    cond do
      cap_direction == :error or win_direction == :error ->
        {:expansion,
         "rolling_spend_cap params could not be parsed; defaulting to expansion to require reinstall"}

      cap_direction == :greater or win_direction == :greater ->
        {:expansion,
         "rolling_spend_cap loosened (higher cap or longer window allows more total spend)"}

      cap_direction == :less and win_direction in [:equal, :less] ->
        {:tightening, "rolling_spend_cap tightened (lower cap, same-or-shorter window)"}

      cap_direction == :equal and win_direction == :less ->
        {:tightening,
         "rolling_spend_cap window shortened with same cap (same total over less time)"}

      cap_direction == :equal and win_direction == :equal ->
        {:tightening, "rolling_spend_cap params unchanged"}

      true ->
        {:expansion,
         "rolling_spend_cap change could not be proved tightening; defaulting to expansion"}
    end
  end

  defp classify_modification(
         %PolicyRule{rule_type: :slippage_ceiling} = prior,
         %PolicyRule{rule_type: :slippage_ceiling} = next
       ) do
    case compare_integer_param(prior.params, next.params, "max_bps") do
      :less ->
        {:tightening, "slippage ceiling lowered (less slippage allowed per swap)"}

      :equal ->
        {:tightening, "slippage ceiling unchanged"}

      :greater ->
        {:expansion, "slippage ceiling raised (more slippage allowed per swap)"}

      _ ->
        {:expansion, "slippage_ceiling params could not be parsed; defaulting to expansion"}
    end
  end

  defp classify_modification(
         %PolicyRule{rule_type: :allowed_asset} = prior,
         %PolicyRule{rule_type: :allowed_asset} = next
       ) do
    classify_allowlist(prior, next, "assets", "allowed assets")
  end

  defp classify_modification(
         %PolicyRule{rule_type: :allowed_chain} = prior,
         %PolicyRule{rule_type: :allowed_chain} = next
       ) do
    classify_allowlist(prior, next, "chains", "allowed chains")
  end

  defp classify_modification(
         %PolicyRule{rule_type: :allowed_router} = prior,
         %PolicyRule{rule_type: :allowed_router} = next
       ) do
    classify_allowlist(prior, next, "routers", "allowed routers")
  end

  defp classify_modification(
         %PolicyRule{rule_type: :autonomy_tier} = prior,
         %PolicyRule{rule_type: :autonomy_tier} = next
       ) do
    prior_tier = Map.get(prior.params || %{}, "tier")
    next_tier = Map.get(next.params || %{}, "tier")

    case {prior_tier, next_tier} do
      {same, same} ->
        {:tightening, "autonomy_tier unchanged"}

      {p, n} when p in ["auto", "manual", "block"] and n in ["auto", "manual", "block"] ->
        if tier_strictness(n) >= tier_strictness(p) do
          {:tightening, "autonomy_tier moved toward block (#{p} → #{n})"}
        else
          {:expansion, "autonomy_tier loosened (#{p} → #{n})"}
        end

      _ ->
        {:expansion, "autonomy_tier value not parseable; defaulting to expansion"}
    end
  end

  defp classify_modification(
         %PolicyRule{rule_type: :time_window},
         %PolicyRule{rule_type: :time_window}
       ) do
    {:expansion,
     "time_window changes are treated as expansion (broader/shifted windows allow new dispatch slots)"}
  end

  # Rule-type change on the SAME id: the supersedes path forbids
  # this (rule_type carries forward), but if it ever happens treat
  # it as expansion. Same for any morpho rule type — those are
  # post-MVP for the advanced screen's diff classifier and default
  # to expansion until per-type semantics land.
  defp classify_modification(%PolicyRule{} = prior, %PolicyRule{} = next) do
    cond do
      prior.rule_type != next.rule_type ->
        {:expansion,
         "rule_type changed (#{prior.rule_type} → #{next.rule_type}); reinstall required"}

      true ->
        {:expansion,
         "rule_type #{next.rule_type} has no tightening classifier yet; defaulting to expansion"}
    end
  end

  # ---------------------------------------------------------------
  # Per-axis comparators.
  # ---------------------------------------------------------------

  defp classify_decimal_param(prior, next, key, label) do
    case compare_decimal_param(prior.params, next.params, key) do
      :less -> {:tightening, "#{label} lowered"}
      :equal -> {:tightening, "#{label} unchanged"}
      :greater -> {:expansion, "#{label} raised"}
      _ -> {:expansion, "#{label} could not be parsed; defaulting to expansion"}
    end
  end

  defp compare_decimal_param(prior_params, next_params, key) do
    with {:ok, a} <- decimal_at(prior_params, key),
         {:ok, b} <- decimal_at(next_params, key) do
      case Decimal.compare(a, b) do
        :lt -> :greater
        :gt -> :less
        :eq -> :equal
      end
    else
      _ -> :error
    end
  end

  defp compare_integer_param(prior_params, next_params, key) do
    with {:ok, a} <- integer_at(prior_params, key),
         {:ok, b} <- integer_at(next_params, key) do
      cond do
        a < b -> :greater
        a > b -> :less
        true -> :equal
      end
    else
      _ -> :error
    end
  end

  defp decimal_at(params, key) do
    case Map.get(params || %{}, key) do
      %Decimal{} = d ->
        {:ok, d}

      n when is_integer(n) or is_float(n) ->
        {:ok, Decimal.new(to_string(n))}

      v when is_binary(v) ->
        case Decimal.parse(v) do
          {d, ""} -> {:ok, d}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp integer_at(params, key) do
    case Map.get(params || %{}, key) do
      n when is_integer(n) and n >= 0 ->
        {:ok, n}

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp classify_allowlist(%PolicyRule{} = prior, %PolicyRule{} = next, list_key, label) do
    prior_params = prior.params || %{}
    next_params = next.params || %{}

    prior_mode = Map.get(prior_params, "mode", "allowlist")
    next_mode = Map.get(next_params, "mode", "allowlist")

    prior_list = list_at(prior_params, list_key)
    next_list = list_at(next_params, list_key)

    cond do
      prior_mode != next_mode ->
        {:expansion,
         "#{label} mode flipped (#{prior_mode} → #{next_mode}); flipping intent is treated as expansion"}

      prior_list == :error or next_list == :error ->
        {:expansion, "#{label} list could not be parsed; defaulting to expansion"}

      true ->
        added = next_list -- prior_list
        removed = prior_list -- next_list
        same? = added == [] and removed == []

        case {next_mode, added, removed} do
          {_, [], []} ->
            {:tightening, "#{label} unchanged"}

          {"allowlist", [], _removed} ->
            {:tightening, "#{label} allowlist shrank (#{length(removed)} entries removed)"}

          {"allowlist", _added, _} ->
            {:expansion,
             "#{label} allowlist grew (#{length(added)} new entries broaden the agent's authority)"}

          {"denylist", _added, []} ->
            {:tightening,
             "#{label} denylist grew (#{length(added)} new denied entries tighten authority)"}

          {"denylist", _, _removed} when removed != [] ->
            {:expansion,
             "#{label} denylist shrank (#{length(removed)} entries removed; previously-blocked surface is now allowed)"}

          _ ->
            if same? do
              {:tightening, "#{label} unchanged"}
            else
              {:expansion,
               "#{label} change could not be proved tightening; defaulting to expansion"}
            end
        end
    end
  end

  defp list_at(params, key) do
    case Map.get(params, key) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1), do: list, else: :error

      _ ->
        :error
    end
  end

  defp tier_strictness("auto"), do: 0
  defp tier_strictness("manual"), do: 1
  defp tier_strictness("block"), do: 2
  defp tier_strictness(_), do: -1
end
