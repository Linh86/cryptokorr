defmodule Bank.IntentsTest do
  @moduledoc """
  Context-level tests for `Bank.Intents.counts_by_state/1`.

  Pins the semantics chosen for issue #53: counts respect `:kind` and
  `:search`, but not `:state` — the breakdown groups by state itself
  so applying a state filter would be useless. The intents page
  relies on this to show a meaningful distribution inside the
  operator's current kind/search scope.
  """

  use Bank.DataCase, async: false

  import Bank.Fixtures

  alias Bank.Intents

  describe "counts_by_state/1 with no filters" do
    test "returns all known states with zero when the table is empty" do
      counts = Intents.counts_by_state()

      for state <- [
            :submitted,
            :evaluating,
            :decided,
            :executing,
            :executed,
            :blocked,
            :cancelled,
            :expired
          ] do
        assert Map.fetch!(counts, state) == 0
      end
    end

    test "groups intents by state across all kinds" do
      _a = agent_intent(kind: :transfer)
      _b = agent_intent(kind: :transfer)

      swap = agent_intent(kind: :swap)
      {:ok, _} = swap |> Ecto.Changeset.change(%{state: :blocked}) |> Bank.Repo.update()

      counts = Intents.counts_by_state()

      assert counts.submitted == 2
      assert counts.blocked == 1
    end
  end

  describe "counts_by_state/1 scoped by :kind" do
    test "only counts intents whose kind matches" do
      _transfer = agent_intent(kind: :transfer)
      swap1 = agent_intent(kind: :swap)
      swap2 = agent_intent(kind: :swap)
      {:ok, _} = swap2 |> Ecto.Changeset.change(%{state: :executed}) |> Bank.Repo.update()

      counts = Intents.counts_by_state(kind: :swap)

      # Two swaps: one submitted, one executed. The transfer is not counted.
      assert counts.submitted == 1
      assert counts.executed == 1
      assert counts.blocked == 0

      _ = swap1
    end

    test "kind=:all is equivalent to no filter" do
      _a = agent_intent(kind: :transfer)
      _b = agent_intent(kind: :swap)

      assert Intents.counts_by_state(kind: :all) == Intents.counts_by_state()
    end
  end

  describe "counts_by_state/1 scoped by :search" do
    test "matches on agent_id substring" do
      _alpha = agent_intent(agent_id: "agent-alpha")
      _beta = agent_intent(agent_id: "agent-beta")

      counts = Intents.counts_by_state(search: "alpha")

      assert counts.submitted == 1
    end

    test "matches on intent id prefix" do
      target = agent_intent()
      _other = agent_intent()

      prefix = String.slice(target.id, 0, 8)
      counts = Intents.counts_by_state(search: prefix)

      assert counts.submitted == 1
    end

    test "empty and whitespace-only search is ignored" do
      _a = agent_intent()
      _b = agent_intent()

      assert Intents.counts_by_state(search: "").submitted == 2
      assert Intents.counts_by_state(search: "   ").submitted == 2
    end
  end

  describe "counts_by_state/1 — :state opt is ignored by design" do
    test "counts ignore the :state opt even when supplied" do
      submitted = agent_intent()
      blocked = agent_intent()
      {:ok, _} = blocked |> Ecto.Changeset.change(%{state: :blocked}) |> Bank.Repo.update()

      # Even though we pass state: :blocked, the breakdown still shows
      # submitted=1, blocked=1. This is the contract the intents page
      # relies on: chips remain meaningful navigation targets.
      counts = Intents.counts_by_state(state: :blocked)

      assert counts.submitted == 1
      assert counts.blocked == 1

      _ = submitted
    end
  end

  describe "counts_by_state/1 combined with :kind + :search" do
    test "applies both filters conjunctively" do
      # Two transfers with "alpha" in the agent_id; one stays submitted,
      # one is moved to executed.
      t1 = agent_intent(kind: :transfer, agent_id: "agent-alpha-1")
      t2 = agent_intent(kind: :transfer, agent_id: "agent-alpha-2")
      {:ok, _} = t2 |> Ecto.Changeset.change(%{state: :executed}) |> Bank.Repo.update()

      # Noise that must NOT be counted.
      _swap_alpha = agent_intent(kind: :swap, agent_id: "agent-alpha-swap")
      _transfer_other = agent_intent(kind: :transfer, agent_id: "agent-other")

      counts = Intents.counts_by_state(kind: :transfer, search: "alpha")

      assert counts.submitted == 1
      assert counts.executed == 1
      assert counts.blocked == 0

      _ = t1
    end
  end
end
