defmodule Bank.Ops.HealthTest do
  @moduledoc """
  Direct tests for `Bank.Ops.Health.emit_telemetry/0` and the
  surrounding telemetry-poller config introduced for issue #52.

  These tests do not rely on the `:telemetry_poller` actually firing
  — that is intentionally disabled in the `:test` env (see
  `config/test.exs`) because its background process has no
  per-process `Req.Test` stub. We exercise `emit_telemetry/0` from
  the test process where stubs are installed, and we assert that
  the poller schedule is empty.
  """

  use Bank.DataCase, async: false

  import Ecto.Query

  alias Bank.Ops.Health

  describe "BankWeb.Telemetry.periodic_measurements/0" do
    test "is empty in :test so the poller does not call emit_telemetry/0" do
      assert BankWeb.Telemetry.periodic_measurements() == []
    end

    test "default (when no config) still includes the health emit MFA" do
      original = Application.get_env(:bank, BankWeb.Telemetry)

      try do
        Application.delete_env(:bank, BankWeb.Telemetry)

        assert BankWeb.Telemetry.periodic_measurements() == [
                 {Bank.Ops.Health, :emit_telemetry, []}
               ]
      after
        if original do
          Application.put_env(:bank, BankWeb.Telemetry, original)
        end
      end
    end
  end

  describe "emit_telemetry/0 (direct invocation in the test process)" do
    test "emits a [:bank, :ops, :health] event with adapter_up=1 when the stub is healthy" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.json(conn, %{status: "ok"})
      end)

      ref = attach_handler()

      assert Health.emit_telemetry() == :ok

      assert_receive {:health_event, measurements, %{}}, 500
      assert measurements.adapter_up == 1
      assert measurements.database_up == 1
      assert is_integer(measurements.stuck_plans)

      detach_handler(ref)
    end

    test "emits adapter_up=0 when the adapter transport fails" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      ref = attach_handler()

      assert Health.emit_telemetry() == :ok

      assert_receive {:health_event, measurements, %{}}, 500
      assert measurements.adapter_up == 0
      assert measurements.database_up == 1

      detach_handler(ref)
    end
  end

  defp attach_handler do
    ref = make_ref()
    parent = self()

    :telemetry.attach(
      {__MODULE__, ref},
      [:bank, :ops, :health],
      fn _event, measurements, metadata, _ ->
        send(parent, {:health_event, measurements, metadata})
      end,
      nil
    )

    ref
  end

  defp detach_handler(ref) do
    :telemetry.detach({__MODULE__, ref})
  end

  # --- #253: dependency status enum + redaction ----------------------------

  describe "database/0 (#253)" do
    test "returns :ok with nil detail when Postgres is reachable" do
      assert %{status: :ok, detail: nil} = Health.database()
    end
  end

  describe "adapter/0 (#253)" do
    test "returns :ok with http_2xx detail when the adapter answers" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.json(conn, %{status: "ok"})
      end)

      assert %{status: :ok, detail: "http_2xx"} = Health.adapter()
    end

    test "returns :ok with http_4xx detail when adapter has no /healthz" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        conn
        |> Plug.Conn.put_status(404)
        |> Req.Test.json(%{error: "not_found"})
      end)

      assert %{status: :ok, detail: "http_4xx"} = Health.adapter()
    end

    test "returns :degraded with http_5xx detail when adapter returns 5xx" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{error: "down"})
      end)

      assert %{status: :degraded, detail: "http_5xx"} = Health.adapter()
    end

    test "returns :down with transport_error detail on connection failure" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert %{status: :down, detail: "transport_error"} = Health.adapter()
    end

    test "returns :not_configured when base_url is unset (local/dev)" do
      original = Application.get_env(:bank, Bank.AdapterClient)

      try do
        Application.put_env(
          :bank,
          Bank.AdapterClient,
          Keyword.delete(original || [], :base_url)
        )

        assert %{status: :not_configured, detail: "adapter_base_url_not_configured"} =
                 Health.adapter()
      after
        if original do
          Application.put_env(:bank, Bank.AdapterClient, original)
        else
          Application.delete_env(:bank, Bank.AdapterClient)
        end
      end
    end

    test "redacts: detail never carries raw transport-error text or RPC URL" do
      # base_url contains a fake credential to prove redaction; the
      # detail field must be the fixed enum string only.
      original = Application.get_env(:bank, Bank.AdapterClient, [])

      try do
        secret_url = "https://user:supersecret@adapter.example.invalid"

        Application.put_env(
          :bank,
          Bank.AdapterClient,
          original
          |> Keyword.put(:base_url, secret_url)
          |> Keyword.put(:req_options, [])
        )

        # Adapter is unreachable in this test config (no Req.Test stub
        # for the per-process owner pid in the real network path);
        # the underlying call may raise/return :down. Either way the
        # detail must be one of the fixed enum strings — not the URL.
        result = Health.adapter()

        assert result.status in [:down, :unknown, :degraded]
        assert is_binary(result.detail)

        refute String.contains?(result.detail, "supersecret"),
               "detail leaked secret credential from RPC URL"

        refute String.contains?(result.detail, "adapter.example.invalid"),
               "detail leaked RPC host"

        refute String.contains?(result.detail, "Req.TransportError"),
               "detail leaked internal struct module name"

        assert result.detail in [
                 "transport_error",
                 "adapter_check_raised",
                 "adapter_check_exit",
                 "http_5xx"
               ]
      after
        Application.put_env(:bank, Bank.AdapterClient, original)
      end
    end
  end

  describe "snapshot/0 overall status (#253)" do
    test "rolls up to :ok when adapter is healthy and DB is healthy" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.json(conn, %{status: "ok"})
      end)

      assert %{status: :ok, checks: checks} = Health.snapshot()
      assert checks.database.status == :ok
      assert checks.adapter.status == :ok
      assert checks.stuck_plans.status == :ok
    end

    test "rolls up to :ok when adapter is :not_configured (local/dev unconfigured)" do
      original = Application.get_env(:bank, Bank.AdapterClient)

      try do
        Application.put_env(
          :bank,
          Bank.AdapterClient,
          Keyword.delete(original || [], :base_url)
        )

        # Local/dev without chain env: must not falsely fail.
        assert %{status: :ok, checks: checks} = Health.snapshot()
        assert checks.adapter.status == :not_configured
      after
        if original do
          Application.put_env(:bank, Bank.AdapterClient, original)
        else
          Application.delete_env(:bank, Bank.AdapterClient)
        end
      end
    end

    test "rolls up to :degraded when adapter is :down" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert %{status: :degraded, checks: checks} = Health.snapshot()
      assert checks.adapter.status == :down
    end

    test "rolls up to :degraded when adapter is :degraded (5xx)" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        conn
        |> Plug.Conn.put_status(502)
        |> Req.Test.json(%{error: "bad_gateway"})
      end)

      assert %{status: :degraded, checks: checks} = Health.snapshot()
      assert checks.adapter.status == :degraded
    end
  end

  # --- Stuck-plan detection (#230-b) --------------------------------------

  describe "stuck_plan_details/1" do
    alias Bank.Decisions.ExecutionPlan
    alias Bank.Repo

    test "returns plans whose per-status threshold elapsed; status-specific cutoffs apply" do
      now = DateTime.utc_now()
      seven_min_ago = DateTime.add(now, -7 * 60, :second)
      twenty_min_ago = DateTime.add(now, -20 * 60, :second)

      # :prepared with 20 min staleness — past 10-min default → IN.
      stale_prepared = stale_plan(:prepared, twenty_min_ago)
      # :signing with 7 min staleness — past 5-min default → IN.
      stale_signing = stale_plan(:signing, seven_min_ago)
      # :pending_confirmation with 7 min staleness — UNDER 30-min default → OUT.
      _fresh_pending = stale_plan(:pending_confirmation, seven_min_ago)
      # Terminal :confirmed regardless of age → OUT.
      _terminal = stale_plan(:confirmed, twenty_min_ago, final_outcome: :confirmed)

      details = Health.stuck_plan_details(now: now)
      ids = Enum.map(details, & &1.id)

      assert stale_prepared.id in ids
      assert stale_signing.id in ids
      assert length(details) == 2
    end

    test "respects an explicit `:thresholds` override" do
      now = DateTime.utc_now()
      one_min_ago = DateTime.add(now, -60, :second)

      _fresh = stale_plan(:prepared, one_min_ago)

      # With the default 10-min threshold the row is fresh; with a
      # 30-second override it's stuck.
      assert Health.stuck_plan_details(now: now) == []

      details =
        Health.stuck_plan_details(
          now: now,
          thresholds: [prepared: 30, signing: 30, broadcasting: 30, pending_confirmation: 30]
        )

      assert length(details) == 1
      assert hd(details).execution_status == :prepared
    end

    test "ignores plans with `active: false` (manual-abort #302 carryover)" do
      now = DateTime.utc_now()
      twenty_min_ago = DateTime.add(now, -20 * 60, :second)

      plan = stale_plan(:aborted, twenty_min_ago, final_outcome: :aborted, active: false)

      # Sanity: the plan exists but is filtered out by both the
      # status guard AND the `active: false` clause.
      assert Repo.exists?(from p in ExecutionPlan, where: p.id == ^plan.id)
      assert Health.stuck_plan_details(now: now) == []
    end

    test "caps result at `:limit`" do
      now = DateTime.utc_now()
      twenty_min_ago = DateTime.add(now, -20 * 60, :second)

      for _ <- 1..7, do: stale_plan(:prepared, twenty_min_ago)

      assert length(Health.stuck_plan_details(now: now, limit: 3)) == 3
    end

    test "with `:workspace_id` filter, sibling-tenant rows do NOT consume the limit budget (#305 review fix)" do
      # Pre-fix the DB query had no `workspace_id` predicate, so the
      # caller's post-fetch `Enum.filter` could only see rows that
      # survived the per-status `LIMIT` — a 12-row pile from
      # another workspace silently hid the current workspace's stuck
      # row. Pin the corrected behavior: the workspace filter is
      # applied INSIDE the DB query, before the limit.
      now = DateTime.utc_now()
      twenty_min_ago = DateTime.add(now, -20 * 60, :second)
      twenty_one_min_ago = DateTime.add(now, -21 * 60, :second)

      {:ok, sibling_ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "sibling-starve-#{System.unique_integer([:positive])}",
          name: "Sibling",
          mainnet_enabled: true
        })

      {:ok, current_ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "current-#{System.unique_integer([:positive])}",
          name: "Current",
          mainnet_enabled: true
        })

      # 12 OLDER sibling-workspace rows that pre-fix would have
      # filled the limit budget and starved the current workspace.
      for _ <- 1..12 do
        stale_plan(:prepared, twenty_one_min_ago, workspace_id: sibling_ws.id)
      end

      current_plan = stale_plan(:prepared, twenty_min_ago, workspace_id: current_ws.id)

      details =
        Health.stuck_plan_details(
          now: now,
          limit: 10,
          workspace_id: current_ws.id
        )

      ids = Enum.map(details, & &1.id)
      assert current_plan.id in ids
      assert Enum.all?(details, &(&1.workspace_id == current_ws.id))
    end

    test "without `:workspace_id`, the cluster-wide scan still returns sibling rows (no regression)" do
      now = DateTime.utc_now()
      twenty_min_ago = DateTime.add(now, -20 * 60, :second)

      {:ok, sibling_ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "sibling-#{System.unique_integer([:positive])}",
          name: "Sibling",
          mainnet_enabled: true
        })

      sibling = stale_plan(:prepared, twenty_min_ago, workspace_id: sibling_ws.id)

      details = Health.stuck_plan_details(now: now)

      ids = Enum.map(details, & &1.id)
      assert sibling.id in ids
    end

    test "selects oldest stuck rows deterministically when more than :limit match (#230 P2 Finding B)" do
      # Pre-fix the per-status query had no `order_by`, so `LIMIT N`
      # returned an arbitrary slice and a younger row could be
      # selected over an older one. Pin the corrected behavior:
      # `:limit` MUST keep the oldest rows.
      now = DateTime.utc_now()

      ages_seconds = [3600, 1500, 1200, 900, 800, 700, 605]

      plans =
        Enum.map(ages_seconds, fn age ->
          stale_plan(:prepared, DateTime.add(now, -age, :second))
        end)

      details = Health.stuck_plan_details(now: now, limit: 3)

      assert length(details) == 3

      ids = Enum.map(details, & &1.id)
      # The three oldest ages [3600, 1500, 1200] correspond to the
      # first three plans inserted.
      expected_oldest = plans |> Enum.take(3) |> Enum.map(& &1.id)

      assert MapSet.new(ids) == MapSet.new(expected_oldest)

      # Returned in oldest-first order across the merged list.
      assert details |> Enum.map(& &1.stuck_for_seconds) ==
               details |> Enum.map(& &1.stuck_for_seconds) |> Enum.sort(:desc)
    end
  end

  describe "detection_window_start/1 + stuck_plan_event_exists?/2" do
    test "detection_window_start aligns to a 5-minute bucket" do
      # Two timestamps inside the same 5-minute bucket should round
      # to the same window-start.
      base = DateTime.from_naive!(~N[2026-05-01 12:34:56], "Etc/UTC")
      a = DateTime.add(base, 30, :second)
      b = DateTime.add(base, 240, :second)

      assert Health.detection_window_start(a) == Health.detection_window_start(b)
    end

    test "stuck_plan_event_exists?/2 flips after an audit row lands" do
      plan_id = Ecto.UUID.generate()
      window_iso = DateTime.utc_now() |> Health.detection_window_start() |> DateTime.to_iso8601()

      refute Health.stuck_plan_event_exists?(plan_id, window_iso)

      attrs =
        Bank.Audit.Events.ops_stuck_plan_detected(
          %{
            id: plan_id,
            workspace_id: nil,
            execution_status: :prepared,
            updated_at: DateTime.utc_now(),
            stuck_for_seconds: 700,
            threshold_seconds: 600
          },
          window_start: DateTime.utc_now() |> Health.detection_window_start()
        )

      assert {:ok, _} = Bank.Audit.append_event(attrs)
      assert Health.stuck_plan_event_exists?(plan_id, window_iso)
    end
  end

  # Insert an `ExecutionPlan` whose `updated_at` is overwritten via a
  # raw SQL update so the stale-clock case is reproducible without
  # Ecto's automatic timestamps. Defaults are workspace-stamped via
  # `Bank.Fixtures` so cross-workspace tests can still distinguish.
  defp stale_plan(status, updated_at, extra \\ []) do
    plan_attrs =
      [execution_status: status]
      |> Keyword.merge(extra)

    plan = Bank.Fixtures.execution_plan(plan_attrs)

    {1, _} =
      Bank.Repo.update_all(
        from(p in Bank.Decisions.ExecutionPlan, where: p.id == ^plan.id),
        set: [updated_at: updated_at]
      )

    %{plan | updated_at: updated_at}
  end
end
