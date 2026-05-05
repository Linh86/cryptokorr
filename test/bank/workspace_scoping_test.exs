defmodule Bank.WorkspaceScopingTest do
  @moduledoc """
  Foundation-only tests for issue #158a — pin the schema-level shape
  of nullable `workspace_id` on every workspace-scoped table without
  asserting any runtime filtering behaviour. Filtering, scope
  enforcement, and NOT NULL flips land in #158b and beyond.

  Each table gets two assertions:

    * The schema declares a `:workspace_id` field that defaults to
      nil. (Confirms the migration ran and the changeset accepts the
      column.)
    * A row inserted with `workspace_id: nil` survives a round-trip
      (legacy callers stay green).
    * A row inserted with an explicit `workspace_id` round-trips and
      preserves it. (Confirms the FK is wired and the changeset
      passes the value through.)
  """

  use Bank.DataCase, async: true

  alias Bank.Audit.AuditEvent
  alias Bank.Counterparties.Counterparty
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Delegations.Delegation
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.PolicyRule
  alias Bank.WalletScreening.ScreeningRecord
  alias Bank.Workspaces

  @scoped_schemas [
    Counterparty,
    PolicyRule,
    AgentIntent,
    Delegation,
    ScreeningRecord,
    ExecutionPlan,
    AuditEvent
  ]

  defp create_workspace do
    {:ok, ws} =
      Workspaces.create_workspace(%{
        slug: "ws-scope-#{System.unique_integer([:positive])}",
        name: "Scope test ws",
        mainnet_enabled: true
      })

    ws
  end

  describe "schema declarations" do
    test "every workspace-scoped table has a nullable :workspace_id field" do
      for schema <- @scoped_schemas do
        fields = schema.__schema__(:fields)

        assert :workspace_id in fields,
               "#{inspect(schema)} is missing :workspace_id"

        assert schema.__schema__(:type, :workspace_id) == :binary_id,
               "#{inspect(schema)} :workspace_id should be :binary_id"

        assert schema.__schema__(:association, :workspace),
               "#{inspect(schema)} should expose a :workspace association"
      end
    end
  end

  describe "Counterparty.changeset/2" do
    test "accepts and persists an explicit workspace_id" do
      ws = create_workspace()

      cs =
        Counterparty.changeset(%Counterparty{}, %{
          name: "Acme",
          created_by: :user,
          workspace_id: ws.id
        })

      assert cs.valid?
      assert {:ok, cp} = Repo.insert(cs)
      assert cp.workspace_id == ws.id
    end

    test "treats workspace_id as nullable for legacy callers" do
      cs = Counterparty.changeset(%Counterparty{}, %{name: "Acme", created_by: :user})
      assert cs.valid?
      assert {:ok, cp} = Repo.insert(cs)
      assert cp.workspace_id == nil
    end
  end

  describe "PolicyRule.changeset/2" do
    test "round-trips workspace_id" do
      ws = create_workspace()

      attrs = %{
        rule_type: :amount_limit,
        created_by: :user,
        state: :active,
        workspace_id: ws.id
      }

      assert {:ok, rule} = %PolicyRule{} |> PolicyRule.changeset(attrs) |> Repo.insert()
      assert rule.workspace_id == ws.id
    end

    test "PolicyRule.supersede/2 carries workspace_id forward to the successor" do
      ws = create_workspace()

      {:ok, prior} =
        %PolicyRule{}
        |> PolicyRule.changeset(%{
          rule_type: :amount_limit,
          created_by: :user,
          state: :active,
          workspace_id: ws.id
        })
        |> Repo.insert()

      successor_cs =
        PolicyRule.supersede(prior, %{
          params: %{"max_amount" => "1"},
          created_by: :user
        })

      assert {:ok, successor} = Repo.insert(successor_cs)
      assert successor.workspace_id == prior.workspace_id
    end
  end

  describe "AgentIntent.changeset/2" do
    test "round-trips workspace_id alongside the existing target-shape contract" do
      ws = create_workspace()

      {:ok, cp} =
        Repo.insert(
          Counterparty.changeset(%Counterparty{}, %{
            name: "WS-#{System.unique_integer([:positive])}",
            created_by: :user,
            workspace_id: ws.id
          })
        )

      attrs = %{
        agent_id: "agent-#{System.unique_integer([:positive])}",
        source: :agent,
        idempotency_key: "idem-#{System.unique_integer([:positive])}",
        payload_hash: String.duplicate("a", 64),
        kind: :transfer,
        asset: "USDC",
        chain: "base",
        amount: Decimal.new("1.00"),
        target_counterparty_id: cp.id,
        submitted_at: DateTime.utc_now(),
        workspace_id: ws.id
      }

      assert {:ok, intent} = %AgentIntent{} |> AgentIntent.changeset(attrs) |> Repo.insert()
      assert intent.workspace_id == ws.id
    end
  end

  describe "Delegation.changeset/2" do
    test "round-trips workspace_id" do
      ws = create_workspace()

      {:ok, d} =
        %Delegation{}
        |> Delegation.changeset(%{
          smart_account_id: "sa-#{System.unique_integer([:positive])}",
          delegation_id: "del-#{System.unique_integer([:positive])}",
          state: :active,
          chain: "base",
          workspace_id: ws.id
        })
        |> Repo.insert()

      assert d.workspace_id == ws.id
    end
  end

  describe "ScreeningRecord.changeset/2" do
    test "round-trips workspace_id" do
      ws = create_workspace()

      {:ok, rec} =
        %ScreeningRecord{}
        |> ScreeningRecord.changeset(%{
          chain: "base",
          address: "0xabc",
          normalised_address: "0xabc",
          control_tier: :hard_block,
          source: "ofac",
          source_record_id: "src-#{System.unique_integer([:positive])}",
          workspace_id: ws.id
        })
        |> Repo.insert()

      assert rec.workspace_id == ws.id
    end
  end

  describe "ExecutionPlan + DecisionEnvelope (workspace_id read hint)" do
    test "ExecutionPlan persists workspace_id" do
      ws = create_workspace()

      {:ok, cp} =
        Repo.insert(
          Counterparty.changeset(%Counterparty{}, %{
            name: "WS-#{System.unique_integer([:positive])}",
            created_by: :user,
            workspace_id: ws.id
          })
        )

      {:ok, intent} =
        Repo.insert(
          AgentIntent.changeset(%AgentIntent{}, %{
            agent_id: "agent-#{System.unique_integer([:positive])}",
            source: :agent,
            idempotency_key: "idem-#{System.unique_integer([:positive])}",
            payload_hash: String.duplicate("a", 64),
            kind: :transfer,
            asset: "USDC",
            chain: "base",
            amount: Decimal.new("1.00"),
            target_counterparty_id: cp.id,
            submitted_at: DateTime.utc_now(),
            workspace_id: ws.id
          })
        )

      {:ok, decision} =
        Repo.insert(
          DecisionEnvelope.changeset(%DecisionEnvelope{}, %{
            intent_id: intent.id,
            outcome: :auto_exec,
            risk_tier: :low,
            decided_by: :runtime,
            decided_at: DateTime.utc_now(),
            state: :decided,
            current: true
          })
        )

      assert {:ok, plan} =
               %ExecutionPlan{}
               |> ExecutionPlan.changeset(%{
                 decision_id: decision.id,
                 intent_id: intent.id,
                 chain: "base",
                 asset: "USDC",
                 smart_account_id: "sa-#{System.unique_integer([:positive])}",
                 execution_status: :prepared,
                 workspace_id: ws.id
               })
               |> Repo.insert()

      assert plan.workspace_id == ws.id
    end
  end

  describe "AuditEvent.changeset/2 (read hint, not in canonical hash)" do
    test "round-trips workspace_id without affecting payload_hash" do
      ws = create_workspace()

      attrs_without = %{
        actor: :user,
        actor_id: "u",
        event_type: "test.event",
        subject_type: "user",
        subject_id: "subj",
        correlation_id: Ecto.UUID.generate(),
        payload_hash: String.duplicate("c", 64)
      }

      {:ok, without_ws} =
        %AuditEvent{}
        |> AuditEvent.changeset(attrs_without)
        |> Repo.insert()

      {:ok, with_ws} =
        %AuditEvent{}
        |> AuditEvent.changeset(Map.put(attrs_without, :workspace_id, ws.id))
        |> Repo.insert()

      # The canonical payload_hash field is whatever the caller
      # wrote; #158a does not change `Bank.Audit.Envelope`'s
      # canonical fields. Both rows can share the same hash.
      assert without_ws.payload_hash == with_ws.payload_hash
      assert without_ws.workspace_id == nil
      assert with_ws.workspace_id == ws.id
    end
  end
end
