defmodule Bank.Fixtures do
  @moduledoc """
  Minimal fixture helpers for data-layer tests. Each helper builds a
  valid row of the given kind with optional overrides, so a test only
  has to spell out the attribute under test.

  ## Workspace scope (#158c)

  Helpers that target workspace-scoped tables (counterparties,
  policy_rules, agent_intents, delegations, execution_plans,
  audit_events) default `workspace_id` to the value
  `BankWeb.ConnCase.register_and_log_in_user/1` stashes in the
  process dictionary. Pass `:workspace_id` explicitly to override
  (e.g. for cross-workspace isolation tests). Pass
  `workspace_id: nil` to deliberately create a legacy unscoped row.
  """

  alias Bank.Audit.AuditEvent
  alias Bank.Counterparties.{AddressLabel, Counterparty, EvidenceArtifact, TrustAssertion}
  alias Bank.Decisions.{DecisionEnvelope, TrustAssessment, ExecutionPlan, SimulationReport}
  alias Bank.Delegations.Delegation
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.PolicyRule
  alias Bank.Repo
  alias Bank.SmartAccounts
  alias Bank.SmartAccounts.SmartAccount

  # Defaulted from `Process.get(:bank_test_workspace_id)`, which
  # `BankWeb.ConnCase.register_and_log_in_user/1` sets per test (#158c).
  # `nil` is the legacy default for tests that don't set up auth.
  defp default_workspace_id, do: Process.get(:bank_test_workspace_id)

  def counterparty(attrs \\ %{}) do
    attrs = to_map(attrs)

    {:ok, cp} =
      %Counterparty{}
      |> Counterparty.changeset(
        Map.merge(
          %{
            name: "Acme #{unique_int()}",
            created_by: :user,
            current_trust_level: :unknown,
            workspace_id: default_workspace_id()
          },
          attrs
        )
      )
      |> Repo.insert()

    cp
  end

  def address_label(attrs \\ %{}) do
    attrs = to_map(attrs)
    counterparty = Map.get_lazy(attrs, :counterparty, fn -> counterparty() end)

    attrs =
      attrs
      |> Map.delete(:counterparty)
      |> Map.put_new(:counterparty_id, counterparty.id)
      |> Map.put_new(:chain, "base")
      |> Map.put_new(:address, "0x#{random_hex(40)}")
      |> Map.put_new(:role, :payout)

    {:ok, label} =
      %AddressLabel{}
      |> AddressLabel.changeset(attrs)
      |> Repo.insert()

    label
  end

  def evidence_artifact(attrs \\ %{}) do
    attrs = to_map(attrs)
    subject = Map.get(attrs, :subject)

    {subject_type, subject_id} =
      case subject do
        %Counterparty{id: id} -> {"counterparty", id}
        %AddressLabel{id: id} -> {"address_label", id}
        nil -> {"counterparty", counterparty().id}
      end

    attrs =
      attrs
      |> Map.delete(:subject)
      |> Map.put_new(:subject_type, subject_type)
      |> Map.put_new(:subject_id, subject_id)
      |> Map.put_new(:kind, :user_note)
      |> Map.put_new(:content_uri, "mem://note-#{unique_int()}")
      |> Map.put_new(:payload_hash, random_hex(64))
      |> Map.put_new(:captured_at, monotonic_now())
      |> Map.put_new(:captured_by, :user)

    {:ok, artifact} =
      %EvidenceArtifact{}
      |> EvidenceArtifact.changeset(attrs)
      |> Repo.insert()

    artifact
  end

  def trust_assertion(attrs \\ %{}) do
    attrs = to_map(attrs)
    subject = Map.get(attrs, :subject)

    {subject_type, subject_id} =
      case subject do
        %Counterparty{id: id} -> {"counterparty", id}
        %AddressLabel{id: id} -> {"address_label", id}
        nil -> {"counterparty", counterparty().id}
      end

    attrs =
      attrs
      |> Map.delete(:subject)
      |> Map.put_new(:subject_type, subject_type)
      |> Map.put_new(:subject_id, subject_id)
      |> Map.put_new(:level, :unknown)
      |> Map.put_new(:issued_at, monotonic_now())
      |> Map.put_new(:issued_by, :runtime)

    {:ok, assertion} =
      %TrustAssertion{}
      |> TrustAssertion.changeset(attrs)
      |> Repo.insert()

    assertion
  end

  def policy_rule(attrs \\ %{}) do
    attrs =
      attrs
      |> to_map()
      |> Map.put_new(:rule_type, :amount_limit)
      |> Map.put_new(:params, %{"max" => "100"})
      |> Map.put_new(:created_by, :user)
      |> Map.put_new(:state, :active)
      |> Map.put_new(:workspace_id, default_workspace_id())

    {:ok, rule} =
      %PolicyRule{}
      |> PolicyRule.changeset(attrs)
      |> Repo.insert()

    rule
  end

  def agent_intent(attrs \\ %{}) do
    attrs = to_map(attrs)
    counterparty = Map.get_lazy(attrs, :counterparty, fn -> counterparty() end)

    attrs =
      attrs
      |> Map.delete(:counterparty)
      |> Map.put_new(:agent_id, "agent-#{unique_int()}")
      |> Map.put_new(:source, :agent)
      |> Map.put_new(:idempotency_key, "idem-#{unique_int()}")
      |> Map.put_new(:payload_hash, random_hex(64))
      |> Map.put_new(:kind, :transfer)
      |> Map.put_new(:asset, "USDC")
      |> Map.put_new(:chain, "base")
      |> Map.put_new(:amount, Decimal.new("10.5"))
      |> Map.put_new(:target_counterparty_id, counterparty.id)
      |> Map.put_new(:submitted_at, monotonic_now())
      |> Map.put_new(:workspace_id, default_workspace_id())

    {:ok, intent} =
      %AgentIntent{}
      |> AgentIntent.changeset(attrs)
      |> Repo.insert()

    intent
  end

  @doc """
  Insert a `Bank.SmartAccounts.SmartAccount` row (#183) for the
  current process workspace by default. Pass `workspace_id` to
  override; pass `:status` to land in a non-default lifecycle
  state. The address is fully unique per call so the
  `(workspace_id, chain, address)` index never collides between
  back-to-back fixtures.
  """
  def smart_account(attrs \\ %{}) do
    attrs = to_map(attrs)

    workspace_id = Map.get(attrs, :workspace_id) || default_workspace_id()

    attrs =
      attrs
      |> Map.put_new(:workspace_id, workspace_id)
      |> Map.put_new(:chain, "base")
      |> Map.put_new(:address, "0x" <> random_hex(40))

    {:ok, %SmartAccount{} = sa} = SmartAccounts.create_smart_account(attrs)

    sa
  end

  def trust_assessment(attrs \\ %{}) do
    attrs = to_map(attrs)
    intent = Map.get_lazy(attrs, :intent, fn -> agent_intent() end)

    attrs =
      attrs
      |> Map.delete(:intent)
      |> Map.put_new(:intent_id, intent.id)
      |> Map.put_new(:derived_trust, :unknown)
      |> Map.put_new(:confidence, :medium)
      |> Map.put_new(:generated_at, monotonic_now())
      |> Map.put_new(:generated_by, :runtime)

    {:ok, claim} =
      %TrustAssessment{}
      |> TrustAssessment.changeset(attrs)
      |> Repo.insert()

    claim
  end

  def simulation_report(attrs \\ %{}) do
    attrs = to_map(attrs)
    intent = Map.get_lazy(attrs, :intent, fn -> agent_intent() end)

    attrs =
      attrs
      |> Map.delete(:intent)
      |> Map.put_new(:intent_id, intent.id)
      |> Map.put_new(:provider, "tenderly")
      |> Map.put_new(:chain, "base")
      |> Map.put_new(:asset, "USDC")
      |> Map.put_new(:generated_at, monotonic_now())
      |> Map.put_new(:freshness_ttl_seconds, 30)
      |> Map.put_new(:status, :completed)

    {:ok, report} =
      %SimulationReport{}
      |> SimulationReport.changeset(attrs)
      |> Repo.insert()

    report
  end

  def decision_envelope(attrs \\ %{}) do
    attrs = to_map(attrs)
    intent = Map.get_lazy(attrs, :intent, fn -> agent_intent() end)

    attrs =
      attrs
      |> Map.delete(:intent)
      |> Map.put_new(:intent_id, intent.id)
      |> Map.put_new(:outcome, :auto_exec)
      |> Map.put_new(:risk_tier, :low)
      |> Map.put_new(:decided_at, monotonic_now())
      |> Map.put_new(:decided_by, :runtime)

    {:ok, envelope} =
      %DecisionEnvelope{}
      |> DecisionEnvelope.changeset(attrs)
      |> Repo.insert()

    envelope
  end

  def execution_plan(attrs \\ %{}) do
    attrs = to_map(attrs)
    decision = Map.get_lazy(attrs, :decision, fn -> decision_envelope() end)

    attrs =
      attrs
      |> Map.delete(:decision)
      |> Map.put_new(:decision_id, decision.id)
      |> Map.put_new(:intent_id, decision.intent_id)
      |> Map.put_new(:chain, "base")
      |> Map.put_new(:asset, "USDC")
      |> Map.put_new(:smart_account_id, "sa-#{unique_int()}")
      |> Map.put_new(:execution_status, :prepared)
      |> Map.put_new(:workspace_id, default_workspace_id())

    {:ok, plan} =
      %ExecutionPlan{}
      |> ExecutionPlan.changeset(attrs)
      |> Repo.insert()

    plan
  end

  def delegation(attrs \\ %{}) do
    attrs =
      attrs
      |> to_map()
      |> Map.put_new(:smart_account_id, "sa-#{unique_int()}")
      |> Map.put_new(:delegation_id, "del-#{unique_int()}")
      |> Map.put_new(:state, :active)
      |> Map.put_new(:chain, "base")
      |> Map.put_new(:granted_at, monotonic_now())
      |> Map.put_new(:workspace_id, default_workspace_id())

    {:ok, delegation} =
      %Delegation{}
      |> Delegation.changeset(attrs)
      |> Repo.insert()

    delegation
  end

  def audit_event(attrs \\ %{}) do
    attrs =
      attrs
      |> to_map()
      |> Map.put_new(:actor, :runtime)
      |> Map.put_new(:event_type, "intent.submitted")
      |> Map.put_new(:subject_type, "agent_intent")
      |> Map.put_new(:subject_id, Ecto.UUID.generate())
      |> Map.put_new(:payload_hash, random_hex(64))
      |> Map.put_new(:workspace_id, default_workspace_id())

    {:ok, event} =
      %AuditEvent{}
      |> AuditEvent.changeset(attrs)
      |> Repo.insert()

    event
  end

  # Accept keyword-list or map inputs uniformly — tests are idiomatic
  # when they pass `name: "x"` rather than `%{name: "x"}`.
  defp to_map(attrs) when is_map(attrs), do: attrs
  defp to_map(attrs) when is_list(attrs), do: Map.new(attrs)

  defp unique_int, do: System.unique_integer([:positive])

  # Strictly-monotonic DateTime helper for domain timestamp fields
  # (`generated_at`, `decided_at`, `captured_at`, `submitted_at`). Two
  # fixtures created back-to-back are guaranteed distinct even when DB
  # `inserted_at` rounds to the same microsecond, so replay ordering
  # tests stay deterministic without forcing `Process.sleep/1`.
  defp monotonic_now do
    offset = System.unique_integer([:monotonic, :positive])
    DateTime.add(DateTime.utc_now(), offset, :microsecond)
  end

  defp random_hex(n) do
    :crypto.strong_rand_bytes(div(n, 2))
    |> Base.encode16(case: :lower)
  end
end
