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

      {:ok, :paused, _} = Pauses.create_pause(ws_id, :chain, "base", actor: user)

      :ok = Phoenix.PubSub.subscribe(Bank.PubSub, PubSub.security_events())
      :ok = Phoenix.PubSub.subscribe(Bank.PubSub, PubSub.audit_stream())

      {:ok, :already_paused, _} = Pauses.create_pause(ws_id, :chain, "base", actor: user)

      refute_receive %{topic: :security_events, event: :scope_paused}, 50
      refute_receive %{topic: :audit_stream, event: :appended}, 50
    end

    test "idempotent re-resume does NOT broadcast a second :scope_resumed" do
      %{id: ws_id} = create_workspace!("bcast-idem-resume")
      user = create_user!()

      {:ok, :paused, _} = Pauses.create_pause(ws_id, :chain, "base", actor: user)
      {:ok, :resumed, _} = Pauses.resume(ws_id, :chain, "base", actor: user)

      :ok = Phoenix.PubSub.subscribe(Bank.PubSub, PubSub.security_events())
      :ok = Phoenix.PubSub.subscribe(Bank.PubSub, PubSub.audit_stream())

      {:ok, :already_running} = Pauses.resume(ws_id, :chain, "base", actor: user)

      refute_receive %{topic: :security_events, event: :scope_resumed}, 50
      refute_receive %{topic: :audit_stream, event: :appended}, 50
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
        name: "WS #{slug_suffix} #{suffix}"
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
