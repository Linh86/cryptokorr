defmodule Bank.Intents.SimulateTest do
  @moduledoc """
  Facade-level tests for `Bank.Intents.simulate/3`.

  Pins the three reason semantics (`pre_submit_dry_run`, `refresh`,
  `operator_inspection`), the state guard (terminal / in-flight
  intents reject), and the audit + replay surface. Controller-level
  HTTP wiring is covered separately under
  `test/bank_web/controllers/api/v1/intent_simulate_controller_test.exs`.
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Bank.Fixtures
  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Decisions.SimulationReport
  alias Bank.Intents
  alias Bank.Intents.AgentIntent

  # `Bank.Quotes.preview/2` defaults to `Bank.Quotes.StubProvider`,
  # which is deterministic and side-effect free — these tests rely on
  # that default. Where a test needs a specific provider error, we
  # twiddle the StubProvider's `:outcome` knob via `Application.put_env`.

  describe "happy paths" do
    test "refresh produces a current report and supersedes the prior current" do
      intent = agent_intent()

      # Seed a prior current simulation so we can prove supersession.
      prior = simulation_report(intent: intent, current: true)

      assert {:ok, result} = Intents.simulate(intent.id, "refresh")

      assert result.reason == "refresh"
      assert result.refreshed?
      assert %SimulationReport{} = result.report
      assert result.report.current
      assert result.report.supersedes_id == prior.id
      assert result.superseded.id == prior.id

      # Prior is demoted.
      refute Repo.get!(SimulationReport, prior.id).current

      # Intent's current_simulation_id advanced.
      assert Repo.get!(AgentIntent, intent.id).current_simulation_id == result.report.id
    end

    test "pre_submit_dry_run produces a non-current report and does not move intent pointer" do
      intent = agent_intent()
      prior = simulation_report(intent: intent, current: true)
      original_pointer = Repo.get!(AgentIntent, intent.id).current_simulation_id

      assert {:ok, result} = Intents.simulate(intent.id, "pre_submit_dry_run")

      refute result.refreshed?
      refute result.report.current
      assert is_nil(result.superseded)

      # Prior current is untouched.
      assert Repo.get!(SimulationReport, prior.id).current
      assert Repo.get!(AgentIntent, intent.id).current_simulation_id == original_pointer
    end

    test "operator_inspection mirrors pre_submit_dry_run (non-current report)" do
      intent = agent_intent()

      assert {:ok, result} = Intents.simulate(intent.id, "operator_inspection")

      refute result.refreshed?
      refute result.report.current
      assert result.reason == "operator_inspection"
    end

    test "failed preview persists a :failed report (still no execution dispatch)" do
      Application.put_env(:bank, Bank.Quotes.StubProvider, outcome: :unavailable)
      on_exit(fn -> Application.put_env(:bank, Bank.Quotes.StubProvider, []) end)

      intent = agent_intent()

      assert {:ok, result} = Intents.simulate(intent.id, "refresh")

      assert result.report.status == :failed
      assert result.report.current

      assert get_in(result.report.failure_conditions, ["items"]) |> List.first() == %{
               "kind" => "preview_failed",
               "message" => "preview provider unavailable"
             }
    end

    test "refresh with a failed preview AND a prior current still demotes the prior" do
      # Pins a non-obvious choice: a refresh that asks the provider and
      # hits an error (e.g. provider unavailable) replaces a previously
      # successful current simulation with a `:failed` one as current.
      # Rationale: the operator/agent explicitly asked to refresh, so a
      # stale "good" simulation is not the right thing to keep as
      # current — the autonomy router reads `current` and will route to
      # `:hold` / `:block` on a `:failed` status, which is the safe
      # outcome.
      Application.put_env(:bank, Bank.Quotes.StubProvider, outcome: :unavailable)
      on_exit(fn -> Application.put_env(:bank, Bank.Quotes.StubProvider, []) end)

      intent = agent_intent()
      prior = simulation_report(intent: intent, current: true, status: :completed)

      assert {:ok, result} = Intents.simulate(intent.id, "refresh")

      assert result.report.status == :failed
      assert result.report.current
      assert result.report.supersedes_id == prior.id
      assert result.superseded.id == prior.id

      # Prior was demoted even though the new report is :failed.
      refute Repo.get!(SimulationReport, prior.id).current

      # Intent pointer advanced to the new (failed) report.
      assert Repo.get!(AgentIntent, intent.id).current_simulation_id == result.report.id
    end

    test "writes an audit event (`simulation.requested`) and `simulation.produced` on refresh" do
      intent = agent_intent()
      assert {:ok, _} = Intents.simulate(intent.id, "refresh")

      events = audit_event_types_for(intent.id)
      assert "simulation.requested" in events
      assert "simulation.produced" in events
    end

    test "writes only `simulation.requested` on dry-run" do
      intent = agent_intent()
      assert {:ok, _} = Intents.simulate(intent.id, "pre_submit_dry_run")

      events = audit_event_types_for(intent.id)
      assert "simulation.requested" in events
      refute "simulation.produced" in events
    end
  end

  describe "state guards" do
    for state <- [:executing, :executed, :cancelled, :expired] do
      @state state

      test "rejects simulation for #{@state} intent" do
        intent = bump_state!(agent_intent(), @state)

        assert {:error, {:wrong_state, @state}} = Intents.simulate(intent.id, "refresh")

        assert Repo.aggregate(SimulationReport, :count, :id) == 0
      end
    end

    test "returns :not_found for an unknown id" do
      assert {:error, :not_found} =
               Intents.simulate(Ecto.UUID.generate(), "refresh")
    end

    test "returns :not_found for a malformed UUID" do
      assert {:error, :not_found} = Intents.simulate("not-a-uuid", "refresh")
    end
  end

  describe "live provider attribution on failure (#175)" do
    # Pre-#175, a failed `Bank.Quotes.preview/2` always persisted
    # `provider: "stub"` on the resulting `:failed` SimulationReport
    # because the failure path fell back to a system default. Post-#175,
    # the attempted provider is recorded so an operator can tell
    # which path failed — the live HTTP simulation, the stub, or a
    # disabled deployment.

    test "failed live preview persists provider: 'tenderly' on the report" do
      Req.Test.stub(Bank.Quotes.LiveProvider, fn conn ->
        Plug.Conn.send_resp(conn, 503, "")
      end)

      intent = agent_intent()

      assert {:ok, result} = Intents.simulate(intent.id, "refresh", provider: :live)

      assert result.report.status == :failed
      assert result.report.provider == "tenderly"
      assert result.report.current
    end

    test "successful live preview persists provider: 'tenderly' on the completed report" do
      Req.Test.stub(Bank.Quotes.LiveProvider, fn conn ->
        Req.Test.json(conn, %{
          "success" => true,
          "trace_id" => "tenderly-trace-#{System.unique_integer([:positive])}",
          "estimated_gas" => 110_000,
          "estimated_fee" => "0.00012",
          "fee_asset" => "ETH",
          "balance_changes" => %{"USDC" => "-1"},
          "failure_conditions" => [],
          "risk_flags" => [],
          "freshness_ttl_seconds" => 30
        })
      end)

      intent = agent_intent()

      assert {:ok, result} = Intents.simulate(intent.id, "refresh", provider: :live)

      assert result.report.status == :completed
      assert result.report.provider == "tenderly"
      assert is_binary(result.report.provider_trace_ref)
    end

    test "failed stub preview still persists provider: 'stub' (regression)" do
      Application.put_env(:bank, Bank.Quotes.StubProvider, outcome: :unavailable)
      on_exit(fn -> Application.put_env(:bank, Bank.Quotes.StubProvider, []) end)

      intent = agent_intent()

      assert {:ok, result} = Intents.simulate(intent.id, "refresh")

      assert result.report.status == :failed
      assert result.report.provider == "stub"
    end

    test "failed disabled-provider preview persists provider: 'disabled'" do
      intent = agent_intent()

      assert {:ok, result} = Intents.simulate(intent.id, "refresh", provider: :disabled)

      assert result.report.status == :failed
      assert result.report.provider == "disabled"
    end
  end

  describe "input validation" do
    test "rejects an unsupported reason with :invalid_reason" do
      intent = agent_intent()

      assert {:error, {:invalid_reason, "force_run"}} =
               Intents.simulate(intent.id, "force_run")
    end

    test "rejects a non-string reason with :invalid_reason" do
      intent = agent_intent()
      assert {:error, {:invalid_reason, nil}} = Intents.simulate(intent.id, nil)
    end
  end

  describe "no execution dispatch" do
    test "simulate never enqueues RunExecution, even on refresh" do
      intent = agent_intent()
      assert {:ok, _} = Intents.simulate(intent.id, "refresh")

      refute_enqueued(worker: Bank.Runtime.Workers.RunExecution)
      refute_enqueued(worker: Bank.Runtime.Workers.ConfirmExecution)
      assert Repo.aggregate(Bank.Decisions.ExecutionPlan, :count, :id) == 0
    end
  end

  describe "replay integration" do
    test "replay surfaces both the prior and the new simulation in deterministic order" do
      intent = agent_intent()

      # Seed the prior with a clearly-earlier generated_at. The fixture
      # default uses a monotonic offset that, under heavy precommit
      # load, can drift past the wall-clock `DateTime.utc_now/0` the
      # `Quotes.preview/2` stub uses — pinning a definite past
      # timestamp here keeps the (generated_at asc, id asc) replay
      # ordering deterministic across precommit interleavings.
      prior =
        simulation_report(
          intent: intent,
          current: true,
          generated_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      assert {:ok, %{report: new_report}} = Intents.simulate(intent.id, "refresh")

      {:ok, bundle} = Bank.Audit.replay(intent.id)

      simulation_ids = Enum.map(bundle.simulations, & &1.id)
      assert prior.id in simulation_ids
      assert new_report.id in simulation_ids

      assert Enum.find_index(simulation_ids, &(&1 == prior.id)) <
               Enum.find_index(simulation_ids, &(&1 == new_report.id))
    end
  end

  defp bump_state!(intent, state) do
    {:ok, updated} =
      intent
      |> AgentIntent.current_pointer_changeset(%{state: state})
      |> Repo.update()

    updated
  end

  defp audit_event_types_for(intent_id) do
    Repo.all(
      from(e in AuditEvent,
        where: e.correlation_id == ^intent_id,
        order_by: [asc: e.ts, asc: e.id],
        select: e.event_type
      )
    )
  end
end
