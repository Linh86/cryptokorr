defmodule Bank.Policies.Simulator do
  @moduledoc """
  Pure policy simulator (#225) — evaluates a hypothetical intent
  against a workspace's draft AND published policy versions and
  returns a side-by-side comparison.

  ## Read-only contract

  This module **never** writes anything. No `AgentIntent`, no
  `ExecutionPlan`, no `DecisionEnvelope`, no audit event, no Oban
  job, no PubSub broadcast, no chain adapter call. The simulator
  reads the workspace's policy version rows + their referenced
  policy rules and runs `Bank.Policies.evaluate/2` against the
  resulting rule lists. Tests assert the no-side-effects
  contract end to end.

  ## Workspace boundary

  Every read filters by `workspace_id`. Rules referenced by a
  draft or published version that don't belong to the requested
  workspace are dropped (preserves the #226 P2 contract). The
  draft snapshot also includes `:draft`-state rules in addition
  to `:active` (matches the #224 P2 contract that draft-only
  rules are visible inside the builder before publish).

  ## Output shape

      %{
        input: %EvaluationInput{...},          # the hypothetical
        draft: %{
          available?: boolean,
          version: %PolicyVersion{} | nil,
          rules: [%PolicyRule{}],
          outcome: :auto_exec | :approval_required | :block,
          pass?: boolean,
          violations: [violation_map],
          matched_rule_ids: [uuid],
          autonomy_tier: :auto | :manual | :block
        },
        published: %{...same shape...},
        changed?: boolean              # true if outcome OR matched
                                       # rule ids differ between
                                       # draft and published
      }

  ## Outcome derivation

  The simulator reports a POLICY-level outcome — what the policy
  evaluator alone says about the hypothetical intent. The full
  runtime decision (`Bank.Autonomy.route/2`) also considers
  trust, simulation/preview, screening, and runtime pause state;
  those inputs are not part of #225's simulator scope. The
  derivation is:

    * any policy violation → `:block`
    * policy passes but `autonomy_tier == :block` → `:block`
    * policy passes but `autonomy_tier == :manual` →
      `:approval_required`
    * policy passes and `autonomy_tier == :auto` → `:auto_exec`

  When neither a draft nor a published version exists for the
  workspace, the corresponding side reports
  `available?: false, outcome: :auto_exec, rules: []` (no rules
  ever applied).
  """

  import Ecto.Query

  alias Bank.Policies
  alias Bank.Policies.{EvaluationInput, PolicyRule, PolicyVersion, Versions}
  alias Bank.Repo

  @typedoc """
  Per-side simulation outcome.
  """
  @type side :: %{
          available?: boolean(),
          version: PolicyVersion.t() | nil,
          rules: [PolicyRule.t()],
          outcome: :auto_exec | :approval_required | :block,
          pass?: boolean(),
          violations: [map()],
          matched_rule_ids: [String.t()],
          autonomy_tier: :auto | :manual | :block
        }

  @typedoc """
  Side-by-side simulation result.
  """
  @type t :: %{
          input: EvaluationInput.t(),
          draft: side(),
          published: side(),
          changed?: boolean()
        }

  @doc """
  Run the simulation for a workspace + a hypothetical intent.

  `params` is a flat map (atom or string keys) carrying the same
  fields a real `AgentIntent` would: `:kind`, `:asset`, `:chain`,
  `:amount`, `:target_counterparty_id`, `:target_address_label_id`,
  `:target_raw_address`, optional `:slippage_bps`, `:router`,
  `:now`.

  Invalid inputs (missing required fields, malformed amount)
  return `{:error, %{field => [message]}}` so the caller can
  surface form errors. A successful build returns `{:ok, t()}`.
  """
  @spec simulate(binary(), map()) :: {:ok, t()} | {:error, map()}
  def simulate(workspace_id, params) when is_binary(workspace_id) and is_map(params) do
    with {:ok, input} <- build_input(params) do
      draft_version = list_workspace_draft(workspace_id)
      published_version = Versions.current_published(workspace_id)

      draft_rules = resolve_draft_rules(workspace_id, draft_version)
      published_rules = resolve_published_rules(workspace_id, published_version)

      draft_side = build_side(draft_version, draft_rules, input)
      published_side = build_side(published_version, published_rules, input)

      # `changed?` only meaningful when BOTH sides exist — a
      # workspace with no draft would always show a trivial
      # difference ("no rules" vs "published rules"), which the UI
      # already conveys through the `available?` flag.
      changed? =
        draft_side.available? and published_side.available? and
          (draft_side.outcome != published_side.outcome or
             Enum.sort(draft_side.matched_rule_ids) !=
               Enum.sort(published_side.matched_rule_ids))

      {:ok,
       %{
         input: input,
         draft: draft_side,
         published: published_side,
         changed?: changed?
       }}
    end
  end

  def simulate(_, _), do: {:error, %{workspace_id: ["must be a binary"]}}

  # --- input building ---------------------------------------------------

  @required_fields [:kind, :asset, :chain, :amount]

  defp build_input(params) do
    norm = normalise_params(params)
    errors = validate_required(norm, @required_fields)

    case parse_amount(norm[:amount]) do
      {:ok, decimal} ->
        if errors == %{} do
          {:ok,
           %EvaluationInput{
             kind: cast_kind(norm[:kind]),
             asset: norm[:asset],
             chain: norm[:chain],
             amount: decimal,
             target_counterparty_id: blank_to_nil(norm[:target_counterparty_id]),
             target_address_label_id: blank_to_nil(norm[:target_address_label_id]),
             target_raw_address: blank_to_nil(norm[:target_raw_address]),
             slippage_bps: parse_int(norm[:slippage_bps]),
             router: blank_to_nil(norm[:router]),
             intent_id: nil,
             submitted_at: norm[:now] || DateTime.utc_now(),
             now: norm[:now] || DateTime.utc_now()
           }}
        else
          {:error, errors}
        end

      :missing ->
        {:error, errors}

      {:error, msg} ->
        {:error, Map.merge(errors, %{amount: [msg]})}
    end
  end

  defp normalise_params(params) do
    Map.new(params, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError ->
      # Unknown key – drop it (no String.to_atom on user input).
      Map.new(params, fn
        {k, v} when is_atom(k) -> {k, v}
        {_k, v} -> {:_unknown, v}
      end)
      |> Map.delete(:_unknown)
  end

  defp validate_required(params, required) do
    required
    |> Enum.reduce(%{}, fn field, acc ->
      case Map.get(params, field) do
        nil -> Map.put(acc, field, ["is required"])
        "" -> Map.put(acc, field, ["is required"])
        _ -> acc
      end
    end)
  end

  defp parse_amount(nil), do: :missing
  defp parse_amount(""), do: :missing

  defp parse_amount(%Decimal{} = d), do: {:ok, d}

  defp parse_amount(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = d, ""} -> {:ok, d}
      _ -> {:error, "must be a decimal"}
    end
  end

  defp parse_amount(value) when is_integer(value),
    do: {:ok, Decimal.new(value)}

  defp parse_amount(value) when is_float(value),
    do: {:ok, Decimal.from_float(value)}

  defp parse_amount(_), do: {:error, "must be a decimal"}

  defp cast_kind(nil), do: nil
  defp cast_kind(value) when is_atom(value), do: value

  # The `:kind` enum in `Bank.Intents.AgentIntent` is closed
  # (`:transfer`, `:swap`, etc.). To stay safe per AGENTS.md
  # ("no `String.to_atom/1` on user input") use
  # `String.to_existing_atom/1` and fall back to `:transfer`
  # if the supplied string isn't a known intent kind.
  defp cast_kind(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :transfer
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp parse_int(nil), do: nil
  defp parse_int(""), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> nil
    end
  end

  # --- version + rule resolution ---------------------------------------

  defp list_workspace_draft(workspace_id) do
    workspace_id
    |> Versions.list_versions(status: :draft, limit: 1)
    |> List.first()
  end

  defp resolve_draft_rules(_workspace_id, nil), do: []

  defp resolve_draft_rules(workspace_id, %PolicyVersion{} = version) do
    ids = PolicyVersion.rule_ids_list(version)
    fetch_rules(workspace_id, ids, [:active, :draft])
  end

  defp resolve_published_rules(_workspace_id, nil), do: []

  defp resolve_published_rules(workspace_id, %PolicyVersion{} = version) do
    ids = PolicyVersion.rule_ids_list(version)
    fetch_rules(workspace_id, ids, [:active])
  end

  defp fetch_rules(_workspace_id, [], _states), do: []

  defp fetch_rules(workspace_id, ids, states) do
    PolicyRule
    |> where(
      [r],
      r.id in ^ids and r.workspace_id == ^workspace_id and r.state in ^states
    )
    |> Repo.all()
  end

  # --- per-side evaluation ---------------------------------------------

  defp build_side(version, rules, %EvaluationInput{} = input) do
    eval = Policies.evaluate(input, rules: rules, now: input.now)
    outcome = simulator_outcome(eval)

    %{
      available?: not is_nil(version),
      version: version,
      rules: rules,
      outcome: outcome,
      pass?: eval.pass?,
      violations: eval.violations,
      matched_rule_ids: eval.matched_rule_ids,
      autonomy_tier: eval.autonomy_tier
    }
  end

  defp simulator_outcome(%{pass?: false}), do: :block
  defp simulator_outcome(%{autonomy_tier: :block}), do: :block
  defp simulator_outcome(%{autonomy_tier: :manual}), do: :approval_required
  defp simulator_outcome(_), do: :auto_exec
end
