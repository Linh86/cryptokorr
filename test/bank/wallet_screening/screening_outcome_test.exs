defmodule Bank.WalletScreening.ScreeningOutcomeTest do
  use ExUnit.Case, async: true

  alias Bank.WalletScreening.{ScreeningOutcome, ScreeningRecord}

  defp record(tier, source \\ "test", opts \\ []) do
    %ScreeningRecord{
      id: Ecto.UUID.generate(),
      chain: Keyword.get(opts, :chain, "base"),
      address: "0xabc",
      normalised_address: "0xabc",
      control_tier: tier,
      source: source,
      source_record_id: "rec-#{System.unique_integer([:positive])}",
      category: Keyword.get(opts, :category),
      reason: Keyword.get(opts, :reason),
      updated_at: DateTime.utc_now()
    }
  end

  describe "from_records/1" do
    test "empty list produces :clean outcome" do
      assert %ScreeningOutcome{outcome: :clean, winning_record: nil, all_records: []} =
               ScreeningOutcome.from_records([])
    end

    test "single hard_block produces :block" do
      rec = record(:hard_block, "ofac")

      result = ScreeningOutcome.from_records([rec])

      assert result.outcome == :block
      assert result.winning_record == rec
      assert result.all_records == [rec]
    end

    test "single challenge produces :challenge" do
      rec = record(:challenge, "scamsniffer")

      result = ScreeningOutcome.from_records([rec])

      assert result.outcome == :challenge
      assert result.winning_record == rec
    end

    test "single context produces :clean" do
      rec = record(:context, "graphsense")

      result = ScreeningOutcome.from_records([rec])

      assert result.outcome == :clean
      assert result.context_records == [rec]
    end

    test "single score_only produces :clean" do
      rec = record(:score_only, "internal_model")

      result = ScreeningOutcome.from_records([rec])

      assert result.outcome == :clean
      assert result.score_records == [rec]
    end
  end

  describe "precedence" do
    test "hard_block wins over challenge" do
      hb = record(:hard_block, "ofac")
      ch = record(:challenge, "scamsniffer")

      result = ScreeningOutcome.from_records([ch, hb])

      assert result.outcome == :block
      assert result.winning_record.control_tier == :hard_block
      assert length(result.all_records) == 2
    end

    test "hard_block wins over all tiers" do
      records = [
        record(:score_only, "model"),
        record(:context, "graphsense"),
        record(:challenge, "etherscamdb"),
        record(:hard_block, "opensanctions")
      ]

      result = ScreeningOutcome.from_records(records)

      assert result.outcome == :block
      assert result.winning_record.control_tier == :hard_block
    end

    test "challenge wins over context and score_only" do
      records = [
        record(:score_only, "model"),
        record(:context, "graphsense"),
        record(:challenge, "scamsniffer")
      ]

      result = ScreeningOutcome.from_records(records)

      assert result.outcome == :challenge
      assert result.winning_record.control_tier == :challenge
    end

    test "context + score_only produces :clean" do
      records = [
        record(:context, "graphsense"),
        record(:score_only, "model")
      ]

      result = ScreeningOutcome.from_records(records)

      assert result.outcome == :clean
      assert length(result.context_records) == 1
      assert length(result.score_records) == 1
    end
  end

  describe "actionable?/1" do
    test "block is actionable" do
      outcome = %ScreeningOutcome{outcome: :block}
      assert ScreeningOutcome.actionable?(outcome)
    end

    test "challenge is actionable" do
      outcome = %ScreeningOutcome{outcome: :challenge}
      assert ScreeningOutcome.actionable?(outcome)
    end

    test "clean is not actionable" do
      outcome = %ScreeningOutcome{outcome: :clean}
      refute ScreeningOutcome.actionable?(outcome)
    end
  end

  describe "blocked?/1" do
    test "true for block" do
      assert ScreeningOutcome.blocked?(%ScreeningOutcome{outcome: :block})
    end

    test "false for challenge" do
      refute ScreeningOutcome.blocked?(%ScreeningOutcome{outcome: :challenge})
    end

    test "false for clean" do
      refute ScreeningOutcome.blocked?(%ScreeningOutcome{outcome: :clean})
    end
  end
end
