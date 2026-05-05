defmodule Bank.Security.PausesTest do
  # async: false because the in-memory PauseState GenServer is global
  # and the global-precedence tests mutate it.
  use Bank.DataCase, async: false

  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Repo
  alias Bank.Runtime.PubSub
  alias Bank.Security.Pause
  alias Bank.Security.Pauses
  alias Bank.Security.PauseState
  alias Bank.Workspaces

  setup do
    PauseState.reset()
    :ok
  end

  describe "create_pause/4" do
    test "happy path: inserts an active pause, emits exactly one audit row" do
      %{id: ws_id} = create_workspace!("pause-happy")
      user = create_user!()

      assert {:ok, :paused, %Pause{} = pause} =
               Pauses.create_pause(ws_id, :chain, "base",
                 actor: user,
                 reason: "rpc outage"
               )

      assert pause.workspace_id == ws_id
      assert pause.scope_type == :chain
      assert pause.scope_value == "base"
      assert pause.reason == "rpc outage"
      assert pause.created_by_user_id == user.id
      assert is_nil(pause.resumed_at)
      assert Pause.active?(pause)

      assert count_active(ws_id, :chain, "base") == 1
      assert count_events("security.scope_paused", ws_id) == 1
    end

    test "idempotent re-pause returns existing row and does not emit a second audit" do
      %{id: ws_id} = create_workspace!("pause-idem")
      user = create_user!()

      {:ok, :paused, first} =
        Pauses.create_pause(ws_id, :chain, "base", actor: user, reason: "first")

      {:ok, :already_paused, second} =
        Pauses.create_pause(ws_id, :chain, "base", actor: user, reason: "second")

      assert first.id == second.id
      # First-pause metadata wins (no in-place rewrite by the second call).
      assert second.reason == "first"
      assert count_events("security.scope_paused", ws_id) == 1
    end

    test "validates reason length (max 256)" do
      %{id: ws_id} = create_workspace!("pause-reason")
      user = create_user!()
      long = String.duplicate("x", 257)

      assert {:error, %Ecto.Changeset{} = cs} =
               Pauses.create_pause(ws_id, :chain, "base", actor: user, reason: long)

      assert {:reason, _} = List.keyfind(cs.errors, :reason, 0)
    end

    test "rejects nil/non-binary workspace_id" do
      assert {:error, :invalid_workspace} = Pauses.create_pause(nil, :chain, "base", [])
      assert {:error, :invalid_workspace} = Pauses.create_pause(:not_a_ws, :chain, "base", [])
    end

    test "rejects unsupported scope_type and bad scope_value" do
      %{id: ws_id} = create_workspace!("pause-type")

      assert {:error, :invalid_scope_type} =
               Pauses.create_pause(ws_id, :smart_account, "sa", [])

      assert {:error, :invalid_scope_value} = Pauses.create_pause(ws_id, :chain, "", [])
      assert {:error, :invalid_scope_value} = Pauses.create_pause(ws_id, :chain, nil, [])
    end

    test "concurrent duplicate pause converges to one active row + one audit event" do
      %{id: ws_id} = create_workspace!("pause-race")
      user = create_user!()

      results =
        1..6
        |> Task.async_stream(
          fn _ ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), self())
            Pauses.create_pause(ws_id, :chain, "base", actor: user, reason: "race")
          end,
          ordered: false,
          max_concurrency: 6
        )
        |> Enum.map(fn {:ok, r} -> r end)

      tags = results |> Enum.map(fn {:ok, tag, _} -> tag end) |> Enum.frequencies()
      assert Map.get(tags, :paused, 0) == 1
      assert Map.get(tags, :already_paused, 0) == 5

      assert count_active(ws_id, :chain, "base") == 1
      assert count_events("security.scope_paused", ws_id) == 1
    end
  end

  describe "create_pause with expires_at (#228 phase 1.5)" do
    test "stores future expires_at on a fresh pause" do
      %{id: ws_id} = create_workspace!("expiry-future")
      user = create_user!()
      future = DateTime.utc_now() |> DateTime.add(3600, :second)

      assert {:ok, :paused, %Pause{} = pause} =
               Pauses.create_pause(ws_id, :chain, "base", actor: user, expires_at: future)

      assert DateTime.compare(pause.expires_at, future) == :eq
    end

    test "rejects expires_at that is not strictly after paused_at" do
      %{id: ws_id} = create_workspace!("expiry-past")
      user = create_user!()
      past = DateTime.utc_now() |> DateTime.add(-60, :second)

      assert {:error, %Ecto.Changeset{} = cs} =
               Pauses.create_pause(ws_id, :chain, "base", actor: user, expires_at: past)

      assert {:expires_at, _} = List.keyfind(cs.errors, :expires_at, 0)
    end

    test "idempotent re-pause does NOT mutate the existing expires_at" do
      %{id: ws_id} = create_workspace!("expiry-idem")
      user = create_user!()
      first = DateTime.utc_now() |> DateTime.add(600, :second)
      second = DateTime.utc_now() |> DateTime.add(7200, :second)

      {:ok, :paused, original} =
        Pauses.create_pause(ws_id, :chain, "base", actor: user, expires_at: first)

      {:ok, :already_paused, returned} =
        Pauses.create_pause(ws_id, :chain, "base", actor: user, expires_at: second)

      assert returned.id == original.id
      # First writer's expires_at wins; the second call's later expiry
      # is silently ignored.
      assert DateTime.compare(returned.expires_at, original.expires_at) == :eq
      refute DateTime.compare(returned.expires_at, second) == :eq

      # No second audit row from the idempotent re-pause.
      assert count_events("security.scope_paused", ws_id) == 1
    end

    test "expires_at is optional — no expiry means manual-resume only" do
      %{id: ws_id} = create_workspace!("expiry-none")
      user = create_user!()

      {:ok, :paused, pause} = Pauses.create_pause(ws_id, :chain, "base", actor: user)

      assert is_nil(pause.expires_at)
    end
  end

  describe "list_active_expired/2 + expire/2 (#228 phase 1.5)" do
    test "list_active_expired returns rows with expires_at <= now from any workspace" do
      %{id: a_id} = create_workspace!("expiry-list-a")
      %{id: b_id} = create_workspace!("expiry-list-b")
      user = create_user!()
      far_future = DateTime.utc_now() |> DateTime.add(7200, :second)
      soon = DateTime.utc_now() |> DateTime.add(60, :second)

      {:ok, :paused, soon_a} =
        Pauses.create_pause(a_id, :chain, "base", actor: user, expires_at: soon)

      {:ok, :paused, far_b} =
        Pauses.create_pause(b_id, :chain, "base", actor: user, expires_at: far_future)

      {:ok, :paused, _no_expiry} = Pauses.create_pause(a_id, :chain, "optimism", actor: user)

      # `now` two minutes from now: only the soon row in workspace A
      # is expired; far_b and the no-expiry row are left alone.
      now = DateTime.utc_now() |> DateTime.add(120, :second)

      ids = Pauses.list_active_expired(now) |> Enum.map(& &1.id)
      assert soon_a.id in ids
      refute far_b.id in ids
    end

    test "expire/2 transitions an expired active row to resumed with anchored resumed_at" do
      %{id: ws_id} = create_workspace!("expire-flip")
      user = create_user!()
      expires_at = DateTime.utc_now() |> DateTime.add(60, :second)

      {:ok, :paused, pause} =
        Pauses.create_pause(ws_id, :chain, "base", actor: user, expires_at: expires_at)

      now = DateTime.utc_now() |> DateTime.add(120, :second)

      assert {:ok, :expired, %Pause{} = expired} = Pauses.expire(pause, now)

      # `resumed_at` is anchored to the recorded `expires_at`, NOT the
      # sweeper's `now`, so re-runs always agree.
      assert DateTime.compare(expired.resumed_at, expires_at) == :eq
      assert is_nil(expired.resumed_by_user_id)
      refute Pauses.paused?(ws_id, :chain, "base")
      assert count_events("security.scope_expired", ws_id) == 1
    end

    test "expire/2 second call on an already-resumed row returns :already_resumed with no audit" do
      %{id: ws_id} = create_workspace!("expire-idem")
      user = create_user!()
      expires_at = DateTime.utc_now() |> DateTime.add(60, :second)

      {:ok, :paused, pause} =
        Pauses.create_pause(ws_id, :chain, "base", actor: user, expires_at: expires_at)

      now = DateTime.utc_now() |> DateTime.add(120, :second)
      {:ok, :expired, _} = Pauses.expire(pause, now)

      assert {:ok, :already_resumed} = Pauses.expire(pause, now)
      assert count_events("security.scope_expired", ws_id) == 1
    end

    test "expire/2 with stale snapshot: row already operator-resumed returns :already_resumed" do
      %{id: ws_id} = create_workspace!("expire-stale-resume")
      user = create_user!()
      expires_at = DateTime.utc_now() |> DateTime.add(60, :second)

      {:ok, :paused, pause} =
        Pauses.create_pause(ws_id, :chain, "base", actor: user, expires_at: expires_at)

      {:ok, :resumed, _} = Pauses.resume(ws_id, :chain, "base", actor: user)

      now = DateTime.utc_now() |> DateTime.add(120, :second)

      assert {:ok, :already_resumed} = Pauses.expire(pause, now)
      assert count_events("security.scope_expired", ws_id) == 0
    end

    test "expire/2 with stale `now`: not-yet-expired row returns :not_yet_expired" do
      %{id: ws_id} = create_workspace!("expire-stale-now")
      user = create_user!()
      expires_at = DateTime.utc_now() |> DateTime.add(7200, :second)

      {:ok, :paused, pause} =
        Pauses.create_pause(ws_id, :chain, "base", actor: user, expires_at: expires_at)

      now = DateTime.utc_now() |> DateTime.add(60, :second)

      assert {:ok, :not_yet_expired} = Pauses.expire(pause, now)
      assert count_events("security.scope_expired", ws_id) == 0
    end

    test "expire/2 broadcasts :scope_expired post-commit" do
      %{id: ws_id} = create_workspace!("expire-bcast")
      user = create_user!()
      expires_at = DateTime.utc_now() |> DateTime.add(60, :second)

      {:ok, :paused, pause} =
        Pauses.create_pause(ws_id, :chain, "base", actor: user, expires_at: expires_at)

      :ok = Phoenix.PubSub.subscribe(Bank.PubSub, PubSub.security_events())
      :ok = Phoenix.PubSub.subscribe(Bank.PubSub, PubSub.audit_stream())

      now = DateTime.utc_now() |> DateTime.add(120, :second)
      {:ok, :expired, _} = Pauses.expire(pause, now)

      assert_receive %{
        topic: :security_events,
        event: :scope_expired,
        payload: %{
          scope: %{kind: :chain, value: "base", workspace_id: ^ws_id},
          actor: :runtime
        }
      }

      assert_receive %{
        topic: :audit_stream,
        event: :appended,
        payload: %{event_type: "security.scope_expired", subject_id: "base"}
      }
    end
  end

  describe "realtime broadcast" do
    test "create_pause emits :scope_paused on security:events and :appended on audit:stream" do
      %{id: ws_id} = create_workspace!("bcast-pause")
      user = create_user!()

      :ok = Phoenix.PubSub.subscribe(Bank.PubSub, PubSub.security_events())
      :ok = Phoenix.PubSub.subscribe(Bank.PubSub, PubSub.audit_stream())

      {:ok, :paused, pause} =
        Pauses.create_pause(ws_id, :chain, "base", actor: user, reason: "rpc outage")

      assert_receive %{
        topic: :security_events,
        event: :scope_paused,
        payload: %{
          scope: %{kind: :chain, value: "base", workspace_id: ^ws_id},
          reason: "rpc outage"
        }
      }

      pause_id = pause.id

      assert_receive %{
        topic: :audit_stream,
        event: :appended,
        payload: %{event_type: "security.scope_paused", subject_id: "base"}
      }

      _ = pause_id
    end

    test "resume emits :scope_resumed on security:events and :appended on audit:stream" do
      %{id: ws_id} = create_workspace!("bcast-resume")
      user = create_user!()

      {:ok, :paused, _} = Pauses.create_pause(ws_id, :chain, "base", actor: user)

      :ok = Phoenix.PubSub.subscribe(Bank.PubSub, PubSub.security_events())
      :ok = Phoenix.PubSub.subscribe(Bank.PubSub, PubSub.audit_stream())

      {:ok, :resumed, _} = Pauses.resume(ws_id, :chain, "base", actor: user)

      assert_receive %{
        topic: :security_events,
        event: :scope_resumed,
        payload: %{scope: %{kind: :chain, value: "base", workspace_id: ^ws_id}}
      }

      assert_receive %{
        topic: :audit_stream,
        event: :appended,
        payload: %{event_type: "security.scope_resumed"}
      }
    end

    test "idempotent re-pause does NOT broadcast a second :scope_paused" do
      %{id: ws_id} = create_workspace!("bcast-idem-pause")
      user = create_user!()
      # Unique scope_value per test so the refute matchers can pin the
      # exact (event, subject_id, workspace_id) we care about and not
      # accidentally false-positive on unrelated audit_stream traffic.
      chain = "idem-pause-#{System.unique_integer([:positive])}"

      {:ok, :paused, _} = Pauses.create_pause(ws_id, :chain, chain, actor: user)

      :ok = Phoenix.PubSub.subscribe(Bank.PubSub, PubSub.security_events())
      :ok = Phoenix.PubSub.subscribe(Bank.PubSub, PubSub.audit_stream())

      {:ok, :already_paused, _} = Pauses.create_pause(ws_id, :chain, chain, actor: user)

      refute_receive %{
                       topic: :security_events,
                       event: :scope_paused,
                       payload: %{scope: %{kind: :chain, value: ^chain, workspace_id: ^ws_id}}
                     },
                     50

      refute_receive %{
                       topic: :audit_stream,
                       event: :appended,
                       payload: %{event_type: "security.scope_paused", subject_id: ^chain}
                     },
                     50
    end

    test "idempotent re-resume does NOT broadcast a second :scope_resumed" do
      %{id: ws_id} = create_workspace!("bcast-idem-resume")
      user = create_user!()
      chain = "idem-resume-#{System.unique_integer([:positive])}"

      {:ok, :paused, _} = Pauses.create_pause(ws_id, :chain, chain, actor: user)
      {:ok, :resumed, _} = Pauses.resume(ws_id, :chain, chain, actor: user)

      :ok = Phoenix.PubSub.subscribe(Bank.PubSub, PubSub.security_events())
      :ok = Phoenix.PubSub.subscribe(Bank.PubSub, PubSub.audit_stream())

      {:ok, :already_running} = Pauses.resume(ws_id, :chain, chain, actor: user)

      refute_receive %{
                       topic: :security_events,
                       event: :scope_resumed,
                       payload: %{scope: %{kind: :chain, value: ^chain, workspace_id: ^ws_id}}
                     },
                     50

      refute_receive %{
                       topic: :audit_stream,
                       event: :appended,
                       payload: %{event_type: "security.scope_resumed", subject_id: ^chain}
                     },
                     50
    end
  end

  describe "resume/4" do
    test "happy path: clears active row, emits exactly one resumed audit" do
      %{id: ws_id} = create_workspace!("resume-happy")
      user = create_user!()

      {:ok, :paused, _} = Pauses.create_pause(ws_id, :chain, "base", actor: user)

      assert {:ok, :resumed, %Pause{} = resumed} =
               Pauses.resume(ws_id, :chain, "base", actor: user)

      refute is_nil(resumed.resumed_at)
      assert resumed.resumed_by_user_id == user.id
      refute Pauses.paused?(ws_id, :chain, "base")
      assert count_active(ws_id, :chain, "base") == 0
      assert count_events("security.scope_resumed", ws_id) == 1
    end

    test "idempotent: resuming a non-paused scope returns :already_running with no audit" do
      %{id: ws_id} = create_workspace!("resume-noop")
      user = create_user!()

      assert {:ok, :already_running} = Pauses.resume(ws_id, :chain, "base", actor: user)
      assert count_events("security.scope_resumed", ws_id) == 0
    end

    test "second resume on an already-resumed scope is also a no-op" do
      %{id: ws_id} = create_workspace!("resume-double")
      user = create_user!()

      {:ok, :paused, _} = Pauses.create_pause(ws_id, :chain, "base", actor: user)
      {:ok, :resumed, _} = Pauses.resume(ws_id, :chain, "base", actor: user)

      assert {:ok, :already_running} = Pauses.resume(ws_id, :chain, "base", actor: user)
      assert count_events("security.scope_resumed", ws_id) == 1
    end

    test "after resume, a fresh pause inserts a new active row" do
      %{id: ws_id} = create_workspace!("resume-then-pause")
      user = create_user!()

      {:ok, :paused, first} = Pauses.create_pause(ws_id, :chain, "base", actor: user)
      {:ok, :resumed, _} = Pauses.resume(ws_id, :chain, "base", actor: user)

      {:ok, :paused, second} =
        Pauses.create_pause(ws_id, :chain, "base", actor: user, reason: "second")

      assert second.id != first.id
      assert count_active(ws_id, :chain, "base") == 1
      assert count_events("security.scope_paused", ws_id) == 2
    end

    test "rejects nil/invalid workspace_id" do
      assert {:error, :invalid_workspace} = Pauses.resume(nil, :chain, "base", [])
      assert {:error, :invalid_workspace} = Pauses.resume(:bad, :chain, "base", [])
    end
  end

  describe "paused?/3" do
    test "true after pause, false after resume" do
      %{id: ws_id} = create_workspace!("paused-flips")
      user = create_user!()

      refute Pauses.paused?(ws_id, :chain, "base")
      {:ok, :paused, _} = Pauses.create_pause(ws_id, :chain, "base", actor: user)
      assert Pauses.paused?(ws_id, :chain, "base")

      {:ok, :resumed, _} = Pauses.resume(ws_id, :chain, "base", actor: user)
      refute Pauses.paused?(ws_id, :chain, "base")
    end

    test "nil workspace_id returns false (legacy-safe)" do
      refute Pauses.paused?(nil, :chain, "base")
      refute Pauses.paused?(:not_binary, :chain, "base")
    end

    test "unsupported scope_type returns false (Phase 1 ships :chain only)" do
      %{id: ws_id} = create_workspace!("paused-scope")
      refute Pauses.paused?(ws_id, :smart_account, "sa")
    end
  end

  describe "cross-workspace isolation" do
    test "paused?/3 scoped to workspace; sibling workspace not affected" do
      %{id: a_id} = create_workspace!("iso-a")
      %{id: b_id} = create_workspace!("iso-b")
      user = create_user!()

      {:ok, :paused, _} = Pauses.create_pause(a_id, :chain, "base", actor: user)

      assert Pauses.paused?(a_id, :chain, "base")
      refute Pauses.paused?(b_id, :chain, "base")
    end

    test "list_active/1 returns only the calling workspace's rows" do
      %{id: a_id} = create_workspace!("list-a")
      %{id: b_id} = create_workspace!("list-b")
      user = create_user!()

      {:ok, :paused, _} = Pauses.create_pause(a_id, :chain, "base", actor: user)
      {:ok, :paused, _} = Pauses.create_pause(b_id, :chain, "optimism", actor: user)

      [pause_a] = Pauses.list_active(a_id)
      assert pause_a.workspace_id == a_id
      assert pause_a.scope_value == "base"

      [pause_b] = Pauses.list_active(b_id)
      assert pause_b.workspace_id == b_id
      assert pause_b.scope_value == "optimism"
    end

    test "list_active/1 returns [] for nil/invalid workspace_id" do
      assert Pauses.list_active(nil) == []
      assert Pauses.list_active(:bogus) == []
    end

    test "get_active_pause/3 is workspace-scoped and refuses nil" do
      %{id: a_id} = create_workspace!("get-a")
      %{id: b_id} = create_workspace!("get-b")
      user = create_user!()

      {:ok, :paused, pause} = Pauses.create_pause(a_id, :chain, "base", actor: user)

      assert %Pause{id: id_a} = Pauses.get_active_pause(a_id, :chain, "base")
      assert id_a == pause.id

      assert is_nil(Pauses.get_active_pause(b_id, :chain, "base"))
      assert is_nil(Pauses.get_active_pause(nil, :chain, "base"))
    end
  end

  # ---- helpers ----

  defp create_workspace!(slug_suffix) do
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Workspaces.create_workspace(%{
        slug: "#{slug_suffix}-#{suffix}",
        name: "WS #{slug_suffix} #{suffix}",
        mainnet_enabled: true
      })

    ws
  end

  defp create_user! do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "pauses-test-#{suffix}",
        email: "pauses-test-#{suffix}@example.com",
        name: "Pauses Test #{suffix}"
      })

    user
  end

  defp count_active(workspace_id, scope_type, scope_value) do
    Repo.aggregate(
      from(p in Pause,
        where:
          p.workspace_id == ^workspace_id and
            p.scope_type == ^scope_type and
            p.scope_value == ^scope_value and
            is_nil(p.resumed_at)
      ),
      :count,
      :id
    )
  end

  defp count_events(event_type, workspace_id) do
    Repo.aggregate(
      from(e in AuditEvent,
        where: e.event_type == ^event_type and e.workspace_id == ^workspace_id
      ),
      :count,
      :id
    )
  end
end
