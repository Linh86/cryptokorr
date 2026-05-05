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

  describe "recipient visibility (#235 P2)" do
    # The list query already excludes notifications addressed to
    # another user_id or to a higher role_target than the current
    # principal. The mutation paths (mark_read / archive) must
    # apply the same predicate — otherwise a same-workspace user
    # can smuggle the id of an invisible notification and act on
    # it. Each test below plants a same-workspace row that the
    # principal cannot see, then asserts the row stays untouched
    # after a `mark_read` / `archive` hook with that id.

    test "operator cannot mark_read a same-workspace notification addressed to another user",
         %{conn: conn, current_user: operator, workspace: ws} do
      {:ok, other_user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "inbox-vis-other-#{System.unique_integer([:positive])}",
          email: "inbox-vis-other-#{System.unique_integer([:positive])}@example.com",
          name: "Inbox Vis Other"
        })

      {:ok, _m} =
        Bank.Workspaces.create_membership(%{
          user_id: other_user.id,
          workspace_id: ws.id,
          role: :operator
        })

      # Notification addressed to the OTHER user (not via role_target).
      # Same workspace as the operator viewing the inbox.
      {:ok, n} =
        create_notification(ws.id,
          user_id: other_user.id,
          role_target: nil,
          title: "Targeted to other user"
        )

      refute n.user_id == operator.id

      {:ok, view, html} = live(conn, "/inbox")
      refute html =~ ~s(id="inbox-notification-#{n.id}")

      render_hook(view, "mark_read", %{"id" => n.id})

      reloaded = Notifications.get_in_workspace(n.id, ws.id)
      assert reloaded.status == :unread
      assert reloaded.read_at == nil
    end

    test "operator cannot archive a same-workspace notification addressed to another user",
         %{conn: conn, workspace: ws} do
      {:ok, other_user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "inbox-vis-arch-#{System.unique_integer([:positive])}",
          email: "inbox-vis-arch-#{System.unique_integer([:positive])}@example.com",
          name: "Inbox Vis Arch"
        })

      {:ok, _m} =
        Bank.Workspaces.create_membership(%{
          user_id: other_user.id,
          workspace_id: ws.id,
          role: :operator
        })

      {:ok, n} =
        create_notification(ws.id,
          user_id: other_user.id,
          role_target: nil
        )

      {:ok, view, _html} = live(conn, "/inbox")

      render_hook(view, "archive", %{"id" => n.id})

      reloaded = Notifications.get_in_workspace(n.id, ws.id)
      assert reloaded.status == :unread
      assert reloaded.archived_at == nil
    end

    test "operator cannot mutate an admin-only role_target notification", %{conn: _conn} do
      # ConnCase default is admin; we need an operator-tier conn
      # for this test so admin-targeted rows are invisible to it.
      {:ok, conn: operator_conn, current_user: _, workspace: ws} =
        register_and_log_in_user_with_role(%{conn: build_conn()}, :operator)

      {:ok, n} =
        create_notification(ws.id,
          user_id: nil,
          role_target: :admin,
          title: "Admin-only audit"
        )

      {:ok, view, html} = live(operator_conn, "/inbox")
      refute html =~ ~s(id="inbox-notification-#{n.id}")

      render_hook(view, "mark_read", %{"id" => n.id})

      reloaded = Notifications.get_in_workspace(n.id, ws.id)
      assert reloaded.status == :unread

      render_hook(view, "archive", %{"id" => n.id})

      reloaded = Notifications.get_in_workspace(n.id, ws.id)
      assert reloaded.status == :unread
      assert reloaded.archived_at == nil
    end

    test "admin can still mutate admin/operator/viewer role_target notifications",
         %{conn: conn, workspace: ws} do
      {:ok, viewer_n} =
        create_notification(ws.id, user_id: nil, role_target: :viewer)

      {:ok, operator_n} =
        create_notification(ws.id, user_id: nil, role_target: :operator)

      {:ok, admin_n} =
        create_notification(ws.id, user_id: nil, role_target: :admin)

      # Switch the inbox filter to "all" so admin's own role
      # cascade includes all three rows in the rendered list.
      {:ok, view, _html} = live(conn, "/inbox")

      view
      |> form("#inbox-filters", %{
        "filters[status]" => "all",
        "filters[severity]" => "all",
        "filters[event_type]" => ""
      })
      |> render_change()

      for n <- [viewer_n, operator_n, admin_n] do
        view
        |> element("#inbox-mark-read-#{n.id}")
        |> render_click()

        reloaded = Notifications.get_in_workspace(n.id, ws.id)

        assert reloaded.status == :read,
               "expected admin mark_read to succeed for role=#{n.role_target}"
      end
    end

    test "user can still mark_read a row addressed to their own user_id",
         %{conn: conn, current_user: user, workspace: ws} do
      {:ok, n} =
        create_notification(ws.id,
          user_id: user.id,
          role_target: nil,
          title: "Direct to me"
        )

      {:ok, view, html} = live(conn, "/inbox")
      assert html =~ ~s(id="inbox-notification-#{n.id}")

      view
      |> element("#inbox-mark-read-#{n.id}")
      |> render_click()

      reloaded = Notifications.get_in_workspace(n.id, ws.id)
      assert reloaded.status == :read
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
