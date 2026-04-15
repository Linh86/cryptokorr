defmodule Bank.Decisions.SimulationReportTest do
  use Bank.DataCase, async: true

  alias Bank.Decisions.SimulationReport
  alias Bank.Fixtures

  describe "stale?/2" do
    test "false before freshness_ttl_seconds elapses" do
      now = DateTime.utc_now()
      report = Fixtures.simulation_report(generated_at: now, freshness_ttl_seconds: 60)
      refute SimulationReport.stale?(report, now)
    end

    test "true once freshness_ttl_seconds has elapsed" do
      now = DateTime.utc_now()

      report =
        Fixtures.simulation_report(
          generated_at: DateTime.add(now, -120, :second),
          freshness_ttl_seconds: 30
        )

      assert SimulationReport.stale?(report, now)
    end
  end

  describe "current invariant" do
    test "rejects a second current simulation per intent" do
      intent = Fixtures.agent_intent()
      _first = Fixtures.simulation_report(intent: intent, current: true)

      {:error, changeset} =
        %SimulationReport{}
        |> SimulationReport.changeset(%{
          intent_id: intent.id,
          provider: "tenderly",
          chain: "base",
          asset: "USDC",
          generated_at: DateTime.utc_now(),
          freshness_ttl_seconds: 30,
          status: :pending,
          current: true
        })
        |> Repo.insert()

      refute changeset.valid?

      assert errors_on(changeset)[:intent_id] == [
               "another current simulation already exists for this intent"
             ]
    end
  end

  describe "changeset/2" do
    test "rejects non-positive freshness_ttl_seconds" do
      intent = Fixtures.agent_intent()

      changeset =
        SimulationReport.changeset(%SimulationReport{}, %{
          intent_id: intent.id,
          provider: "tenderly",
          chain: "base",
          asset: "USDC",
          generated_at: DateTime.utc_now(),
          freshness_ttl_seconds: 0,
          status: :pending
        })

      refute changeset.valid?
      assert errors_on(changeset).freshness_ttl_seconds != []
    end
  end
end
