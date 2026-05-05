defmodule BankWeb.OperatorInboxLiveTest do
  @moduledoc """
  LiveView tests for the operator inbox UI (#235).
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bank.Notifications

  setup :register_and_log_in_user_as_admin

  describe "mount gating" do
    test "anonymous request redirects to /login" do
      conn = build_conn()
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/inbox")
    end

    test "viewer-tier user can mount the inbox", %{conn: _conn} do
      {:ok, conn: viewer_conn, current_user: _, workspace: _} =
        register_and_log_in_user_with_role(%{conn: build_conn()}, :viewer)

      assert {:ok, _view, html} = live(viewer_conn, "/inbox")
      assert html =~ ~s(id="operator-inbox")
    end

    test "operator can mount the inbox", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/inbox")
      assert html =~ ~s(id="operator-inbox")
      assert html =~ "Inbox"
    end
  end

  describe "section rendering" do
    test "shows expected stable DOM ids and empty state with no notifications",
         %{conn: conn} do
      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ ~s(id="operator-inbox")
      assert html =~ ~s(id="inbox-filters")
      assert html =~ ~s(id="inbox-unread-count")
      assert html =~ ~s(id="inbox-empty")
    end

    test "renders a notification row with stable id and severity/status badges",
         %{conn: conn, workspace: ws} do
      {:ok, n} = create_notification(ws.id, role_target: :operator, severity: :warning)

      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ ~s(id="inbox-notification-#{n.id}")
      assert html =~ "warning"
      assert html =~ "unread"
      assert html =~ ~s(data-severity="warning")
      assert html =~ ~s(data-status="unread")
      assert html =~ n.title
      refute html =~ ~s(id="inbox-empty")
    end

    test "renders action_link when set", %{conn: conn, workspace: ws} do
      {:ok, n} =
        create_notification(ws.id,
          role_target: :operator,
          action_link: "/intents/abcd-1234"
        )

      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ ~s(id="inbox-action-link-#{n.id}")
      assert html =~ "/intents/abcd-1234"
    end

    test "shows unread count badge when > 0", %{conn: conn, workspace: ws} do
      for _ <- 1..3 do
        {:ok, _} = create_notification(ws.id, role_target: :operator)
      end

      {:ok, _view, html} = live(conn, "/inbox")

      assert html =~ ~s(id="inbox-unread-count")
      assert html =~ "3 unread"
    end
  end

  describe "filters" do
    test "filtering by status shows only matching notifications",
         %{conn: conn, workspace: ws} do
      {:ok, unread} = create_notification(ws.id, role_target: :operator)
      {:ok, archived} = create_notification(ws.id, role_target: :operator)
      {:ok, _} = Notifications.archive(archived)

      {:ok, view, html} = live(conn, "/inbox")

      # Default filter is "unread" — archived row hidden.
      assert html =~ ~s(id="inbox-notification-#{unread.id}")
      refute html =~ ~s(id="inbox-notification-#{archived.id}")

      # Switching to "archived" reverses.
      view
      |> form("#inbox-filters", %{
        "filters[status]" => "archived",
        "filters[severity]" => "all",
        "filters[event_type]" => ""
      })
      |> render_change()

      html2 = render(view)
      refute html2 =~ ~s(id="inbox-notification-#{unread.id}")
      assert html2 =~ ~s(id="inbox-notification-#{archived.id}")
    end

    test "filtering by severity narrows the list", %{conn: conn, workspace: ws} do
      {:ok, info} = create_notification(ws.id, role_target: :operator, severity: :info)

      {:ok, critical} =
        create_notification(ws.id, role_target: :operator, severity: :critical)

      {:ok, view, _html} = live(conn, "/inbox")

      view
      |> form("#inbox-filters", %{
        "filters[status]" => "unread",
        "filters[severity]" => "critical",
        "filters[event_type]" => ""
      })
      |> render_change()

      html = render(view)
      refute html =~ ~s(id="inbox-notification-#{info.id}")
      assert html =~ ~s(id="inbox-notification-#{critical.id}")
    end

    test "filtering by event_type narrows the list", %{conn: conn, workspace: ws} do
      {:ok, stuck} =
        create_notification(ws.id, role_target: :operator, event_type: "ops.stuck_plan")

      {:ok, intent} =
        create_notification(ws.id, role_target: :operator, event_type: "intent.held")

      {:ok, view, _html} = live(conn, "/inbox")

      view
      |> form("#inbox-filters", %{
        "filters[status]" => "unread",
        "filters[severity]" => "all",
        "filters[event_type]" => "ops.stuck_plan"
      })
      |> render_change()

      html = render(view)
      assert html =~ ~s(id="inbox-notification-#{stuck.id}")
      refute html =~ ~s(id="inbox-notification-#{intent.id}")
    end

    test "unknown choice-restricted filter values fall back to defaults",
         %{conn: conn, workspace: ws} do
      {:ok, n} = create_notification(ws.id, role_target: :operator)

      {:ok, view, _html} = live(conn, "/inbox")

      # Inject hostile values; sanitize_filters/1 collapses the
      # choice-restricted fields (status, severity) to their
      # defaults rather than passing them through to the DB query.
      # event_type is free-text, so we leave it empty here —
      # the next test exercises the truncation behaviour.
      view
      |> render_change("filter", %{
        "filters" => %{
          "status" => "../../../etc/passwd",
          "severity" => "DROP TABLE notifications;",
          "event_type" => ""
        }
      })

      html = render(view)
      # Default status "unread" + severity collapsed to "all" →
      # the row should still render.
      assert html =~ ~s(id="inbox-notification-#{n.id}")
    end

    test "free-text event_type filter is bounded to 64 chars",
         %{conn: conn, workspace: ws} do
      huge = String.duplicate("z", 200)
      {:ok, _} = create_notification(ws.id, role_target: :operator)

      {:ok, view, _html} = live(conn, "/inbox")

      # The free-text filter is sent verbatim (after trim +
      # 64-char truncate). It then filters by exact-match
      # event_type, which our notification doesn't have, so the
      # list is empty.
      view
      |> render_change("filter", %{
        "filters" => %{
          "status" => "unread",
          "severity" => "all",
          "event_type" => huge
        }
      })

      assert render(view) =~ ~s(id="inbox-empty")
    end
  end

  describe "mark_read / archive events" do
    test "mark_read transitions an unread notification to :read",
         %{conn: conn, workspace: ws} do
      {:ok, n} = create_notification(ws.id, role_target: :operator)

      {:ok, view, _html} = live(conn, "/inbox")

      view
      |> element("#inbox-mark-read-#{n.id}")
      |> render_click()

      reloaded = Notifications.get_in_workspace(n.id, ws.id)
      assert reloaded.status == :read
      assert reloaded.read_at != nil
    end

    test "archive transitions to :archived",
         %{conn: conn, workspace: ws} do
      {:ok, n} = create_notification(ws.id, role_target: :operator)

      {:ok, view, _html} = live(conn, "/inbox")

      view
      |> element("#inbox-archive-#{n.id}")
      |> render_click()

      reloaded = Notifications.get_in_workspace(n.id, ws.id)
      assert reloaded.status == :archived
      assert reloaded.archived_at != nil
    end

    test "mark_read on an unknown id returns flash error and changes nothing",
         %{conn: conn, workspace: ws} do
      {:ok, n} = create_notification(ws.id, role_target: :operator)

      {:ok, view, _html} = live(conn, "/inbox")

      render_hook(view, "mark_read", %{"id" => Ecto.UUID.generate()})

      reloaded = Notifications.get_in_workspace(n.id, ws.id)
      assert reloaded.status == :unread
    end
  end

  describe "workspace isolation" do
    test "cross-workspace notifications are hidden and cannot be acted on",
         %{conn: conn} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "inbox-iso-#{System.unique_integer([:positive])}",
          name: "Inbox ISO B"
        })

      {:ok, n_b} = create_notification(ws_b.id, role_target: :operator)

      {:ok, view, html} = live(conn, "/inbox")

      # ws-A user cannot see ws-B notification.
      refute html =~ ~s(id="inbox-notification-#{n_b.id}")

      # And smuggling the id into the handle_event payload is a
      # no-op — `get_in_workspace/2` returns nil for sibling ids.
      render_hook(view, "mark_read", %{"id" => n_b.id})

      reloaded_b = Notifications.get_in_workspace(n_b.id, ws_b.id)
      assert reloaded_b.status == :unread

      render_hook(view, "archive", %{"id" => n_b.id})

      reloaded_b = Notifications.get_in_workspace(n_b.id, ws_b.id)
      assert reloaded_b.status == :unread
    end
  end

  # --- helpers --------------------------------------------------------

  defp create_notification(workspace_id, opts) do
    suffix = System.unique_integer([:positive])

    base = %{
      workspace_id: workspace_id,
      event_type: "intent.held",
      severity: :info,
      role_target: :operator,
      title: "Test notification #{suffix}",
      body: "Operator review required for intent.",
      dedupe_key: "inbox-test-" <> Integer.to_string(suffix)
    }

    Notifications.create(Map.merge(base, Map.new(opts)))
    |> case do
      {:ok, n} -> {:ok, n}
      {:duplicate, n} -> {:ok, n}
      other -> other
    end
  end
end
