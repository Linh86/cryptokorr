defmodule Bank.Demo do
  @moduledoc """
  Seeded demo dataset and reset helpers.

  The alpha and design-partner sessions reuse a curated set of
  counterparties, policies, delegations, and historical intents so
  operators always know what "healthy baseline" looks like. This
  module owns both halves of that workflow:

    * `seed/0` — idempotent population. Safe to run repeatedly; the
      upsert keys are `(Counterparty.name)`, `(chain, address)` for
      labels, `(agent_id, idempotency_key)` for intents, and the
      `:rule_type, :priority` combo for policy rules.
    * `reset/1` — destructive truncation of every demo-owned table
      followed by `seed/0`. Guarded behind a hard-coded env allowlist
      plus an explicit `confirm: true` flag so it can never fire
      against a real prod database.

  The corresponding Mix tasks (`mix bank.demo.seed`,
  `mix bank.demo.reset`) live in `lib/mix/tasks/`.

  See `docs/demo.md` for the operator-facing instructions.
  """

  require Logger

  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Counterparties.{AddressLabel, Counterparty}
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan}
  alias Bank.Delegations.Delegation
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.PolicyRule
  alias Bank.Repo

  @smart_account_id "sa_demo_01"
  @delegation_id "del_demo_01"
  @chain "base"
  @asset "USDC"

  # Environments where `reset/1` is allowed to truncate. Prod is never
  # on this list — resetting a demo dataset should never be something
  # an operator can do against production data.
  @reset_envs [:dev, :test, :staging]

  @doc """
  Populate the demo dataset. Idempotent: running it twice leaves the
  database in the same shape as running it once.
  """
  @spec seed() :: :ok
  def seed do
    Logger.info("Bank.Demo: seeding demo dataset")

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
  Truncate every demo-owned table, then re-seed. Guarded by env +
  confirm flag.

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
        truncate_all()
        seed()
        :ok
    end
  end

  @doc """
  The list of tables this module owns. Exposed so the reset Mix task
  can print the list in its dry-run output.
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
      trust_assertions
      evidence_artifacts
      address_labels
      counterparties
      policy_rules
      delegations
    )
  end

  # --- Counterparties ----------------------------------------------------

  defp seed_counterparties do
    [
      %{
        name: "Payroll Provider",
        trust: :trusted,
        note: "Monthly payroll rails — pre-approved recurring transfers."
      },
      %{
        name: "Treasury Ops",
        trust: :trusted,
        note: "Internal treasury movement account."
      },
      %{
        name: "New Partner X",
        trust: :sensitive,
        note: "Recent onboarding — elevated review for first 30 days."
      },
      %{
        name: "Unverified Recipient",
        trust: :unknown,
        note: "Address encountered without counterparty match."
      }
    ]
    |> Enum.map(fn attrs ->
      {:ok, cp} = upsert_counterparty(attrs)
      {attrs.name, cp}
    end)
    |> Map.new()
  end

  defp upsert_counterparty(%{name: name, trust: trust, note: note}) do
    case Repo.get_by(Counterparty, name: name) do
      %Counterparty{} = cp ->
        {:ok, cp}

      nil ->
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
      {"Payroll Provider", "0x1111111111111111111111111111111111111111", :payout, true},
      {"Treasury Ops", "0x2222222222222222222222222222222222222222", :funding, true},
      {"New Partner X", "0x3333333333333333333333333333333333333333", :payout, false},
      {"Unverified Recipient", "0x4444444444444444444444444444444444444444", :other, false}
    ]
    |> Enum.map(fn {name, address, role, verified} ->
      counterparty = Map.fetch!(counterparties, name)
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

  defp seed_policy_rules do
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
    |> Enum.map(&upsert_policy_rule/1)
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
    # A representative spread:
    #   * a completed auto_exec (Payroll Provider, trusted, small amount)
    #   * a completed approval_required → approved (New Partner X, sensitive)
    #   * a blocked unknown-recipient intent (Unverified Recipient)
    #   * an in-flight executing intent (Treasury Ops)
    scenarios = [
      %{
        name: "payroll-confirmed",
        counterparty: "Payroll Provider",
        amount: Decimal.new("250"),
        outcome: :auto_exec,
        final_status: :confirmed,
        intent_state: :executed,
        tx_hash: "0xabc111...demo-payroll"
      },
      %{
        name: "partner-x-approved",
        counterparty: "New Partner X",
        amount: Decimal.new("1000"),
        outcome: :approval_required,
        final_status: :confirmed,
        intent_state: :executed,
        tx_hash: "0xabc222...demo-partner"
      },
      %{
        name: "unknown-blocked",
        counterparty: "Unverified Recipient",
        amount: Decimal.new("500"),
        outcome: :block,
        final_status: nil,
        intent_state: :blocked,
        tx_hash: nil
      },
      %{
        name: "treasury-executing",
        counterparty: "Treasury Ops",
        amount: Decimal.new("100"),
        outcome: :auto_exec,
        final_status: nil,
        intent_state: :executing,
        tx_hash: nil
      }
    ]

    Enum.map(scenarios, &build_scenario(&1, counterparties))
  end

  defp build_scenario(scenario, counterparties) do
    counterparty = Map.fetch!(counterparties, scenario.counterparty)
    label = primary_label(counterparty)

    idempotency = "demo-" <> scenario.name

    {:ok, intent} = upsert_intent(scenario, counterparty, label, idempotency)

    case scenario.outcome do
      :block ->
        {:ok, decision} = upsert_decision(intent, :block, :severe)
        emit_audit(intent, decision, scenario)
        %{intent: intent, decision: decision, plan: nil}

      outcome ->
        {:ok, decision} = upsert_decision(intent, outcome, decision_risk(outcome))

        {:ok, plan} =
          upsert_plan(decision, intent, execution_status(scenario), scenario)

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
    case Repo.get_by(AgentIntent, idempotency_key: idempotency) do
      %AgentIntent{} = intent ->
        {:ok, intent}

      nil ->
        %AgentIntent{}
        |> AgentIntent.changeset(%{
          agent_id: "demo-agent",
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
  defp decision_risk(_), do: :moderate

  defp upsert_decision(intent, outcome, risk_tier) do
    case Repo.get_by(DecisionEnvelope, intent_id: intent.id, current: true) do
      %DecisionEnvelope{} = d ->
        {:ok, d}

      nil ->
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

  defp execution_status(%{final_status: :confirmed}), do: :confirmed
  defp execution_status(%{intent_state: :executing}), do: :broadcasting
  defp execution_status(_), do: :prepared

  defp upsert_plan(decision, intent, status, scenario) do
    case Repo.one(
           from p in ExecutionPlan,
             where: p.decision_id == ^decision.id and p.active == true,
             limit: 1
         ) do
      %ExecutionPlan{} = plan ->
        {:ok, plan}

      nil ->
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
          final_reason: if(scenario.final_status == :confirmed, do: "demo_seed", else: nil)
        })
        |> Repo.insert()
    end
  end

  defp emit_audit(intent, decision, scenario, plan \\ nil) do
    # Two minimal events per scenario: submission + decision. Plus one
    # more if there is a plan. Covers the happy path of an intent's
    # life so the replay page has something to render.
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

    Enum.each(events, fn attrs ->
      # Skip if an event with the same (correlation_id, subject_id,
      # event_type) already exists — keeps seed idempotent.
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
    end)
  end

  # --- Reset -------------------------------------------------------------

  defp truncate_all do
    Enum.each(owned_tables(), fn table ->
      Repo.query!("TRUNCATE TABLE #{table} RESTART IDENTITY CASCADE")
    end)
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
