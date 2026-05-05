defmodule Bank.Ops.AlertsTest do
  @moduledoc """
  Tests for `Bank.Ops.Alerts` (#256) — operational alert hooks
  with dedupe and recovery.

  Coverage matches the issue body's `## Tests` block:

    * threshold crossing emits an alert
    * repeated alert deduped
    * recovery / resolved behavior

  Plus the cross-cutting checklist: workspace isolation, severity
  defaults, kind allowlist, secret-hygiene rejection, and the
  read-only "no chain side effects" invariant.
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Notifications
  alias Bank.Notifications.Notification
  alias Bank.Ops.Alerts
  alias Bank.Repo

  setup do
    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "ops-alerts-#{System.unique_integer([:positive])}",
        name: "Ops Alerts WS",
        mainnet_enabled: true
      })

    %{workspace: ws}
  end

  describe "emit/1 — happy path (#256)" do
    test "threshold crossing emits a notification with the expected shape",
         %{workspace: ws} do
      assert {:ok, :emitted, %Notification{} = n} =
               Alerts.emit(%{
                 workspace_id: ws.id,
                 kind: :stuck_plan,
                 subject: "plan-abc-123",
                 details: %{stuck_for_seconds: 900, status: "pending_confirmation"}
               })

      assert n.workspace_id == ws.id
      assert n.event_type == "ops.stuck_plan"
      assert n.severity == :warning
      assert n.role_target == :operator
      assert n.subject_type == "ops_alert"
      assert n.title == "Execution plan stuck"
      assert n.dedupe_key == "ops.stuck_plan:plan-abc-123"

      # body carries structured details (sorted by key) — never raw
      # callback text, never a URL.
      assert n.body =~ "stuck_for_seconds=900"
      assert n.body =~ "status=pending_confirmation"
      assert n.body =~ "plan-abc-123"
    end

    test "every Phase 1 alert kind round-trips through emit/1",
         %{workspace: ws} do
      for kind <- Alerts.kinds() do
        assert {:ok, :emitted, %Notification{} = n} =
                 Alerts.emit(%{
                   workspace_id: ws.id,
                   kind: kind,
                   subject: "subj-#{kind}-#{System.unique_integer([:positive])}"
                 })

        assert n.event_type == "ops." <> Atom.to_string(kind)
      end
    end

    test "explicit :severity is preserved on the persisted row",
         %{workspace: ws} do
      assert {:ok, :emitted, n} =
               Alerts.emit(%{
                 workspace_id: ws.id,
                 kind: :adapter_down,
                 subject: "adapter",
                 severity: :critical
               })

      assert n.severity == :critical
    end

    test "explicit :role_target overrides the :operator default",
         %{workspace: ws} do
      assert {:ok, :emitted, n} =
               Alerts.emit(%{
                 workspace_id: ws.id,
                 kind: :queue_depth_high,
                 subject: "default-queue",
                 role_target: :admin
               })

      assert n.role_target == :admin
    end
  end

  describe "emit/1 — dedupe (#256)" do
    test "repeated emit on the same (workspace, kind, subject) collapses to one row",
         %{workspace: ws} do
      attrs = %{
        workspace_id: ws.id,
        kind: :stuck_plan,
        subject: "plan-dup",
        details: %{stuck_for_seconds: 900}
      }

      {:ok, :emitted, n1} = Alerts.emit(attrs)
      assert {:ok, :deduped, n2} = Alerts.emit(attrs)
      assert {:ok, :deduped, n3} = Alerts.emit(attrs)

      assert n1.id == n2.id
      assert n1.id == n3.id

      assert length(Notifications.list_for_workspace(ws.id)) == 1
    end

    test ":dedupe_window lets the same kind+subject re-fire across windows",
         %{workspace: ws} do
      base = %{
        workspace_id: ws.id,
        kind: :queue_depth_high,
        subject: "default"
      }

      {:ok, :emitted, _} = Alerts.emit(Map.put(base, :dedupe_window, "2026-05-04T15Z"))
      {:ok, :emitted, _} = Alerts.emit(Map.put(base, :dedupe_window, "2026-05-04T16Z"))

      # Same window collapses.
      {:ok, :deduped, _} = Alerts.emit(Map.put(base, :dedupe_window, "2026-05-04T16Z"))

      assert length(Notifications.list_for_workspace(ws.id)) == 2
    end
  end

  describe "resolve/1 — recovery (#256)" do
    test "resolve emits a paired ops.<kind>.resolved notification",
         %{workspace: ws} do
      base = %{
        workspace_id: ws.id,
        kind: :stuck_plan,
        subject: "plan-recover"
      }

      {:ok, :emitted, alert} = Alerts.emit(base)
      assert alert.event_type == "ops.stuck_plan"
      assert alert.severity == :warning

      assert {:ok, :emitted, resolved} = Alerts.resolve(base)
      assert resolved.event_type == "ops.stuck_plan.resolved"
      assert resolved.title =~ "resolved"
      # Recovery is informational, not a warning.
      assert resolved.severity == :info

      # The two are independent rows — alert + resolved coexist.
      events =
        Notifications.list_for_workspace(ws.id)
        |> Enum.map(& &1.event_type)
        |> Enum.sort()

      assert events == ["ops.stuck_plan", "ops.stuck_plan.resolved"]
    end

    test "repeated resolve calls are idempotent",
         %{workspace: ws} do
      base = %{workspace_id: ws.id, kind: :stuck_plan, subject: "plan-r-idem"}

      {:ok, :emitted, _} = Alerts.emit(base)
      {:ok, :emitted, r1} = Alerts.resolve(base)
      {:ok, :deduped, r2} = Alerts.resolve(base)

      assert r1.id == r2.id

      assert length(Notifications.list_for_workspace(ws.id)) == 2
    end

    test "resolve dedupe_key cannot collide with the open alert dedupe_key",
         %{workspace: ws} do
      base = %{workspace_id: ws.id, kind: :adapter_down, subject: "adapter"}

      {:ok, :emitted, alert} = Alerts.emit(base)
      {:ok, :emitted, resolved} = Alerts.resolve(base)

      refute alert.dedupe_key == resolved.dedupe_key
      assert resolved.dedupe_key =~ ".resolved"
    end
  end

  describe "emit/1 — workspace isolation (#256)" do
    test "ws-A and ws-B can use the same kind+subject independently",
         %{workspace: ws_a} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "ops-alerts-iso-#{System.unique_integer([:positive])}",
          name: "Ops Alerts ISO B",
          mainnet_enabled: true
        })

      attrs_for = fn ws ->
        %{
          workspace_id: ws.id,
          kind: :rpc_down,
          subject: "base-sepolia"
        }
      end

      {:ok, :emitted, _} = Alerts.emit(attrs_for.(ws_a))
      {:ok, :emitted, _} = Alerts.emit(attrs_for.(ws_b))

      # Each workspace sees exactly one row — no cross-leak.
      assert length(Notifications.list_for_workspace(ws_a.id)) == 1
      assert length(Notifications.list_for_workspace(ws_b.id)) == 1

      # Repeated emit in ws-A still collapses (same dedupe_key
      # within ws-A) without touching ws-B.
      {:ok, :deduped, _} = Alerts.emit(attrs_for.(ws_a))

      assert length(Notifications.list_for_workspace(ws_a.id)) == 1
      assert length(Notifications.list_for_workspace(ws_b.id)) == 1
    end
  end

  describe "emit/1 — input validation (#256)" do
    test "unknown :kind returns :unknown_kind without writing a row",
         %{workspace: ws} do
      assert {:error, :unknown_kind} =
               Alerts.emit(%{
                 workspace_id: ws.id,
                 kind: :totally_made_up,
                 subject: "x"
               })

      assert Notifications.list_for_workspace(ws.id) == []
    end

    test "missing :workspace_id returns :missing_workspace",
         %{workspace: _ws} do
      assert {:error, :missing_workspace} =
               Alerts.emit(%{
                 kind: :stuck_plan,
                 subject: "x"
               })
    end

    test "missing :subject returns :missing_subject",
         %{workspace: ws} do
      assert {:error, :missing_subject} =
               Alerts.emit(%{
                 workspace_id: ws.id,
                 kind: :stuck_plan
               })
    end

    test "non-map input returns :invalid_attrs" do
      assert {:error, :invalid_attrs} = Alerts.emit("not a map")
      assert {:error, :invalid_attrs} = Alerts.emit(nil)
    end
  end

  describe "emit/1 — secret hygiene (#256)" do
    test "summary carrying a credentialed RPC URL is rejected by the notifications gate",
         %{workspace: ws} do
      # The downstream `Bank.Notifications.Notification` schema's
      # `:unsafe_text` validator (#233) catches tokenized URLs in
      # body. Alert callers that try to leak surface as
      # `{:error, %Ecto.Changeset{}}` instead of a persisted leak.
      assert {:error, %Ecto.Changeset{} = cs} =
               Alerts.emit(%{
                 workspace_id: ws.id,
                 kind: :rpc_down,
                 subject: "base-sepolia",
                 summary: "lost connection to https://user:secret@rpc.example/path"
               })

      assert Keyword.has_key?(cs.errors, :body)
      assert Notifications.list_for_workspace(ws.id) == []
    end

    test "summary carrying a Bearer token is rejected",
         %{workspace: ws} do
      assert {:error, %Ecto.Changeset{}} =
               Alerts.emit(%{
                 workspace_id: ws.id,
                 kind: :adapter_down,
                 subject: "adapter",
                 summary: "Authorization: Bearer sk_live_AAAA"
               })

      assert Notifications.list_for_workspace(ws.id) == []
    end

    test "details with safe primitive values pass through",
         %{workspace: ws} do
      assert {:ok, :emitted, n} =
               Alerts.emit(%{
                 workspace_id: ws.id,
                 kind: :callback_latency_high,
                 subject: "adapter",
                 details: %{p99_ms: 4500, threshold_ms: 1500, samples: 240}
               })

      assert n.body =~ "p99_ms=4500"
      assert n.body =~ "samples=240"
      assert n.body =~ "threshold_ms=1500"
    end

    test "long benign summary is bounded by the 240-char cap",
         %{workspace: ws} do
      huge = String.duplicate("z", 5_000)

      assert {:ok, :emitted, n} =
               Alerts.emit(%{
                 workspace_id: ws.id,
                 kind: :queue_depth_high,
                 subject: "default",
                 summary: huge
               })

      assert byte_size(n.body) <= 2_000
    end
  end

  describe "emit/1 — no chain side effects (#256)" do
    test "emitting an alert does not enqueue Oban jobs / plans / audit events",
         %{workspace: ws} do
      audit_before = Repo.aggregate(AuditEvent, :count, :id)
      plan_before = Repo.aggregate(ExecutionPlan, :count, :id)

      {:ok, :emitted, _} =
        Alerts.emit(%{
          workspace_id: ws.id,
          kind: :stuck_plan,
          subject: "plan-nosfx",
          details: %{stuck_for_seconds: 900}
        })

      # Notification row exists but no chain-adjacent side effect.
      assert length(Notifications.list_for_workspace(ws.id)) == 1
      assert Repo.aggregate(AuditEvent, :count, :id) == audit_before
      assert Repo.aggregate(ExecutionPlan, :count, :id) == plan_before

      refute_enqueued(worker: Bank.Runtime.Workers.RunExecution)
      refute_enqueued(worker: Bank.Runtime.Workers.GrantDelegation)
      refute_enqueued(worker: Bank.Runtime.Workers.RevokeDelegation)
    end
  end
end
