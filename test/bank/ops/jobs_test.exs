defmodule Bank.Ops.JobsTest do
  use Bank.DataCase, async: false

  alias Bank.Ops.Jobs
  alias Bank.Repo

  describe "list_problem_jobs/1" do
    test "returns [] when no problem jobs exist" do
      assert Jobs.list_problem_jobs() == []
    end

    test "surfaces a discarded job with sanitized fields only" do
      now = DateTime.utc_now()

      insert_job!(%{
        worker: "Bank.Runtime.Workers.RunExecution",
        queue: "executions_run",
        state: "discarded",
        args: %{"decision_id" => "leak-#{Ecto.UUID.generate()}"},
        errors: [%{"attempt" => 5, "error" => "Bearer sk_live_4242 leak"}],
        meta: %{"sensitive" => "value"},
        tags: ["should_not_appear"],
        attempt: 5,
        max_attempts: 5,
        inserted_at: now,
        scheduled_at: now,
        attempted_at: now
      })

      assert [row] = Jobs.list_problem_jobs()

      # Allowlisted fields present.
      assert row.worker == "Bank.Runtime.Workers.RunExecution"
      assert row.queue == "executions_run"
      assert row.state == "discarded"
      assert row.attempt == 5
      assert row.max_attempts == 5
      assert is_integer(row.id)
      assert %DateTime{} = row.inserted_at
      assert %DateTime{} = row.scheduled_at
      assert %DateTime{} = row.attempted_at

      # Disallowlisted fields ABSENT — `args`, `errors`, `meta`,
      # `tags` keys must not appear on the result map at all.
      assert Map.keys(row) |> Enum.sort() ==
               ~w(attempt attempted_at id inserted_at max_attempts queue scheduled_at state worker)a

      refute Map.has_key?(row, :args)
      refute Map.has_key?(row, :errors)
      refute Map.has_key?(row, :meta)
      refute Map.has_key?(row, :tags)
    end

    test "surfaces a retryable job" do
      insert_job!(%{
        state: "retryable",
        worker: "RetryWorker",
        queue: "ops_scan",
        attempt: 2,
        max_attempts: 5
      })

      assert [row] = Jobs.list_problem_jobs()
      assert row.state == "retryable"
      assert row.worker == "RetryWorker"
      assert row.attempt == 2
    end

    test "surfaces a cancelled job" do
      insert_job!(%{state: "cancelled", worker: "CancelledWorker", queue: "default"})

      assert [row] = Jobs.list_problem_jobs()
      assert row.state == "cancelled"
    end

    test "does NOT surface completed / scheduled / available / executing / suspended jobs" do
      for state <- ~w(completed scheduled available executing suspended) do
        insert_job!(%{state: state, worker: "Quiet#{state}Worker", queue: "default"})
      end

      assert Jobs.list_problem_jobs() == []
    end

    test "JSON-scan: sanitized result does NOT leak any args/errors/meta/tags substrings" do
      insert_job!(%{
        worker: "Bank.Runtime.Workers.RunExecution",
        queue: "executions_run",
        state: "discarded",
        args: %{
          "decision_id" => "secret-id-12345",
          "url" => "https://secret@adapter.test/dispatch",
          "Authorization" => "Bearer sk_live_4242"
        },
        errors: [
          %{
            "attempt" => 5,
            "error" => "** (RuntimeError) https://secret@adapter.test sk_live_4242 0xdeadbeef"
          }
        ],
        meta: %{"private_key" => "0xabc"},
        tags: ["sensitive-tag-secret"],
        attempt: 5,
        max_attempts: 5
      })

      [row] = Jobs.list_problem_jobs()
      json = Jason.encode!(row)

      for needle <- [
            "Bearer",
            "Authorization",
            "sk_live",
            "secret",
            "https://",
            "private_key",
            "0xdeadbeef",
            "0xabc",
            "sensitive-tag",
            "RuntimeError"
          ] do
        refute String.contains?(json, needle),
               "list_problem_jobs row must not leak #{needle}: #{inspect(json)}"
      end
    end

    test "limit defaults to 10 and is hard-capped at 50" do
      for i <- 1..60 do
        insert_job!(%{state: "discarded", worker: "BulkWorker#{i}", queue: "default"})
      end

      assert length(Jobs.list_problem_jobs()) == 10
      assert length(Jobs.list_problem_jobs(limit: 25)) == 25
      assert length(Jobs.list_problem_jobs(limit: 50)) == 50
      # Exceeding cap clamps down, not up; never returns > 50.
      assert length(Jobs.list_problem_jobs(limit: 999)) == 50
      # Negative / zero / non-integer falls back to default.
      assert length(Jobs.list_problem_jobs(limit: 0)) == 10
      assert length(Jobs.list_problem_jobs(limit: -3)) == 10
      assert length(Jobs.list_problem_jobs(limit: "lots")) == 10
    end

    test "orders by attempted_at desc, then inserted_at desc, then id desc" do
      old_attempt = DateTime.utc_now() |> DateTime.add(-3600, :second)
      mid_attempt = DateTime.utc_now() |> DateTime.add(-60, :second)
      new_attempt = DateTime.utc_now()

      insert_job!(%{state: "discarded", worker: "OldestWorker", attempted_at: old_attempt})
      insert_job!(%{state: "discarded", worker: "MidWorker", attempted_at: mid_attempt})
      insert_job!(%{state: "discarded", worker: "NewestWorker", attempted_at: new_attempt})

      workers = Jobs.list_problem_jobs() |> Enum.map(& &1.worker)
      assert workers == ~w(NewestWorker MidWorker OldestWorker)
    end

    test "problem_states/0 lists the surfaced states" do
      assert Jobs.problem_states() == ~w(retryable discarded cancelled)
    end
  end

  describe "problem_job_summary/1" do
    test "returns total 0 and zero counts when no problem jobs exist" do
      summary = Jobs.problem_job_summary()

      assert summary.total == 0
      assert summary.counts == %{"retryable" => 0, "discarded" => 0, "cancelled" => 0}
      assert is_nil(summary.oldest_attempted_at)
      assert is_nil(summary.newest_attempted_at)
      assert summary.limit == 10
      assert summary.global? == true
    end

    test "counts mixed states correctly and totals match counts" do
      now = DateTime.utc_now()

      # 2 retryable, 3 discarded, 1 cancelled
      for _ <- 1..2,
          do: insert_job!(%{state: "retryable", attempted_at: now})

      for _ <- 1..3,
          do: insert_job!(%{state: "discarded", attempted_at: now})

      insert_job!(%{state: "cancelled", attempted_at: now})

      summary = Jobs.problem_job_summary()

      assert summary.total == 6
      assert summary.counts == %{"retryable" => 2, "discarded" => 3, "cancelled" => 1}
      assert summary.total == summary.counts |> Map.values() |> Enum.sum()
    end

    test "non-problem states do NOT affect counts or total" do
      now = DateTime.utc_now()

      # Real problem jobs.
      insert_job!(%{state: "retryable", attempted_at: now})
      insert_job!(%{state: "discarded", attempted_at: now})

      # Noise that must be ignored.
      for state <- ~w(completed scheduled available executing suspended) do
        insert_job!(%{state: state, attempted_at: now})
      end

      summary = Jobs.problem_job_summary()

      assert summary.total == 2
      assert summary.counts == %{"retryable" => 1, "discarded" => 1, "cancelled" => 0}
    end

    test "limit defaults to 10 and is hard-capped at 50" do
      for _ <- 1..60, do: insert_job!(%{state: "discarded"})

      assert Jobs.problem_job_summary().limit == 10
      assert Jobs.problem_job_summary().total == 10

      assert Jobs.problem_job_summary(limit: 25).limit == 25
      assert Jobs.problem_job_summary(limit: 25).total == 25

      assert Jobs.problem_job_summary(limit: 50).limit == 50
      assert Jobs.problem_job_summary(limit: 50).total == 50

      # Exceeding cap clamps down to 50.
      capped = Jobs.problem_job_summary(limit: 999)
      assert capped.limit == 50
      assert capped.total == 50

      # Invalid input falls back to default.
      assert Jobs.problem_job_summary(limit: 0).limit == 10
      assert Jobs.problem_job_summary(limit: -3).limit == 10
      assert Jobs.problem_job_summary(limit: "lots").limit == 10
    end

    test "oldest/newest attempted_at extents come from non-nil window rows" do
      old = DateTime.utc_now() |> DateTime.add(-7200, :second)
      mid = DateTime.utc_now() |> DateTime.add(-3600, :second)
      new = DateTime.utc_now()

      insert_job!(%{state: "discarded", attempted_at: old})
      insert_job!(%{state: "retryable", attempted_at: mid})
      insert_job!(%{state: "cancelled", attempted_at: new})
      # An attempted_at: nil row must NOT affect the extents.
      insert_job!(%{state: "discarded", attempted_at: nil})

      summary = Jobs.problem_job_summary()

      assert DateTime.compare(summary.oldest_attempted_at, old) == :eq
      assert DateTime.compare(summary.newest_attempted_at, new) == :eq
    end

    test "extents are nil when every problem row has attempted_at: nil" do
      insert_job!(%{state: "cancelled", attempted_at: nil})

      summary = Jobs.problem_job_summary()

      assert summary.total == 1
      assert is_nil(summary.oldest_attempted_at)
      assert is_nil(summary.newest_attempted_at)
    end

    test "summary shape: only allowlisted top-level keys" do
      insert_job!(%{state: "discarded"})

      summary = Jobs.problem_job_summary()

      assert Map.keys(summary) |> Enum.sort() ==
               ~w(counts global? limit newest_attempted_at oldest_attempted_at total)a

      refute Map.has_key?(summary, :rows)
      refute Map.has_key?(summary, :args)
      refute Map.has_key?(summary, :errors)
      refute Map.has_key?(summary, :meta)
      refute Map.has_key?(summary, :tags)
    end

    test "global? is always true so UI cannot accidentally label workspace-isolated" do
      insert_job!(%{state: "retryable"})
      assert Jobs.problem_job_summary().global? == true
      assert Jobs.problem_job_summary(limit: 50).global? == true
    end

    test "JSON-scan: summary derived from secret-bearing rows leaks nothing" do
      insert_job!(%{
        state: "discarded",
        worker: "Bank.Runtime.Workers.RunExecution",
        queue: "executions_run",
        args: %{
          "decision_id" => "secret-id-12345",
          "url" => "https://secret@adapter.test/dispatch",
          "Authorization" => "Bearer sk_live_4242"
        },
        errors: [
          %{
            "attempt" => 5,
            "error" => "** (RuntimeError) https://secret@adapter.test sk_live_4242 0xdeadbeef"
          }
        ],
        meta: %{"private_key" => "0xabc"},
        tags: ["sensitive-tag-secret"]
      })

      summary = Jobs.problem_job_summary()
      json = Jason.encode!(summary)

      for needle <- [
            "Bearer",
            "Authorization",
            "sk_live",
            "sk_",
            "secret@",
            "https://",
            "private_key",
            "0xdeadbeef",
            "0xabc",
            "sensitive-tag",
            "RuntimeError",
            "args",
            "errors",
            "meta",
            "tags"
          ] do
        refute String.contains?(json, needle),
               "summary must not leak #{needle}: #{inspect(json)}"
      end

      # Sanity: the row WAS counted, so the sanitization didn't
      # silently drop it.
      assert summary.counts["discarded"] == 1
      assert summary.total == 1
    end
  end

  # ---- helpers ----

  # Insert directly into `oban_jobs` so we can drive `state`,
  # `errors`, `meta`, `tags`, etc. independently of the worker
  # API. Oban's `insert/1` won't let us set `state: "discarded"`
  # at insert time.
  defp insert_job!(attrs) do
    now = DateTime.utc_now()

    row = %{
      worker: Map.get(attrs, :worker, "TestWorker"),
      queue: Map.get(attrs, :queue, "default"),
      state: Map.fetch!(attrs, :state),
      args: Map.get(attrs, :args, %{}),
      errors: Map.get(attrs, :errors, []),
      meta: Map.get(attrs, :meta, %{}),
      tags: Map.get(attrs, :tags, []),
      attempt: Map.get(attrs, :attempt, 0),
      max_attempts: Map.get(attrs, :max_attempts, 20),
      priority: Map.get(attrs, :priority, 0),
      inserted_at: Map.get(attrs, :inserted_at, now),
      scheduled_at: Map.get(attrs, :scheduled_at, now),
      attempted_at: Map.get(attrs, :attempted_at, nil)
    }

    {1, [%{id: id}]} =
      Repo.insert_all("oban_jobs", [row], returning: [:id])

    id
  end
end
