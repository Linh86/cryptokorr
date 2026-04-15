defmodule Bank.Policies.PolicyRuleTest do
  use Bank.DataCase, async: true

  alias Bank.Fixtures
  alias Bank.Policies.PolicyRule

  describe "changeset/2" do
    test "requires rule_type and created_by" do
      changeset = PolicyRule.changeset(%PolicyRule{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.rule_type
      assert "can't be blank" in errors.created_by
    end

    test "rejects an unknown rule_type or state" do
      changeset =
        PolicyRule.changeset(%PolicyRule{}, %{
          rule_type: :unicorn_cap,
          params: %{},
          created_by: :user,
          state: :haunted
        })

      refute changeset.valid?
    end

    test "accepts a minimal valid payload" do
      changeset =
        PolicyRule.changeset(%PolicyRule{}, %{
          rule_type: :amount_limit,
          params: %{"max" => "250"},
          created_by: :user,
          state: :draft
        })

      assert changeset.valid?
    end
  end

  describe "supersession chain" do
    test "supersede/2 carries rule_type, bumps version, links the chain" do
      prior =
        Fixtures.policy_rule(
          rule_type: :amount_limit,
          params: %{"max" => "100"},
          version: 1
        )

      {:ok, successor} =
        prior
        |> PolicyRule.supersede(%{
          params: %{"max" => "250"},
          created_by: :user
        })
        |> Repo.insert()

      assert successor.rule_type == :amount_limit
      assert successor.version == 2
      assert successor.supersedes_id == prior.id
      assert successor.state == :active
    end

    test "mark_superseded/1 flips the prior state" do
      rule = Fixtures.policy_rule(state: :active)

      {:ok, flipped} =
        rule
        |> PolicyRule.mark_superseded()
        |> Repo.update()

      assert flipped.state == :superseded
    end

    test "activate/1 flips draft into active" do
      rule = Fixtures.policy_rule(state: :draft)
      {:ok, active} = rule |> PolicyRule.activate() |> Repo.update()
      assert active.state == :active
    end
  end
end
