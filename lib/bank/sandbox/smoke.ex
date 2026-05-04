defmodule Bank.Sandbox.Smoke do
  @moduledoc """
  Level 1 sandbox smoke runner (#240).

  Exercises the local no-chain product flow end-to-end against the
  seeded sandbox demo dataset and produces a deterministic
  pass/fail report.

  Read-only by construction:

    * No secrets, no `.env`, no environment variables required.
      The database is the only external dependency.
    * No chain RPC, no signing, no broadcast, no dispatch.
    * No mutation of demo or non-demo data — every check is a
      bounded `LIMIT` read or a context lookup.

  Each check is workspace-scoped to `Bank.Demo.demo_workspace_id/0`,
  matching the boundary the `/sandbox` LiveView checklist uses
  (#239). A check fails when a read path returns empty or stubbed
  data where the seed guarantees real rows — that catches 501-style
  endpoint regressions on the read surfaces this command exercises.

  Driven from `Mix.Tasks.Bank.Sandbox.Smoke`; the runner is split
  out from the task so it can be unit-tested without invoking
  `Mix.Task.run/2`.
  """

  import Ecto.Query

  alias Bank.Audit
  alias Bank.Counterparties
  alias Bank.Decisions
  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Decisions.SimulationReport
  alias Bank.Demo
  alias Bank.Intents
  alias Bank.Intents.AgentIntent
  alias Bank.Ops.Health
  alias Bank.Policies
  alias Bank.Repo

  @type status :: :pass | :fail

  @type check :: %{
          name: String.t(),
          status: status(),
          detail: String.t()
        }

  @type report :: %{
          workspace_slug: String.t(),
          workspace_id: Ecto.UUID.t() | nil,
          status: status(),
          checks: [check()],
          passed: non_neg_integer(),
          total: non_neg_integer()
        }

  @doc """
  Run every smoke check and return `{:ok, report}` if all pass or
  `{:error, report}` if any fail. Never raises on a failed check —
  the caller (Mix task / test) decides how to surface the result.
  """
  @spec run() :: {:ok, report()} | {:error, report()}
  def run do
    workspace_slug = Demo.workspace_slug()

    case Demo.demo_workspace_id() do
      nil ->
        finalize(workspace_slug, nil, [
          %{
            name: "seed",
            status: :fail,
            detail: "demo workspace #{workspace_slug} not found — run `mix bank.demo.seed`"
          }
        ])

      workspace_id ->
        finalize(workspace_slug, workspace_id, run_checks(workspace_id))
    end
  end

  defp run_checks(workspace_id) do
    [
      check_health(),
      check_workspace(workspace_id),
      check_policies(workspace_id),
      check_counterparty(workspace_id),
      check_intent(workspace_id),
      check_simulate(workspace_id),
      check_approval(workspace_id),
      check_held_or_blocked(workspace_id),
      check_cancel(workspace_id),
      check_replay(workspace_id)
    ]
  end

  defp finalize(workspace_slug, workspace_id, checks) do
    passed = Enum.count(checks, &(&1.status == :pass))
    total = length(checks)
    overall = if passed == total, do: :pass, else: :fail

    report = %{
      workspace_slug: workspace_slug,
      workspace_id: workspace_id,
      status: overall,
      checks: checks,
      passed: passed,
      total: total
    }

    case overall do
      :pass -> {:ok, report}
      :fail -> {:error, report}
    end
  end

  # --- Checks ----------------------------------------------------------

  defp check_health do
    %{status: status, checks: checks} = Health.snapshot()

    case status do
      :ok ->
        pass("health", "database=#{checks.database.status} adapter=#{checks.adapter.status}")

      :degraded ->
        fail(
          "health",
          "database=#{checks.database.status} adapter=#{checks.adapter.status} stuck_plans=#{checks.stuck_plans.status}"
        )
    end
  end

  defp check_workspace(workspace_id) do
    pass("workspace", "id=#{workspace_id}")
  end

  defp check_policies(workspace_id) do
    %{entries: entries} =
      Policies.list_rules(%{state: :active}, workspace_id: workspace_id, limit: 1)

    case entries do
      [] -> fail("policies", "no active policy rules in workspace")
      [_ | _] -> pass("policies", "at least one active policy rule")
    end
  end

  defp check_counterparty(workspace_id) do
    %{entries: entries} = Counterparties.list_counterparties(%{}, workspace_id: workspace_id)

    if Enum.any?(entries, &(&1.current_trust_level != :unknown)) do
      pass("counterparty", "trust assertion present (#{length(entries)} counterparty rows)")
    else
      fail("counterparty", "no counterparty has non-:unknown trust")
    end
  end

  defp check_intent(workspace_id) do
    case Intents.list(workspace_id: workspace_id, limit: 1) do
      [] ->
        fail("intent", "no intents listed in workspace")

      [%AgentIntent{id: id} | _] ->
        # Round-trip list → get_in_workspace to detect the case where
        # the list path returns rows but the workspace-scoped get
        # path is stubbed and returns nil.
        case Intents.get_in_workspace(id, workspace_id) do
          nil ->
            fail("intent", "list returned id=#{id} but get_in_workspace returned nil")

          %AgentIntent{} ->
            pass("intent", "list+get_in_workspace round-trip ok (id=#{id})")
        end
    end
  end

  defp check_simulate(workspace_id) do
    if Repo.exists?(
         from(s in SimulationReport,
           join: i in AgentIntent,
           on: i.id == s.intent_id,
           where: i.workspace_id == ^workspace_id
         )
       ) do
      pass("simulate", "at least one simulation report exists")
    else
      fail("simulate", "no simulation reports recorded for workspace intents")
    end
  end

  defp check_approval(workspace_id) do
    if Repo.exists?(
         from(e in DecisionEnvelope,
           join: i in AgentIntent,
           on: i.id == e.intent_id,
           where: i.workspace_id == ^workspace_id and e.outcome == :approval_required
         )
       ) do
      pass("approval", "decision with outcome=:approval_required present")
    else
      fail("approval", "no approval-required decision in workspace")
    end
  end

  defp check_held_or_blocked(workspace_id) do
    if Repo.exists?(
         from(e in DecisionEnvelope,
           join: i in AgentIntent,
           on: i.id == e.intent_id,
           where: i.workspace_id == ^workspace_id and e.outcome in [:hold, :block]
         )
       ) do
      pass("held_or_blocked", "decision with outcome in [:hold, :block] present")
    else
      fail("held_or_blocked", "no held/blocked decision — safety rails not exercised")
    end
  end

  defp check_cancel(workspace_id) do
    cancelled =
      Repo.exists?(
        from(i in AgentIntent,
          where: i.workspace_id == ^workspace_id and i.state == :cancelled
        )
      )

    cancel_audit =
      Repo.exists?(
        from(i in AgentIntent,
          join: a in Bank.Audit.AuditEvent,
          on: a.correlation_id == i.id,
          where:
            i.workspace_id == ^workspace_id and i.state == :cancelled and
              a.event_type == "intent.cancelled"
        )
      )

    cond do
      not cancelled -> fail("cancel", "no cancelled intent in workspace")
      not cancel_audit -> fail("cancel", "cancelled intent has no intent.cancelled audit event")
      true -> pass("cancel", "cancelled intent present with intent.cancelled audit event")
    end
  end

  defp check_replay(workspace_id) do
    case Decisions.list_recent_decisions(1, workspace_id: workspace_id) do
      [] ->
        fail("replay", "no decision envelopes available for replay")

      [%DecisionEnvelope{intent_id: intent_id} | _] ->
        case Audit.replay(intent_id) do
          {:ok, %{audit: [_ | _]}} ->
            pass("replay", "replay returns at least one audit event for intent=#{intent_id}")

          {:ok, %{audit: []}} ->
            fail("replay", "replay returned an empty audit-event list for intent=#{intent_id}")

          {:error, :not_found} ->
            fail("replay", "replay returned :not_found for intent=#{intent_id}")
        end
    end
  end

  # --- Helpers ---------------------------------------------------------

  defp pass(name, detail), do: %{name: name, status: :pass, detail: detail}
  defp fail(name, detail), do: %{name: name, status: :fail, detail: detail}
end
