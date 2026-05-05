defmodule Bank.Notifications.EmitterTest do
  @moduledoc """
  Focused tests for `Bank.Notifications.Emitter` (#234).

  Each emitter is exercised against a real seeded fixture pair
  (`%AgentIntent{}` + `%DecisionEnvelope{}`) to prove the surfaced
  notification has the right shape, dedupe behavior, and never
  reflects unsafe text into the inbox.
  """

  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  import Bank.Fixtures

  alias Bank.Notifications
  alias Bank.Notifications.Emitter
  alias Bank.Notifications.Notification

  setup do
    suffix = System.unique_integer([:positive])

    {:ok, workspace} =
      Bank.Workspaces.create_workspace(%{
        slug: "emitter-test-#{suffix}",
        name: "Emitter Test #{suffix}",
        mainnet_enabled: true
      })

    # Bank.Fixtures.agent_intent/1 reads :bank_test_workspace_id
    # from the process dict to default the intent's workspace_id —
    # the same hook `BankWeb.ConnCase.register_and_log_in_user`
    # uses. Set it for the rest of this test process so fixtures
    # do not have to thread `workspace_id:` through every call.
    Process.put(:bank_test_workspace_id, workspace.id)
    on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

    %{workspace: workspace}
  end

  describe "emit_decision_outcome/2 — surfaces operator-action outcomes" do
    test "creates a warning notification for :approval_required" do
      intent = agent_intent()

      envelope =
        decision_envelope(
          intent: intent,
          outcome: :approval_required,
          risk_tier: :elevated,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      assert {:ok, %Notification{} = n} = Emitter.emit_decision_outcome(intent, envelope)

      assert n.workspace_id == intent.workspace_id
      assert n.role_target == :operator
      assert n.user_id == nil
      assert n.event_type == "decision.approval_required"
      assert n.severity == :warning
      assert n.subject_type == "decision_envelope"
      assert n.subject_id == envelope.id
      assert n.correlation_id == intent.id
      assert n.action_link == "/queue#pending-approvals-section"
      assert n.dedupe_key == "decision:#{intent.id}:approval_required"
      assert n.title =~ "Approval required"
      assert n.title =~ to_string(intent.kind)
      assert n.body =~ "Risk elevated"
    end

    test "creates a warning notification for :hold" do
      intent = agent_intent()
      envelope = decision_envelope(intent: intent, outcome: :hold, risk_tier: :moderate)

      assert {:ok, %Notification{} = n} = Emitter.emit_decision_outcome(intent, envelope)

      assert n.severity == :warning
      assert n.event_type == "decision.hold"
      assert n.action_link == "/queue#held-actions-section"
      assert n.dedupe_key == "decision:#{intent.id}:hold"
      assert n.title =~ "held"
    end

    test "creates a critical notification for :block" do
      intent = agent_intent()
      envelope = decision_envelope(intent: intent, outcome: :block, risk_tier: :severe)

      assert {:ok, %Notification{} = n} = Emitter.emit_decision_outcome(intent, envelope)

      assert n.severity == :critical
      assert n.event_type == "decision.block"
      assert n.action_link == "/queue#held-actions-section"
      assert n.dedupe_key == "decision:#{intent.id}:block"
      assert n.title =~ "blocked"
    end

    test "skips :auto_exec — operators do not need an inbox row for the happy path" do
      intent = agent_intent()
      envelope = decision_envelope(intent: intent, outcome: :auto_exec, risk_tier: :low)

      assert {:skip, :auto_exec_no_inbox_row} =
               Emitter.emit_decision_outcome(intent, envelope)

      assert Notifications.list_for_workspace(intent.workspace_id) == []
    end
  end

  describe "emit_decision_outcome/2 — dedupe" do
    test "re-emitting the same intent + outcome returns {:duplicate, _} without a second row" do
      intent = agent_intent()
      envelope1 = decision_envelope(intent: intent, outcome: :hold, risk_tier: :moderate)

      assert {:ok, %Notification{id: first_id}} =
               Emitter.emit_decision_outcome(intent, envelope1)

      # A second envelope (different id) for the same intent +
      # outcome — typical when the runtime re-evaluates and lands
      # on the same outcome again. Operator should not get a
      # second inbox row.
      envelope2 = decision_envelope(intent: intent, outcome: :hold, risk_tier: :moderate)

      assert {:duplicate, %Notification{id: ^first_id}} =
               Emitter.emit_decision_outcome(intent, envelope2)

      # Exactly one row for this intent in this workspace.
      assert [%Notification{id: ^first_id}] =
               Notifications.list_for_workspace(intent.workspace_id)
    end

    test "different outcomes for the same intent generate separate rows" do
      intent = agent_intent()
      hold_env = decision_envelope(intent: intent, outcome: :hold, risk_tier: :moderate)

      block_env = decision_envelope(intent: intent, outcome: :block, risk_tier: :severe)

      assert {:ok, %Notification{}} = Emitter.emit_decision_outcome(intent, hold_env)
      assert {:ok, %Notification{}} = Emitter.emit_decision_outcome(intent, block_env)

      rows = Notifications.list_for_workspace(intent.workspace_id)
      dedupe_keys = Enum.map(rows, & &1.dedupe_key) |> Enum.sort()

      assert dedupe_keys == [
               "decision:#{intent.id}:block",
               "decision:#{intent.id}:hold"
             ]
    end
  end

  describe "emit_decision_outcome/2 — workspace isolation" do
    test "a notification emitted in workspace A does not leak into workspace B" do
      intent_a = agent_intent()

      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "sibling-#{System.unique_integer([:positive])}",
          name: "Sibling",
          mainnet_enabled: true
        })

      intent_b = agent_intent(workspace_id: ws_b.id)

      env_a =
        decision_envelope(
          intent: intent_a,
          outcome: :approval_required,
          risk_tier: :elevated,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      env_b =
        decision_envelope(
          intent: intent_b,
          outcome: :approval_required,
          risk_tier: :elevated,
          approval_expires_at: ~U[2030-01-01 00:00:00Z]
        )

      assert {:ok, _} = Emitter.emit_decision_outcome(intent_a, env_a)
      assert {:ok, _} = Emitter.emit_decision_outcome(intent_b, env_b)

      [n_a] = Notifications.list_for_workspace(intent_a.workspace_id)
      [n_b] = Notifications.list_for_workspace(ws_b.id)

      assert n_a.workspace_id == intent_a.workspace_id
      assert n_b.workspace_id == ws_b.id
      refute n_a.workspace_id == n_b.workspace_id
    end
  end

  describe "emit_execution_outcome/1 — failure-side terminal outcomes" do
    test ":reverted lands a critical operator notification linked to the intent replay" do
      intent = agent_intent()
      envelope = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      plan =
        execution_plan(
          decision: envelope,
          execution_status: :reverted,
          final_outcome: :reverted,
          final_reason: "chain_revert:out_of_gas",
          active: false
        )
        |> Bank.Repo.preload(:intent)

      assert {:ok, %Notification{} = n} = Emitter.emit_execution_outcome(plan)

      assert n.workspace_id == intent.workspace_id
      assert n.role_target == :operator
      assert n.user_id == nil
      assert n.event_type == "execution.reverted"
      assert n.severity == :critical
      assert n.subject_type == "execution_plan"
      assert n.subject_id == plan.id
      assert n.correlation_id == intent.id
      assert n.action_link == "/audit/replay/#{intent.id}"
      assert n.dedupe_key == "execution:#{plan.id}:reverted"
      assert n.title =~ "Execution reverted"
      assert n.title =~ to_string(intent.kind)
      # Final reason MUST NOT bleed into the inbox payload.
      refute n.title =~ "out_of_gas"
      refute n.body =~ "out_of_gas"
      refute (n.action_link || "") =~ "out_of_gas"
    end

    test ":aborted lands a warning operator notification linked to the intent replay" do
      intent = agent_intent()
      envelope = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      plan =
        execution_plan(
          decision: envelope,
          execution_status: :aborted,
          final_outcome: :aborted,
          final_reason: "operator_aborted:incident-1234",
          active: false
        )
        |> Bank.Repo.preload(:intent)

      assert {:ok, %Notification{} = n} = Emitter.emit_execution_outcome(plan)

      assert n.severity == :warning
      assert n.event_type == "execution.aborted"
      assert n.action_link == "/audit/replay/#{intent.id}"
      assert n.dedupe_key == "execution:#{plan.id}:aborted"
      assert n.title =~ "Execution aborted"
      refute n.title =~ "incident-1234"
      refute n.body =~ "incident-1234"
    end

    test "skips :confirmed by default (opt-in flag is false on a fresh workspace)" do
      intent = agent_intent()
      envelope = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      plan =
        execution_plan(
          decision: envelope,
          execution_status: :confirmed,
          final_outcome: :confirmed,
          active: false
        )
        |> Bank.Repo.preload(:intent)

      assert {:skip, :confirmed_not_opted_in} =
               Emitter.emit_execution_outcome(plan)

      assert Notifications.list_for_workspace(intent.workspace_id) == []
    end

    test "emits an :info :confirmed notification when the workspace opts in (#234)",
         %{workspace: ws} do
      # Flip the opt-in flag for this test workspace.
      {:ok, _} = Bank.Workspaces.set_notify_execution_confirmed(ws, true)

      intent = agent_intent()
      envelope = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      plan =
        execution_plan(
          decision: envelope,
          execution_status: :confirmed,
          final_outcome: :confirmed,
          active: false
        )
        |> Bank.Repo.preload(:intent)

      assert {:ok, %Notification{} = n} = Emitter.emit_execution_outcome(plan)

      assert n.workspace_id == intent.workspace_id
      assert n.role_target == :operator
      assert n.event_type == "execution.confirmed"
      assert n.severity == :info
      assert n.subject_type == "execution_plan"
      assert n.subject_id == plan.id
      assert n.dedupe_key == "execution:#{plan.id}:confirmed"
      assert n.title =~ "confirmed"
      assert n.title =~ to_string(intent.kind)
    end

    test "re-emitting :confirmed for an opted-in workspace dedupes",
         %{workspace: ws} do
      {:ok, _} = Bank.Workspaces.set_notify_execution_confirmed(ws, true)

      intent = agent_intent()
      envelope = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      plan =
        execution_plan(
          decision: envelope,
          execution_status: :confirmed,
          final_outcome: :confirmed,
          active: false
        )
        |> Bank.Repo.preload(:intent)

      assert {:ok, %Notification{id: id}} = Emitter.emit_execution_outcome(plan)
      assert {:duplicate, %Notification{id: ^id}} = Emitter.emit_execution_outcome(plan)
    end

    test "skips non-terminal interim statuses (e.g. :broadcasting)" do
      intent = agent_intent()
      envelope = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      plan =
        execution_plan(
          decision: envelope,
          execution_status: :broadcasting,
          active: true
        )
        |> Bank.Repo.preload(:intent)

      assert {:skip, {:not_terminal, :broadcasting}} =
               Emitter.emit_execution_outcome(plan)
    end
  end

  describe "emit_execution_outcome/1 — dedupe" do
    test "re-emitting the same plan + same terminal outcome dedupes to one row" do
      intent = agent_intent()
      envelope = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      plan =
        execution_plan(
          decision: envelope,
          execution_status: :reverted,
          final_outcome: :reverted,
          active: false
        )
        |> Bank.Repo.preload(:intent)

      assert {:ok, %Notification{id: first_id}} = Emitter.emit_execution_outcome(plan)

      # A second emission for the exact same plan + terminal
      # status — the protective dedupe-key guard collapses it.
      assert {:duplicate, %Notification{id: ^first_id}} =
               Emitter.emit_execution_outcome(plan)

      assert [%Notification{id: ^first_id}] =
               Notifications.list_for_workspace(intent.workspace_id)
    end
  end

  describe "emit_execution_outcome/1 — workspace isolation" do
    test "an execution failure in workspace A does not list under workspace B" do
      intent_a = agent_intent()
      env_a = decision_envelope(intent: intent_a, outcome: :auto_exec, current: true)

      plan_a =
        execution_plan(
          decision: env_a,
          execution_status: :reverted,
          final_outcome: :reverted,
          active: false
        )
        |> Bank.Repo.preload(:intent)

      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "exec-iso-#{System.unique_integer([:positive])}",
          name: "Sibling exec",
          mainnet_enabled: true
        })

      intent_b = agent_intent(workspace_id: ws_b.id)
      env_b = decision_envelope(intent: intent_b, outcome: :auto_exec, current: true)

      plan_b =
        execution_plan(
          decision: env_b,
          execution_status: :aborted,
          final_outcome: :aborted,
          active: false,
          workspace_id: ws_b.id
        )
        |> Bank.Repo.preload(:intent)

      assert {:ok, _} = Emitter.emit_execution_outcome(plan_a)
      assert {:ok, _} = Emitter.emit_execution_outcome(plan_b)

      [n_a] = Notifications.list_for_workspace(intent_a.workspace_id)
      [n_b] = Notifications.list_for_workspace(ws_b.id)

      assert n_a.workspace_id == intent_a.workspace_id
      assert n_b.workspace_id == ws_b.id
      assert n_a.event_type == "execution.reverted"
      assert n_b.event_type == "execution.aborted"
    end
  end

  describe "emit_execution_outcome/1 — secret hygiene" do
    test "raw final_reason and tx_refs do not appear in the inbox payload" do
      intent = agent_intent()
      envelope = decision_envelope(intent: intent, outcome: :auto_exec, current: true)

      plan =
        execution_plan(
          decision: envelope,
          execution_status: :reverted,
          final_outcome: :reverted,
          # Both fields here are realistic regression probes —
          # operators / adapters do paste structured/free-text
          # values into them.
          final_reason: "Authorization: Bearer LEAKED_PROBE",
          tx_refs: ["0xLEAKED_TXREF_PROBE"],
          active: false
        )
        |> Bank.Repo.preload(:intent)

      assert {:ok, n} = Emitter.emit_execution_outcome(plan)

      refute n.title =~ "LEAKED_PROBE"
      refute n.body =~ "LEAKED_PROBE"
      refute (n.action_link || "") =~ "LEAKED_PROBE"
      refute n.title =~ "LEAKED_TXREF_PROBE"
      refute n.body =~ "LEAKED_TXREF_PROBE"
      refute (n.action_link || "") =~ "LEAKED_TXREF_PROBE"
      refute n.title =~ "Bearer"
      refute n.body =~ "Bearer"
    end
  end

  describe "emit_access_approved/1 — successful access approvals" do
    setup do
      suffix = System.unique_integer([:positive])

      {:ok, user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "approve-#{suffix}",
          email: "approve-#{suffix}@example.com",
          name: "Approve User"
        })

      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "access-approve-#{suffix}",
          name: "Access Approve #{suffix}",
          mainnet_enabled: true
        })

      {:ok, membership} =
        Bank.Workspaces.create_membership(%{
          user_id: user.id,
          workspace_id: ws.id,
          role: :operator
        })

      %{user: user, workspace: ws, membership: membership}
    end

    test "creates an :info notification for the newly admitted user",
         %{user: user, workspace: ws, membership: m} do
      assert {:ok, %Notification{} = n} = Emitter.emit_access_approved(m)

      assert n.workspace_id == ws.id
      assert n.user_id == user.id
      assert n.role_target == nil
      assert n.event_type == "access.approved"
      assert n.severity == :info
      assert n.subject_type == "membership"
      assert n.subject_id == m.id
      assert n.correlation_id == user.id
      assert n.action_link == "/dashboard"
      assert n.dedupe_key == "access:approved:#{user.id}:#{ws.id}"
      assert n.title =~ ws.slug
      assert n.body =~ to_string(m.role)
    end

    test "re-emitting the same membership returns {:duplicate, _} with one inbox row",
         %{workspace: ws, membership: m} do
      assert {:ok, %Notification{id: first_id}} = Emitter.emit_access_approved(m)
      assert {:duplicate, %Notification{id: ^first_id}} = Emitter.emit_access_approved(m)

      assert [%Notification{id: ^first_id}] = Notifications.list_for_workspace(ws.id)
    end

    test "skips when membership has no workspace_id" do
      partial = %Bank.Workspaces.Membership{
        id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        workspace_id: nil,
        role: :operator
      }

      assert {:skip, :no_workspace_id} = Emitter.emit_access_approved(partial)
    end

    test "skips when membership has no user_id" do
      partial = %Bank.Workspaces.Membership{
        id: Ecto.UUID.generate(),
        user_id: nil,
        workspace_id: Ecto.UUID.generate(),
        role: :operator
      }

      assert {:skip, :no_user_id} = Emitter.emit_access_approved(partial)
    end

    test "skips when the workspace was deleted out from under the membership" do
      detached = %Bank.Workspaces.Membership{
        id: Ecto.UUID.generate(),
        user_id: Ecto.UUID.generate(),
        workspace_id: Ecto.UUID.generate(),
        role: :operator
      }

      assert {:skip, :workspace_not_found} = Emitter.emit_access_approved(detached)
    end
  end

  describe "emit_access_rejected/1 — operator notification on rejection (#421)" do
    setup do
      suffix = System.unique_integer([:positive])

      {:ok, user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "rejected-#{suffix}",
          email: "rejected-#{suffix}@example.com",
          name: "Rejected User"
        })

      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "access-reject-#{suffix}",
          name: "Access Reject #{suffix}",
          mainnet_enabled: true
        })

      %{user: user, workspace: ws}
    end

    test "creates a :warning operator notification scoped to the invite workspace",
         %{user: user, workspace: ws} do
      actor_id = Ecto.UUID.generate()

      assert {:ok, %Notification{} = n} =
               Emitter.emit_access_rejected(%{
                 workspace_id: ws.id,
                 user: user,
                 actor_user_id: actor_id
               })

      assert n.workspace_id == ws.id
      assert n.role_target == :operator
      assert n.user_id == nil
      assert n.event_type == "access.rejected"
      assert n.severity == :warning
      assert n.subject_type == "user"
      assert n.subject_id == user.id
      assert n.correlation_id == user.id
      assert n.action_link == "/admin/access"
      assert n.dedupe_key == "access.rejected:#{user.id}"
      assert n.title =~ ws.slug
      assert n.title =~ "rejected"
    end

    test "re-emitting for the same user dedupes to one inbox row",
         %{user: user, workspace: ws} do
      assert {:ok, %Notification{id: first_id}} =
               Emitter.emit_access_rejected(%{workspace_id: ws.id, user: user})

      assert {:duplicate, %Notification{id: ^first_id}} =
               Emitter.emit_access_rejected(%{workspace_id: ws.id, user: user})

      assert [%Notification{id: ^first_id}] = Notifications.list_for_workspace(ws.id)
    end

    test "skips when workspace_id is missing", %{user: user} do
      assert {:skip, :no_workspace_id} = Emitter.emit_access_rejected(%{user: user})
    end

    test "skips when user is not a %User{} struct", %{workspace: ws} do
      assert {:skip, :no_user} =
               Emitter.emit_access_rejected(%{workspace_id: ws.id, user: nil})
    end

    test "skips when user has no id", %{workspace: ws} do
      partial = %Bank.Accounts.User{id: nil, email: "x@example.com"}

      assert {:skip, :no_user_id} =
               Emitter.emit_access_rejected(%{workspace_id: ws.id, user: partial})
    end

    test "skips when the workspace was deleted out from under the invite", %{user: user} do
      assert {:skip, :workspace_not_found} =
               Emitter.emit_access_rejected(%{
                 workspace_id: Ecto.UUID.generate(),
                 user: user
               })
    end

    test "skips on a non-map argument" do
      assert {:skip, :invalid_args} = Emitter.emit_access_rejected(:nope)
    end

    test "the rejected user's free-text email does NOT leak into the inbox payload",
         %{workspace: ws} do
      # A user whose name / email carries a Bearer-marker shape —
      # the emitter must never reflect that into the inbox.
      {:ok, leaky_user} =
        Bank.Accounts.find_or_create_from_oauth(%{
          provider: :google,
          subject: "leaky-#{System.unique_integer([:positive])}",
          email: "alice+authorization-bearer-leaked_probe@example.com",
          name: "Authorization Bearer LEAKED_PROBE"
        })

      assert {:ok, n} =
               Emitter.emit_access_rejected(%{workspace_id: ws.id, user: leaky_user})

      refute n.title =~ "LEAKED_PROBE"
      refute n.body =~ "LEAKED_PROBE"
      refute (n.action_link || "") =~ "LEAKED_PROBE"
      refute n.title =~ "Bearer"
      refute n.body =~ "Bearer"
      refute n.title =~ leaky_user.email
      refute n.body =~ leaky_user.email
      refute n.dedupe_key =~ "Bearer"
    end
  end

  describe "emit_pause_scope_paused/1 (#234)" do
    setup do
      suffix = System.unique_integer([:positive])

      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "pause-emit-#{suffix}",
          name: "Pause Emit #{suffix}"
        })

      {:ok, :paused, pause} =
        Bank.Security.Pauses.create_pause(ws.id, :chain, "base-sepolia",
          actor: :user,
          reason: "test pause"
        )

      %{workspace: ws, pause: pause}
    end

    test "the pause path itself emits the notification (integration)",
         %{workspace: ws, pause: pause} do
      [n] =
        Notifications.list_for_workspace(ws.id, event_type: "security.scope_paused")

      assert n.workspace_id == ws.id
      assert n.role_target == :operator
      assert n.severity == :warning
      assert n.subject_type == "pause"
      assert n.subject_id == pause.id
      assert n.correlation_id == pause.id
      assert n.action_link == "/security"
      assert n.dedupe_key == "pause:scope_paused:#{pause.id}"
      assert n.title =~ "chain:base-sepolia"
    end

    test "calling the emitter directly is idempotent on the same pause id",
         %{pause: pause} do
      # The integration path already inserted one row; re-emitting
      # collapses to {:duplicate, _} on the dedupe key.
      assert {:duplicate, _} = Emitter.emit_pause_scope_paused(pause)
    end

    test "skip when pause has no workspace_id" do
      partial = %Bank.Security.Pause{
        id: Ecto.UUID.generate(),
        workspace_id: nil,
        scope_type: :chain,
        scope_value: "base-sepolia"
      }

      assert {:skip, :no_workspace_id} = Emitter.emit_pause_scope_paused(partial)
    end

    test "skip when pause is not persisted (id is nil)" do
      partial = %Bank.Security.Pause{
        id: nil,
        workspace_id: Ecto.UUID.generate(),
        scope_type: :chain,
        scope_value: "base-sepolia"
      }

      assert {:skip, :pause_not_persisted} = Emitter.emit_pause_scope_paused(partial)
    end

    test "free-text reason is NOT threaded into the notification body",
         %{workspace: ws} do
      # A second workspace's pause carries a Bearer-marker reason —
      # the emitter must never reflect that into the inbox payload.
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "pause-leak-#{System.unique_integer([:positive])}",
          name: "Pause Leak"
        })

      {:ok, :paused, _pause} =
        Bank.Security.Pauses.create_pause(ws_b.id, :chain, "base-sepolia",
          actor: :user,
          reason: "Authorization: Bearer LEAKED_PROBE"
        )

      [n] =
        Notifications.list_for_workspace(ws_b.id, event_type: "security.scope_paused")

      refute n.title =~ "LEAKED_PROBE"
      refute n.body =~ "LEAKED_PROBE"
      refute n.body =~ "Bearer"
      refute n.body =~ "Authorization"
      # Other workspace untouched.
      assert length(Notifications.list_for_workspace(ws.id, event_type: "security.scope_paused")) ==
               1
    end
  end

  describe "emit_pause_scope_resumed/1 (#234)" do
    setup do
      suffix = System.unique_integer([:positive])

      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "resume-emit-#{suffix}",
          name: "Resume Emit #{suffix}"
        })

      {:ok, :paused, _pause} =
        Bank.Security.Pauses.create_pause(ws.id, :chain, "base-sepolia", actor: :user)

      {:ok, :resumed, resumed} =
        Bank.Security.Pauses.resume(ws.id, :chain, "base-sepolia", actor: :user)

      %{workspace: ws, pause: resumed}
    end

    test "the resume path itself emits an :info notification (integration)",
         %{workspace: ws, pause: pause} do
      [n] =
        Notifications.list_for_workspace(ws.id, event_type: "security.scope_resumed")

      assert n.workspace_id == ws.id
      assert n.role_target == :operator
      assert n.severity == :info
      assert n.subject_type == "pause"
      assert n.subject_id == pause.id
      assert n.action_link == "/security"
      assert n.dedupe_key == "pause:scope_resumed:#{pause.id}"
      assert n.title =~ "chain:base-sepolia"
    end

    test "scope_paused and scope_resumed have distinct dedupe keys",
         %{workspace: ws} do
      events =
        Notifications.list_for_workspace(ws.id, status: :all)
        |> Enum.map(& &1.event_type)
        |> Enum.sort()

      assert events == ["security.scope_paused", "security.scope_resumed"]
    end

    test "re-emit collapses to :duplicate on the same pause id",
         %{pause: pause} do
      assert {:duplicate, _} = Emitter.emit_pause_scope_resumed(pause)
    end

    test "skip when pause has no workspace_id" do
      partial = %Bank.Security.Pause{
        id: Ecto.UUID.generate(),
        workspace_id: nil,
        scope_type: :chain,
        scope_value: "base-sepolia"
      }

      assert {:skip, :no_workspace_id} = Emitter.emit_pause_scope_resumed(partial)
    end

    test "idempotent resume short-circuits BEFORE the emitter runs" do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "resume-noop-#{System.unique_integer([:positive])}",
          name: "Resume No-op"
        })

      # No pause to resume — the Pauses module returns
      # {:ok, :already_running} without emitting any audit event,
      # so the emitter must not run either (no inbox row).
      assert {:ok, :already_running} =
               Bank.Security.Pauses.resume(ws_b.id, :chain, "base-sepolia", actor: :user)

      assert Notifications.list_for_workspace(ws_b.id) == []
    end
  end

  describe "emit_decision_outcome/2 — secret hygiene" do
    test "no notification field reflects the intent's free-text fields" do
      # Realistic regression: operators paste secret-shaped values
      # into intent.notes (free text). The emitter must NEVER
      # surface that into the inbox payload.
      intent =
        agent_intent(notes: "Authorization: Bearer LEAKED_PROBE memo: 0xLEAKED_TOKEN")

      envelope = decision_envelope(intent: intent, outcome: :hold, risk_tier: :moderate)

      assert {:ok, n} = Emitter.emit_decision_outcome(intent, envelope)

      refute n.title =~ "LEAKED_PROBE"
      refute n.body =~ "LEAKED_PROBE"
      refute (n.action_link || "") =~ "LEAKED_PROBE"
      refute n.title =~ "LEAKED_TOKEN"
      refute n.body =~ "LEAKED_TOKEN"
      refute (n.action_link || "") =~ "LEAKED_TOKEN"
      refute n.title =~ "Bearer"
      refute n.body =~ "Bearer"
    end
  end
end
