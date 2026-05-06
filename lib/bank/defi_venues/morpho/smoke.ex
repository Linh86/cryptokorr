defmodule Bank.DefiVenues.Morpho.Smoke do
  @moduledoc """
  Morpho vault risk + deposit decision smoke runner (#209).

  Drives every read-only Morpho surface a fresh reviewer needs to
  inspect locally:

    * **Snapshot ingestion (#199)** via `Snapshots.persist/2`
      using an in-process `%VaultSnapshot{}` (no Morpho HTTP);
      `Snapshots.get_current/2` confirms the round-trip;
      `Snapshots.freshness_summary/2` returns the per-field
      freshness tuple.
    * **Risk explanation (#201)** via `RiskExplanation.explain/3`
      across the three documented MVP outcomes — safe vault →
      `:approval_required`, unallowlisted vault → `:block`,
      stale critical snapshot → `:hold`.
    * **Decision pipeline (#203)** via `Bank.Decisions.evaluate_intent/2`
      for a `kind: :defi_yield_deposit` intent, end-to-end
      through `Bank.Decisions.MorphoEvaluator`.
    * **Audit & replay surface (#208)** by reading the
      `morpho_evidence` slice on `Bank.Audit.replay/1` and
      asserting the `morpho.risk_explained` event lands.
    * **Secret hygiene** by scanning every emitted Morpho audit
      row for the same secret-marker family the
      `morpho_snapshot_ref/1` helper redacts at construction
      time.

  ## Side-effect contract

    * No `.env`, no `ADAPTER_*`, no `RPC_*` reads.
    * No `Bank.AdapterClient` calls.
    * No `Bank.DefiVenues.Morpho.Client` HTTP calls — every
      snapshot exercised in the smoke is built in-process from
      `morpho_vault_snapshot_attrs/2` and persisted via
      `Snapshots.persist/2`.
    * No Oban jobs enqueued.
    * No execution dispatch — `MorphoEvaluator.evaluate/2`
      returns `dispatch: :not_applicable` for the read-only
      decision path. Execution belongs to #206/#207.

  Within the demo workspace the smoke writes Morpho intents,
  vault snapshots, decision envelopes, and audit rows. Re-runs
  are idempotent: snapshot persistence demotes the prior
  current row via the partial unique index; intent inserts use
  a fresh idempotency key per run; the decision pipeline
  supersedes any prior current envelope.

  Exits via the calling Mix task with code 0 on PASS and 1 on
  FAIL so a CI step can pick up the outcome without parsing
  stdout.
  """

  alias Bank.Audit
  alias Bank.Decisions
  alias Bank.Decisions.DecisionEnvelope
  alias Bank.DefiVenues.Morpho.PolicyInput
  alias Bank.DefiVenues.Morpho.RiskExplanation
  alias Bank.DefiVenues.Morpho.Snapshots
  alias Bank.DefiVenues.Morpho.VaultSnapshot
  alias Bank.Demo
  alias Bank.Intents.AgentIntent
  alias Bank.Policies.PolicyRule
  alias Bank.Repo

  require Ecto.Query

  @safe_vault "0xbeef000000000000000000000000000000000099"
  @stale_vault "0xbeef000000000000000000000000000000000209"
  @unknown_vault "0xdead000000000000000000000000000000000209"
  @oracle "0xchainlinkoracle"
  @collateral "0xwsteth"
  @allocator "0xallocator1"
  @chain "base-sepolia"
  @chain_id 84_532

  @secret_markers [
    ~r/Authorization\s*:/i,
    ~r/Bearer\s+[^\s]+/i,
    ~r/sk_(test|live)_/i,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    ~r/private_key/i,
    ~r/blue-api\.morpho\.org\/graphql\?token=/i
  ]

  @check_order ~w(
    vault_snapshot_persistence
    risk_explanation_safe_vault
    risk_explanation_unknown_vault
    risk_explanation_stale_snapshot
    decision_pipeline_approval
    decision_pipeline_block
    decision_pipeline_hold_stale
    replay_carries_morpho_evidence
    secret_hygiene
  )

  @type status :: :pass | :fail
  @type check :: %{name: String.t(), status: status(), detail: String.t()}
  @type report :: %{
          workspace_slug: String.t(),
          workspace_id: Ecto.UUID.t() | nil,
          status: status(),
          checks: [check()],
          passed: non_neg_integer(),
          total: non_neg_integer()
        }

  @doc """
  Run every smoke check. Always returns; never raises. The Mix
  task wraps this in a `case` to choose the exit code.
  """
  @spec run() :: {:ok, report()} | {:error, report()}
  def run do
    workspace_slug = Demo.workspace_slug()

    case Demo.demo_workspace_id() do
      nil ->
        finalize(workspace_slug, nil, [
          %{
            name: "seed",
            status: :fail,
            detail: "demo workspace #{workspace_slug} not found — run `mix bank.demo.seed`"
          }
        ])

      workspace_id ->
        finalize(workspace_slug, workspace_id, run_checks(workspace_id))
    end
  end

  @doc """
  Fixed ordered list of check names this runner emits when a
  demo workspace is present. Pinned by the smoke test so the
  runbook and the runner stay in lock-step (#209).
  """
  @spec check_order() :: [String.t()]
  def check_order, do: @check_order

  defp run_checks(workspace_id) do
    now = DateTime.utc_now()

    # Persist all snapshots that flow through the decision
    # pipeline so the audit constructors (which expect a row id
    # for the snapshot subject) can stamp it. The risk-explanation
    # standalone checks accept either shape, but they too go
    # through the persisted ones for symmetry with the
    # operator-runbook narrative.
    safe_snapshot = build_persisted_snapshot(@safe_vault, fresh?: true)
    stale_snapshot = build_persisted_snapshot(@stale_vault, fresh?: false)
    unknown_snapshot = build_persisted_snapshot(@unknown_vault, fresh?: true)

    rules = ensure_morpho_rules(workspace_id)

    [
      check_vault_snapshot_persistence(safe_snapshot, now),
      check_risk_explanation_safe_vault(safe_snapshot, now),
      check_risk_explanation_unknown_vault(unknown_snapshot, now),
      check_risk_explanation_stale_snapshot(stale_snapshot, now),
      check_decision_pipeline_approval(workspace_id, safe_snapshot, rules),
      check_decision_pipeline_block(workspace_id, unknown_snapshot, rules),
      check_decision_pipeline_hold_stale(workspace_id, stale_snapshot, rules, now),
      check_replay_carries_morpho_evidence(workspace_id, safe_snapshot, rules),
      check_secret_hygiene(workspace_id)
    ]
  end

  defp finalize(workspace_slug, workspace_id, checks) do
    passed = Enum.count(checks, &(&1.status == :pass))
    total = length(checks)
    overall = if passed == total, do: :pass, else: :fail

    report = %{
      workspace_slug: workspace_slug,
      workspace_id: workspace_id,
      status: overall,
      checks: checks,
      passed: passed,
      total: total
    }

    case overall do
      :pass -> {:ok, report}
      :fail -> {:error, report}
    end
  end

  # --- Snapshot fixtures (in-process) --------------------------------------

  # Persisted snapshot: builds an in-memory `%VaultSnapshot{}`
  # and runs it through `Snapshots.persist/2` so the read path
  # exercises the same supersession/freshness invariants any
  # ingestion-time snapshot would.
  defp build_persisted_snapshot(vault_address, opts) do
    snap = build_in_memory_snapshot(vault_address, opts)

    case Snapshots.persist(snap) do
      {:ok, persisted} -> persisted
      {:error, reason} -> raise "Morpho smoke: snapshot persist failed: #{inspect(reason)}"
    end
  end

  defp build_in_memory_snapshot(vault_address, opts) do
    fresh? = Keyword.get(opts, :fresh?, true)
    now = DateTime.utc_now()
    fetched_at = if fresh?, do: now, else: DateTime.add(now, -3600, :second)

    %VaultSnapshot{
      vault_address: vault_address,
      chain_id: @chain_id,
      network: @chain,
      name: "Demo USDC Vault",
      symbol: "demoUSDC",
      listed: true,
      deposit_asset: %{address: "0xusdc", symbol: "USDC", decimals: 6},
      state: %{
        apy: "0.045",
        net_apy: "0.041",
        total_assets: "10000000000000",
        fee: nil,
        timelock: nil
      },
      allocations: [
        %{
          market_unique_key: "0xmarket1",
          loan_asset: "0xusdc",
          collateral_asset: @collateral,
          oracle: @oracle,
          irm: "0xirm",
          lltv: 750_000_000_000_000_000,
          supply_cap: "1000000000000",
          supplied_assets: "100000000000",
          supplied_assets_usd: "100000.00"
        }
      ],
      warnings: [],
      pending_caps: [],
      allocators: [%{address: @allocator}],
      source: %{
        fetched_at: fetched_at,
        source_name: "morpho_blue_graphql",
        source_schema_version: "1",
        source_warnings: [],
        payload_hash: payload_hash_for(vault_address, fetched_at)
      }
    }
  end

  # Deterministic payload_hash so two persists with the same
  # (vault, fetched_at) dedupe into the existing current row
  # via the idempotent path in `Snapshots.persist/2`.
  defp payload_hash_for(vault_address, %DateTime{} = fetched_at) do
    seed = vault_address <> "|" <> DateTime.to_iso8601(fetched_at)
    :sha256 |> :crypto.hash(seed) |> Base.encode16(case: :lower)
  end

  # --- Workspace policy rules ---------------------------------------------

  # Idempotent allowlist: insert one Morpho rule of each type
  # the safe-vault smoke needs. Re-runs see the existing rows
  # via the `(workspace_id, rule_type, scope, params)` shape and
  # skip insert.
  defp ensure_morpho_rules(workspace_id) do
    rule_specs = [
      %{
        rule_type: :allowed_vault,
        params: %{
          "vaults" => [
            %{"chain_id" => @chain_id, "address" => @safe_vault},
            %{"chain_id" => @chain_id, "address" => @stale_vault}
          ]
        }
      },
      %{rule_type: :allowed_oracle, params: %{"oracles" => [@oracle]}},
      %{rule_type: :allowed_collateral_asset, params: %{"assets" => [@collateral]}},
      %{rule_type: :allowed_curator, params: %{"curators" => [@allocator]}},
      %{rule_type: :max_vault_exposure, params: %{"max_amount" => "1000000"}}
    ]

    Enum.map(rule_specs, fn spec -> ensure_rule(workspace_id, spec) end)
  end

  defp ensure_rule(workspace_id, %{rule_type: rule_type, params: params}) do
    scope = %{"venue" => "morpho", "morpho_smoke" => true}

    query =
      Ecto.Query.from(r in PolicyRule,
        where:
          r.workspace_id == ^workspace_id and
            r.rule_type == ^rule_type and
            fragment("?->>'morpho_smoke' = 'true'", r.scope),
        limit: 1
      )

    case Repo.one(query) do
      %PolicyRule{} = rule ->
        rule

      nil ->
        attrs = %{
          rule_type: rule_type,
          params: params,
          scope: scope,
          state: :active,
          created_by: :user,
          workspace_id: workspace_id
        }

        case PolicyRule.changeset(%PolicyRule{}, attrs) |> Repo.insert() do
          {:ok, rule} ->
            rule

          {:error, changeset} ->
            raise "Morpho smoke: policy rule #{rule_type} insert failed: #{inspect(changeset.errors)}"
        end
    end
  end

  # --- Intent fixture (per-run fresh) -------------------------------------

  defp build_intent(workspace_id, vault_address, amount_string) do
    now = DateTime.utc_now()
    suffix = System.unique_integer([:positive])

    attrs = %{
      agent_id: "morpho-smoke-agent",
      source: :runtime,
      idempotency_key: "morpho-smoke-#{suffix}",
      payload_hash: payload_hash_for("intent-#{suffix}", now),
      kind: :defi_yield_deposit,
      asset: "USDC",
      chain: @chain,
      amount: Decimal.new(amount_string),
      target_raw_address: vault_address,
      submitted_at: now,
      workspace_id: workspace_id
    }

    case AgentIntent.changeset(%AgentIntent{}, attrs) |> Repo.insert() do
      {:ok, intent} ->
        intent

      {:error, changeset} ->
        raise "Morpho smoke: intent insert failed: #{inspect(changeset.errors)}"
    end
  end

  # --- Checks --------------------------------------------------------------

  defp check_vault_snapshot_persistence(persisted, now) do
    case Snapshots.get_current(persisted.chain_id, persisted.vault_address) do
      nil ->
        fail(
          "vault_snapshot_persistence",
          "Snapshots.get_current/2 returned nil for vault #{short(persisted.vault_address)}"
        )

      current ->
        freshness = Snapshots.freshness_summary(current, now)

        if Enum.all?(freshness, fn {_field, state} -> state == :fresh end) do
          pass(
            "vault_snapshot_persistence",
            "current snapshot id=#{short(current.id)} all four fields :fresh"
          )
        else
          fail(
            "vault_snapshot_persistence",
            "freshness not all :fresh — got #{inspect(freshness)}"
          )
        end
    end
  end

  defp check_risk_explanation_safe_vault(snapshot, now) do
    policy = safe_policy_input(Decimal.new("1000"))
    explanation = RiskExplanation.explain(snapshot, policy, now)

    cond do
      explanation["decision"] != "approval_required" ->
        fail(
          "risk_explanation_safe_vault",
          "expected decision=approval_required; got #{inspect(explanation["decision"])}"
        )

      explanation["risk_tier"] not in ["low", "moderate"] ->
        fail(
          "risk_explanation_safe_vault",
          "expected risk_tier in [low, moderate]; got #{inspect(explanation["risk_tier"])}"
        )

      not no_block_reasons?(explanation) ->
        fail("risk_explanation_safe_vault", "unexpected block-severity reason in safe vault")

      not has_mvp_morpho_deposit_reason?(explanation) ->
        fail(
          "risk_explanation_safe_vault",
          "missing mvp_morpho_deposit :approval reason (MVP rule)"
        )

      true ->
        pass(
          "risk_explanation_safe_vault",
          "decision=approval_required tier=#{explanation["risk_tier"]} primary_reasons=#{length(explanation["primary_reasons"])}"
        )
    end
  end

  defp check_risk_explanation_unknown_vault(snapshot, now) do
    # Empty vault_allowlist (workspace has no Morpho rules) →
    # engine fails closed at :block per #202 P2.
    policy = %PolicyInput{
      PolicyInput.default()
      | vault_allowlist: [],
        oracle_allowlist: [@oracle],
        collateral_allowlist: [@collateral],
        curator_allowlist: [@allocator],
        expected_loan_asset: "USDC",
        proposed_amount: Decimal.new("1000"),
        exposure_cap: Decimal.new("1000000")
    }

    explanation = RiskExplanation.explain(snapshot, policy, now)

    cond do
      explanation["decision"] != "block" ->
        fail(
          "risk_explanation_unknown_vault",
          "expected decision=block; got #{inspect(explanation["decision"])}"
        )

      explanation["risk_tier"] != "severe" ->
        fail(
          "risk_explanation_unknown_vault",
          "expected risk_tier=severe; got #{inspect(explanation["risk_tier"])}"
        )

      not block_reason_present?(explanation, "vault_not_allowlisted") ->
        fail(
          "risk_explanation_unknown_vault",
          "missing vault_not_allowlisted :block reason"
        )

      true ->
        pass(
          "risk_explanation_unknown_vault",
          "decision=block tier=severe vault_not_allowlisted on #{short(snapshot.vault_address)}"
        )
    end
  end

  defp check_risk_explanation_stale_snapshot(snapshot, now) do
    policy = safe_policy_input(Decimal.new("1000"))
    explanation = RiskExplanation.explain(snapshot, policy, now)

    cond do
      explanation["decision"] != "hold" ->
        fail(
          "risk_explanation_stale_snapshot",
          "expected decision=hold; got #{inspect(explanation["decision"])}"
        )

      not hold_reason_present_for_freshness?(explanation) ->
        fail("risk_explanation_stale_snapshot", "no freshness_* :hold reason in explanation")

      true ->
        pass(
          "risk_explanation_stale_snapshot",
          "decision=hold; freshness reason present"
        )
    end
  end

  defp check_decision_pipeline_approval(workspace_id, snapshot, rules) do
    intent = build_intent(workspace_id, @safe_vault, "1000")

    case Decisions.evaluate_intent(intent, morpho_snapshot: snapshot, rules: rules) do
      {:ok, %{outcome: :approval_required, decision: %DecisionEnvelope{} = envelope} = result} ->
        explanation = morpho_explanation(envelope)

        cond do
          result.execution_plan != nil ->
            fail("decision_pipeline_approval", "unexpected execution_plan attached")

          result.dispatch != :not_applicable ->
            fail("decision_pipeline_approval", "unexpected dispatch=#{inspect(result.dispatch)}")

          is_nil(explanation) ->
            fail("decision_pipeline_approval", "envelope reasons missing morpho_risk_explanation")

          true ->
            pass(
              "decision_pipeline_approval",
              "envelope id=#{short(envelope.id)} outcome=approval_required tier=#{envelope.risk_tier}"
            )
        end

      other ->
        fail("decision_pipeline_approval", "unexpected evaluate_intent result: #{inspect(other)}")
    end
  end

  defp check_decision_pipeline_block(workspace_id, snapshot, rules) do
    intent = build_intent(workspace_id, @unknown_vault, "1000")

    case Decisions.evaluate_intent(intent, morpho_snapshot: snapshot, rules: rules) do
      {:ok, %{outcome: :block, decision: envelope} = result} ->
        cond do
          envelope.risk_tier != :severe ->
            fail(
              "decision_pipeline_block",
              "expected risk_tier=:severe; got #{inspect(envelope.risk_tier)}"
            )

          result.execution_plan != nil ->
            fail("decision_pipeline_block", "unexpected execution_plan attached on :block")

          true ->
            pass(
              "decision_pipeline_block",
              "envelope id=#{short(envelope.id)} outcome=block tier=severe"
            )
        end

      other ->
        fail("decision_pipeline_block", "unexpected evaluate_intent result: #{inspect(other)}")
    end
  end

  defp check_decision_pipeline_hold_stale(workspace_id, snapshot, rules, now) do
    intent = build_intent(workspace_id, @stale_vault, "1000")

    case Decisions.evaluate_intent(intent,
           morpho_snapshot: snapshot,
           rules: rules,
           now: now
         ) do
      {:ok, %{outcome: :hold, decision: envelope}} ->
        explanation = morpho_explanation(envelope)

        if hold_reason_present_for_freshness?(explanation) do
          pass(
            "decision_pipeline_hold_stale",
            "envelope id=#{short(envelope.id)} outcome=hold (freshness expired)"
          )
        else
          fail(
            "decision_pipeline_hold_stale",
            "envelope outcome=hold but no freshness_* reason in explanation"
          )
        end

      other ->
        fail(
          "decision_pipeline_hold_stale",
          "unexpected evaluate_intent result: #{inspect(other)}"
        )
    end
  end

  defp check_replay_carries_morpho_evidence(workspace_id, snapshot, rules) do
    intent = build_intent(workspace_id, @safe_vault, "750")

    with {:ok, _} <-
           Decisions.evaluate_intent(intent, morpho_snapshot: snapshot, rules: rules),
         {:ok, bundle} <- Audit.replay(intent.id) do
      types = Enum.map(bundle.morpho_evidence, & &1.event_type)

      if "morpho.risk_explained" in types do
        pass(
          "replay_carries_morpho_evidence",
          "bundle.morpho_evidence types=#{inspect(types)}"
        )
      else
        fail(
          "replay_carries_morpho_evidence",
          "morpho.risk_explained absent from bundle.morpho_evidence (#{inspect(types)})"
        )
      end
    else
      other ->
        fail(
          "replay_carries_morpho_evidence",
          "evaluate or replay failed: #{inspect(other)}"
        )
    end
  end

  defp check_secret_hygiene(workspace_id) do
    morpho_events =
      Bank.Audit.AuditEvent
      |> morpho_events_query(workspace_id)
      |> Repo.all()

    case scan_events(morpho_events) do
      [] ->
        pass(
          "secret_hygiene",
          "scanned #{length(morpho_events)} morpho.* audit row(s); no secret markers"
        )

      leaks ->
        fail("secret_hygiene", "secret marker(s) found: #{inspect(leaks)}")
    end
  end

  # --- Helpers -------------------------------------------------------------

  defp pass(name, detail), do: %{name: name, status: :pass, detail: detail}
  defp fail(name, detail), do: %{name: name, status: :fail, detail: detail}

  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short(_), do: ""

  defp safe_policy_input(proposed_amount) do
    %PolicyInput{
      PolicyInput.default()
      | vault_allowlist: [{@chain_id, @safe_vault}, {@chain_id, @stale_vault}],
        oracle_allowlist: [@oracle],
        collateral_allowlist: [@collateral],
        curator_allowlist: [@allocator],
        expected_loan_asset: "USDC",
        proposed_amount: proposed_amount,
        exposure_cap: Decimal.new("1000000")
    }
  end

  defp morpho_explanation(%DecisionEnvelope{reasons: %{"items" => [item | _]}}),
    do: get_in(item, ["details", "morpho_risk_explanation"])

  defp morpho_explanation(_), do: nil

  defp no_block_reasons?(%{"primary_reasons" => reasons}) when is_list(reasons),
    do: not Enum.any?(reasons, &(&1["severity"] == "block"))

  defp no_block_reasons?(_), do: false

  defp has_mvp_morpho_deposit_reason?(%{"primary_reasons" => reasons}) when is_list(reasons),
    do: Enum.any?(reasons, &(&1["code"] == "mvp_morpho_deposit"))

  defp has_mvp_morpho_deposit_reason?(_), do: false

  defp block_reason_present?(%{"primary_reasons" => reasons}, code) when is_list(reasons),
    do: Enum.any?(reasons, &(&1["code"] == code and &1["severity"] == "block"))

  defp block_reason_present?(_, _), do: false

  defp hold_reason_present_for_freshness?(%{"primary_reasons" => reasons})
       when is_list(reasons) do
    Enum.any?(reasons, fn r ->
      r["severity"] == "hold" and is_binary(r["code"]) and
        String.starts_with?(r["code"], "freshness_")
    end)
  end

  defp hold_reason_present_for_freshness?(_), do: false

  defp scan_events(events) do
    Enum.flat_map(events, fn e ->
      blob = inspect(e.after_ref)

      case Enum.find(@secret_markers, &Regex.match?(&1, blob)) do
        nil -> []
        marker -> [{:morpho_audit, e.id, marker}]
      end
    end)
  end

  defp morpho_events_query(schema, workspace_id) do
    Ecto.Query.from(e in schema,
      where:
        e.workspace_id == ^workspace_id and
          like(e.event_type, "morpho.%")
    )
  end
end
