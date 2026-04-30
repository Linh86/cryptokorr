defmodule Bank.Policies do
  @moduledoc """
  Policies bounded context.

  Owns the `PolicyRule` catalog and its versioning semantics. A rule is
  never mutated in place: every revision writes a new version and marks
  the prior one `superseded` so that past decisions can be replayed
  against the exact text that was active at decision time.

  ## Public surface

      # catalog reads
      list_rules(filters, opts)
      get_rule(id)
      load_active_ruleset()

      # catalog writes (all audited)
      create_rule(attrs, opts)
      revise_rule(rule, attrs, opts)
      archive_rule(rule, opts)

      # evaluation
      snapshot_applicable(input, opts)
      evaluate(input, opts)

  The context owns the DB, the audit composition, and the evaluator.
  HTTP controllers, workers, and the future decision engine all go
  through this API — no caller reaches into `PolicyRule` schemas
  directly for writes.

  ## Rule types (v1)

  `amount_limit`, `rolling_spend_cap`, `slippage_ceiling`,
  `allowed_router`, `allowed_asset`, `allowed_chain`, `autonomy_tier`,
  `time_window`. Each evaluator lives in this module as a private
  `evaluate_rule/3` clause.

  ## Applicability

  A rule applies to a candidate when its `scope` covers the candidate:

    * `{}` — global, matches every candidate.
    * `{"counterparty_id": uuid}` — matches intents whose
      `target_counterparty_id` is that uuid. A raw-address intent
      never matches a counterparty-scoped rule.
    * `{"asset": "USDC"}` — matches intents with that asset.
    * `{"chain": "base"}` — matches intents on that chain.

  Scope keys compose: a `{"asset": "USDC", "chain": "base"}` rule
  matches only USDC-on-base candidates. Unknown keys are ignored (a
  forward-compat decision — future scope keys can land without
  breaking old rules).

  Rule types that are meaningful only for a particular intent kind
  (slippage, router → swap) are **skipped** for other kinds rather
  than raised as violations. That mirrors the runtime-flow doc's
  "swap-only rules don't fire on transfers" contract.

  ## Rolling spend cap semantics (MVP)

  `rolling_spend_cap` sums `agent_intents.amount` for intents in state
  `:executing` or `:executed` whose `submitted_at` is within the
  rule's `window_hours` and whose `asset` matches the rule's
  `currency`. Intent-based (rather than execution-based) accounting is
  chosen for v0.1 because it is:

    * sufficient for "stop the runtime from spending more than X per
      window" without waiting on on-chain confirmations;
    * trivially auditable from persisted rows;
    * conservative — an intent that has been accepted for execution
      already committed against the cap, even if the on-chain
      confirmation is still in flight.

  Execution-based accounting (summing confirmed `ExecutionPlan`
  amounts) is the right v1.1 upgrade — tracked in the v1 doc.

  ## Snapshot shape

  `snapshot_applicable/2` and `evaluate/2` both return the ids of
  every applicable active rule as `%{"rule_ids" => [...]}`. This is
  the same jsonb shape `DecisionEnvelope.policy_snapshot_ref` accepts,
  so the decision engine can persist it as-is for deterministic
  replay.
  """

  import Ecto.Query

  alias Bank.Audit.Events
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.{Evaluation, EvaluationInput, PolicyRule}
  alias Bank.Repo
  alias Bank.Runtime
  alias Ecto.Multi

  @type uuid :: String.t()
  @type opts :: keyword()
  @type actor_opts :: [actor: atom(), actor_id: String.t() | nil]

  @default_page_limit 50
  @max_page_limit 500

  @swap_only_rule_types [:slippage_ceiling, :allowed_router]

  # ---------------------------------------------------------------------
  # Catalog reads
  # ---------------------------------------------------------------------

  @doc """
  List policy rules. Returns `%{entries, next_cursor}` to match the
  counterparties / audit pagination contract.

  Filters:

    * `:state` — `:draft` | `:active` | `:superseded` | `:archived` |
      `nil` (all). Default: `nil`.
    * `:rule_type` — one of the `v1` rule types, or `nil` for all.

  Options:

    * `:limit` — default #{@default_page_limit}, capped at
      #{@max_page_limit}.
    * `:cursor` — opaque id cursor returned from a prior page.
    * `:workspace_id` — narrow to one workspace (#158b). When unset,
      every workspace's rules come back; that legacy path stays
      open until every caller is on the new path.
  """
  @spec list_rules(map() | keyword(), opts()) :: %{
          entries: [PolicyRule.t()],
          next_cursor: String.t() | nil
        }
  def list_rules(filters \\ %{}, opts \\ []) do
    filters = to_map(filters)
    limit = opts |> Keyword.get(:limit, @default_page_limit) |> clamp_limit()
    cursor = Keyword.get(opts, :cursor)
    workspace_id = Keyword.get(opts, :workspace_id)

    base =
      PolicyRule
      |> apply_rule_filters(filters)
      |> scope_rule_to_workspace(workspace_id)
      |> order_by([r], asc: r.inserted_at, asc: r.id)

    base =
      case cursor do
        nil -> base
        cursor -> apply_cursor(base, cursor)
      end

    rows = base |> limit(^(limit + 1)) |> Repo.all()

    {entries, has_more?} =
      case rows do
        rows when length(rows) > limit -> {Enum.take(rows, limit), true}
        rows -> {rows, false}
      end

    next_cursor =
      case {has_more?, List.last(entries)} do
        {true, %PolicyRule{} = last} -> encode_cursor(last)
        _ -> nil
      end

    %{entries: entries, next_cursor: next_cursor}
  end

  @doc """
  Fetch a single policy rule by id.
  """
  @spec get_rule(uuid()) :: {:ok, PolicyRule.t()} | {:error, :not_found}
  def get_rule(id) when is_binary(id) do
    case Repo.get(PolicyRule, id) do
      nil -> {:error, :not_found}
      %PolicyRule{} = rule -> {:ok, rule}
    end
  end

  @doc """
  Workspace-scoped `get_rule/1` (#159b). Returns
  `{:error, :not_found}` for unknown ids AND for ids that belong
  to a different workspace.
  """
  @spec get_rule_in_workspace(uuid(), uuid()) ::
          {:ok, PolicyRule.t()} | {:error, :not_found}
  def get_rule_in_workspace(id, workspace_id)
      when is_binary(id) and is_binary(workspace_id) do
    case Repo.one(
           from r in PolicyRule,
             where: r.id == ^id and r.workspace_id == ^workspace_id
         ) do
      nil -> {:error, :not_found}
      %PolicyRule{} = rule -> {:ok, rule}
    end
  end

  @doc """
  Load the current active rule set, sorted `(priority desc,
  inserted_at asc)`. Rules with higher priority evaluate first — the
  order matters for tie-breaks inside a single rule type (e.g. two
  `autonomy_tier` rules both matching).

  Options:

    * `:workspace_id` — narrow to one workspace (#158b). Defaults
      to `nil` (legacy: returns the full active ruleset across
      workspaces).
  """
  @spec load_active_ruleset(opts()) :: [PolicyRule.t()]
  def load_active_ruleset(opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)

    PolicyRule
    |> where([r], r.state == :active)
    |> scope_rule_to_workspace(workspace_id)
    |> order_by([r], desc: r.priority, asc: r.inserted_at, asc: r.id)
    |> Repo.all()
  end

  # ---------------------------------------------------------------------
  # Catalog writes
  # ---------------------------------------------------------------------

  @doc """
  Create a new policy rule. Emits `policy.created`.

  `attrs` takes the same keys as `PolicyRule.changeset/2`. The caller
  supplies `:rule_type`, `:params`, and `:created_by`; `:state`
  defaults to `:active` (freshly-authored rules go live immediately)
  unless the caller asks for `:draft`.
  """
  @spec create_rule(map(), actor_opts()) ::
          {:ok, PolicyRule.t()} | {:error, Ecto.Changeset.t()}
  def create_rule(attrs, opts \\ []) do
    attrs =
      attrs
      |> normalise_attrs()
      |> Map.put_new(:state, :active)
      |> stamp_workspace_id(opts)

    Multi.new()
    |> Multi.insert(:rule, PolicyRule.changeset(%PolicyRule{}, attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{rule: rule}} ->
        Runtime.emit_audit(Events.policy_created(rule, actor_opts(opts)))
        {:ok, rule}

      {:error, :rule, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Revise an existing active rule. Inserts a new version that
  supersedes the prior row in a single transaction; emits
  `policy.revised` on success.

  Returns `{:error, :not_active}` when the supplied rule is not the
  current active version — revisions run against the tip of the
  supersession chain so that older rows aren't reborn.
  """
  @spec revise_rule(PolicyRule.t(), map(), actor_opts()) ::
          {:ok, PolicyRule.t()}
          | {:error, Ecto.Changeset.t()}
          | {:error, :not_active}
  def revise_rule(%PolicyRule{state: state} = _rule, _attrs, _opts) when state != :active,
    do: {:error, :not_active}

  def revise_rule(%PolicyRule{} = prior, attrs, opts) do
    attrs =
      attrs
      |> normalise_attrs()
      |> Map.put_new(:created_by, Keyword.get(opts, :actor, :user))

    Multi.new()
    |> Multi.update(:superseded, PolicyRule.mark_superseded(prior))
    |> Multi.insert(:successor, PolicyRule.supersede(prior, attrs))
    |> Repo.transaction()
    |> case do
      {:ok, %{successor: successor}} ->
        Runtime.emit_audit(Events.policy_revised(prior, successor, actor_opts!(opts)))
        {:ok, successor}

      {:error, :successor, changeset, _} ->
        {:error, changeset}

      {:error, :superseded, changeset, _} ->
        {:error, changeset}
    end
  end

  @doc """
  Archive an active policy rule. Idempotent-ish: returns
  `{:error, :not_active}` when the rule has already been superseded
  or archived so the caller sees the distinction explicitly.
  """
  @spec archive_rule(PolicyRule.t(), actor_opts()) ::
          {:ok, PolicyRule.t()} | {:error, Ecto.Changeset.t()} | {:error, :not_active}
  def archive_rule(%PolicyRule{state: state}, _opts) when state != :active,
    do: {:error, :not_active}

  def archive_rule(%PolicyRule{} = rule, opts) do
    changeset = PolicyRule.changeset(rule, %{state: :archived})

    Multi.new()
    |> Multi.update(:rule, changeset)
    |> Repo.transaction()
    |> case do
      {:ok, %{rule: archived}} ->
        Runtime.emit_audit(Events.policy_archived(archived, actor_opts!(opts)))
        {:ok, archived}

      {:error, :rule, changeset, _} ->
        {:error, changeset}
    end
  end

  # ---------------------------------------------------------------------
  # Evaluation
  # ---------------------------------------------------------------------

  @doc """
  Capture the applicable rule uuids for a candidate. Returns the jsonb
  shape `DecisionEnvelope.policy_snapshot_ref` accepts:

      %{"rule_ids" => [uuid, ...]}

  `rule_ids` is ordered `(priority desc, inserted_at asc)` — the same
  order used for evaluation — so downstream replays hit the rules in
  the order the engine considered them.

  Options:

    * `:rules` — skip the Repo call and use the passed-in list
      (useful for tests and for the decision engine calling
      `evaluate/2` + `snapshot_applicable/2` with the same load).
  """
  @spec snapshot_applicable(AgentIntent.t() | EvaluationInput.t() | map(), opts()) :: %{
          String.t() => [uuid()]
        }
  def snapshot_applicable(input, opts \\ []) do
    input = coerce_input(input)
    rules = Keyword.get_lazy(opts, :rules, &load_active_ruleset/0)
    ids = rules |> Enum.filter(&applicable?(&1, input)) |> Enum.map(& &1.id)
    %{"rule_ids" => ids}
  end

  @doc """
  Evaluate a candidate against the active rule set. Returns a
  populated `%Evaluation{}`.

  Options:

    * `:rules` — use the passed-in rule list rather than hitting the
      DB. Tests pass focused subsets; the decision engine can load
      once and hand the same list to `snapshot_applicable/2` and
      `evaluate/2` for consistency.
    * `:now` — override the evaluation wall clock (test seam for
      `time_window` and `rolling_spend_cap`).
  """
  @spec evaluate(AgentIntent.t() | EvaluationInput.t() | map(), opts()) :: Evaluation.t()
  def evaluate(input, opts \\ []) do
    input = coerce_input(input, opts)
    rules = Keyword.get_lazy(opts, :rules, &load_active_ruleset/0)
    applicable = Enum.filter(rules, &applicable?(&1, input))

    {violations, constraints} =
      applicable
      |> Enum.reduce({[], %{}}, fn rule, {vios, cons} ->
        case evaluate_rule(rule, input, cons) do
          :ok ->
            {vios, cons}

          {:ok, extra} ->
            {vios, merge_constraints(cons, extra)}

          {:violation, details} ->
            {[details | vios], cons}

          {:violation, details, extra} ->
            {[details | vios], merge_constraints(cons, extra)}
        end
      end)

    Evaluation.build(%{
      violations: Enum.reverse(violations),
      matched_rule_ids: Enum.map(applicable, & &1.id),
      autonomy_tier: Map.get(constraints, :autonomy_tier, :auto),
      constraints: constraints,
      evaluated_at: input.now
    })
  end

  # ---------------------------------------------------------------------
  # Applicability
  # ---------------------------------------------------------------------

  # Every matching scope key must match the candidate. An unknown key
  # is ignored; an empty scope matches every candidate.
  defp applicable?(%PolicyRule{scope: scope}, %EvaluationInput{} = input) do
    scope = scope || %{}

    Enum.all?(scope, fn {key, expected} ->
      scope_matches?(to_string(key), expected, input)
    end)
  end

  defp scope_matches?("counterparty_id", expected, %EvaluationInput{
         target_counterparty_id: actual
       }),
       do: actual == expected

  defp scope_matches?("asset", expected, %EvaluationInput{asset: actual}),
    do: actual == expected

  defp scope_matches?("chain", expected, %EvaluationInput{chain: actual}),
    do: actual == expected

  defp scope_matches?("global", true, _input), do: true
  defp scope_matches?("global", _other, _input), do: true

  # Unknown scope keys are permissive — a future engine version may
  # add a new key and we don't want old rules to stop firing.
  defp scope_matches?(_key, _expected, _input), do: true

  # ---------------------------------------------------------------------
  # Per-rule-type evaluation
  # ---------------------------------------------------------------------

  # Each clause returns one of:
  #   :ok                                       — rule passed, no constraint
  #   {:ok, constraints_map}                    — rule passed, contributes constraints
  #   {:violation, violation_map}               — rule failed
  #   {:violation, violation_map, constraints_map} — rule failed AND contributes a constraint
  #
  # Violations are built via `Evaluation.violation/4` so the shape
  # stays consistent.

  defp evaluate_rule(%PolicyRule{rule_type: type} = rule, input, _so_far)
       when type in @swap_only_rule_types do
    case input.kind do
      :swap -> do_evaluate_swap_rule(rule, input)
      _ -> :ok
    end
  end

  defp evaluate_rule(%PolicyRule{rule_type: :amount_limit} = rule, input, _so_far) do
    with {:ok, max} <- decimal_param(rule.params, "max_per_tx") do
      currency = Map.get(rule.params, "currency")
      matches_currency? = is_nil(currency) or currency == input.asset

      cond do
        not matches_currency? ->
          :ok

        is_nil(input.amount) ->
          {:ok, %{amount_ceiling: max}}

        Decimal.compare(input.amount, max) == :gt ->
          {:violation,
           Evaluation.violation(
             rule,
             "amount_above_limit",
             "amount #{Decimal.to_string(input.amount, :normal)} exceeds per-tx limit of #{Decimal.to_string(max, :normal)}",
             %{
               limit: Decimal.to_string(max, :normal),
               amount: Decimal.to_string(input.amount, :normal),
               currency: currency
             }
           )}

        true ->
          {:ok, %{amount_ceiling: max}}
      end
    else
      {:error, reason} -> {:violation, malformed_params_violation(rule, reason)}
    end
  end

  defp evaluate_rule(%PolicyRule{rule_type: :rolling_spend_cap} = rule, input, _so_far) do
    with {:ok, max} <- decimal_param(rule.params, "max_total"),
         {:ok, window_hours} <- integer_param(rule.params, "window_hours") do
      currency = Map.get(rule.params, "currency") || input.asset

      cond do
        currency != input.asset ->
          :ok

        true ->
          rolled = sum_rolling_spend(input, rule, currency, window_hours)
          candidate = input.amount || Decimal.new(0)
          projected = Decimal.add(rolled, candidate)

          if Decimal.compare(projected, max) == :gt do
            {:violation,
             Evaluation.violation(
               rule,
               "rolling_cap_exceeded",
               "rolling #{window_hours}h spend would be #{Decimal.to_string(projected, :normal)}, cap is #{Decimal.to_string(max, :normal)}",
               %{
                 cap: Decimal.to_string(max, :normal),
                 window_hours: window_hours,
                 projected: Decimal.to_string(projected, :normal),
                 already_spent: Decimal.to_string(rolled, :normal),
                 currency: currency
               }
             )}
          else
            :ok
          end
      end
    else
      {:error, reason} -> {:violation, malformed_params_violation(rule, reason)}
    end
  end

  defp evaluate_rule(%PolicyRule{rule_type: :allowed_asset} = rule, input, _so_far) do
    evaluate_allowlist(rule, input.asset, "assets", "asset", %{asset: input.asset})
  end

  defp evaluate_rule(%PolicyRule{rule_type: :allowed_chain} = rule, input, _so_far) do
    evaluate_allowlist(rule, input.chain, "chains", "chain", %{chain: input.chain})
  end

  defp evaluate_rule(%PolicyRule{rule_type: :autonomy_tier} = rule, _input, _so_far) do
    case tier_param(rule.params) do
      {:ok, :block} ->
        {:violation,
         Evaluation.violation(
           rule,
           "blocked_by_autonomy_tier",
           "autonomy tier rule blocks automated execution",
           %{tier: "block"}
         ), %{autonomy_tier: :block}}

      {:ok, tier} when tier in [:manual, :auto] ->
        {:ok, %{autonomy_tier: tier}}

      {:error, reason} ->
        {:violation, malformed_params_violation(rule, reason)}
    end
  end

  defp evaluate_rule(%PolicyRule{rule_type: :time_window} = rule, input, _so_far) do
    evaluate_time_window(rule, input.now)
  end

  # Defensive fallback: an active rule with a type we don't know how
  # to evaluate is flagged explicitly rather than silently passed.
  # The `rule_type` column is CHECK-constrained to the v1 set, so this
  # branch only triggers during future upgrades.
  defp evaluate_rule(%PolicyRule{} = rule, _input, _so_far) do
    {:violation,
     Evaluation.violation(
       rule,
       "unknown_rule_type",
       "engine does not know how to evaluate rule_type=#{rule.rule_type}",
       %{rule_type: to_string(rule.rule_type)}
     )}
  end

  # --- swap-only rules -------------------------------------------------

  defp do_evaluate_swap_rule(%PolicyRule{rule_type: :slippage_ceiling} = rule, input) do
    with {:ok, max_bps} <- integer_param(rule.params, "max_bps") do
      constraint = %{max_slippage_bps: max_bps}

      cond do
        is_nil(input.slippage_bps) ->
          {:violation,
           Evaluation.violation(
             rule,
             "missing_slippage",
             "swap candidate has no slippage_bps; rule requires ≤ #{max_bps}",
             %{max_bps: max_bps}
           ), constraint}

        input.slippage_bps > max_bps ->
          {:violation,
           Evaluation.violation(
             rule,
             "slippage_above_ceiling",
             "slippage #{input.slippage_bps} bps exceeds ceiling of #{max_bps} bps",
             %{slippage_bps: input.slippage_bps, max_bps: max_bps}
           ), constraint}

        true ->
          {:ok, constraint}
      end
    else
      {:error, reason} -> {:violation, malformed_params_violation(rule, reason)}
    end
  end

  defp do_evaluate_swap_rule(%PolicyRule{rule_type: :allowed_router} = rule, input) do
    with {:ok, mode, routers} <- allowlist_params(rule.params, "routers") do
      constraint = %{allowed_routers: routers}

      cond do
        is_nil(input.router) ->
          # A swap with no router field: we still surface the
          # constraint for downstream; the enforcement point is the
          # adapter handing us a router.
          {:ok, constraint}

        mode == "allowlist" and input.router in routers ->
          {:ok, constraint}

        mode == "allowlist" ->
          {:violation,
           Evaluation.violation(
             rule,
             "router_not_allowed",
             "router #{input.router} is not in the allowlist",
             %{router: input.router, allowlist: routers}
           ), constraint}

        mode == "denylist" and input.router not in routers ->
          {:ok, constraint}

        mode == "denylist" ->
          {:violation,
           Evaluation.violation(
             rule,
             "router_denied",
             "router #{input.router} is on the denylist",
             %{router: input.router, denylist: routers}
           ), constraint}
      end
    else
      {:error, reason} -> {:violation, malformed_params_violation(rule, reason)}
    end
  end

  # --- shared helpers for rule eval -----------------------------------

  defp evaluate_allowlist(%PolicyRule{} = rule, actual, list_key, field_name, violation_details) do
    with {:ok, mode, list} <- allowlist_params(rule.params, list_key) do
      in_list? = actual in list

      cond do
        mode == "allowlist" and in_list? ->
          :ok

        mode == "allowlist" ->
          {:violation,
           Evaluation.violation(
             rule,
             "#{field_name}_not_allowed",
             "#{field_name} #{inspect(actual)} is not in the allowlist",
             Map.put(violation_details, :allowlist, list)
           )}

        mode == "denylist" and not in_list? ->
          :ok

        mode == "denylist" ->
          {:violation,
           Evaluation.violation(
             rule,
             "#{field_name}_denied",
             "#{field_name} #{inspect(actual)} is on the denylist",
             Map.put(violation_details, :denylist, list)
           )}
      end
    else
      {:error, reason} -> {:violation, malformed_params_violation(rule, reason)}
    end
  end

  defp evaluate_time_window(%PolicyRule{params: params} = rule, %DateTime{} = now) do
    with {:ok, tz} <- tz_param(params),
         {:ok, local} <- shift_to_tz(now, tz),
         {:ok, days} <- days_of_week_param(params),
         {:ok, {start_m, end_m}} <- hhmm_range_param(params) do
      iso_dow = Date.day_of_week(local)
      minutes = local.hour * 60 + local.minute

      cond do
        iso_dow not in days ->
          {:violation,
           Evaluation.violation(
             rule,
             "outside_allowed_days",
             "candidate time is on ISO day #{iso_dow}; allowed days are #{inspect(days)}",
             %{day_of_week: iso_dow, allowed_days: days, timezone: tz}
           )}

        minutes < start_m or minutes >= end_m ->
          {:violation,
           Evaluation.violation(
             rule,
             "outside_allowed_hours",
             "candidate local time is outside the allowed window",
             %{
               local_time: format_hhmm(minutes),
               window: "#{format_hhmm(start_m)}–#{format_hhmm(end_m)}",
               timezone: tz
             }
           )}

        true ->
          :ok
      end
    else
      {:error, reason} -> {:violation, malformed_params_violation(rule, reason)}
    end
  end

  # Merge strategy for the rolling constraint map. Most fields are
  # "last write wins" (the highest-priority rule with a matching type
  # wins because we process in priority-desc order), but
  # `autonomy_tier` must collapse to the most restrictive tier
  # regardless of order.
  defp merge_constraints(existing, new) do
    Map.merge(existing, new, fn
      :autonomy_tier, a, b -> strictest_tier(a, b)
      :amount_ceiling, a, b -> Decimal.min(a, b)
      :max_slippage_bps, a, b -> min(a, b)
      :allowed_routers, a, b -> intersect_lists(a, b)
      _k, _a, b -> b
    end)
  end

  defp strictest_tier(:block, _), do: :block
  defp strictest_tier(_, :block), do: :block
  defp strictest_tier(:manual, _), do: :manual
  defp strictest_tier(_, :manual), do: :manual
  defp strictest_tier(_, _), do: :auto

  defp intersect_lists(a, b) when is_list(a) and is_list(b) do
    b_set = MapSet.new(b)
    Enum.filter(a, &MapSet.member?(b_set, &1))
  end

  # --- rolling spend aggregation --------------------------------------

  defp sum_rolling_spend(%EvaluationInput{} = input, %PolicyRule{scope: scope}, currency, hours) do
    now = input.now
    window_start = DateTime.add(now, -hours * 3600, :second)

    base =
      from i in AgentIntent,
        where: i.asset == ^currency,
        where: i.state in [:executing, :executed],
        where: i.submitted_at >= ^window_start and i.submitted_at <= ^now

    base =
      case Map.get(scope || %{}, "counterparty_id") do
        nil -> base
        cp_id -> where(base, [i], i.target_counterparty_id == ^cp_id)
      end

    base =
      case Map.get(scope || %{}, "chain") do
        nil -> base
        chain -> where(base, [i], i.chain == ^chain)
      end

    # Exclude the candidate intent itself if it already exists in the
    # DB in one of the summed states — otherwise an operator asking
    # "would re-evaluating this intent violate the cap?" double-counts.
    base =
      case input.intent_id do
        nil -> base
        id -> where(base, [i], i.id != ^id)
      end

    case Repo.aggregate(base, :sum, :amount) do
      nil -> Decimal.new(0)
      %Decimal{} = total -> total
    end
  end

  # ---------------------------------------------------------------------
  # Param coercion
  # ---------------------------------------------------------------------

  defp decimal_param(params, key) do
    case Map.get(params, key) do
      nil ->
        {:error, "missing `#{key}`"}

      %Decimal{} = d ->
        {:ok, d}

      v when is_integer(v) or is_float(v) ->
        {:ok, Decimal.new(to_string(v))}

      v when is_binary(v) ->
        case Decimal.parse(v) do
          {d, ""} -> {:ok, d}
          _ -> {:error, "`#{key}` must be a decimal-formatted string"}
        end

      _ ->
        {:error, "`#{key}` must be a decimal-formatted string"}
    end
  end

  defp integer_param(params, key) do
    case Map.get(params, key) do
      n when is_integer(n) and n >= 0 ->
        {:ok, n}

      v when is_binary(v) ->
        case Integer.parse(v) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> {:error, "`#{key}` must be a non-negative integer"}
        end

      _ ->
        {:error, "`#{key}` must be a non-negative integer"}
    end
  end

  defp allowlist_params(params, list_key) do
    mode = Map.get(params, "mode", "allowlist")

    with {:ok, list} <- list_param(params, list_key),
         true <- mode in ["allowlist", "denylist"] do
      {:ok, mode, list}
    else
      false -> {:error, "`mode` must be 'allowlist' or 'denylist'"}
      {:error, _} = err -> err
    end
  end

  defp list_param(params, key) do
    case Map.get(params, key) do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1) do
          {:ok, list}
        else
          {:error, "`#{key}` must be a list of strings"}
        end

      _ ->
        {:error, "`#{key}` must be a list of strings"}
    end
  end

  defp tier_param(%{"tier" => tier}) when tier in ["auto", "manual", "block"],
    do: {:ok, String.to_existing_atom(tier)}

  defp tier_param(_),
    do: {:error, "`tier` must be one of 'auto', 'manual', 'block'"}

  defp tz_param(params) do
    case Map.get(params, "timezone", "UTC") do
      tz when is_binary(tz) -> {:ok, tz}
      _ -> {:error, "`timezone` must be a string"}
    end
  end

  defp shift_to_tz(%DateTime{} = utc, "UTC"), do: {:ok, utc}

  defp shift_to_tz(%DateTime{} = utc, tz) do
    case DateTime.shift_zone(utc, tz) do
      {:ok, local} -> {:ok, local}
      {:error, _} -> {:error, "unsupported timezone #{tz}; v0.1 supports 'UTC' only"}
    end
  end

  defp days_of_week_param(params) do
    case Map.get(params, "days_of_week") do
      nil ->
        {:ok, [1, 2, 3, 4, 5, 6, 7]}

      list when is_list(list) ->
        cond do
          Enum.all?(list, fn d -> is_integer(d) and d in 1..7 end) ->
            {:ok, list}

          true ->
            {:error, "`days_of_week` must be a list of integers in 1..7 (ISO, Monday=1)"}
        end

      _ ->
        {:error, "`days_of_week` must be a list of integers in 1..7"}
    end
  end

  defp hhmm_range_param(params) do
    with {:ok, start_m} <- hhmm_param(Map.get(params, "start_hhmm", "00:00"), "start_hhmm"),
         {:ok, end_m} <- hhmm_param(Map.get(params, "end_hhmm", "24:00"), "end_hhmm"),
         true <- start_m < end_m do
      {:ok, {start_m, end_m}}
    else
      false -> {:error, "`start_hhmm` must be earlier than `end_hhmm`"}
      {:error, _} = err -> err
    end
  end

  defp hhmm_param(value, key) when is_binary(value) do
    case String.split(value, ":") do
      [hh, mm] ->
        with {h, ""} <- Integer.parse(hh),
             {m, ""} <- Integer.parse(mm),
             true <- h in 0..24 and m in 0..59,
             true <- not (h == 24 and m != 0) do
          {:ok, h * 60 + m}
        else
          _ -> {:error, "`#{key}` must be HH:MM in 00:00..24:00"}
        end

      _ ->
        {:error, "`#{key}` must be HH:MM"}
    end
  end

  defp hhmm_param(_, key), do: {:error, "`#{key}` must be HH:MM"}

  defp format_hhmm(minutes) do
    hh = div(minutes, 60)
    mm = rem(minutes, 60)
    :io_lib.format("~2..0B:~2..0B", [hh, mm]) |> IO.iodata_to_binary()
  end

  defp malformed_params_violation(%PolicyRule{} = rule, reason) do
    Evaluation.violation(
      rule,
      "malformed_params",
      "rule params failed validation: #{reason}",
      %{reason: reason}
    )
  end

  # ---------------------------------------------------------------------
  # Input coercion
  # ---------------------------------------------------------------------

  defp coerce_input(input, opts \\ [])

  defp coerce_input(%EvaluationInput{} = input, opts) do
    case Keyword.get(opts, :now) do
      nil -> %{input | now: input.now || DateTime.utc_now()}
      %DateTime{} = now -> %{input | now: now}
    end
  end

  defp coerce_input(%AgentIntent{} = intent, opts) do
    extras = opts |> Keyword.take([:now, :slippage_bps, :router]) |> Map.new()
    EvaluationInput.from_intent(intent, extras)
  end

  defp coerce_input(%{} = map, opts) do
    struct!(EvaluationInput, Map.to_list(Map.put_new(map, :now, Keyword.get(opts, :now))))
    |> coerce_input(opts)
  end

  # ---------------------------------------------------------------------
  # Filter / query plumbing
  # ---------------------------------------------------------------------

  defp apply_rule_filters(query, filters) do
    Enum.reduce(filters, query, fn
      {:state, nil}, q ->
        q

      {:state, state}, q when is_atom(state) ->
        where(q, [r], r.state == ^state)

      {:rule_type, nil}, q ->
        q

      {:rule_type, type}, q when is_atom(type) ->
        where(q, [r], r.rule_type == ^type)

      {_unknown, _}, q ->
        q
    end)
  end

  # Optional workspace filter for #158b. See `Bank.Counterparties` for
  # the same pattern; the no-op default protects legacy callers.
  defp scope_rule_to_workspace(query, nil), do: query

  defp scope_rule_to_workspace(query, workspace_id) when is_binary(workspace_id),
    do: where(query, [r], r.workspace_id == ^workspace_id)

  # Caller-supplied `opts[:workspace_id]` is the only sanctioned
  # source of the workspace scope. We always strip any
  # `:workspace_id` (atom or string) from `attrs` first — `attrs`
  # may carry user-controlled body fields, and the workspace
  # boundary must never be forgeable from a request body. Trusted
  # internal callers (e.g. `Bank.Demo`) call the schema changeset
  # directly when they need to set workspace_id without going
  # through this function.
  defp stamp_workspace_id(attrs, opts) do
    stripped = attrs |> Map.delete(:workspace_id) |> Map.delete("workspace_id")

    case Keyword.get(opts, :workspace_id) do
      nil -> stripped
      ws_id -> Map.put(stripped, :workspace_id, ws_id)
    end
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_page_limit)
  defp clamp_limit(_), do: @default_page_limit

  defp apply_cursor(query, cursor) when is_binary(cursor) do
    case Ecto.UUID.cast(cursor) do
      {:ok, id} ->
        from r in query,
          join: prev in PolicyRule,
          on: prev.id == ^id,
          where: {r.inserted_at, r.id} > {prev.inserted_at, prev.id}

      :error ->
        query
    end
  end

  defp encode_cursor(%PolicyRule{id: id}), do: id

  # ---------------------------------------------------------------------
  # actor / audit plumbing
  # ---------------------------------------------------------------------

  # `policy_revised` / `policy_archived` take `:actor_id` as required
  # because the runtime-flow doc requires operator attribution for
  # rule changes. `create_rule` accepts a missing actor_id (e.g. a
  # seed script) so we don't raise here.
  defp actor_opts(opts) do
    Keyword.take(opts, [:actor, :actor_id])
  end

  defp actor_opts!(opts) do
    opts
    |> actor_opts()
    |> Keyword.put_new(:actor, :user)
    |> Keyword.put_new(:actor_id, nil)
  end

  # ---------------------------------------------------------------------
  # attr coercion
  # ---------------------------------------------------------------------

  defp normalise_attrs(attrs) when is_list(attrs), do: attrs |> Map.new() |> normalise_attrs()

  defp normalise_attrs(%{} = attrs) do
    attrs
    |> Enum.map(fn
      {k, v} when is_atom(k) -> {k, normalise_value(k, v)}
      {k, v} when is_binary(k) -> {safe_atom(k), normalise_value(safe_atom(k), v)}
    end)
    |> Map.new()
  end

  defp normalise_value(:state, v) when is_binary(v), do: safe_atom(v)
  defp normalise_value(:rule_type, v) when is_binary(v), do: safe_atom(v)
  defp normalise_value(:created_by, v) when is_binary(v), do: safe_atom(v)
  defp normalise_value(_key, v), do: v

  defp safe_atom(string) when is_binary(string) do
    try do
      String.to_existing_atom(string)
    rescue
      ArgumentError -> string
    end
  end

  defp safe_atom(atom) when is_atom(atom), do: atom

  defp to_map(%{} = m), do: m
  defp to_map(list) when is_list(list), do: Map.new(list)
end
