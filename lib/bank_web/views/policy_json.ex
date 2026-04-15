defmodule BankWeb.API.V1.PolicyJSON do
  @moduledoc """
  JSON renderers for `/v1/policies*`.

  The rendered shape is the external contract; it is not a 1:1 mirror
  of `PolicyRule`. Evaluation results render under a separate helper
  (`evaluation/1`) because the decision engine — not the policy API —
  is the public caller for evaluation output, and the shape should be
  additive rather than a reflection of internal structs.
  """

  alias Bank.Policies.{Evaluation, PolicyRule}

  @doc "Paged `GET /v1/policies` envelope."
  def index(%{entries: entries, next_cursor: cursor}) do
    %{
      data: Enum.map(entries, &rule/1),
      page: %{next_cursor: cursor}
    }
  end

  @doc "`POST /v1/policies` / `POST /v1/policies/:id/revise` payload."
  def rule_created(%{rule: %PolicyRule{} = r}), do: %{data: rule(r)}

  @doc "`POST /v1/policies/:id/archive` payload."
  def rule_archived(%{rule: %PolicyRule{} = r}), do: %{data: rule(r)}

  @doc """
  Evaluation result. Not routed by a /v1 endpoint in v0.1 — the
  decision engine renders from here so the same shape is available
  for future `POST /v1/policies/evaluate` debug surfaces.
  """
  def evaluation(%{evaluation: %Evaluation{} = eval}) do
    %{
      pass: eval.pass?,
      violations: Enum.map(eval.violations, &violation/1),
      matched_rule_ids: eval.matched_rule_ids,
      snapshot_ref: eval.snapshot_ref,
      autonomy_tier: eval.autonomy_tier,
      constraints: render_constraints(eval.constraints),
      evaluated_at: eval.evaluated_at
    }
  end

  # --- entity renderers --------------------------------------------------

  @doc false
  def rule(%PolicyRule{} = r) do
    %{
      id: r.id,
      version: r.version,
      state: r.state,
      rule_type: r.rule_type,
      scope: r.scope,
      params: r.params,
      priority: r.priority,
      created_by: r.created_by,
      supersedes_id: r.supersedes_id,
      inserted_at: r.inserted_at,
      updated_at: r.updated_at
    }
  end

  defp violation(%{
         rule_id: rule_id,
         rule_type: rule_type,
         code: code,
         message: message,
         details: details
       }) do
    %{
      rule_id: rule_id,
      rule_type: rule_type,
      code: code,
      message: message,
      details: render_details(details)
    }
  end

  # Decimal values in constraints / details serialize to their string
  # form; JSON has no native decimal.
  defp render_constraints(constraints) when is_map(constraints) do
    Map.new(constraints, fn {k, v} -> {k, render_value(v)} end)
  end

  defp render_details(details) when is_map(details) do
    Map.new(details, fn {k, v} -> {k, render_value(v)} end)
  end

  defp render_value(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp render_value(other), do: other
end
