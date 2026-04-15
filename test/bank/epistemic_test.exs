defmodule Bank.EpistemicTest do
  use Bank.DataCase, async: true

  alias Bank.Epistemic
  alias Bank.Fixtures

  describe "classify/2 — raw-address intents" do
    test "returns unknown/low regardless of evidence" do
      # Build directly — fixture helper always attaches a counterparty.
      {:ok, intent} =
        %Bank.Intents.AgentIntent{}
        |> Bank.Intents.AgentIntent.changeset(%{
          agent_id: "agent-raw",
          source: :agent,
          idempotency_key: "idem-raw-#{System.unique_integer([:positive])}",
          payload_hash: String.duplicate("a", 64),
          kind: :transfer,
          asset: "USDC",
          chain: "base",
          amount: Decimal.new("10"),
          target_raw_address: "0x" <> String.duplicate("ab", 20),
          submitted_at: DateTime.utc_now()
        })
        |> Bank.Repo.insert()

      claim = Epistemic.classify(intent)

      assert claim.derived_trust == :unknown
      assert claim.confidence == :low
      assert claim.supporting_assertion_ids == []
      assert claim.rationale["kind"] == "raw_address"
    end
  end

  describe "classify/2 — no covering assertion" do
    test "counterparty with no assertions → unknown/low with missing_evidence contradiction" do
      cp = Fixtures.counterparty(name: "No Assertions")
      intent = Fixtures.agent_intent(counterparty: cp)

      claim = Epistemic.classify(intent)

      assert claim.derived_trust == :unknown
      assert claim.confidence == :low
      assert [%{"kind" => "missing_evidence"}] = claim.contradictions["items"]
    end

    test "counterparty with an assertion whose scope does not cover candidate" do
      cp = Fixtures.counterparty(name: "Scoped Only")

      _assertion =
        Fixtures.trust_assertion(%{
          subject: cp,
          level: :trusted,
          scope: %{"chain" => "ethereum"}
        })

      intent = Fixtures.agent_intent(counterparty: cp, chain: "base")
      claim = Epistemic.classify(intent)

      assert claim.derived_trust == :unknown
      assert claim.supporting_assertion_ids == []
    end
  end

  describe "classify/2 — dominant assertion" do
    test "broad trusted assertion classifies candidate as trusted" do
      cp = Fixtures.counterparty(name: "Broad Trusted")

      a =
        Fixtures.trust_assertion(%{
          subject: cp,
          level: :trusted,
          scope: %{},
          issued_by: :user
        })

      intent = Fixtures.agent_intent(counterparty: cp, asset: "USDC", chain: "base")
      claim = Epistemic.classify(intent)

      assert claim.derived_trust == :trusted
      assert claim.confidence == :medium
      assert a.id in claim.supporting_assertion_ids
    end

    test "sensitive dominates trusted" do
      cp = Fixtures.counterparty(name: "Sensitive + Trusted")

      Fixtures.trust_assertion(%{subject: cp, level: :trusted, scope: %{}})
      _sens = Fixtures.trust_assertion(%{subject: cp, level: :sensitive, scope: %{}})

      intent = Fixtures.agent_intent(counterparty: cp)
      claim = Epistemic.classify(intent)

      assert claim.derived_trust == :conflicted
      items = claim.contradictions["items"]
      assert Enum.any?(items, &(&1["kind"] == "level_disagreement"))
    end

    test "scoped trusted + unknown broader → conflicted" do
      cp = Fixtures.counterparty(name: "Mixed")

      Fixtures.trust_assertion(%{subject: cp, level: :trusted, scope: %{"asset" => "USDC"}})
      Fixtures.trust_assertion(%{subject: cp, level: :unknown, scope: %{}})

      intent = Fixtures.agent_intent(counterparty: cp, asset: "USDC")
      claim = Epistemic.classify(intent)

      assert claim.derived_trust == :conflicted
      assert claim.confidence == :low
    end

    test "strong evidence bumps confidence to high" do
      cp = Fixtures.counterparty(name: "With Evidence")
      evidence = Fixtures.evidence_artifact(%{subject: cp, kind: :signed_message})
      Fixtures.trust_assertion(%{subject: cp, level: :trusted, scope: %{}, issued_by: :user})

      intent = Fixtures.agent_intent(counterparty: cp)
      claim = Epistemic.classify(intent)

      assert claim.derived_trust == :trusted
      assert claim.confidence == :high
      assert evidence.id in claim.supporting_evidence_ids
    end
  end

  describe "classify/2 — scope coverage rules" do
    test "amount_ceiling scope covers amounts at or below ceiling" do
      cp = Fixtures.counterparty(name: "Payroll")

      Fixtures.trust_assertion(%{
        subject: cp,
        level: :trusted,
        scope: %{"asset" => "USDC", "amount_ceiling" => "500"}
      })

      small = Fixtures.agent_intent(counterparty: cp, asset: "USDC", amount: Decimal.new("250"))
      big = Fixtures.agent_intent(counterparty: cp, asset: "USDC", amount: Decimal.new("750"))

      assert Epistemic.classify(small).derived_trust == :trusted
      assert Epistemic.classify(big).derived_trust == :unknown
    end
  end
end
