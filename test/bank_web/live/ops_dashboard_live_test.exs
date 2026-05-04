defmodule BankWeb.OpsDashboardLiveTest do
  @moduledoc """
  LiveView tests for the production operations dashboard (#254).
  """

  use BankWeb.ConnCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Phoenix.LiveViewTest
  import Ecto.Query

  alias Bank.Audit
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Repo
  alias Bank.Stablecoins.ProviderHealth
  alias Oban.Job

  # The default ConnCase setup logs the user in as admin which
  # satisfies the `:operator` minimum on `/ops`.
  setup :register_and_log_in_user_as_admin

  setup do
    ProviderHealth.reset()
    on_exit(fn -> ProviderHealth.reset() end)
    :ok
  end

  describe "mount gating" do
    test "anonymous request redirects to /login" do
      conn = build_conn()
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/ops")
    end

    test "viewer-tier user is redirected to /unauthorized" do
      {:ok, conn: viewer_conn, current_user: _viewer, workspace: _ws} =
        register_and_log_in_user_with_role(%{conn: build_conn()}, :viewer)

      assert {:error, {:redirect, %{to: "/unauthorized"}}} = live(viewer_conn, "/ops")
    end

    test "operator can mount the dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/ops")

      assert html =~ ~s(id="ops-dashboard")
      assert html =~ "Operations"
    end
  end

  describe "section rendering" do
    test "renders every required section with its stable id", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/ops")

      assert html =~ ~s(id="ops-dashboard")
      assert html =~ ~s(id="ops-health-adapter")
      assert html =~ ~s(id="ops-health-rpc")
      assert html =~ ~s(id="ops-health-quotes")
      assert html =~ ~s(id="ops-queue-depth")
      assert html =~ ~s(id="ops-failed-jobs")
      assert html =~ ~s(id="ops-retrying-jobs")
      assert html =~ ~s(id="ops-stuck-plans")
      assert html =~ ~s(id="ops-callback-failures")
      assert html =~ ~s(id="ops-incidents")
    end

    test "discarded job fixture is visible in the failed-jobs section", %{conn: conn} do
      job = oban_job_fixture("discarded", "executions_run", "Bank.Runtime.Workers.RunExecution")

      {:ok, _view, html} = live(conn, "/ops")

      assert html =~ ~s(data-job-id="#{job.id}")
      assert html =~ "Bank.Runtime.Workers.RunExecution"
      assert html =~ ~s(data-state="discarded")
    end

    test "retryable job fixture is visible in the retrying-jobs section", %{conn: conn} do
      job = oban_job_fixture("retryable", "callbacks", "Bank.Runtime.Workers.HandleCallback")

      {:ok, _view, html} = live(conn, "/ops")

      assert html =~ ~s(data-job-id="#{job.id}")
      assert html =~ "Bank.Runtime.Workers.HandleCallback"
      assert html =~ ~s(data-state="retryable")
    end

    test "stuck execution plan is visible with a safe queue link", %{conn: conn, workspace: ws} do
      now = DateTime.utc_now()

      plan = Bank.Fixtures.execution_plan(workspace_id: ws.id, execution_status: :prepared)

      {1, _} =
        Repo.update_all(
          from(p in ExecutionPlan, where: p.id == ^plan.id),
          set: [updated_at: DateTime.add(now, -2 * 3600, :second)]
        )

      {:ok, _view, html} = live(conn, "/ops")

      assert html =~ ~s(data-plan-id="#{plan.id}")
      assert html =~ ~s(/queue?plan=#{plan.id})
      assert html =~ ~s(data-status="prepared")
    end

    test "queue depth row shows non-terminal job counts per queue", %{conn: conn} do
      _ = oban_job_fixture("available", "ops_scan", "Bank.Runtime.Workers.ScanStuckPlans")
      _ = oban_job_fixture("scheduled", "ops_scan", "Bank.Runtime.Workers.ScanStuckPlans")

      {:ok, _view, html} = live(conn, "/ops")

      assert html =~ ~s(data-queue="ops_scan")
    end

    test "active scope pause is visible in the incidents section",
         %{conn: conn, workspace: ws} do
      {:ok, :paused, _pause} =
        Bank.Security.Pauses.create_pause(ws.id, :chain, "base-sepolia",
          actor: :runtime,
          reason: "incident-drill"
        )

      {:ok, _view, html} = live(conn, "/ops")

      assert html =~ "chain:base-sepolia"
    end

    test "recent security incident audit row appears with a security link",
         %{conn: conn, workspace: ws} do
      attrs = %{
        workspace_id: ws.id,
        ts: DateTime.utc_now(),
        actor: :user,
        actor_id: "ops-test-user",
        event_type: "security.paused",
        subject_type: "workspace",
        subject_id: ws.id,
        payload_hash: String.duplicate("a", 64),
        before_ref: %{},
        after_ref: %{}
      }

      {:ok, event} = Audit.append_event(attrs)

      {:ok, _view, html} = live(conn, "/ops")

      assert html =~ ~s(data-event-id="#{event.id}")
      assert html =~ "security.paused"
      assert html =~ ~s(href="/security")
    end
  end

  describe "secret hygiene" do
    test "quote provider failure_reason carrying secret-looking text is NOT rendered",
         %{conn: conn} do
      ProviderHealth.record_failure(
        "leaky_provider",
        "Authorization: Bearer sk_live_AAAA exposed in https://user:pass@rpc.example/path"
      )

      {:ok, _view, html} = live(conn, "/ops")

      # The provider id is rendered.
      assert html =~ "leaky_provider"

      # But none of the secret-looking failure_reason content
      # leaks into the page.
      for needle <- [
            "Authorization",
            "Bearer",
            "sk_live_",
            "https://user:pass@",
            "rpc.example"
          ] do
        refute html =~ needle,
               "secret-looking provider failure marker leaked: #{inspect(needle)}"
      end
    end

    test "discarded job's args / errors / meta are NOT rendered", %{conn: conn} do
      _ =
        oban_job_fixture(
          "discarded",
          "executions_run",
          "Bank.Runtime.Workers.RunExecution",
          args: %{
            "intent_id" => "leaked-intent-id-xyz",
            "rpc_url" => "https://user:tkn@rpc.example"
          },
          errors: [
            %{
              "at" => DateTime.utc_now() |> DateTime.to_iso8601(),
              "attempt" => 1,
              "error" =>
                "raw 500 from https://user:tkn@rpc.example/v1: Authorization: Bearer sk_live_BBB"
            }
          ],
          meta: %{"trace" => "Bearer sk_live_internal"}
        )

      {:ok, _view, html} = live(conn, "/ops")

      for needle <- [
            "leaked-intent-id-xyz",
            "https://user:tkn@",
            "rpc.example",
            "Authorization",
            "Bearer",
            "sk_live_"
          ] do
        refute html =~ needle,
               "ops dashboard leaked sanitized field: #{inspect(needle)}"
      end
    end
  end

  describe "no chain / dispatch side effects" do
    test "mounting the dashboard enqueues no Oban dispatch jobs", %{conn: conn} do
      {:ok, _view, _html} = live(conn, "/ops")

      refute_enqueued(worker: Bank.Runtime.Workers.RunExecution)
      refute_enqueued(worker: Bank.Runtime.Workers.GrantDelegation)
      refute_enqueued(worker: Bank.Runtime.Workers.RevokeDelegation)
    end
  end

  describe "refresh" do
    test "phx-click refresh re-renders without crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/ops")

      view |> element("#ops-refresh") |> render_click()

      assert has_element?(view, "#ops-dashboard")
    end
  end

  # --- helpers ---------------------------------------------------------

  defp oban_job_fixture(state, queue, worker, opts \\ []) do
    args = Keyword.get(opts, :args, %{})

    job = Oban.insert!(Job.new(args, queue: queue, worker: worker, max_attempts: 5))

    set =
      [
        state: state,
        attempt: 3,
        attempted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      ]
      |> maybe_put_meta(opts)

    {1, _} =
      Repo.update_all(
        from(j in Job, where: j.id == ^job.id),
        set: set
      )

    %{job | state: state}
  end

  defp maybe_put_meta(set, opts) do
    case Keyword.get(opts, :meta) do
      m when is_map(m) -> Keyword.put(set, :meta, m)
      _ -> set
    end
  end
end
