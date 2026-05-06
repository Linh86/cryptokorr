defmodule Bank.Quotes.ProviderHealthTest do
  # async: false — the ETS table is GenServer-owned and shared across
  # the process tree; mutations from parallel tests would race.
  use ExUnit.Case, async: false

  alias Bank.Quotes.ProviderHealth

  setup do
    ProviderHealth.reset()
    :ok
  end

  describe "record_success/1" do
    test "sets status to :healthy on first success" do
      ProviderHealth.record_success("tenderly")
      state = ProviderHealth.get("tenderly")
      assert state.status == :healthy
      assert state.success_count == 1
      assert %DateTime{} = state.last_success_at
      assert state.last_failure_at == nil
      assert state.last_failure_reason == nil
    end

    test "increments success_count across calls" do
      for _ <- 1..3, do: ProviderHealth.record_success("stub")
      state = ProviderHealth.get("stub")
      assert state.success_count == 3
      assert state.failure_count == 0
      assert state.status == :healthy
    end
  end

  describe "record_failure/2" do
    test "tracks failure_count + last_failure_reason atom" do
      ProviderHealth.record_failure("tenderly", :provider_unavailable)
      state = ProviderHealth.get("tenderly")
      assert state.failure_count == 1
      assert state.last_failure_reason == :provider_unavailable
      assert %DateTime{} = state.last_failure_at
    end

    test ":failing once success rate drops below 80%" do
      for _ <- 1..5, do: ProviderHealth.record_failure("bad", :provider_unavailable)
      state = ProviderHealth.get("bad")
      assert state.status == :failing
    end

    test ":degraded when ≥80% success but at least one failure" do
      for _ <- 1..9, do: ProviderHealth.record_success("partial")
      ProviderHealth.record_failure("partial", :simulation_failed)
      state = ProviderHealth.get("partial")
      assert state.status == :degraded
      assert state.success_count == 9
      assert state.failure_count == 1
    end

    test "redacts non-allowlist reason atoms to :error" do
      # A provider module attempting to record a free-form atom is
      # collapsed to `:error` so future regressions cannot smuggle
      # raw upstream data into the readiness payload (#176).
      ProviderHealth.record_failure("tenderly", :tenderly_returned_html)
      state = ProviderHealth.get("tenderly")
      assert state.last_failure_reason == :error
    end

    test "redacts non-atom reasons (strings, tuples) to :error" do
      ProviderHealth.record_failure("tenderly", "raw upstream body should not appear here")
      state_a = ProviderHealth.get("tenderly")
      assert state_a.last_failure_reason == :error

      ProviderHealth.reset()

      ProviderHealth.record_failure("tenderly", {:simulation_failed, "free-form reason"})
      state_b = ProviderHealth.get("tenderly")
      # Compound terms collapse to :error — only the bare atom from
      # the allowlist survives.
      assert state_b.last_failure_reason == :error
    end

    test "every allowlist atom passes through unchanged" do
      for tag <- ProviderHealth.result_tag_allowlist() do
        ProviderHealth.reset()
        ProviderHealth.record_failure("tenderly", tag)
        assert ProviderHealth.get("tenderly").last_failure_reason == tag
      end
    end
  end

  describe "get/1" do
    test "returns an :unknown skeleton for untracked providers" do
      state = ProviderHealth.get("never-seen")
      assert state.provider == "never-seen"
      assert state.status == :unknown
      assert state.success_count == 0
      assert state.failure_count == 0
      assert state.last_success_at == nil
      assert state.last_failure_at == nil
      assert state.last_failure_reason == nil
    end
  end

  describe "all/0" do
    test "returns every tracked provider" do
      ProviderHealth.record_success("stub")
      ProviderHealth.record_success("tenderly")
      ProviderHealth.record_failure("tenderly", :provider_unavailable)

      ids = ProviderHealth.all() |> Enum.map(& &1.provider) |> Enum.sort()
      assert ids == ["stub", "tenderly"]
    end

    test "returns empty list when nothing has been observed" do
      assert ProviderHealth.all() == []
    end
  end

  describe "secret hygiene of stored state" do
    test "stored state never carries the result_tag allowlist's transitive secrets" do
      # Defence-in-depth: even if a future refactor relaxed the
      # sanitiser, the persisted state must not carry URLs, headers,
      # tokens, or PEM material. This test pins the inspect/1 output
      # surface.
      ProviderHealth.record_failure(
        "tenderly",
        :provider_unavailable
      )

      blob = ProviderHealth.get("tenderly") |> inspect()

      refute blob =~ ~r{https?://}
      refute blob =~ ~r/authorization|bearer/i
      refute blob =~ ~r/sk_(live|test)_/
      refute blob =~ ~r/pk_(live|test)_/
      refute blob =~ "PRIVATE KEY"
    end
  end
end
