defmodule Bank.WalletScreening.FeedHealthTest do
  use ExUnit.Case, async: false

  alias Bank.WalletScreening.FeedHealth

  setup do
    FeedHealth.reset()
    :ok
  end

  describe "record_success/3 and get/2" do
    test "records fresh state after successful ingestion" do
      FeedHealth.record_success("ofac", %{ingested: 42, skipped: 3})

      state = FeedHealth.get("ofac")
      assert state.status == :fresh
      assert state.source == "ofac"
      assert state.last_ingested == 42
      assert state.last_skipped == 3
      assert state.last_success_at != nil
      assert state.severity == :high
      assert state.tier == :hard_block
    end

    test "preserves prior failure info after success" do
      FeedHealth.record_failure("ofac", :http_error)
      FeedHealth.record_success("ofac", %{ingested: 10, skipped: 0})

      state = FeedHealth.get("ofac")
      assert state.status == :fresh
      assert state.last_failure_at != nil
      assert state.last_failure_reason =~ "http_error"
    end
  end

  describe "record_failure/3" do
    test "records failed state" do
      FeedHealth.record_failure("opensanctions", {:http_error, 503})

      state = FeedHealth.get("opensanctions")
      assert state.status == :failed
      assert state.last_failure_reason =~ "503"
      assert state.severity == :high
    end
  end

  describe "staleness detection" do
    test "source becomes stale after threshold passes" do
      past = DateTime.add(DateTime.utc_now(), -25 * 3600, :second)
      FeedHealth.record_success("ofac", %{ingested: 10, skipped: 0}, now: past)

      state = FeedHealth.get("ofac")
      assert state.status == :stale
    end

    test "source stays fresh within threshold" do
      recent = DateTime.add(DateTime.utc_now(), -1 * 3600, :second)
      FeedHealth.record_success("ofac", %{ingested: 10, skipped: 0}, now: recent)

      state = FeedHealth.get("ofac")
      assert state.status == :fresh
    end

    test "scam feed uses 48-hour threshold" do
      past_36h = DateTime.add(DateTime.utc_now(), -36 * 3600, :second)
      FeedHealth.record_success("scamsniffer", %{ingested: 5, skipped: 0}, now: past_36h)

      state = FeedHealth.get("scamsniffer")
      assert state.status == :fresh

      past_50h = DateTime.add(DateTime.utc_now(), -50 * 3600, :second)
      FeedHealth.record_success("scamsniffer", %{ingested: 5, skipped: 0}, now: past_50h)

      state = FeedHealth.get("scamsniffer")
      assert state.status == :stale
    end

    test "context feed uses 7-day threshold" do
      past_5d = DateTime.add(DateTime.utc_now(), -5 * 24 * 3600, :second)
      FeedHealth.record_success("graphsense", %{ingested: 100, skipped: 0}, now: past_5d)

      state = FeedHealth.get("graphsense")
      assert state.status == :fresh

      past_8d = DateTime.add(DateTime.utc_now(), -8 * 24 * 3600, :second)
      FeedHealth.record_success("graphsense", %{ingested: 100, skipped: 0}, now: past_8d)

      state = FeedHealth.get("graphsense")
      assert state.status == :stale
    end
  end

  describe "unknown sources" do
    test "never-ingested source returns :unknown" do
      state = FeedHealth.get("ofac")
      assert state.status == :unknown
      assert state.severity == :high
      assert state.last_success_at == nil
    end

    test "unregistered source gets info defaults" do
      state = FeedHealth.get("totally_new_source")
      assert state.status == :unknown
      assert state.severity == :info
    end
  end

  describe "severity mapping" do
    test "sanctions sources are :high severity" do
      assert FeedHealth.get("ofac").severity == :high
      assert FeedHealth.get("opensanctions").severity == :high
    end

    test "scam sources are :warning severity" do
      assert FeedHealth.get("scamsniffer").severity == :warning
      assert FeedHealth.get("etherscamdb").severity == :warning
      assert FeedHealth.get("btc_abuse").severity == :warning
    end

    test "context and scoring sources are :info severity" do
      assert FeedHealth.get("graphsense").severity == :info
      assert FeedHealth.get("internal_scoring").severity == :info
    end
  end

  describe "all/1" do
    test "returns all known sources including never-ingested" do
      states = FeedHealth.all()
      sources = Enum.map(states, & &1.source)

      assert "ofac" in sources
      assert "opensanctions" in sources
      assert "scamsniffer" in sources
      assert "graphsense" in sources
      assert "internal_scoring" in sources
    end

    test "sorts by severity (high first)" do
      states = FeedHealth.all()
      severities = Enum.map(states, & &1.severity)

      high_idx = Enum.find_index(severities, &(&1 == :high))
      warning_idx = Enum.find_index(severities, &(&1 == :warning))
      info_idx = Enum.find_index(severities, &(&1 == :info))

      if high_idx && warning_idx, do: assert(high_idx < warning_idx)
      if warning_idx && info_idx, do: assert(warning_idx < info_idx)
    end
  end

  describe "stale_sources/1" do
    test "returns only stale, failed, or unknown sources" do
      FeedHealth.record_success("ofac", %{ingested: 10, skipped: 0})

      stale = FeedHealth.stale_sources()
      sources = Enum.map(stale, & &1.source)

      refute "ofac" in sources
      assert "opensanctions" in sources
    end
  end

  describe "stale_sources_by_severity/2" do
    test "filters by severity" do
      high_stale = FeedHealth.stale_sources_by_severity(:high)
      sources = Enum.map(high_stale, & &1.source)

      assert "ofac" in sources or "opensanctions" in sources
      refute "graphsense" in sources
    end
  end

  describe "clock seam" do
    test "get/2 accepts :now for deterministic staleness" do
      FeedHealth.record_success("ofac", %{ingested: 10, skipped: 0})

      future = DateTime.add(DateTime.utc_now(), 25 * 3600, :second)
      state = FeedHealth.get("ofac", now: future)
      assert state.status == :stale
    end
  end
end
