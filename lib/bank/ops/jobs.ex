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

  @typedoc """
  Aggregate shape returned by `problem_job_summary/1`. Derived
  from the same sanitized row set as `list_problem_jobs/1` so no
  unsafe column ever reaches the caller.

  ## Fields

    * `:total` — number of rows in the bounded window. Equal to
      `Enum.sum(Map.values(:counts))`.
    * `:counts` — per-state counts. Always carries one key per
      `problem_states/0` value so callers can `Map.fetch!/2`
      without nil-checks. Counts come from the bounded window
      (i.e. `list_problem_jobs/1` with `:limit`), not the full
      table.
    * `:oldest_attempted_at` — earliest `attempted_at` in the
      window, or `nil` if every row has `attempted_at == nil` /
      the window is empty.
    * `:newest_attempted_at` — latest `attempted_at` in the
      window (same nil rule).
    * `:limit` — the resolved limit used for the underlying scan.
    * `:global?` — always `true` in v1. Explicit marker so a
      future workspace-scoped variant cannot silently flip the
      semantics; UI labels the card "ops-wide" when `true`.
  """
  @type problem_job_summary :: %{
          total: non_neg_integer(),
          counts: %{String.t() => non_neg_integer()},
          oldest_attempted_at: DateTime.t() | nil,
          newest_attempted_at: DateTime.t() | nil,
          limit: pos_integer(),
          global?: true
        }

  @doc """
  Sanitized aggregate over the same problem-job window as
  `list_problem_jobs/1`. Suitable for a single-row "ops health"
  card on SecurityLive.

  Counts come from the *bounded* window (the first `:limit` rows
  ordered by `attempted_at desc nulls last, inserted_at desc, id
  desc`), so a runaway problem-job pile-up cannot widen the
  query past the hard cap. UI consumers wanting a true
  unbounded total should ask for a future endpoint, not extend
  the limit here.

  ## Options

    * `:limit` — default `#{@default_limit}`, hard-capped at
      `#{@max_limit}`. Same clamp rule as `list_problem_jobs/1`.

  ## Workspace scoping (v1 limitation)

  Same as `list_problem_jobs/1` — v1 is global. The returned
  `:global?` is always `true` and acts as the explicit marker
  C-UI must check before deciding how to label the card. A
  future revision can introduce per-workspace summaries; the
  shape will gain a workspace_id field at that point but
  `global?` stays as the discriminator.
  """
  @spec problem_job_summary(keyword()) :: problem_job_summary()
  def problem_job_summary(opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    rows = list_problem_jobs(limit: limit)
    total = length(rows)
    counts = build_counts(rows)
    {oldest, newest} = attempted_at_extents(rows)

    %{
      total: total,
      counts: counts,
      oldest_attempted_at: oldest,
      newest_attempted_at: newest,
      limit: limit,
      global?: true
    }
  end

  defp build_counts(rows) do
    base = Map.new(@problem_states, fn state -> {state, 0} end)

    Enum.reduce(rows, base, fn row, acc ->
      Map.update(acc, row.state, 1, &(&1 + 1))
    end)
  end

  # Walks the row list once; returns {oldest, newest} of the
  # non-nil `attempted_at` values. Both `nil` when the window has
  # no rows that have been attempted yet (e.g. cancelled jobs
  # never run, or the window is empty).
  defp attempted_at_extents([]), do: {nil, nil}

  defp attempted_at_extents(rows) do
    rows
    |> Enum.map(& &1.attempted_at)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        {nil, nil}

      [first | _] = stamps ->
        Enum.reduce(stamps, {first, first}, fn t, {oldest, newest} ->
          {min_dt(t, oldest), max_dt(t, newest)}
        end)
    end
  end

  defp min_dt(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)
  defp max_dt(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)

  defp clamp_limit(n) when is_integer(n) and n > 0 and n <= @max_limit, do: n
  defp clamp_limit(n) when is_integer(n) and n > @max_limit, do: @max_limit
  defp clamp_limit(_), do: @default_limit
end
