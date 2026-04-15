defmodule Bank.Runtime.Workers.RunExecutionTest do
  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Fixtures
  alias Bank.Runtime.Workers.RunExecution

  test "cancels with :adapter_pending on a current auto_exec envelope" do
    decision = Fixtures.decision_envelope(current: true, outcome: :auto_exec)

    assert {:cancel, :adapter_pending} =
             perform_job(RunExecution, %{"decision_id" => decision.id})
  end

  test "cancels with :not_found for unknown decision id" do
    assert {:cancel, :not_found} =
             perform_job(RunExecution, %{"decision_id" => Ecto.UUID.generate()})
  end

  test "cancels with :not_current when the envelope has been superseded" do
    decision = Fixtures.decision_envelope(current: false, outcome: :auto_exec)

    assert {:cancel, :not_current} =
             perform_job(RunExecution, %{"decision_id" => decision.id})
  end

  test "cancels with {:wrong_outcome, outcome} for non-auto_exec envelopes" do
    expires_at = DateTime.add(DateTime.utc_now(), 300, :second)

    decision =
      Fixtures.decision_envelope(
        current: true,
        outcome: :approval_required,
        approval_expires_at: expires_at
      )

    assert {:cancel, {:wrong_outcome, :approval_required}} =
             perform_job(RunExecution, %{"decision_id" => decision.id})

    # Still the current envelope; nothing was mutated.
    assert %DecisionEnvelope{current: true} = Repo.get!(DecisionEnvelope, decision.id)
  end
end
