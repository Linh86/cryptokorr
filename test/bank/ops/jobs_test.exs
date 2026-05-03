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
