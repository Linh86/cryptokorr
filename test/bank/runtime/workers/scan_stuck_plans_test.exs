defmodule Bank.Runtime.Workers.ScanStuckPlansTest do
  @moduledoc """
  Tests for the periodic stuck-plan detector worker (#230-b).
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Notifications
  alias Bank.Notifications.Notification
  alias Bank.Ops.Health
  alias Bank.Repo
  alias Bank.Runtime.Workers.ScanStuckPlans

  setup do
    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "scan-stuck-#{System.unique_integer([:positive])}",
        name: "Scan Stuck",
        mainnet_enabled: true
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

    test "audit M8: SQL-level partial unique index dedupes parallel emitters bypassing pre-check" do
      # Bypass the per-plan pre-check — pre-build the audit attrs and
      # call `Audit.append_event/2` twice with the same
      # `(subject_id, after_ref->>'window_start')` key. With the
      # `audit_events_recurring_dedupe_idx` partial unique index in
      # place and `dedupe: :recurring_window`, the second insert
      # collapses to `{:ok, :already_exists}` instead of producing a
      # second row. Without the index this test would create two
      # rows under load (manual back-fill paralleling cron) — that
      # was the audit M8 finding.
      now = DateTime.utc_now()
      window_start = Health.detection_window_start(now)
      window_iso = DateTime.to_iso8601(window_start)
      plan_id = Ecto.UUID.generate()

      attrs =
        Bank.Audit.Events.ops_stuck_plan_detected(
          %{
            id: plan_id,
            workspace_id: nil,
            execution_status: :prepared,
            updated_at: now,
            stuck_for_seconds: 700,
            threshold_seconds: 600
          },
          window_start: window_start
        )

      assert {:ok, %AuditEvent{}} =
               Bank.Audit.append_event(attrs, dedupe: :recurring_window)

      assert {:ok, :already_exists} =
               Bank.Audit.append_event(attrs, dedupe: :recurring_window)

      assert Repo.aggregate(
               from(e in AuditEvent,
                 where:
                   e.event_type == "ops.stuck_plan_detected" and
                     e.subject_id == ^plan_id and
                     fragment("?->>'window_start' = ?", e.after_ref, ^window_iso)
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

    test "stuck plan crossing the threshold also emits an ops.stuck_plan alert notification (#256)",
         %{workspace: ws} do
      now = DateTime.utc_now()
      window_iso = now |> Health.detection_window_start() |> DateTime.to_iso8601()

      stuck = stale_plan(:prepared, DateTime.add(now, -20 * 60, :second))

      assert :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      [alert] =
        Notifications.list_for_workspace(ws.id, event_type: "ops.stuck_plan")

      assert alert.workspace_id == ws.id
      assert alert.event_type == "ops.stuck_plan"
      assert alert.severity == :warning
      assert alert.role_target == :operator
      assert alert.subject_type == "execution_plan"
      assert alert.subject_id == stuck.id
      assert alert.dedupe_key == "ops.stuck_plan:#{stuck.id}:#{window_iso}"
      assert alert.body =~ "status=prepared"
      assert alert.body =~ "threshold_seconds=600"
      assert alert.body =~ "stuck_for_seconds="
    end

    test "repeated scans within the same window do not duplicate the ops.stuck_plan alert (#256)",
         %{workspace: ws} do
      now = DateTime.utc_now()
      window_iso = now |> Health.detection_window_start() |> DateTime.to_iso8601()

      _stuck = stale_plan(:prepared, DateTime.add(now, -20 * 60, :second))

      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})
      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})
      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      assert length(Notifications.list_for_workspace(ws.id, event_type: "ops.stuck_plan")) == 1
    end

    test "a previously-stuck plan that is no longer stuck emits ops.stuck_plan.resolved (#256)",
         %{workspace: ws} do
      now = DateTime.utc_now()
      window_iso = now |> Health.detection_window_start() |> DateTime.to_iso8601()

      stuck = stale_plan(:prepared, DateTime.add(now, -20 * 60, :second))

      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      assert [%Notification{event_type: "ops.stuck_plan"}] =
               Notifications.list_for_workspace(ws.id, event_type: "ops.stuck_plan")

      # Recover the plan: bump updated_at to "now" so it falls
      # below every per-status threshold.
      {1, _} =
        Repo.update_all(
          from(p in ExecutionPlan, where: p.id == ^stuck.id),
          set: [updated_at: now]
        )

      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      events =
        Notifications.list_for_workspace(ws.id)
        |> Enum.map(& &1.event_type)
        |> Enum.sort()

      assert events == ["ops.stuck_plan", "ops.stuck_plan.resolved"]

      [resolved] =
        Notifications.list_for_workspace(ws.id, event_type: "ops.stuck_plan.resolved")

      assert resolved.severity == :info
      assert resolved.subject_id == stuck.id
      assert resolved.title =~ "resolved"
      assert resolved.dedupe_key =~ ".resolved"
      assert resolved.dedupe_key =~ window_iso
    end

    test "recovery is deduped: rerunning the scan after resolve does not emit another resolved row (#256)",
         %{workspace: ws} do
      now = DateTime.utc_now()
      window_iso = now |> Health.detection_window_start() |> DateTime.to_iso8601()

      stuck = stale_plan(:prepared, DateTime.add(now, -20 * 60, :second))

      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      {1, _} =
        Repo.update_all(
          from(p in ExecutionPlan, where: p.id == ^stuck.id),
          set: [updated_at: now]
        )

      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})
      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})
      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      assert length(
               Notifications.list_for_workspace(ws.id, event_type: "ops.stuck_plan.resolved")
             ) == 1
    end

    test "alerted plan that falls outside the capped scan batch is NOT falsely resolved (#256 P2)",
         %{workspace: ws} do
      now = DateTime.utc_now()
      window_iso = now |> Health.detection_window_start() |> DateTime.to_iso8601()

      # First tick: alert one plan that has been stuck a long
      # time. (3 h is well past every per-status threshold.)
      alerted = stale_plan(:prepared, DateTime.add(now, -3 * 3600, :second))

      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      [alert] = Notifications.list_for_workspace(ws.id, event_type: "ops.stuck_plan")
      assert alert.subject_id == alerted.id

      # Now plant 60 OLDER stuck plans so the alerted row falls
      # outside any reasonable capped detection batch (default
      # cap is 50, so 60 fillers + 1 alerted = the alerted one
      # is past the cap when ordered ASC by `updated_at`).
      filler_ts = DateTime.add(now, -10 * 3600, :second)

      for _i <- 1..60 do
        _ = stale_plan(:prepared, filler_ts)
      end

      # Sanity check: the alerted plan is now NOT in the capped
      # detection batch — proving the regression scenario.
      capped_ids =
        Health.stuck_plan_details(now: now)
        |> Enum.map(& &1.id)
        |> MapSet.new()

      refute MapSet.member?(capped_ids, alerted.id),
             "test fixture must place the alerted plan outside the capped scan batch"

      # Second tick: the alerted plan is still stuck (its
      # `updated_at` was never bumped). The recovery logic must
      # NOT fire `.resolved` for it just because it fell out of
      # the capped batch.
      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      assert Notifications.list_for_workspace(ws.id,
               event_type: "ops.stuck_plan.resolved"
             ) == []

      # Subject-targeted recheck confirms the alerted plan is
      # still stuck (so `Health.plans_currently_stuck/2` agrees
      # with the assertion above).
      still_stuck = Health.plans_currently_stuck([alerted.id], now: now)
      assert MapSet.member?(still_stuck, alerted.id)
    end

    test "subject-targeted recovery still emits resolved when the plan genuinely cleared, even surrounded by other stuck plans (#256 P2)",
         %{workspace: ws} do
      now = DateTime.utc_now()
      window_iso = now |> Health.detection_window_start() |> DateTime.to_iso8601()

      stuck = stale_plan(:prepared, DateTime.add(now, -3 * 3600, :second))

      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})
      assert length(Notifications.list_for_workspace(ws.id, event_type: "ops.stuck_plan")) == 1

      # Surround it with many other still-stuck plans so the
      # capped batch on the next tick won't contain `stuck.id`.
      filler_ts = DateTime.add(now, -10 * 3600, :second)

      for _i <- 1..60 do
        _ = stale_plan(:prepared, filler_ts)
      end

      # Now genuinely clear the alerted plan.
      {1, _} =
        Repo.update_all(
          from(p in ExecutionPlan, where: p.id == ^stuck.id),
          set: [updated_at: now]
        )

      :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      [resolved] =
        Notifications.list_for_workspace(ws.id, event_type: "ops.stuck_plan.resolved")

      assert resolved.subject_id == stuck.id
      assert resolved.severity == :info
    end

    test "scan does not emit alerts for stuck plans whose workspace_id is nil (#256)" do
      now = DateTime.utc_now()
      window_iso = now |> Health.detection_window_start() |> DateTime.to_iso8601()

      legacy = stale_plan(:prepared, DateTime.add(now, -20 * 60, :second), workspace_id: nil)

      assert :ok = perform_job(ScanStuckPlans, %{"window_start" => window_iso})

      # Audit emission still happens on the unscoped row.
      assert Repo.aggregate(
               from(e in AuditEvent,
                 where:
                   e.event_type == "ops.stuck_plan_detected" and
                     e.subject_id == ^legacy.id
               ),
               :count
             ) == 1

      # But no notification — alerts are workspace-scoped by contract.
      assert Repo.aggregate(
               from(n in Notification,
                 where:
                   n.event_type == "ops.stuck_plan" and
                     n.subject_id == ^legacy.id
               ),
               :count
             ) == 0
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
