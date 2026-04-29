defmodule Bank.Demo do
  @moduledoc """
  Seeded demo dataset and reset helpers for the local sandbox mode.

  The alpha and design-partner sessions reuse a curated set of
  counterparties, policies, delegations, and historical intents so
  operators always know what "healthy baseline" looks like. This
  module owns both halves of that workflow:

    * `seed/0` — idempotent population. Safe to run repeatedly; the
      upsert keys are `Counterparty.name`, `(chain, address)` for
      labels, `(agent_id, idempotency_key)` for intents, and the
      `(rule_type, priority)` combo for policy rules.
    * `reset/1` — scoped delete of every row this module created
      (matched by stable demo identifiers — `[Sandbox]` counterparty
      names, `sandbox-demo-*` agent ids, `sa_demo_01` smart account,
      and the exact policy-rule specs the seeder produces) followed
      by `seed/0`. Guarded behind a hard-coded env allowlist plus an
      explicit `confirm: true` flag. Non-demo rows in the same tables
      are not touched.

  The corresponding Mix tasks (`mix bank.demo.seed`,
  `mix bank.demo.reset`) live in `lib/mix/tasks/`.

  ## Visibly fake / test-only

  All counterparty names carry a `[Sandbox]` prefix, addresses use
  the obvious `0x111…1` / `0x222…2` test pattern, and the smart
  account / delegation / agent identifiers are explicit `*_demo_*` /
  `sandbox-demo-*` strings. There are no real private keys, API
  keys, bearer tokens, or environment-sourced URLs anywhere in the
  seeded data — the test suite asserts that on every row the seeder
  produces.

  ## Workspace placeholder (#155)

  Until issue #155 lands the `workspaces` / `memberships` tables,
  every seeded row is implicitly scoped to `workspace_slug/0` —
  `"sandbox-demo"`. Each `seed_*` / `upsert_*` helper carries a
  `# TODO #155` marker pointing at the exact line where
  `workspace_id:` will need to be set on the changeset.

  See `docs/demo.md` for the operator-facing instructions.
  """

  require Logger

  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Counterparties.{AddressLabel, Counterparty, EvidenceArtifact, TrustAssertion}
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan, SimulationReport, TrustAssessment}
  alias Bank.Delegations.Delegation
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.PolicyRule
  alias Bank.Repo

  @demo_workspace_slug "sandbox-demo"
  @sandbox_prefix "[Sandbox] "
  @smart_account_id "sa_demo_01"
  @delegation_id "del_demo_01"
  @demo_agent_id "sandbox-demo-agent"
  # Carried so a reset can clean rows from earlier seed versions that
  # used the unprefixed `demo-agent` / bare counterparty names. New
  # writes always use the [Sandbox]-prefixed form.
  @legacy_demo_agent_id "demo-agent"
  @legacy_counterparty_names [
    "Payroll Provider",
    "Treasury Ops",
    "New Partner X",
    "Unverified Recipient"
  ]
  @chain "base"
  @asset "USDC"

  # Environments where `reset/1` is allowed to delete. Prod is never
  # on this list — resetting a demo dataset should never be something
  # an operator can do against production data.
  @reset_envs [:dev, :test, :staging]

  @doc """
  The placeholder workspace slug every seeded row is implicitly scoped
  to until issue #155 ships the `workspaces` table. Human-readable so
  operator dashboards, audit trails, and `mix bank.demo.reset` output
  can refer to the same handle.
  """
  @spec workspace_slug() :: String.t()
  def workspace_slug, do: @demo_workspace_slug

  @doc """
  Populate the demo dataset. Idempotent: running it twice leaves the
  database in the same shape as running it once.
  """
  @spec seed() :: :ok
  def seed do
    Logger.info("Bank.Demo: seeding demo dataset (workspace=#{@demo_workspace_slug})")

    Repo.transaction(fn ->
      counterparties = seed_counterparties()
      _labels = seed_address_labels(counterparties)
      _rules = seed_policy_rules()
      _delegation = seed_delegation()
      _intents = seed_intents(counterparties)
      :ok
    end)

    :ok
  end

  @doc """
  Delete every row this module created and re-seed. Guarded by env +
  confirm flag. Unlike a `TRUNCATE`, this only removes rows matching
  the demo identifiers — non-demo rows in the same tables (staging
  fixtures, partner test data) are preserved.

  ## Example

      Bank.Demo.reset(env: :staging, confirm: true)
  """
  @spec reset(keyword()) :: :ok | {:error, term()}
  def reset(opts \\ []) do
    env = Keyword.get(opts, :env, runtime_env())
    confirm? = Keyword.get(opts, :confirm, false)

    cond do
      env not in @reset_envs ->
        {:error, {:reset_not_allowed, env}}

      not confirm? ->
        {:error, :confirmation_required}

      true ->
        Logger.warning("Bank.Demo: resetting demo dataset in #{inspect(env)}")
        delete_demo_owned()
        seed()
        :ok
    end
  end

  @doc """
  The list of tables this module touches. Exposed so the reset Mix
  task can print the list in its dry-run output. Reset only deletes
  rows matching the demo identifiers — non-demo rows in the same
  tables are not touched.
  """
  @spec owned_tables() :: [String.t()]
  def owned_tables do
    ~w(
      audit_events
      execution_plans
      decision_envelopes
      trust_assessments
      simulation_reports
      agent_intents
      address_labels
      counterparties
      policy_rules
      delegations
    )
  end

  @doc """
  Returns the canonical demo identifiers (workspace slug, agent ids,
  smart-account / delegation ids, counterparty names) so tests and
  operator tooling can assert on the exact set this module owns.
  Includes both the current `[Sandbox]`-prefixed counterparty names
  and the legacy unprefixed ones the reset path is expected to clean
  up.
  """
  @spec identifiers() :: %{
          required(:workspace_slug) => String.t(),
          required(:agent_ids) => [String.t()],
          required(:smart_account_id) => String.t(),
          required(:delegation_id) => String.t(),
          required(:counterparty_names) => [String.t()],
          required(:legacy_counterparty_names) => [String.t()]
        }
  def identifiers do
    %{
      workspace_slug: @demo_workspace_slug,
      agent_ids: [@demo_agent_id, @legacy_demo_agent_id],
      smart_account_id: @smart_account_id,
      delegation_id: @delegation_id,
      counterparty_names: Enum.map(counterparty_specs(), & &1.name),
      legacy_counterparty_names: @legacy_counterparty_names
    }
  end

  # --- Counterparties ----------------------------------------------------

  defp counterparty_specs do
    [
      %{
        key: "payroll",
        name: @sandbox_prefix <> "Payroll Provider",
        trust: :trusted,
        note: sandbox_note("Monthly payroll rails — pre-approved recurring transfers.")
      },
      %{
        key: "treasury",
        name: @sandbox_prefix <> "Treasury Ops",
        trust: :trusted,
        note: sandbox_note("Internal treasury movement account.")
      },
      %{
        key: "partner_x",
        name: @sandbox_prefix <> "New Partner X",
        trust: :sensitive,
        note: sandbox_note("Recent onboarding — elevated review for first 30 days.")
      },
      %{
        key: "unverified",
        name: @sandbox_prefix <> "Unverified Recipient",
        trust: :unknown,
        note: sandbox_note("Address encountered without counterparty match.")
      }
    ]
  end

  defp sandbox_note(detail) do
    "[#{@demo_workspace_slug}] #{detail} Test-only — do not transact against this record."
  end

  defp seed_counterparties do
    counterparty_specs()
    |> Enum.map(fn spec ->
      {:ok, cp} = upsert_counterparty(spec)
      {spec.key, cp}
    end)
    |> Map.new()
  end

  defp upsert_counterparty(%{name: name, trust: trust, note: note}) do
    case Repo.get_by(Counterparty, name: name) do
      %Counterparty{} = cp ->
        {:ok, cp}

      nil ->
        # TODO #155: set workspace_id once the `workspaces` schema lands.
        %Counterparty{}
        |> Counterparty.changeset(%{
          name: name,
          created_by: :user,
          current_trust_level: trust,
          notes: note
        })
        |> Repo.insert()
    end
  end

  # --- Address labels ----------------------------------------------------

  defp seed_address_labels(counterparties) do
    [
      {"payroll", "0x1111111111111111111111111111111111111111", :payout, true},
      {"treasury", "0x2222222222222222222222222222222222222222", :funding, true},
      {"partner_x", "0x3333333333333333333333333333333333333333", :payout, false},
      {"unverified", "0x4444444444444444444444444444444444444444", :other, false}
    ]
    |> Enum.map(fn {key, address, role, verified} ->
      counterparty = Map.fetch!(counterparties, key)
      upsert_address_label(counterparty, address, role, verified)
    end)
  end

  defp upsert_address_label(counterparty, address, role, verified) do
    existing =
      Repo.one(
        from l in AddressLabel,
          where:
            l.counterparty_id == ^counterparty.id and
              l.chain == ^@chain and
              l.address == ^address and
              is_nil(l.retired_at),
          limit: 1
      )

    case existing do
      %AddressLabel{} = label ->
        {:ok, label}

      nil ->
        # TODO #155: scope to the demo workspace.
        %AddressLabel{}
        |> AddressLabel.changeset(%{
          counterparty_id: counterparty.id,
          chain: @chain,
          address: address,
          role: role,
          verified: verified
        })
        |> Repo.insert()
    end
  end

  # --- Policy rules ------------------------------------------------------

  defp policy_rule_specs do
    [
      %{
        rule_type: :amount_limit,
        priority: 10,
        scope: %{"asset" => @asset, "chain" => @chain},
        params: %{"max_amount" => "10000"}
      },
      %{
        rule_type: :allowed_chain,
        priority: 20,
        scope: %{},
        params: %{"chains" => [@chain]}
      },
      %{
        rule_type: :allowed_asset,
        priority: 30,
        scope: %{},
        params: %{"assets" => [@asset]}
      },
      %{
        rule_type: :autonomy_tier,
        priority: 40,
        scope: %{},
        params: %{"tier" => "guarded"}
      }
    ]
  end

  defp seed_policy_rules do
    Enum.map(policy_rule_specs(), &upsert_policy_rule/1)
  end

  defp upsert_policy_rule(%{rule_type: rt, priority: prio} = attrs) do
    existing =
      Repo.one(
        from r in PolicyRule,
          where: r.rule_type == ^rt and r.priority == ^prio and r.state == :active,
          limit: 1
      )

    case existing do
      %PolicyRule{} = rule ->
        {:ok, rule}

      nil ->
        # TODO #155: scope to the demo workspace once policy rules
        # gain a `workspace_id` column.
        %PolicyRule{}
        |> PolicyRule.changeset(
          attrs
          |> Map.put(:state, :active)
          |> Map.put(:created_by, :user)
        )
        |> Repo.insert()
    end
  end

  # --- Delegation --------------------------------------------------------

  defp seed_delegation do
    case Repo.get_by(Delegation, smart_account_id: @smart_account_id) do
      %Delegation{} = d ->
        {:ok, d}

      nil ->
        # TODO #155: attach to the demo workspace.
        %Delegation{}
        |> Delegation.changeset(%{
          smart_account_id: @smart_account_id,
          delegation_id: @delegation_id,
          state: :active,
          chain: @chain,
          granted_at: DateTime.utc_now()
        })
        |> Repo.insert()
    end
  end

  # --- Intents + decisions + plans + audit ------------------------------

  defp seed_intents(counterparties) do
    # Covers every intent state the runtime produces: submitted,
    # decided (auto_exec / approval_required / hold), executing,
    # executed, blocked, cancelled. Each scenario's `phase` selects
    # which rows get created — only `:planned` scenarios produce an
    # `ExecutionPlan`.
    Enum.map(intent_scenarios(), &build_scenario(&1, counterparties))
  end

  defp intent_scenarios do
    [
      %{
        name: "submitted-fresh",
        counterparty: "payroll",
        amount: Decimal.new("75"),
        phase: :submitted,
        intent_state: :submitted
      },
      %{
        name: "decided-pending-exec",
        counterparty: "payroll",
        amount: Decimal.new("125"),
        phase: :decided,
        decision_outcome: :auto_exec,
        intent_state: :decided
      },
      %{
        name: "payroll-confirmed",
        counterparty: "payroll",
        amount: Decimal.new("250"),
        phase: :planned,
        decision_outcome: :auto_exec,
        intent_state: :executed,
        execution_status: :confirmed,
        final_status: :confirmed,
        tx_hash: "0xabc111...sandbox-payroll"
      },
      %{
        name: "partner-x-pending-approval",
        counterparty: "partner_x",
        amount: Decimal.new("1500"),
        phase: :decided,
        decision_outcome: :approval_required,
        intent_state: :decided
      },
      %{
        name: "partner-x-approved",
        counterparty: "partner_x",
        amount: Decimal.new("1000"),
        phase: :planned,
        decision_outcome: :approval_required,
        intent_state: :executed,
        execution_status: :confirmed,
        final_status: :confirmed,
        tx_hash: "0xabc222...sandbox-partner"
      },
      %{
        name: "treasury-held",
        counterparty: "treasury",
        amount: Decimal.new("400"),
        phase: :decided,
        decision_outcome: :hold,
        intent_state: :decided
      },
      %{
        name: "treasury-executing",
        counterparty: "treasury",
        amount: Decimal.new("100"),
        phase: :planned,
        decision_outcome: :auto_exec,
        intent_state: :executing,
        execution_status: :broadcasting,
        final_status: nil,
        tx_hash: nil
      },
      %{
        name: "unknown-blocked",
        counterparty: "unverified",
        amount: Decimal.new("500"),
        phase: :blocked,
        intent_state: :blocked
      },
      %{
        name: "cancelled-pre-decision",
        counterparty: "payroll",
        amount: Decimal.new("60"),
        phase: :cancelled,
        intent_state: :cancelled
      }
    ]
  end

  defp build_scenario(scenario, counterparties) do
    counterparty = Map.fetch!(counterparties, scenario.counterparty)
    label = primary_label(counterparty)

    idempotency = "sandbox-" <> scenario.name

    {:ok, intent} = upsert_intent(scenario, counterparty, label, idempotency)

    case scenario.phase do
      :submitted ->
        emit_submitted_audit(intent)
        %{intent: intent, decision: nil, plan: nil}

      :cancelled ->
        emit_cancelled_audit(intent)
        %{intent: intent, decision: nil, plan: nil}

      :blocked ->
        {:ok, decision} = upsert_decision(intent, :block, :severe)
        emit_audit(intent, decision, scenario)
        %{intent: intent, decision: decision, plan: nil}

      :decided ->
        {:ok, decision} =
          upsert_decision(
            intent,
            scenario.decision_outcome,
            decision_risk(scenario.decision_outcome)
          )

        emit_audit(intent, decision, scenario)
        %{intent: intent, decision: decision, plan: nil}

      :planned ->
        {:ok, decision} =
          upsert_decision(
            intent,
            scenario.decision_outcome,
            decision_risk(scenario.decision_outcome)
          )

        {:ok, plan} = upsert_plan(decision, intent, scenario.execution_status, scenario)
        emit_audit(intent, decision, scenario, plan)
        %{intent: intent, decision: decision, plan: plan}
    end
  end

  defp primary_label(counterparty) do
    Repo.one(
      from l in AddressLabel,
        where: l.counterparty_id == ^counterparty.id and is_nil(l.retired_at),
        limit: 1
    )
  end

  defp upsert_intent(scenario, counterparty, label, idempotency) do
    case Repo.get_by(AgentIntent, agent_id: @demo_agent_id, idempotency_key: idempotency) do
      %AgentIntent{} = intent ->
        {:ok, intent}

      nil ->
        # TODO #155: scope to the demo workspace.
        %AgentIntent{}
        |> AgentIntent.changeset(%{
          agent_id: @demo_agent_id,
          source: :agent,
          idempotency_key: idempotency,
          payload_hash: :crypto.hash(:sha256, idempotency) |> Base.encode16(case: :lower),
          kind: :transfer,
          asset: @asset,
          chain: @chain,
          amount: scenario.amount,
          target_counterparty_id: counterparty.id,
          target_address_label_id: label && label.id,
          submitted_at: DateTime.utc_now(),
          state: scenario.intent_state
        })
        |> Repo.insert()
    end
  end

  defp decision_risk(:auto_exec), do: :low
  defp decision_risk(:approval_required), do: :elevated
  defp decision_risk(:hold), do: :moderate
  defp decision_risk(_), do: :moderate

  defp upsert_decision(intent, outcome, risk_tier) do
    case Repo.get_by(DecisionEnvelope, intent_id: intent.id, current: true) do
      %DecisionEnvelope{} = d ->
        {:ok, d}

      nil ->
        # TODO #155: scope to the demo workspace.
        %DecisionEnvelope{}
        |> DecisionEnvelope.changeset(%{
          intent_id: intent.id,
          outcome: outcome,
          risk_tier: risk_tier,
          decided_at: DateTime.utc_now(),
          decided_by: :runtime,
          state: :decided,
          current: true,
          approval_expires_at:
            if(outcome == :approval_required,
              do: DateTime.utc_now() |> DateTime.add(3600, :second),
              else: nil
            )
        })
        |> Repo.insert()
    end
  end

  defp upsert_plan(decision, intent, status, scenario) do
    case Repo.one(
           from p in ExecutionPlan,
             where: p.decision_id == ^decision.id and p.active == true,
             limit: 1
         ) do
      %ExecutionPlan{} = plan ->
        {:ok, plan}

      nil ->
        # TODO #155: scope to the demo workspace.
        %ExecutionPlan{}
        |> ExecutionPlan.changeset(%{
          decision_id: decision.id,
          intent_id: intent.id,
          chain: @chain,
          asset: @asset,
          smart_account_id: @smart_account_id,
          execution_status: status,
          signing_requirements: %{"delegation_id" => @delegation_id, "scope" => %{}},
          tx_refs: if(scenario.tx_hash, do: [scenario.tx_hash], else: []),
          final_outcome: scenario.final_status,
          final_reason: if(scenario.final_status == :confirmed, do: "sandbox_seed", else: nil)
        })
        |> Repo.insert()
    end
  end

  defp emit_submitted_audit(intent) do
    insert_audit_event(%{
      correlation_id: intent.id,
      ts: DateTime.utc_now(),
      actor: :agent,
      actor_id: intent.agent_id,
      subject_type: "agent_intent",
      subject_id: intent.id,
      schema_version: "1",
      event_type: "intent.submitted",
      payload_hash: intent.payload_hash
    })
  end

  defp emit_cancelled_audit(intent) do
    emit_submitted_audit(intent)

    insert_audit_event(%{
      correlation_id: intent.id,
      ts: DateTime.utc_now(),
      actor: :user,
      actor_id: intent.agent_id,
      subject_type: "agent_intent",
      subject_id: intent.id,
      schema_version: "1",
      event_type: "intent.cancelled",
      payload_hash: :crypto.hash(:sha256, "cancel:" <> intent.id) |> Base.encode16(case: :lower)
    })
  end

  defp emit_audit(intent, decision, scenario, plan \\ nil) do
    base = %{
      correlation_id: intent.id,
      ts: DateTime.utc_now(),
      actor: :agent,
      actor_id: intent.agent_id,
      subject_type: "agent_intent",
      subject_id: intent.id,
      schema_version: "1"
    }

    events = [
      Map.merge(base, %{
        event_type: "intent.submitted",
        payload_hash: intent.payload_hash
      }),
      Map.merge(base, %{
        event_type: "decision.recorded",
        subject_type: "decision_envelope",
        subject_id: decision.id,
        actor: :runtime,
        actor_id: nil,
        payload_hash:
          :crypto.hash(:sha256, "decision:" <> intent.id)
          |> Base.encode16(case: :lower)
      })
    ]

    events =
      if plan do
        events ++
          [
            Map.merge(base, %{
              event_type: "execution.#{scenario.final_status || "progressed"}",
              subject_type: "execution_plan",
              subject_id: plan.id,
              actor: :adapter,
              actor_id: nil,
              payload_hash:
                :crypto.hash(:sha256, "plan:" <> plan.id) |> Base.encode16(case: :lower)
            })
          ]
      else
        events
      end

    Enum.each(events, &insert_audit_event/1)
  end

  defp insert_audit_event(attrs) do
    existing =
      Repo.one(
        from e in AuditEvent,
          where:
            e.correlation_id == ^attrs.correlation_id and
              e.subject_id == ^attrs.subject_id and
              e.event_type == ^attrs.event_type,
          limit: 1
      )

    if is_nil(existing) do
      %AuditEvent{}
      |> AuditEvent.changeset(attrs)
      |> Repo.insert!()
    end
  end

  # --- Scoped reset ------------------------------------------------------

  # Targeted delete that only removes rows matching the demo
  # identifiers — not a TRUNCATE. Non-demo rows in the same tables
  # (staging fixtures, partner test data, etc.) are preserved.
  #
  # `audit_events` is intentionally NOT touched here. The table is
  # append-only at the DB layer (a `BEFORE DELETE` trigger raises
  # `read_only_sql_transaction`, see migration #170600), and the
  # whole point of audit is that history isn't rewriteable. Demo
  # audit rows tied to deleted intents become orphans (correlation
  # ids that no longer resolve) — harmless because replay queries
  # the live `agent_intents` table; the next `seed/0` writes fresh
  # audit rows for the new intent uuids.
  #
  # Order matters because most FKs use the default `:restrict`
  # behaviour: leaves first, then roots.
  defp delete_demo_owned do
    Repo.transaction(fn ->
      delete_demo_intent_subgraph()
      delete_demo_counterparties()
      delete_demo_delegation()
      delete_demo_policy_rules()
    end)

    :ok
  end

  defp delete_demo_intent_subgraph do
    intent_ids_query =
      from i in AgentIntent,
        where: i.agent_id in ^all_demo_agent_ids(),
        select: i.id

    # Execution plans, decisions, simulations and trust assessments
    # referencing demo intents (the live runtime may have written
    # extra simulation/trust rows during a previous demo session).
    Repo.delete_all(
      from p in ExecutionPlan,
        where: p.intent_id in subquery(intent_ids_query)
    )

    Repo.delete_all(
      from d in DecisionEnvelope,
        where: d.intent_id in subquery(intent_ids_query)
    )

    Repo.delete_all(
      from s in SimulationReport,
        where: s.intent_id in subquery(intent_ids_query)
    )

    Repo.delete_all(
      from t in TrustAssessment,
        where: t.intent_id in subquery(intent_ids_query)
    )

    Repo.delete_all(
      from i in AgentIntent,
        where: i.agent_id in ^all_demo_agent_ids()
    )
  end

  defp delete_demo_counterparties do
    names = all_demo_counterparty_names()

    counterparty_ids =
      Counterparty
      |> where([c], c.name in ^names)
      |> select([c], c.id)
      |> Repo.all()

    label_ids =
      AddressLabel
      |> where([l], l.counterparty_id in ^counterparty_ids)
      |> select([l], l.id)
      |> Repo.all()

    # Polymorphic evidence/trust have no DB FK to their subject, so a
    # cascade won't reach them. Wipe them by `(subject_type,
    # subject_id)` ahead of deleting the labels and counterparties so
    # the seed cannot re-create the subject row underneath an orphaned
    # assertion.
    delete_demo_subject_rows(EvidenceArtifact, counterparty_ids, label_ids)
    delete_demo_subject_rows(TrustAssertion, counterparty_ids, label_ids)

    Repo.delete_all(from l in AddressLabel, where: l.id in ^label_ids)
    Repo.delete_all(from c in Counterparty, where: c.id in ^counterparty_ids)
  end

  defp delete_demo_subject_rows(schema, counterparty_ids, label_ids) do
    Repo.delete_all(
      from r in schema,
        where:
          (r.subject_type == "counterparty" and r.subject_id in ^counterparty_ids) or
            (r.subject_type == "address_label" and r.subject_id in ^label_ids)
    )
  end

  defp delete_demo_delegation do
    Repo.delete_all(
      from d in Delegation,
        where: d.smart_account_id == ^@smart_account_id
    )
  end

  defp delete_demo_policy_rules do
    # Match each seeded rule by `(rule_type, priority, params)` so
    # operator-authored rules with the same `(rule_type, priority)`
    # but different params survive the reset.
    Enum.each(policy_rule_specs(), fn %{
                                        rule_type: rt,
                                        priority: prio,
                                        params: params
                                      } ->
      Repo.delete_all(
        from r in PolicyRule,
          where: r.rule_type == ^rt and r.priority == ^prio and r.params == ^params
      )
    end)
  end

  defp all_demo_agent_ids, do: [@demo_agent_id, @legacy_demo_agent_id]

  defp all_demo_counterparty_names do
    Enum.map(counterparty_specs(), & &1.name) ++ @legacy_counterparty_names
  end

  defp runtime_env do
    cond do
      Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) ->
        Mix.env()

      true ->
        # In a release the config_env is baked into config/runtime.exs;
        # we expose it via application env as a fallback.
        Application.get_env(:bank, :demo_runtime_env, :prod)
    end
  end
end
