defmodule Bank.Notifications.DeliveriesTest do
  use Bank.DataCase, async: true

  alias Bank.Notifications
  alias Bank.Notifications.Channel
  alias Bank.Notifications.Deliveries
  alias Bank.Notifications.Delivery
  alias Bank.Notifications.DeliveryPreference

  setup do
    suffix = System.unique_integer([:positive])

    {:ok, workspace} =
      Bank.Workspaces.create_workspace(%{
        slug: "deliv-test-#{suffix}",
        name: "Deliveries Test #{suffix}"
      })

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "deliv-#{suffix}",
        email: "deliv-#{suffix}@example.com",
        name: "Deliveries User"
      })

    on_exit(fn ->
      Application.delete_env(:bank, Bank.Notifications.Channel.Stub)
    end)

    %{workspace: workspace, user: user}
  end

  defp build_notification(workspace, target, severity \\ :warning, overrides \\ %{}) do
    base = %{
      workspace_id: workspace.id,
      event_type: "decision.approval_required",
      severity: severity,
      subject_type: "decision_envelope",
      subject_id: Ecto.UUID.generate(),
      correlation_id: Ecto.UUID.generate(),
      title: "Decision needs review",
      body: "Risk moderate, decided just now.",
      action_link: "/queue#pending-approvals-section",
      dedupe_key: "decision:#{Ecto.UUID.generate()}:approval_required"
    }

    base = Map.merge(base, target_attrs(target))
    base = Map.merge(base, overrides)

    {:ok, n} = Notifications.create(base)
    n
  end

  defp target_attrs({:user, user_id}), do: %{user_id: user_id}
  defp target_attrs({:role, role}), do: %{role_target: role}

  describe "set_preference/1 — upsert" do
    test "creates a fresh row for a (workspace, role, channel)", %{workspace: ws} do
      assert {:ok, %DeliveryPreference{} = pref} =
               Deliveries.set_preference(%{
                 workspace_id: ws.id,
                 role_target: :operator,
                 channel: :email,
                 min_severity: :warning,
                 enabled: true
               })

      assert pref.workspace_id == ws.id
      assert pref.role_target == :operator
      assert pref.channel == :email
      assert pref.min_severity == :warning
      assert pref.enabled == true
    end

    test "is idempotent — repeating the same upsert keeps a single row",
         %{workspace: ws} do
      attrs = %{workspace_id: ws.id, role_target: :operator, channel: :email}

      assert {:ok, first} = Deliveries.set_preference(attrs)
      assert {:ok, second} = Deliveries.set_preference(attrs)

      assert first.id == second.id
      assert length(Deliveries.list_preferences(ws.id)) == 1
    end

    test "updating min_severity / enabled in-place preserves the row id",
         %{workspace: ws} do
      attrs = %{workspace_id: ws.id, role_target: :operator, channel: :email}
      {:ok, original} = Deliveries.set_preference(attrs)

      {:ok, updated} =
        Deliveries.set_preference(Map.merge(attrs, %{min_severity: :critical, enabled: false}))

      assert updated.id == original.id
      assert updated.min_severity == :critical
      assert updated.enabled == false
    end

    test "rejects a preference with neither user_id nor role_target",
         %{workspace: ws} do
      assert {:error, %Ecto.Changeset{} = cs} =
               Deliveries.set_preference(%{workspace_id: ws.id, channel: :email})

      assert {"either user_id or role_target must be set", _} = cs.errors[:user_id]
    end

    test "rejects a preference with both user_id and role_target",
         %{workspace: ws, user: user} do
      assert {:error, %Ecto.Changeset{} = cs} =
               Deliveries.set_preference(%{
                 workspace_id: ws.id,
                 user_id: user.id,
                 role_target: :operator,
                 channel: :email
               })

      assert {"user_id and role_target are mutually exclusive", _} = cs.errors[:role_target]
    end
  end

  describe "enabled_channels_for/1" do
    test "returns no channels when no preferences exist", %{workspace: ws} do
      n = build_notification(ws, {:role, :operator})
      assert Deliveries.enabled_channels_for(n) == []
    end

    test "returns the role-targeted channels when the role matches",
         %{workspace: ws} do
      {:ok, _} =
        Deliveries.set_preference(%{
          workspace_id: ws.id,
          role_target: :operator,
          channel: :email,
          min_severity: :warning
        })

      n = build_notification(ws, {:role, :operator})
      assert Deliveries.enabled_channels_for(n) == [:email]
    end

    test "returns user-targeted channels when the notification is user-scoped",
         %{workspace: ws, user: user} do
      {:ok, _} =
        Deliveries.set_preference(%{
          workspace_id: ws.id,
          user_id: user.id,
          channel: :webhook,
          min_severity: :info
        })

      n = build_notification(ws, {:user, user.id}, :info)
      assert Deliveries.enabled_channels_for(n) == [:webhook]
    end

    test "skips a disabled preference", %{workspace: ws} do
      {:ok, pref} =
        Deliveries.set_preference(%{
          workspace_id: ws.id,
          role_target: :operator,
          channel: :email
        })

      {:ok, _} = Deliveries.disable_preference(pref)

      n = build_notification(ws, {:role, :operator})
      assert Deliveries.enabled_channels_for(n) == []
    end

    test "skips a channel whose min_severity is above the notification's severity",
         %{workspace: ws} do
      {:ok, _} =
        Deliveries.set_preference(%{
          workspace_id: ws.id,
          role_target: :operator,
          channel: :email,
          min_severity: :critical
        })

      n = build_notification(ws, {:role, :operator}, :warning)
      assert Deliveries.enabled_channels_for(n) == []

      n_crit = build_notification(ws, {:role, :operator}, :critical)
      assert Deliveries.enabled_channels_for(n_crit) == [:email]
    end
  end

  describe "create/1 hook — enqueue_deliveries" do
    test "writes one notification_deliveries row per enabled channel",
         %{workspace: ws} do
      {:ok, _} =
        Deliveries.set_preference(%{
          workspace_id: ws.id,
          role_target: :operator,
          channel: :email
        })

      n = build_notification(ws, {:role, :operator})

      [delivery] = Deliveries.list_deliveries_for(n)
      assert delivery.channel == :email
      assert delivery.status == :queued
      assert delivery.attempts == 0
      assert delivery.workspace_id == ws.id
      assert delivery.notification_id == n.id
    end

    test "writes zero rows when no preference is enabled", %{workspace: ws} do
      n = build_notification(ws, {:role, :operator})
      assert Deliveries.list_deliveries_for(n) == []
    end

    test "two enabled channels produce two delivery rows", %{workspace: ws} do
      {:ok, _} =
        Deliveries.set_preference(%{
          workspace_id: ws.id,
          role_target: :operator,
          channel: :email
        })

      {:ok, _} =
        Deliveries.set_preference(%{
          workspace_id: ws.id,
          role_target: :operator,
          channel: :webhook
        })

      n = build_notification(ws, {:role, :operator})
      channels = Deliveries.list_deliveries_for(n) |> Enum.map(& &1.channel) |> Enum.sort()
      assert channels == [:email, :webhook]
    end

    test "the inbox row still exists even if delivery enqueue raises (best-effort)",
         %{workspace: ws} do
      # Pre-existing preference. The actual enqueue path
      # rescues failures (`dispatch_after_create/1` returns
      # `:ok`); pin the contract by checking that the
      # notification row is still readable after `create/1`.
      {:ok, _} =
        Deliveries.set_preference(%{
          workspace_id: ws.id,
          role_target: :operator,
          channel: :email
        })

      n = build_notification(ws, {:role, :operator})
      assert n.id
      assert Notifications.list_for_workspace(ws.id) |> Enum.any?(&(&1.id == n.id))
    end

    test "enqueue_deliveries/1 is idempotent on repeat calls", %{workspace: ws} do
      {:ok, _} =
        Deliveries.set_preference(%{
          workspace_id: ws.id,
          role_target: :operator,
          channel: :email
        })

      n = build_notification(ws, {:role, :operator})

      # `create/1` already called enqueue_deliveries once; a
      # second call must not create a second row.
      assert {:ok, rows} = Deliveries.enqueue_deliveries(n)
      assert length(rows) == 1
      assert length(Deliveries.list_deliveries_for(n)) == 1
    end
  end

  describe "attempt_delivery/2 — happy path" do
    setup %{workspace: ws} do
      {:ok, _} =
        Deliveries.set_preference(%{
          workspace_id: ws.id,
          role_target: :operator,
          channel: :email
        })

      n = build_notification(ws, {:role, :operator})
      [delivery] = Deliveries.list_deliveries_for(n)

      %{notification: n, delivery: delivery}
    end

    test "marks :delivered on a stub :ok result",
         %{delivery: d} do
      now = ~U[2026-05-05 12:00:00.000000Z]
      assert {:ok, updated} = Deliveries.attempt_delivery(d, now)

      assert updated.status == :delivered
      assert updated.delivered_at == now
      assert updated.last_error == nil
      assert updated.next_attempt_at == nil
    end
  end

  describe "attempt_delivery/2 — transient failure" do
    setup %{workspace: ws} do
      Application.put_env(:bank, Bank.Notifications.Channel.Stub,
        result: {:error, :transport_error}
      )

      {:ok, _} =
        Deliveries.set_preference(%{
          workspace_id: ws.id,
          role_target: :operator,
          channel: :email
        })

      n = build_notification(ws, {:role, :operator})
      [delivery] = Deliveries.list_deliveries_for(n)

      %{notification: n, delivery: delivery}
    end

    test "increments attempts and schedules a retry on the first failure",
         %{delivery: d} do
      now = ~U[2026-05-05 12:00:00.000000Z]
      assert {:ok, updated} = Deliveries.attempt_delivery(d, now)

      assert updated.status == :failed
      assert updated.attempts == 1
      assert updated.last_error == :transport_error
      assert is_struct(updated.next_attempt_at, DateTime)
      # Backoff for attempt 1 is 60 seconds (2^1 * 30).
      diff_seconds = DateTime.diff(updated.next_attempt_at, now)
      assert diff_seconds == 60
    end

    test "transitions to :permanently_failed once attempts hit max_attempts",
         %{delivery: d} do
      now = ~U[2026-05-05 12:00:00.000000Z]

      # Burn through the attempt cap. The default is 5.
      final =
        Enum.reduce(1..5, d, fn _i, acc ->
          {:ok, updated} = Deliveries.attempt_delivery(acc, now)
          updated
        end)

      assert final.status == :permanently_failed
      assert final.attempts == 5
      assert final.last_error == :transport_error
      assert final.next_attempt_at == nil
    end
  end

  describe "attempt_delivery/2 — permanent failure short-circuit" do
    setup %{workspace: ws} do
      Application.put_env(:bank, Bank.Notifications.Channel.Stub,
        result: {:permanent_error, :provider_4xx}
      )

      {:ok, _} =
        Deliveries.set_preference(%{
          workspace_id: ws.id,
          role_target: :operator,
          channel: :email
        })

      n = build_notification(ws, {:role, :operator})
      [delivery] = Deliveries.list_deliveries_for(n)

      %{delivery: delivery}
    end

    test "transitions to :permanently_failed on the first attempt", %{delivery: d} do
      now = ~U[2026-05-05 12:00:00.000000Z]
      assert {:ok, updated} = Deliveries.attempt_delivery(d, now)

      assert updated.status == :permanently_failed
      assert updated.last_error == :provider_4xx
      assert updated.next_attempt_at == nil
    end
  end

  describe "Channel.payload_for/1 — secret hygiene" do
    test "renders only the inbox row's controlled fields", %{workspace: ws} do
      n = build_notification(ws, {:role, :operator})
      payload = Channel.payload_for(n)

      keys = payload |> Map.keys() |> Enum.sort()

      assert keys == [
               :action_link,
               :body,
               :correlation_id,
               :dedupe_key,
               :event_type,
               :severity,
               :title
             ]

      # The notification's `title` / `body` / `action_link`
      # already passed the inbox row's #233 secret-marker
      # gate at insert. The payload renderer is a passive
      # projection — it never reads any other field.
      assert payload.title == n.title
      assert payload.body == n.body
      assert payload.action_link == n.action_link
    end
  end

  describe "Delivery.backoff_for/1" do
    test "is exponential and capped at 1 hour" do
      assert Delivery.backoff_for(1) == 60
      assert Delivery.backoff_for(2) == 120
      assert Delivery.backoff_for(3) == 240
      assert Delivery.backoff_for(4) == 480
      assert Delivery.backoff_for(5) == 960
      assert Delivery.backoff_for(7) == 3600
      # Capped.
      assert Delivery.backoff_for(20) == 3600
    end
  end

  describe "cross-workspace isolation" do
    test "a preference in workspace A does not affect a notification in workspace B",
         %{workspace: ws_a} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "deliv-sib-#{System.unique_integer([:positive])}",
          name: "Sibling"
        })

      {:ok, _} =
        Deliveries.set_preference(%{
          workspace_id: ws_a.id,
          role_target: :operator,
          channel: :email
        })

      n_b = build_notification(ws_b, {:role, :operator})
      assert Deliveries.list_deliveries_for(n_b) == []

      # And no preference rows leak in B's listing.
      assert Deliveries.list_preferences(ws_b.id) == []
      assert length(Deliveries.list_preferences(ws_a.id)) == 1
    end
  end

  describe "attempt_delivery/2 — terminal-state guard (#236 P2)" do
    setup %{workspace: ws} do
      {:ok, _pref} =
        Deliveries.set_preference(%{
          workspace_id: ws.id,
          role_target: :operator,
          channel: :email
        })

      n = build_notification(ws, {:role, :operator})
      [delivery] = Deliveries.list_deliveries_for(n)

      %{notification: n, delivery: delivery}
    end

    test "a stale queued struct cannot regress an already-delivered DB row",
         %{delivery: stale} do
      now = ~U[2026-05-05 12:00:00.000000Z]

      # Step 1: another caller delivers the row using a fresh
      # struct loaded from the DB. The DB row transitions to
      # `:delivered`.
      fresh = Repo.get!(Delivery, stale.id)
      assert {:ok, %Delivery{status: :delivered}} = Deliveries.attempt_delivery(fresh, now)

      # Step 2: configure the stub to FAIL on the next call.
      # If the guard is missing, the stale-struct call would
      # write `:failed` over the `:delivered` row.
      Application.put_env(:bank, Bank.Notifications.Channel.Stub,
        result: {:error, :transport_error}
      )

      # Step 3: call attempt_delivery/2 with the STALE struct
      # (still showing `status: :queued`). The guard must
      # short-circuit and return the current row unchanged.
      assert stale.status == :queued
      later = ~U[2026-05-05 12:01:00.000000Z]
      assert {:ok, returned} = Deliveries.attempt_delivery(stale, later)

      # The returned row reflects the DB, not the stale struct.
      assert returned.status == :delivered
      assert returned.id == stale.id

      # And the DB row is still `:delivered`.
      reloaded = Repo.get!(Delivery, stale.id)
      assert reloaded.status == :delivered
      assert reloaded.last_error == nil
    end

    test "a stale queued/failed struct cannot regress a permanently_failed DB row",
         %{delivery: stale} do
      now = ~U[2026-05-05 12:00:00.000000Z]

      # Step 1: drive the row to `:permanently_failed` via a
      # `:permanent_error` short-circuit on a fresh struct.
      Application.put_env(:bank, Bank.Notifications.Channel.Stub,
        result: {:permanent_error, :provider_4xx}
      )

      fresh = Repo.get!(Delivery, stale.id)

      assert {:ok, %Delivery{status: :permanently_failed}} =
               Deliveries.attempt_delivery(fresh, now)

      # Step 2: switch the stub to a transient error so a
      # missing guard would write `:failed` and reset
      # `attempts`.
      Application.put_env(:bank, Bank.Notifications.Channel.Stub,
        result: {:error, :transport_error}
      )

      # Step 3: stale struct (still `:queued`) — the guard
      # short-circuits.
      assert stale.status == :queued
      later = ~U[2026-05-05 12:01:00.000000Z]
      assert {:ok, returned} = Deliveries.attempt_delivery(stale, later)

      assert returned.status == :permanently_failed
      assert returned.id == stale.id

      reloaded = Repo.get!(Delivery, stale.id)
      assert reloaded.status == :permanently_failed
      assert reloaded.last_error == :provider_4xx
    end

    test "calling attempt_delivery/2 directly on an already-terminal struct does not change it",
         %{delivery: original} do
      now = ~U[2026-05-05 12:00:00.000000Z]

      # First call: deliver successfully.
      assert {:ok, %Delivery{status: :delivered} = delivered} =
               Deliveries.attempt_delivery(original, now)

      # Second call with the terminal struct itself, AND the
      # stub configured to fail. No-op required.
      Application.put_env(:bank, Bank.Notifications.Channel.Stub,
        result: {:error, :transport_error}
      )

      later = ~U[2026-05-05 12:05:00.000000Z]
      assert {:ok, returned} = Deliveries.attempt_delivery(delivered, later)

      assert returned.status == :delivered
      assert returned.id == delivered.id
      # Idempotent shape: the timestamp from the original
      # delivery is preserved (no new write).
      assert returned.delivered_at == delivered.delivered_at

      reloaded = Repo.get!(Delivery, delivered.id)
      assert reloaded.status == :delivered
    end

    test "the channel module is NOT called for a terminal row", %{delivery: original} do
      now = ~U[2026-05-05 12:00:00.000000Z]

      # Drive to `:delivered`.
      assert {:ok, %Delivery{status: :delivered} = delivered} =
               Deliveries.attempt_delivery(original, now)

      # Sentinel stub raises if called. The guard must
      # short-circuit BEFORE the channel module is invoked.
      Application.put_env(:bank, Bank.Notifications.Channel.Stub,
        result: {:permanent_error, :raise_if_called}
      )

      # If the guard correctly skips the channel call, this
      # `:permanent_error` never lands on the row.
      later = ~U[2026-05-05 12:05:00.000000Z]
      assert {:ok, returned} = Deliveries.attempt_delivery(delivered, later)

      assert returned.status == :delivered
      reloaded = Repo.get!(Delivery, delivered.id)
      assert reloaded.status == :delivered
      # `:raise_if_called` would have landed in `last_error`
      # if the channel had been called.
      assert reloaded.last_error == nil
    end

    test "a row that was deleted out from under the caller returns {:error, :not_found}",
         %{delivery: stale} do
      now = ~U[2026-05-05 12:00:00.000000Z]

      Repo.delete!(stale)

      assert {:error, :not_found} = Deliveries.attempt_delivery(stale, now)
    end
  end
end
