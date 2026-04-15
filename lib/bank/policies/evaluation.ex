defmodule Bank.Policies.Evaluation do
  @moduledoc """
  Structured result of evaluating a candidate action against the active
  policy rule set.

  The result is explicit by design: every rule that was considered
  appears in `matched_rule_ids`, every failure carries a rule-level
  `code` and `message`, and downstream callers that need to shape a
  `DecisionEnvelope` can read `snapshot_ref` directly without
  reconstructing the jsonb wrapper.

  ## Fields

    * `pass?` — `true` iff `violations == []`. The engine does not
      short-circuit on the first violation; all applicable rules run so
      the operator sees the full picture.
    * `violations` — list of `%{rule_id, rule_type, code, message,
      details}` maps. `details` is rule-specific (e.g. the amount
      ceiling that was exceeded, the bps that overshot the cap). Order
      follows `matched_rule_ids`.
    * `matched_rule_ids` — ids of every rule whose scope matched the
      candidate, in `(priority desc, inserted_at asc)` order. These are
      the rules the engine actually considered, whether or not they
      produced a violation.
    * `snapshot_ref` — `%{"rule_ids" => matched_rule_ids}`, the exact
      jsonb shape `DecisionEnvelope.policy_snapshot_ref` accepts.
    * `autonomy_tier` — the most restrictive `:autonomy_tier` rule's
      tier (`:auto`, `:manual`, or `:block`) among matching rules.
      Defaults to `:auto` when no `autonomy_tier` rule applies.
    * `constraints` — a map of machine-usable signals the decision
      engine can consume (amount ceiling, slippage cap, allowed
      routers, etc). Callers treat the map as advisory — violations
      are the hard stops.
    * `evaluated_at` — when the evaluation ran. Recorded so replay
      readers know which clock was used for the time-window /
      rolling-cap calculations.
  """

  alias Bank.Policies.PolicyRule

  @type violation :: %{
          rule_id: Ecto.UUID.t(),
          rule_type: atom(),
          code: String.t(),
          message: String.t(),
          details: map()
        }

  @type constraints :: %{optional(atom()) => term()}

  @type t :: %__MODULE__{
          pass?: boolean(),
          violations: [violation()],
          matched_rule_ids: [Ecto.UUID.t()],
          snapshot_ref: %{String.t() => [Ecto.UUID.t()]},
          autonomy_tier: :auto | :manual | :block,
          constraints: constraints(),
          evaluated_at: DateTime.t() | nil
        }

  defstruct pass?: true,
            violations: [],
            matched_rule_ids: [],
            snapshot_ref: %{"rule_ids" => []},
            autonomy_tier: :auto,
            constraints: %{},
            evaluated_at: nil

  @doc """
  Build the result from the raw fold output. Keeps the invariant
  `pass? == (violations == [])` in one place.
  """
  @spec build(%{
          violations: [violation()],
          matched_rule_ids: [Ecto.UUID.t()],
          autonomy_tier: :auto | :manual | :block,
          constraints: constraints(),
          evaluated_at: DateTime.t()
        }) :: t()
  def build(%{
        violations: violations,
        matched_rule_ids: rule_ids,
        autonomy_tier: tier,
        constraints: constraints,
        evaluated_at: ts
      }) do
    %__MODULE__{
      pass?: violations == [],
      violations: violations,
      matched_rule_ids: rule_ids,
      snapshot_ref: %{"rule_ids" => rule_ids},
      autonomy_tier: tier,
      constraints: constraints,
      evaluated_at: ts
    }
  end

  @doc """
  Construct a single violation entry. Extracts `rule_type` / `id` from
  a `%PolicyRule{}` so callers only pass the rule plus the
  rule-specific code/message/details.
  """
  @spec violation(PolicyRule.t(), String.t(), String.t(), map()) :: violation()
  def violation(%PolicyRule{} = rule, code, message, details \\ %{})
      when is_binary(code) and is_binary(message) and is_map(details) do
    %{
      rule_id: rule.id,
      rule_type: rule.rule_type,
      code: code,
      message: message,
      details: details
    }
  end
end
