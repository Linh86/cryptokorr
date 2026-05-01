defmodule Bank.Runtime.Workers.ScanStuckPlansTest do
  @moduledoc """
  Tests for the periodic stuck-plan detector worker (#230-b).
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Ops.Health
  alias Bank.Repo
  alias Bank.Runtime.Workers.ScanStuckPlans

  setup do
    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "scan-stuck-#{System.unique_integer([:positive])}",
        name: "Scan Stuck"
      })

    Process.put(:bank_test_workspace_id, ws.id)
    on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

    %{workspace: ws}
  end

  describe "perform/1" do
    test "emits one ops.stuck_plan_detected per stuck plan with workspace_id stamped",
         %{workspace: ws} do
      now = DateTime.utc_now()
      window_start = Health.detection_window_start(now)
      window_iso = DateTime.to_iso8601(window_start)

      stuck_plan = stale_plan(:prepared, DateTime.add(now, -20 * 60, :second))
      _fresh_plan = stale_plan(:prepared, DateTime.add(now, -30, :second))

      assert :ok =
               perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      events =
        Repo.all(
          from(e in AuditEvent,
            where: e.event_type == "ops.stuck_plan_detected" and e.subject_id == ^stuck_plan.id
          )
        )

      assert length(events) == 1
      [event] = events
      assert event.workspace_id == ws.id
      assert event.subject_type == "execution_plan"
      assert event.actor == :runtime
      assert event.after_ref["execution_status"] == "prepared"
      assert event.after_ref["window_start"] == window_iso
      assert is_integer(event.after_ref["stuck_for_seconds"])
      assert event.after_ref["threshold_seconds"] == 600
    end

    test "is idempotent within the same detection window (no second audit row)" do
      now = DateTime.utc_now()
      window_start = Health.detection_window_start(now)
      window_iso = DateTime.to_iso8601(window_start)

      stuck = stale_plan(:prepared, DateTime.add(now, -20 * 60, :second))

      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})
      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      assert Repo.aggregate(
               from(e in AuditEvent,
                 where: e.event_type == "ops.stuck_plan_detected" and e.subject_id == ^stuck.id
               ),
               :count
             ) == 1
    end

    test "emits no rows when no plans are stuck" do
      now = DateTime.utc_now()
      window_start = Health.detection_window_start(now)
      window_iso = DateTime.to_iso8601(window_start)

      _fresh = stale_plan(:prepared, DateTime.add(now, -30, :second))

      assert :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      assert Repo.aggregate(
               from(e in AuditEvent, where: e.event_type == "ops.stuck_plan_detected"),
               :count
             ) == 0
    end

    test "ignores `active: false` plans (manual-abort #302 flag)" do
      now = DateTime.utc_now()
      window_iso = now |> Health.detection_window_start() |> DateTime.to_iso8601()

      _aborted =
        stale_plan(:aborted, DateTime.add(now, -20 * 60, :second),
          final_outcome: :aborted,
          active: false
        )

      assert :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      assert Repo.aggregate(
               from(e in AuditEvent, where: e.event_type == "ops.stuck_plan_detected"),
               :count
             ) == 0
    end

    test "audit JSON contains no raw bearer / Authorization / secret_hash" do
      now = DateTime.utc_now()
      window_iso = now |> Health.detection_window_start() |> DateTime.to_iso8601()

      stuck = stale_plan(:prepared, DateTime.add(now, -20 * 60, :second))

      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      [event] =
        Repo.all(
          from(e in AuditEvent,
            where: e.event_type == "ops.stuck_plan_detected" and e.subject_id == ^stuck.id
          )
        )

      json = event |> Map.from_struct() |> Map.drop([:__meta__, :workspace]) |> Jason.encode!()

      refute json =~ "secret_hash"
      refute json =~ "Bearer "
      refute json =~ "Authorization"
    end

    test "uses real `now` for the threshold check, not the rounded `window_start` (#230 P2 Finding A)" do
      # Pre-fix the worker passed `window_start` (the 5-min aligned
      # bucket) as `now` into `Health.stuck_plan_details/1`, which
      # delayed detection by up to one bucket. A plan that became
      # stuck at 12:33:30 with a 10-min threshold (cutoff 12:23:30)
      # should be detected at 12:34, but the buggy worker would
      # evaluate at 12:30 (cutoff 12:20) and miss it.
      now = DateTime.from_naive!(~N[2026-05-01 12:34:00], "Etc/UTC")
      window_start = Health.detection_window_start(now)

      assert window_start == DateTime.from_naive!(~N[2026-05-01 12:30:00], "Etc/UTC")

      # Plan went stuck at 12:23:30 — past the 10-min threshold for
      # `:prepared` (cutoff 12:24:00). The buggy code evaluated
      # against a 12:20 cutoff and would have missed this row.
      borderline =
        stale_plan(:prepared, DateTime.from_naive!(~N[2026-05-01 12:23:30], "Etc/UTC"))

      assert :ok =
               perform_job(ScanStuckPlans, %{
                 "now" => DateTime.to_iso8601(now),
                 "window_start" => DateTime.to_iso8601(window_start)
               })

      assert Repo.aggregate(
               from(e in AuditEvent,
                 where:
                   e.event_type == "ops.stuck_plan_detected" and
                     e.subject_id == ^borderline.id
               ),
               :count
             ) == 1
    end

    test "fires the [:bank, :ops, :stuck_plan, :detected] telemetry event per emit" do
      now = DateTime.utc_now()
      window_iso = now |> Health.detection_window_start() |> DateTime.to_iso8601()

      _stuck = stale_plan(:prepared, DateTime.add(now, -20 * 60, :second))

      ref = make_ref()
      parent = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:bank, :ops, :stuck_plan, :detected],
        fn _event, measurements, metadata, _ ->
          send(parent, {:detected_event, measurements, metadata})
        end,
        nil
      )

      try do
        :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

        assert_receive {:detected_event, %{count: 1}, %{status: :prepared}}, 500
      after
        :telemetry.detach({__MODULE__, ref})
      end
    end
  end

  defp stale_plan(status, updated_at, extra \\ []) do
    plan_attrs = [execution_status: status] |> Keyword.merge(extra)

    plan = Bank.Fixtures.execution_plan(plan_attrs)

    {1, _} =
      Repo.update_all(
        from(p in ExecutionPlan, where: p.id == ^plan.id),
        set: [updated_at: updated_at]
      )

    %{plan | updated_at: updated_at}
  end
end
