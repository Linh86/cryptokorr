defmodule Bank.Ops.Jobs do
  @moduledoc """
  Sanitized read API over the Oban jobs table for operator UI
  surfaces (#229 Incident Center: "failed/retrying jobs" card).

  ## Why this exists

  C-UI / SecurityLive needs to surface jobs that have failed or are
  in a retry loop so operators can spot stuck pipelines. Querying
  `oban_jobs` directly from a LiveView would be unsafe in two
  ways:

    1. **Unbounded scans.** The table can hold weeks of completed
       jobs (Oban prunes after 7 days in this deployment). A
       LiveView mount must not pay for an unbounded scan.
    2. **Sensitive payloads.** `args`, `errors`, `meta`, and
       `tags` columns can carry caller-supplied IDs, raw exception
       messages, stack traces, RPC URLs with embedded tokens,
       transaction hashes, signing-payload fragments, and more.
       None of those are safe to render to operators.

  This module owns the only sanctioned read path: a fixed-shape
  result row with a hard query cap. Callers cannot reach `args`,
  `errors`, `meta`, or `tags` through this module.

  ## Workspace scoping (v1 limitation)

  Job `args` in this codebase carry domain ids (`intent_id`,
  `decision_envelope_id`, `execution_plan_id`, `workspace_id` for
  some workers, ...) but the encoding is per-worker and not
  uniform. Reliable workspace filtering would require a per-worker
  args→workspace_id resolver plus joins back to the source rows on
  every list call.

  v1 deliberately does NOT do that. `list_problem_jobs/1` is a
  **global ops view** — every workspace's failed jobs show up
  together. C-UI surfaces it as a workspace-agnostic ops card,
  not a tenant card. A future revision can extend the resolver
  per worker; for now, do not pretend isolation that the data
  cannot back.

  ## States returned

    * `:retryable` — execution failed; Oban will retry.
    * `:discarded` — job failed past `max_attempts`. Operator
      action required (manual abort, fix upstream, etc.).
    * `:cancelled` — operator/admin cancelled the job.

  Completed, scheduled, available, executing, and suspended jobs
  are intentionally excluded — they aren't "problem" jobs.

  ## Returned row shape

      %{
        id: integer(),
        worker: String.t(),       # e.g. "Bank.Runtime.Workers.RunExecution"
        queue: String.t(),        # e.g. "executions_run"
        state: String.t(),        # "retryable" | "discarded" | "cancelled"
        attempt: non_neg_integer(),
        max_attempts: non_neg_integer(),
        inserted_at: DateTime.t() | nil,
        scheduled_at: DateTime.t() | nil,
        attempted_at: DateTime.t() | nil
      }

  All fields are either code-controlled (atoms / module names /
  state enum) or timestamps. None expose caller-supplied data.
  """

  import Ecto.Query

  alias Bank.Repo
  alias Oban.Job

  @problem_states ~w(retryable discarded cancelled)
  @default_limit 10
  @max_limit 50

  @typedoc "Sanitized problem-job row returned by `list_problem_jobs/1`."
  @type problem_job :: %{
          id: integer(),
          worker: String.t(),
          queue: String.t(),
          state: String.t(),
          attempt: non_neg_integer(),
          max_attempts: non_neg_integer(),
          inserted_at: DateTime.t() | nil,
          scheduled_at: DateTime.t() | nil,
          attempted_at: DateTime.t() | nil
        }

  @doc """
  List Oban jobs in a non-terminal-but-failing state
  (`retryable`, `discarded`, `cancelled`), most recently
  attempted first. Returns a sanitized row shape — never the
  raw `args`, `errors`, `meta`, or `tags`.

  ## Options

    * `:limit` — default `#{@default_limit}`, hard-capped at
      `#{@max_limit}`. Values outside `1..#{@max_limit}` clamp
      into range.

  ## Returns

  A list of `t:problem_job/0` (possibly empty). Never raises;
  on a Repo failure the caller will see the underlying Ecto
  exception (callers in LiveView should let the supervisor
  recover the socket).

  ## Workspace scoping

  See moduledoc — v1 is global only.
  """
  @spec list_problem_jobs(keyword()) :: [problem_job()]
  def list_problem_jobs(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    from(j in Job,
      where: j.state in ^@problem_states,
      order_by: [desc_nulls_last: j.attempted_at, desc: j.inserted_at, desc: j.id],
      limit: ^limit,
      select: %{
        id: j.id,
        worker: j.worker,
        queue: j.queue,
        state: j.state,
        attempt: j.attempt,
        max_attempts: j.max_attempts,
        inserted_at: j.inserted_at,
        scheduled_at: j.scheduled_at,
        attempted_at: j.attempted_at
      }
    )
    |> Repo.all()
  end

  @doc "List of states this module surfaces. Stable for tests / docs."
  @spec problem_states() :: [String.t()]
  def problem_states, do: @problem_states

  defp clamp_limit(n) when is_integer(n) and n > 0 and n <= @max_limit, do: n
  defp clamp_limit(n) when is_integer(n) and n > @max_limit, do: @max_limit
  defp clamp_limit(_), do: @default_limit
end
