defmodule Bank.Counterparties.TrustAssertionTest do
  use Bank.DataCase, async: true

  alias Bank.Counterparties.TrustAssertion
  alias Bank.Fixtures

  describe "supersession" do
    test "stamps superseded_at via mark_superseded/2" do
      assertion = Fixtures.trust_assertion()

      {:ok, superseded} =
        assertion
        |> TrustAssertion.mark_superseded(DateTime.utc_now())
        |> Repo.update()

      assert superseded.superseded_at
    end

    test "supersede/2 builds successor with subject carried over" do
      cp = Fixtures.counterparty()
      prior = Fixtures.trust_assertion(subject: cp, level: :sensitive)

      {:ok, successor} =
        prior
        |> TrustAssertion.supersede(%{
          level: :trusted,
          issued_at: DateTime.utc_now(),
          issued_by: :user
        })
        |> Repo.insert()

      assert successor.subject_type == "counterparty"
      assert successor.subject_id == cp.id
      assert successor.supersedes_id == prior.id
      assert successor.level == :trusted
    end
  end

  describe "effective?/2" do
    test "true when not superseded and not expired" do
      assertion = Fixtures.trust_assertion(level: :trusted)
      assert TrustAssertion.effective?(assertion)
    end

    test "false when superseded_at is set" do
      assertion = Fixtures.trust_assertion(superseded_at: DateTime.utc_now())
      refute TrustAssertion.effective?(assertion)
    end

    test "false when expires_at has passed" do
      past = DateTime.add(DateTime.utc_now(), -60, :second)
      assertion = Fixtures.trust_assertion(expires_at: past)
      refute TrustAssertion.effective?(assertion)
    end

    test "true when expires_at is in the future" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assertion = Fixtures.trust_assertion(expires_at: future)
      assert TrustAssertion.effective?(assertion)
    end
  end

  describe "changeset/2" do
    test "rejects an unknown level" do
      changeset =
        TrustAssertion.changeset(%TrustAssertion{}, %{
          subject_type: "counterparty",
          subject_id: Ecto.UUID.generate(),
          level: :ambivalent,
          issued_at: DateTime.utc_now(),
          issued_by: :runtime
        })

      refute changeset.valid?
    end

    test "rejects a bad subject_type" do
      changeset =
        TrustAssertion.changeset(%TrustAssertion{}, %{
          subject_type: "chainlink_oracle",
          subject_id: Ecto.UUID.generate(),
          level: :trusted,
          issued_at: DateTime.utc_now(),
          issued_by: :runtime
        })

      refute changeset.valid?
    end
  end
end
