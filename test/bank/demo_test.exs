defmodule Bank.DemoTest do
  use Bank.DataCase, async: false

  alias Bank.Audit.AuditEvent
  alias Bank.Counterparties.{AddressLabel, Counterparty, EvidenceArtifact, TrustAssertion}
  alias Bank.Decisions.{DecisionEnvelope, ExecutionPlan, SimulationReport}
  alias Bank.Delegations.Delegation
  alias Bank.Demo
  alias Bank.Fixtures
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.PolicyRule

  describe "seed/0" do
    test "creates the curated counterparties, address labels, policy rules, delegation, and intents" do
      :ok = Demo.seed()

      ids = Demo.identifiers()

      counterparties =
        Counterparty
        |> where([c], c.name in ^ids.counterparty_names)
        |> Repo.all()
        |> Enum.sort_by(& &1.name)

      assert length(counterparties) == 4

      assert Enum.all?(counterparties, fn cp -> String.starts_with?(cp.name, "[Sandbox] ") end)

      trust_levels = Enum.map(counterparties, & &1.current_trust_level) |> Enum.sort()
      assert trust_levels == [:sensitive, :trusted, :trusted, :unknown]

      labels =
        AddressLabel
        |> join(:inner, [l], c in Counterparty, on: c.id == l.counterparty_id)
        |> where([_l, c], c.name in ^ids.counterparty_names)
        |> select([l, _c], l)
        |> Repo.all()

      assert length(labels) == 4
      assert Enum.all?(labels, &(&1.chain == "base"))
      assert Enum.all?(labels, &String.starts_with?(&1.address, "0x"))

      policy_rule_types =
        PolicyRule |> select([r], r.rule_type) |> Repo.all() |> Enum.sort()

      assert :amount_limit in policy_rule_types
      assert :allowed_chain in policy_rule_types
      assert :allowed_asset in policy_rule_types
      assert :autonomy_tier in policy_rule_types

      delegation = Repo.get_by!(Delegation, smart_account_id: ids.smart_account_id)
      assert delegation.state == :active
      assert delegation.delegation_id == ids.delegation_id

      intents =
        AgentIntent
        |> where([i], i.agent_id in ^ids.agent_ids)
        |> Repo.all()

      assert length(intents) == 10
    end

    test "covers every #238 intent state (submitted, decided, approval_required, held, cancelled, executing, executed, blocked)" do
      :ok = Demo.seed()

      ids = Demo.identifiers()

      intents =
        AgentIntent
        |> where([i], i.agent_id in ^ids.agent_ids)
        |> Repo.all()

      states = intents |> Enum.map(& &1.state) |> MapSet.new()

      # The five #238-required states.
      assert :submitted in states
      assert :decided in states
      assert :cancelled in states
      assert :blocked in states
      assert :executing in states
      assert :executed in states

      # Decision shapes (held + approval_required surface here).
      decisions =
        DecisionEnvelope
        |> join(:inner, [d], i in AgentIntent, on: i.id == d.intent_id)
        |> where([_d, i], i.agent_id in ^ids.agent_ids)
        |> select([d, _i], d.outcome)
        |> Repo.all()
        |> MapSet.new()

      assert :auto_exec in decisions
      assert :approval_required in decisions
      assert :hold in decisions
      assert :block in decisions
    end

    test "is idempotent — running it twice produces the same row counts" do
      :ok = Demo.seed()

      counts_after_first = demo_owned_counts()

      :ok = Demo.seed()

      assert demo_owned_counts() == counts_after_first
    end

    test "tags every audit event with a sandbox-demo actor_id or correlation_id" do
      :ok = Demo.seed()

      ids = Demo.identifiers()

      demo_intent_ids =
        AgentIntent
        |> where([i], i.agent_id in ^ids.agent_ids)
        |> select([i], i.id)
        |> Repo.all()

      events =
        AuditEvent
        |> where([e], e.correlation_id in ^demo_intent_ids)
        |> Repo.all()

      # Every demo intent has at least one audit event (intent.submitted).
      submission_correlations =
        events
        |> Enum.filter(&(&1.event_type == "intent.submitted"))
        |> Enum.map(& &1.correlation_id)
        |> MapSet.new()

      assert submission_correlations == MapSet.new(demo_intent_ids)

      # The cancelled scenario also writes intent.cancelled.
      assert Enum.any?(events, &(&1.event_type == "intent.cancelled"))

      # Decisions and executions show up for the planned scenarios.
      assert Enum.any?(events, &(&1.event_type == "decision.recorded"))
      assert Enum.any?(events, &String.starts_with?(&1.event_type, "execution."))
    end

    test "writes a current SimulationReport for every decided/planned/blocked demo intent (#242 P2)" do
      :ok = Demo.seed()

      ids = Demo.identifiers()

      decided_intent_ids =
        AgentIntent
        |> join(:inner, [i], d in DecisionEnvelope, on: d.intent_id == i.id)
        |> where([i], i.agent_id in ^ids.agent_ids)
        |> distinct(true)
        |> select([i], i.id)
        |> Repo.all()

      # Every intent that produced a decision must have exactly one
      # current simulation report on the seeded path. The runbook
      # promises `/sandbox` is fully green after a fresh seed; that
      # is now true because `simulate_captured?` returns truthy.
      assert decided_intent_ids != []

      sim_intents =
        SimulationReport
        |> where([s], s.intent_id in ^decided_intent_ids and s.current == true)
        |> select([s], s.intent_id)
        |> Repo.all()
        |> MapSet.new()

      assert sim_intents == MapSet.new(decided_intent_ids)

      # Provider / trace are explicitly fake — never a real provider
      # token, never a value that looks like a secret.
      sims =
        SimulationReport
        |> where([s], s.intent_id in ^decided_intent_ids and s.current == true)
        |> Repo.all()

      for sim <- sims do
        assert sim.provider == "sandbox_seed"
        assert String.starts_with?(sim.provider_trace_ref, "sandbox_seed:")
        assert sim.status in [:completed, :failed]
        assert sim.freshness_ttl_seconds > 0
      end
    end
  end

  describe "workspace bootstrap (#158a)" do
    test "seed/0 creates the sandbox-demo workspace if it does not exist" do
      assert Bank.Workspaces.get_workspace_by_slug("sandbox-demo") == nil

      :ok = Demo.seed()

      assert %Bank.Workspaces.Workspace{slug: "sandbox-demo", id: id} =
               Bank.Workspaces.get_workspace_by_slug("sandbox-demo")

      assert Demo.demo_workspace_id() == id
    end

    test "seed/0 is idempotent — running it twice keeps a single sandbox workspace row" do
      :ok = Demo.seed()
      :ok = Demo.seed()

      ws_count = Bank.Repo.aggregate(Bank.Workspaces.Workspace, :count)
      assert ws_count == 1
    end

    test "seeded workspace-scoped rows carry the demo workspace id" do
      :ok = Demo.seed()
      ws_id = Demo.demo_workspace_id()
      assert is_binary(ws_id)

      ids = Demo.identifiers()

      counterparties =
        Counterparty
        |> where([c], c.name in ^ids.counterparty_names)
        |> Repo.all()

      assert Enum.all?(counterparties, &(&1.workspace_id == ws_id)),
             "every seeded counterparty should be scoped to the demo workspace"

      rules = Repo.all(PolicyRule)

      assert Enum.all?(rules, &(&1.workspace_id == ws_id)),
             "every seeded policy rule should be scoped to the demo workspace"

      [delegation] =
        Delegation
        |> where(smart_account_id: ^ids.smart_account_id)
        |> Repo.all()

      assert delegation.workspace_id == ws_id

      intents =
        AgentIntent
        |> where([i], i.agent_id in ^ids.agent_ids)
        |> Repo.all()

      assert Enum.all?(intents, &(&1.workspace_id == ws_id)),
             "every seeded intent should be scoped to the demo workspace"

      plans =
        ExecutionPlan
        |> where([p], p.intent_id in ^Enum.map(intents, & &1.id))
        |> Repo.all()

      assert Enum.all?(plans, &(&1.workspace_id == ws_id)),
             "every seeded execution plan should be scoped to the demo workspace"
    end

    test "demo_workspace_id/0 returns nil before seed is run" do
      assert Demo.demo_workspace_id() == nil
    end
  end

  describe "secret hygiene" do
    test "no seeded row contains anything that looks like a private key, API key, bearer secret, or env-sourced URL" do
      :ok = Demo.seed()

      ids = Demo.identifiers()

      counterparty_strings =
        Counterparty
        |> where([c], c.name in ^ids.counterparty_names)
        |> Repo.all()
        |> Enum.flat_map(&[&1.name, &1.notes || ""])

      label_strings =
        AddressLabel
        |> join(:inner, [l], c in Counterparty, on: c.id == l.counterparty_id)
        |> where([_l, c], c.name in ^ids.counterparty_names)
        |> select([l, _c], l)
        |> Repo.all()
        |> Enum.map(& &1.address)

      delegation = Repo.get_by!(Delegation, smart_account_id: ids.smart_account_id)

      delegation_strings = [
        delegation.smart_account_id,
        delegation.delegation_id,
        delegation.last_tx_hash || "",
        delegation.session_signer_address || ""
      ]

      intent_strings =
        AgentIntent
        |> where([i], i.agent_id in ^ids.agent_ids)
        |> Repo.all()
        |> Enum.flat_map(&[&1.agent_id, &1.idempotency_key, &1.notes || ""])

      plan_strings =
        ExecutionPlan
        |> join(:inner, [p], i in AgentIntent, on: i.id == p.intent_id)
        |> where([_p, i], i.agent_id in ^ids.agent_ids)
        |> select([p, _i], p)
        |> Repo.all()
        |> Enum.flat_map(&([&1.smart_account_id, &1.adapter_ref || ""] ++ &1.tx_refs))

      strings =
        counterparty_strings ++
          label_strings ++
          delegation_strings ++
          intent_strings ++
          plan_strings

      Enum.each(strings, fn value ->
        assert is_binary(value)
        refute_secret_shape(value)
      end)
    end

    test "every counterparty name carries the [Sandbox] prefix" do
      :ok = Demo.seed()

      ids = Demo.identifiers()

      Counterparty
      |> where([c], c.name in ^ids.counterparty_names)
      |> Repo.all()
      |> Enum.each(fn cp ->
        assert String.starts_with?(cp.name, "[Sandbox] "),
               "demo counterparty #{inspect(cp.name)} is missing the [Sandbox] prefix"
      end)
    end

    # #241 acceptance: "secret hygiene grep over seed files".
    #
    # The earlier test scans the *seeded rows*. This one scans the
    # *source files* that produce the seed and reset, so a future
    # change that hard-codes a private key, bearer token, tokenized
    # RPC URL, or any production/mainnet credential into the seed
    # path is caught before it ever reaches the DB. The list of
    # files here is intentionally narrow: the demo helpers and the
    # mix tasks that exercise them. If new helpers are added, they
    # should be listed here too.
    test "no seed/reset source file contains a real-looking private key, API key, bearer secret, tokenized URL, or production literal" do
      paths = [
        Path.expand("../../lib/bank/demo.ex", __DIR__),
        Path.expand("../../lib/mix/tasks/bank.demo.seed.ex", __DIR__),
        Path.expand("../../lib/mix/tasks/bank.demo.reset.ex", __DIR__)
      ]

      for path <- paths do
        assert File.exists?(path), "#241 hygiene scan target missing: #{path}"
        contents = File.read!(path)

        refute_seed_source_secret(
          path,
          contents,
          ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
          "PEM private-key block"
        )

        refute_seed_source_secret(
          path,
          contents,
          ~r/\b(sk_live|pk_live|sk_test)_[A-Za-z0-9_-]+/,
          "Stripe-style live/test secret token"
        )

        refute_seed_source_secret(
          path,
          contents,
          ~r/\bauthorization\s*:\s*\"?bearer\s+[A-Za-z0-9._-]+/i,
          "literal Authorization: Bearer header"
        )

        refute_seed_source_secret(
          path,
          contents,
          ~r{https?://[^/\s\"`]+:[^@/\s\"`]+@[A-Za-z0-9.-]+},
          "tokenized https://user:pass@host URL"
        )

        # 64 hex chars = 32-byte material. The seed has no reason to
        # carry one. SHA-256 hashes over user-supplied data live in
        # the DB rows produced at runtime, not as literals in the
        # seed source.
        refute_seed_source_secret(
          path,
          contents,
          ~r/\b0x[0-9a-fA-F]{64}\b/,
          "32-byte hex literal (private-key-shaped)"
        )
      end
    end

    # #241 acceptance: "Demo data cannot be mistaken for
    # production/mainnet". The runtime-row hygiene test covers
    # seeded values; this test is the static-side guard that the
    # seed source cannot accidentally describe a sandbox row as
    # `mainnet`/`production`/`:live` *in a place that becomes a
    # row value*. We deliberately scan only quoted strings and
    # atoms — comments that say "production" in prose (e.g.
    # describing what the demo is NOT) are fine and expected.
    test "seed source files contain no production/mainnet/live tokens in string literals or atoms" do
      paths = [
        Path.expand("../../lib/bank/demo.ex", __DIR__),
        Path.expand("../../lib/mix/tasks/bank.demo.seed.ex", __DIR__),
        Path.expand("../../lib/mix/tasks/bank.demo.reset.ex", __DIR__)
      ]

      # Each entry is a regex that matches the banned token only in
      # a code-emitting position: between double quotes, after a
      # `:` (atom literal), or as the chain field of a known seed
      # struct. Comments are ignored by construction.
      patterns = [
        {~r/"mainnet"/, "string literal \"mainnet\""},
        {~r/"ethereum_mainnet"/, "string literal \"ethereum_mainnet\""},
        {~r/:mainnet\b/, ":mainnet atom"},
        {~r/:ethereum_mainnet\b/, ":ethereum_mainnet atom"},
        {~r/"production"/, "string literal \"production\""},
        {~r/:production\b/, ":production atom"},
        {~r/:live\b/, ":live atom"},
        {~r/"live"/, "string literal \"live\""}
      ]

      for path <- paths do
        contents = File.read!(path)

        for {pattern, label} <- patterns do
          refute Regex.match?(pattern, contents),
                 "seed source #{Path.relative_to_cwd(path)} contains #{label}; sandbox seed must stay visibly fake (matched #{inspect(pattern)})"
        end
      end
    end
  end

  describe "reset/1" do
    test "refuses without confirm" do
      assert {:error, :confirmation_required} = Demo.reset(env: :test)
    end

    test "refuses outside the env allowlist" do
      assert {:error, {:reset_not_allowed, :prod}} = Demo.reset(env: :prod, confirm: true)
    end

    test "deletes only demo data and preserves non-demo rows in the same tables" do
      # Non-demo data that must survive the reset.
      keeper_cp = Fixtures.counterparty(name: "Real Customer Inc.", current_trust_level: :trusted)

      keeper_label =
        Fixtures.address_label(
          counterparty: keeper_cp,
          chain: "base",
          address: "0x9999999999999999999999999999999999999999"
        )

      keeper_intent = Fixtures.agent_intent(counterparty: keeper_cp, agent_id: "real-prod-agent")

      keeper_audit =
        Fixtures.audit_event(
          actor_id: "real-prod-agent",
          correlation_id: keeper_intent.id,
          subject_type: "agent_intent",
          subject_id: keeper_intent.id
        )

      keeper_rule =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          # Exact same (rule_type, priority) as the demo `amount_limit` —
          # but different params. The reset must not delete this row.
          priority: 10,
          params: %{"max_amount" => "999999"},
          state: :active
        )

      :ok = Demo.seed()

      assert :ok = Demo.reset(env: :test, confirm: true)

      # All non-demo rows survived. `audit_events` is append-only at
      # the DB layer; the reset never touches it, so keeper_audit
      # would survive even without scope filtering.
      assert Repo.get(Counterparty, keeper_cp.id)
      assert Repo.get(AddressLabel, keeper_label.id)
      assert Repo.get(AgentIntent, keeper_intent.id)
      assert Repo.get(AuditEvent, keeper_audit.id)
      assert Repo.get(PolicyRule, keeper_rule.id)

      # And the seed re-ran cleanly.
      ids = Demo.identifiers()

      assert AgentIntent
             |> where([i], i.agent_id in ^ids.agent_ids)
             |> Repo.aggregate(:count) == 10
    end

    test "cleans up legacy unprefixed counterparties + demo-agent rows" do
      legacy_cp = Fixtures.counterparty(name: "Payroll Provider", current_trust_level: :trusted)

      legacy_intent =
        Fixtures.agent_intent(
          counterparty: legacy_cp,
          agent_id: "demo-agent",
          idempotency_key: "demo-payroll-confirmed"
        )

      :ok = Demo.reset(env: :test, confirm: true)

      refute Repo.get(Counterparty, legacy_cp.id)
      refute Repo.get(AgentIntent, legacy_intent.id)

      ids = Demo.identifiers()
      assert Repo.get_by(Counterparty, name: hd(ids.counterparty_names))
    end

    test "deletes polymorphic evidence + trust rows attached to sandbox subjects, keeps non-demo ones" do
      :ok = Demo.seed()

      ids = Demo.identifiers()

      sandbox_cp = Repo.get_by!(Counterparty, name: hd(ids.counterparty_names))

      sandbox_label =
        Repo.one!(
          from l in AddressLabel,
            where: l.counterparty_id == ^sandbox_cp.id,
            limit: 1
        )

      sandbox_cp_evidence = Fixtures.evidence_artifact(subject: sandbox_cp)
      sandbox_cp_trust = Fixtures.trust_assertion(subject: sandbox_cp)
      sandbox_label_evidence = Fixtures.evidence_artifact(subject: sandbox_label)
      sandbox_label_trust = Fixtures.trust_assertion(subject: sandbox_label)

      keeper_cp = Fixtures.counterparty(name: "Keeper Corp.", current_trust_level: :trusted)

      keeper_label =
        Fixtures.address_label(
          counterparty: keeper_cp,
          chain: "base",
          address: "0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        )

      keeper_cp_evidence = Fixtures.evidence_artifact(subject: keeper_cp)
      keeper_cp_trust = Fixtures.trust_assertion(subject: keeper_cp)
      keeper_label_evidence = Fixtures.evidence_artifact(subject: keeper_label)
      keeper_label_trust = Fixtures.trust_assertion(subject: keeper_label)

      assert :ok = Demo.reset(env: :test, confirm: true)

      # Sandbox-subject evidence + trust must be gone (no orphans).
      refute Repo.get(EvidenceArtifact, sandbox_cp_evidence.id)
      refute Repo.get(EvidenceArtifact, sandbox_label_evidence.id)
      refute Repo.get(TrustAssertion, sandbox_cp_trust.id)
      refute Repo.get(TrustAssertion, sandbox_label_trust.id)

      # Non-demo evidence + trust survive.
      assert Repo.get(EvidenceArtifact, keeper_cp_evidence.id)
      assert Repo.get(EvidenceArtifact, keeper_label_evidence.id)
      assert Repo.get(TrustAssertion, keeper_cp_trust.id)
      assert Repo.get(TrustAssertion, keeper_label_trust.id)
      assert Repo.get(Counterparty, keeper_cp.id)
      assert Repo.get(AddressLabel, keeper_label.id)

      # Seed re-ran cleanly (sandbox counterparty is back).
      assert Repo.get_by(Counterparty, name: hd(ids.counterparty_names))
    end
  end

  # Used by the #241 source-file hygiene test. Refutes that a
  # specific regex appears anywhere in the file content; the failure
  # message names the file and the kind of credential the regex is
  # guarding against so a future regression points the implementer
  # at the offending line directly.
  defp refute_seed_source_secret(path, contents, pattern, label) do
    refute Regex.match?(pattern, contents),
           "#{Path.relative_to_cwd(path)} contains #{label} (matched #{inspect(pattern)})"
  end

  defp refute_secret_shape(value) do
    # Bearer/API tokens, Bearer headers.
    refute Regex.match?(~r/(bearer|sk[_-]live|sk[_-]test|pk[_-]live)\s*[:=]?\s*\S/i, value),
           "value looks like a credential: #{inspect(value)}"

    # `https://user:password@host` style URLs.
    refute Regex.match?(~r{https?://[^/\s]+:[^@/\s]+@}, value),
           "value contains a tokenized URL: #{inspect(value)}"

    # Hex blobs that look like real 32-byte private keys (64 hex chars).
    # The seed's payload_hashes are SHA-256 (also 64 hex chars), so we
    # check seeded *user-facing* strings only — secret hygiene is about
    # the values an operator would see, not internal hashes.
    refute Regex.match?(~r/^0x[0-9a-fA-F]{64}$/, value),
           "value looks like a 32-byte hex blob: #{inspect(value)}"

    # Eth-style 20-byte addresses are fine, but only if they use the
    # obvious sandbox pattern (0x111…1 / 0x222…2 / etc.) or 0x999…9 for
    # the test keeper. A "real-looking" 40-hex address would be a leak.
    if Regex.match?(~r/^0x[0-9a-fA-F]{40}$/, value) do
      first = String.at(value, 2)
      rest = String.slice(value, 3..-1//1)

      assert String.duplicate(first, String.length(rest)) == rest,
             "address #{inspect(value)} is not a visibly-fake repeated-digit pattern"
    end
  end

  defp demo_owned_counts do
    ids = Demo.identifiers()

    %{
      counterparties:
        Counterparty
        |> where([c], c.name in ^ids.counterparty_names)
        |> Repo.aggregate(:count),
      labels:
        AddressLabel
        |> join(:inner, [l], c in Counterparty, on: c.id == l.counterparty_id)
        |> where([_l, c], c.name in ^ids.counterparty_names)
        |> Repo.aggregate(:count),
      policy_rules: Repo.aggregate(PolicyRule, :count),
      delegations:
        Delegation
        |> where([d], d.smart_account_id == ^ids.smart_account_id)
        |> Repo.aggregate(:count),
      intents:
        AgentIntent
        |> where([i], i.agent_id in ^ids.agent_ids)
        |> Repo.aggregate(:count),
      decisions:
        DecisionEnvelope
        |> join(:inner, [d], i in AgentIntent, on: i.id == d.intent_id)
        |> where([_d, i], i.agent_id in ^ids.agent_ids)
        |> Repo.aggregate(:count),
      plans:
        ExecutionPlan
        |> join(:inner, [p], i in AgentIntent, on: i.id == p.intent_id)
        |> where([_p, i], i.agent_id in ^ids.agent_ids)
        |> Repo.aggregate(:count),
      simulations:
        SimulationReport
        |> join(:inner, [s], i in AgentIntent, on: i.id == s.intent_id)
        |> where([_s, i], i.agent_id in ^ids.agent_ids)
        |> Repo.aggregate(:count),
      audit_events:
        AuditEvent
        |> join(:inner, [e], i in AgentIntent, on: i.id == e.correlation_id)
        |> where([_e, i], i.agent_id in ^ids.agent_ids)
        |> Repo.aggregate(:count)
    }
  end
end
