defmodule Bank.Audit.EventsTest do
  use Bank.DataCase, async: true

  alias Bank.Audit
  alias Bank.Audit.Events
  alias Bank.Fixtures

  describe "intent_submitted/2" do
    test "builds an intent.submitted envelope with correlation_id = intent.id" do
      intent = Fixtures.agent_intent()
      attrs = Events.intent_submitted(intent)

      assert attrs.event_type == "intent.submitted"
      assert attrs.subject_type == "agent_intent"
      assert attrs.subject_id == intent.id
      assert attrs.correlation_id == intent.id
      assert attrs.actor == :agent
      assert is_map(attrs.after_ref)
      assert attrs.after_ref.id == intent.id
    end

    test "is writeable through Audit.append_event/1" do
      intent = Fixtures.agent_intent()
      {:ok, event} = Audit.append_event(Events.intent_submitted(intent))
      assert event.event_type == "intent.submitted"
      assert event.correlation_id == intent.id
    end
  end

  describe "intent_state_changed/4" do
    test "captures from/to in before_ref / after_ref" do
      intent = Fixtures.agent_intent()
      attrs = Events.intent_state_changed(intent, :submitted, :evaluating)
      assert attrs.before_ref == %{state: "submitted"}
      assert attrs.after_ref == %{state: "evaluating"}
      assert attrs.event_type == "intent.state_changed"
    end
  end

  describe "decision_decided/2" do
    test "subject is the envelope; correlation is the intent" do
      intent = Fixtures.agent_intent()
      envelope = Fixtures.decision_envelope(intent: intent, current: true)
      attrs = Events.decision_decided(envelope)

      assert attrs.event_type == "decision.decided"
      assert attrs.subject_type == "decision_envelope"
      assert attrs.subject_id == envelope.id
      assert attrs.correlation_id == intent.id
      assert attrs.after_ref.id == envelope.id
      assert attrs.after_ref.outcome == "auto_exec"
    end
  end

  describe "execution_transition/3" do
    test "names the event after the current status" do
      plan = Fixtures.execution_plan()

      attrs = Events.execution_transition(plan, :prepared)

      assert attrs.event_type == "execution.prepared"
      assert attrs.subject_type == "execution_plan"
      assert attrs.correlation_id == plan.intent_id
    end
  end

  describe "policy_revised/3" do
    test "correlation_id is the successor rule id" do
      prior = Fixtures.policy_rule(version: 1)
      successor = Fixtures.policy_rule(version: 2, supersedes_id: prior.id)

      attrs = Events.policy_revised(prior, successor, actor_id: "user-1")

      assert attrs.event_type == "policy.revised"
      assert attrs.subject_id == successor.id
      assert attrs.correlation_id == successor.id
      assert attrs.before_ref.version == 1
      assert attrs.after_ref.version == 2
    end
  end

  describe "security_scope_paused/2" do
    test "builds a security.scope_paused envelope keyed by chain + workspace_id" do
      pause =
        build_chain_pause(%{
          workspace_id: "ws-aaaa-1111",
          scope_value: "base",
          reason: "rpc outage",
          created_by_user_id: "user-1"
        })

      attrs = Events.security_scope_paused(pause, actor_id: "user-1")

      assert attrs.event_type == "security.scope_paused"
      assert attrs.subject_type == "chain"
      assert attrs.subject_id == "base"
      assert attrs.workspace_id == "ws-aaaa-1111"
      assert attrs.actor == :user
      assert attrs.actor_id == "user-1"
      assert is_nil(attrs.correlation_id)
      assert attrs.before_ref == %{paused_at: nil}

      assert attrs.after_ref == %{
               scope_type: "chain",
               scope_value: "base",
               paused_at: pause.paused_at,
               reason: "rpc outage",
               created_by_user_id: "user-1"
             }
    end

    test "non-user actor (e.g. :runtime) is preserved, not collapsed to :user" do
      pause =
        build_chain_pause(%{
          workspace_id: "ws-actor-runtime",
          scope_value: "base"
        })

      attrs = Events.security_scope_paused(pause, actor: :runtime)

      assert attrs.actor == :runtime
      # No actor_id supplied, no User struct — actor_id stays nil.
      assert is_nil(attrs.actor_id)
    end

    test "%User{} actor rolls up to :user with actor_id from the struct" do
      user = %Bank.Accounts.User{id: "user-from-struct"}

      pause =
        build_chain_pause(%{
          workspace_id: "ws-actor-user-struct",
          scope_value: "base"
        })

      attrs = Events.security_scope_paused(pause, actor: user)

      assert attrs.actor == :user
      assert attrs.actor_id == "user-from-struct"
    end

    test "after_ref carries no secret-bearing substrings (JSON-scan)" do
      pause =
        build_chain_pause(%{
          workspace_id: "ws-secrets",
          scope_value: "base",
          reason: "looks fine",
          created_by_user_id: "user-secrets"
        })

      attrs = Events.security_scope_paused(pause, actor_id: "user-secrets")
      json = Jason.encode!(attrs)

      for needle <- ["Bearer", "Authorization", "0x", "sk_", "pk_", "http"] do
        refute String.contains?(json, needle),
               "security.scope_paused envelope must not leak #{needle}: #{inspect(json)}"
      end
    end
  end

  describe "security_scope_resumed/3" do
    test "non-user actor (e.g. :adapter) is preserved" do
      pause =
        build_chain_pause(%{
          workspace_id: "ws-resume-actor",
          scope_value: "base",
          resumed_at: DateTime.utc_now()
        })

      attrs = Events.security_scope_resumed(pause, %{}, actor: :adapter)

      assert attrs.actor == :adapter
    end

    test "carries before_ref pause snapshot and after_ref resume marker" do
      pause =
        build_chain_pause(%{
          workspace_id: "ws-resume-1",
          scope_value: "optimism",
          resumed_at: DateTime.utc_now(),
          resumed_by_user_id: "user-resume"
        })

      prior = %{
        paused_at: pause.paused_at,
        reason: "old reason",
        created_by_user_id: "user-pause"
      }

      attrs = Events.security_scope_resumed(pause, prior, actor_id: "user-resume")

      assert attrs.event_type == "security.scope_resumed"
      assert attrs.subject_type == "chain"
      assert attrs.subject_id == "optimism"
      assert attrs.workspace_id == "ws-resume-1"
      assert attrs.before_ref.paused_at == pause.paused_at
      assert attrs.before_ref.reason == "old reason"
      assert attrs.before_ref.created_by_user_id == "user-pause"
      assert attrs.after_ref.scope_type == "chain"
      assert attrs.after_ref.scope_value == "optimism"
      assert attrs.after_ref.resumed_at == pause.resumed_at
      assert attrs.after_ref.resumed_by_user_id == "user-resume"
    end
  end

  describe "security_scope_expired/3" do
    test "actor is :runtime; before_ref carries pause snapshot incl. expires_at" do
      expires_at = DateTime.utc_now() |> DateTime.add(60, :second)

      pause =
        build_chain_pause(%{
          workspace_id: "ws-expired-1",
          scope_value: "base",
          resumed_at: expires_at,
          expires_at: expires_at
        })

      prior = %{
        paused_at: pause.paused_at,
        reason: "rpc outage",
        created_by_user_id: "user-paused",
        expires_at: expires_at
      }

      attrs = Events.security_scope_expired(pause, prior)

      assert attrs.event_type == "security.scope_expired"
      assert attrs.actor == :runtime
      assert is_nil(attrs.actor_id)
      assert attrs.subject_type == "chain"
      assert attrs.subject_id == "base"
      assert attrs.workspace_id == "ws-expired-1"
      assert attrs.before_ref.paused_at == pause.paused_at
      assert attrs.before_ref.reason == "rpc outage"
      assert attrs.before_ref.created_by_user_id == "user-paused"
      assert attrs.before_ref.expires_at == expires_at
      assert attrs.after_ref.scope_type == "chain"
      assert attrs.after_ref.scope_value == "base"
      assert attrs.after_ref.resumed_at == expires_at
      assert attrs.after_ref.expires_at == expires_at
    end
  end

  defp build_chain_pause(attrs) do
    base = %Bank.Security.Pause{
      id: Ecto.UUID.generate(),
      scope_type: :chain,
      scope_value: "base",
      paused_at: DateTime.utc_now()
    }

    Map.merge(base, attrs)
  end
end
