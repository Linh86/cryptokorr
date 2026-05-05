defmodule Bank.SecurityTest do
  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Repo
  alias Bank.Runtime.Workers.RevokeDelegation
  alias Bank.Security
  alias Bank.Security.PauseState

  import Ecto.Query

  setup do
    PauseState.reset()
    :ok
  end

  describe "pause/2 + resume/2 — global scope" do
    test "pauses, reports paused?, resumes, reports running" do
      refute Security.paused?(:global)

      assert {:ok, :paused} =
               Security.pause(:global, reason: :liveness_check_failed, actor: :runtime)

      assert Security.paused?(:global)

      assert {:ok, :resumed} = Security.resume(:global, actor: :user, actor_id: "op-42")
      refute Security.paused?(:global)
    end

    test "is idempotent — double pause returns :already_paused, double resume :already_running" do
      assert {:ok, :paused} = Security.pause(:global)
      assert {:ok, :already_paused} = Security.pause(:global)

      assert {:ok, :resumed} = Security.resume(:global)
      assert {:ok, :already_running} = Security.resume(:global)
    end

    test "emits security.paused and security.resumed audit events" do
      {:ok, :paused} = Security.pause(:global, actor: :user, actor_id: "op-1")

      paused_event = fetch_latest_event("security.paused")
      assert paused_event.subject_type == "runtime"
      assert paused_event.subject_id == "global"
      assert paused_event.actor == :user
      assert paused_event.actor_id == "op-1"
      assert is_nil(paused_event.correlation_id)

      {:ok, :resumed} = Security.resume(:global, actor: :user, actor_id: "op-1")

      resumed_event = fetch_latest_event("security.resumed")
      assert resumed_event.subject_type == "runtime"
    end

    test "does not emit a duplicate audit event on an idempotent no-op" do
      {:ok, :paused} = Security.pause(:global)
      before = count_events("security.paused")

      {:ok, :already_paused} = Security.pause(:global)
      assert count_events("security.paused") == before
    end
  end

  describe "pause/2 + resume/2 — counterparty scope" do
    test "pauses a single counterparty without affecting global" do
      cp_id = Ecto.UUID.generate()
      assert {:ok, :paused} = Security.pause({:counterparty, cp_id}, actor: :user)

      assert Security.paused?({:counterparty, cp_id})
      refute Security.paused?(:global)
      refute Security.paused?({:counterparty, Ecto.UUID.generate()})
    end

    test "counterparty scope inherits global pause" do
      cp_id = Ecto.UUID.generate()
      assert {:ok, :paused} = Security.pause(:global)
      assert Security.paused?({:counterparty, cp_id})
    end

    test "audit event carries counterparty subject_id" do
      cp_id = Ecto.UUID.generate()
      {:ok, :paused} = Security.pause({:counterparty, cp_id}, actor: :user)

      event = fetch_latest_event("security.paused")
      assert event.subject_type == "counterparty"
      assert event.subject_id == cp_id
    end
  end

  describe "revoke_delegation/2" do
    test "enqueues on :security_revoke and emits delegation.revoke_requested" do
      smart_account_id = "sa_#{Ecto.UUID.generate()}"

      assert {:ok, %Oban.Job{}} =
               Security.revoke_delegation(smart_account_id,
                 reason: :operator_requested,
                 actor: :user,
                 actor_id: "op-7"
               )

      assert_enqueued(
        worker: RevokeDelegation,
        queue: :security_revoke,
        args: %{"smart_account_id" => smart_account_id, "reason" => "operator_requested"}
      )

      event = fetch_latest_event("delegation.revoke_requested")
      assert event.subject_type == "smart_account"
      assert event.subject_id == smart_account_id
      assert is_nil(event.correlation_id)
      assert event.actor == :user
    end
  end

  describe "pause/3 + resume/3 + paused?/2 — workspace-scoped chain" do
    test "DB-backed pause/resume happy path through Bank.Security" do
      ws = create_workspace_for_security_test!()
      user = create_user_for_security_test!()

      assert {:ok, :paused, pause} =
               Security.pause(ws.id, {:chain, "base"}, actor: user, reason: "rpc outage")

      assert pause.workspace_id == ws.id
      assert pause.scope_type == :chain
      assert pause.scope_value == "base"

      assert Security.paused?(ws.id, {:chain, "base"})
      refute Security.paused?(ws.id, {:chain, "optimism"})

      assert {:ok, :resumed, _} = Security.resume(ws.id, {:chain, "base"}, actor: user)
      refute Security.paused?(ws.id, {:chain, "base"})
    end

    test "global pause precedence — paused?/2 returns true even with no DB row" do
      ws = create_workspace_for_security_test!()

      refute Security.paused?(ws.id, {:chain, "base"})
      {:ok, :paused} = Security.pause(:global)

      assert Security.paused?(ws.id, {:chain, "base"})
      assert Security.paused?(ws.id, {:chain, "anything"})
    end

    test "nil workspace_id is legacy-safe and respects global precedence" do
      refute Security.paused?(nil, {:chain, "base"})

      {:ok, :paused} = Security.pause(:global)
      assert Security.paused?(nil, {:chain, "base"})
    end

    test "pause/3 with nil workspace_id rejects with :invalid_workspace" do
      assert {:error, :invalid_workspace} =
               Security.pause(nil, {:chain, "base"}, [])

      assert {:error, :invalid_workspace} =
               Security.resume(nil, {:chain, "base"}, [])
    end

    test "sibling workspaces are isolated" do
      ws_a = create_workspace_for_security_test!()
      ws_b = create_workspace_for_security_test!()
      user = create_user_for_security_test!()

      {:ok, :paused, _} = Security.pause(ws_a.id, {:chain, "base"}, actor: user)

      assert Security.paused?(ws_a.id, {:chain, "base"})
      refute Security.paused?(ws_b.id, {:chain, "base"})
    end
  end

  describe "snapshot/0" do
    test "returns the current pause shape" do
      cp_id = Ecto.UUID.generate()
      {:ok, :paused} = Security.pause(:global, reason: :rollout)
      {:ok, :paused} = Security.pause({:counterparty, cp_id}, reason: :suspect_activity)

      snapshot = Security.snapshot()
      assert %{global: %{reason: :rollout}, counterparties: cps} = snapshot
      assert %{reason: :suspect_activity} = Map.fetch!(cps, cp_id)
    end
  end

  # ---- helpers ----

  defp fetch_latest_event(event_type) do
    AuditEvent
    |> where([e], e.event_type == ^event_type)
    |> order_by([e], desc: e.ts, desc: e.id)
    |> limit(1)
    |> Repo.one!()
  end

  defp count_events(event_type) do
    AuditEvent
    |> where([e], e.event_type == ^event_type)
    |> Repo.aggregate(:count, :id)
  end

  defp create_workspace_for_security_test! do
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "sec-test-#{suffix}",
        name: "Security Test #{suffix}",
        mainnet_enabled: true
      })

    ws
  end

  defp create_user_for_security_test! do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "sec-test-user-#{suffix}",
        email: "sec-test-user-#{suffix}@example.com",
        name: "Sec Test User #{suffix}"
      })

    user
  end
end
