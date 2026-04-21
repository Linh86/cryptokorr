defmodule Bank.AutonomyScreeningTest do
  use Bank.DataCase, async: true

  alias Bank.Autonomy
  alias Bank.Fixtures
  alias Bank.Policies.Evaluation
  alias Bank.WalletScreening

  defp passing_eval do
    Evaluation.build(%{
      violations: [],
      matched_rule_ids: [],
      autonomy_tier: :auto,
      constraints: %{},
      evaluated_at: DateTime.utc_now()
    })
  end

  defp base_inputs(intent, overrides \\ %{}) do
    Map.merge(
      %{
        intent: intent,
        policy: passing_eval(),
        trust: %{derived_trust: :trusted, confidence: :high},
        preview: {:ok, %Bank.Quotes.Preview{provider: "test"}},
        paused?: false
      },
      overrides
    )
  end

  defp insert_screening!(attrs) do
    {:ok, _} = WalletScreening.upsert_record(attrs)
  end

  describe "screening: hard_block" do
    test "sanctions hit forces block with screening rationale" do
      insert_screening!(%{
        chain: "base",
        address: "0xSanctionedAutonomy001",
        control_tier: :hard_block,
        source: "ofac",
        source_record_id: "sdn-auto-001",
        category: "sanctions",
        reason: "OFAC SDN: LAZARUS GROUP"
      })

      intent =
        Fixtures.agent_intent(
          target_counterparty_id: nil,
          target_raw_address: "0xSanctionedAutonomy001",
          chain: "base"
        )

      decision = Autonomy.route(base_inputs(intent))

      assert decision.outcome == :block
      assert decision.risk_tier == :severe
      assert decision.reason_code == :wallet_screening_hard_block
      assert decision.reason =~ "sanctioned"
      assert decision.rationale.screening_source == "ofac"
      assert decision.rationale.screening_reason =~ "LAZARUS"
    end

    test "sanctions hit still blocks when preview is unavailable" do
      insert_screening!(%{
        chain: "base",
        address: "0xSanctionedPreviewDown001",
        control_tier: :hard_block,
        source: "ofac",
        source_record_id: "sdn-preview-down-001",
        category: "sanctions",
        reason: "OFAC SDN: preview outage must not hide sanctions"
      })

      intent =
        Fixtures.agent_intent(
          target_counterparty_id: nil,
          target_raw_address: "0xSanctionedPreviewDown001",
          chain: "base"
        )

      decision = Autonomy.route(base_inputs(intent, %{preview: {:error, :provider_unavailable}}))

      assert decision.outcome == :block
      assert decision.reason_code == :wallet_screening_hard_block
    end

    test "hard_block beats challenge through screening precedence" do
      insert_screening!(%{
        chain: "base",
        address: "0xMixedAutonomy002",
        control_tier: :hard_block,
        source: "ofac",
        source_record_id: "sdn-auto-002",
        category: "sanctions",
        reason: "OFAC sanctioned"
      })

      insert_screening!(%{
        chain: "base",
        address: "0xMixedAutonomy002",
        control_tier: :challenge,
        source: "scamsniffer",
        source_record_id: "ss-auto-002",
        category: "phishing",
        reason: "ScamSniffer phishing"
      })

      intent =
        Fixtures.agent_intent(
          target_counterparty_id: nil,
          target_raw_address: "0xMixedAutonomy002",
          chain: "base"
        )

      decision = Autonomy.route(base_inputs(intent))

      assert decision.outcome == :block
      assert decision.reason_code == :wallet_screening_hard_block
    end
  end

  describe "screening: challenge" do
    test "scam feed hit forces approval_required" do
      insert_screening!(%{
        chain: "base",
        address: "0xScamAutonomy003",
        control_tier: :challenge,
        source: "scamsniffer",
        source_record_id: "ss-auto-003",
        category: "phishing",
        reason: "ScamSniffer: phishing — Inferno Drainer"
      })

      intent =
        Fixtures.agent_intent(
          target_counterparty_id: nil,
          target_raw_address: "0xScamAutonomy003",
          chain: "base"
        )

      decision = Autonomy.route(base_inputs(intent))

      assert decision.outcome == :approval_required
      assert decision.risk_tier == :elevated
      assert decision.reason_code == :wallet_screening_challenge
      assert decision.reason =~ "scam" or decision.reason =~ "phishing"
      assert decision.rationale.screening_source == "scamsniffer"
    end
  end

  describe "screening: context-only" do
    test "context record does not change autonomy outcome" do
      insert_screening!(%{
        chain: "base",
        address: "0xContextAutonomy004",
        control_tier: :context,
        source: "graphsense",
        source_record_id: "gs-auto-004",
        category: "exchange",
        reason: "GraphSense: Binance"
      })

      intent =
        Fixtures.agent_intent(
          target_counterparty_id: nil,
          target_raw_address: "0xContextAutonomy004",
          chain: "base"
        )

      decision = Autonomy.route(base_inputs(intent))

      assert decision.outcome == :auto_exec
      assert decision.risk_tier == :low
      assert decision.rationale.screening.status == :clean
      assert decision.rationale.screening.winning_source == "graphsense"
    end
  end

  describe "screening: score_only" do
    test "score_only record does not change autonomy outcome" do
      insert_screening!(%{
        chain: "base",
        address: "0xScoreAutonomy005",
        control_tier: :score_only,
        source: "internal_scoring",
        source_record_id: "score-auto-005",
        category: "suspicious",
        reason: "Internal scoring: suspicious",
        score: Decimal.new("0.85"),
        score_version: "v2.1"
      })

      intent =
        Fixtures.agent_intent(
          target_counterparty_id: nil,
          target_raw_address: "0xScoreAutonomy005",
          chain: "base"
        )

      decision = Autonomy.route(base_inputs(intent))

      assert decision.outcome == :auto_exec
      assert decision.rationale.screening.status == :clean
    end
  end

  describe "screening: clean / no-hit" do
    test "clean address preserves normal autonomy behavior" do
      intent =
        Fixtures.agent_intent(
          target_counterparty_id: nil,
          target_raw_address: "0xCleanAutonomy006",
          chain: "base"
        )

      decision = Autonomy.route(base_inputs(intent))

      assert decision.outcome == :auto_exec
      assert decision.rationale.screening.status == :clean
    end
  end

  describe "screening: address resolution" do
    test "screens address label target" do
      cp = Fixtures.counterparty()

      label =
        Fixtures.address_label(counterparty: cp, chain: "ethereum", address: "0xLabelTarget007")

      insert_screening!(%{
        chain: "ethereum",
        address: "0xLabelTarget007",
        control_tier: :hard_block,
        source: "opensanctions",
        source_record_id: "os-auto-007",
        category: "sanctions",
        reason: "OpenSanctions sanctioned"
      })

      intent =
        Fixtures.agent_intent(
          counterparty: cp,
          target_address_label_id: label.id,
          chain: "base"
        )

      decision = Autonomy.route(base_inputs(intent))

      assert decision.outcome == :block
      assert decision.reason_code == :wallet_screening_hard_block
      assert decision.rationale.screening.chain == "ethereum"
    end

    test "screens counterparty-only target when exactly one active label matches the intent chain" do
      cp = Fixtures.counterparty()

      _label =
        Fixtures.address_label(counterparty: cp, chain: "base", address: "0xCounterpartyOnly008")

      insert_screening!(%{
        chain: "base",
        address: "0xCounterpartyOnly008",
        control_tier: :challenge,
        source: "scamsniffer",
        source_record_id: "ss-auto-008",
        category: "phishing",
        reason: "ScamSniffer counterparty-only target"
      })

      intent = Fixtures.agent_intent(counterparty: cp, chain: "base")

      decision = Autonomy.route(base_inputs(intent))

      assert decision.outcome == :approval_required
      assert decision.reason_code == :wallet_screening_challenge
      assert decision.rationale.screening.address == "0xCounterpartyOnly008"
    end

    test "counterparty-only intent with no active label gets explicit unresolved screening" do
      intent = Fixtures.agent_intent()

      decision = Autonomy.route(base_inputs(intent))

      assert decision.outcome == :hold
      assert decision.reason_code == :wallet_screening_unresolved
      assert decision.rationale.screening.status == :unresolved
      assert decision.rationale.screening.reason == :no_active_label
    end
  end

  describe "screening: annotation in rationale" do
    test "screening annotation present even when screening does not determine outcome" do
      intent =
        Fixtures.agent_intent(
          target_counterparty_id: nil,
          target_raw_address: "0xAnnotated008",
          chain: "base"
        )

      decision = Autonomy.route(base_inputs(intent))

      assert is_map(decision.rationale.screening)
      assert decision.rationale.screening.status in [:clean, :not_applicable]
    end
  end
end
