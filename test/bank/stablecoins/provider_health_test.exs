defmodule Bank.Stablecoins.ProviderHealthTest do
  use ExUnit.Case, async: false

  alias Bank.Stablecoins.ProviderHealth

  setup do
    ProviderHealth.reset()
    :ok
  end

  describe "record_success/1" do
    test "sets status to healthy" do
      ProviderHealth.record_success("zerox")
      state = ProviderHealth.get("zerox")
      assert state.status == :healthy
      assert state.success_count == 1
      assert state.last_success_at != nil
    end
  end

  describe "record_failure/2" do
    test "tracks failure count and reason" do
      ProviderHealth.record_failure("zerox", :provider_unavailable)
      state = ProviderHealth.get("zerox")
      assert state.failure_count == 1
      assert state.last_failure_reason == :provider_unavailable
    end

    test "tracks rate_limited count" do
      ProviderHealth.record_failure("oneinch", :rate_limited)
      state = ProviderHealth.get("oneinch")
      assert state.rate_limited_count == 1
    end

    test "tracks no_route_found count" do
      ProviderHealth.record_failure("jupiter", :no_route_found)
      state = ProviderHealth.get("jupiter")
      assert state.no_route_count == 1
    end

    test "status degrades with failures" do
      for _ <- 1..5, do: ProviderHealth.record_failure("bad", :provider_unavailable)
      state = ProviderHealth.get("bad")
      assert state.status == :failing
    end
  end

  describe "get/1" do
    test "returns unknown for untracked provider" do
      state = ProviderHealth.get("nonexistent")
      assert state.status == :unknown
      assert state.success_count == 0
    end
  end

  describe "all/0" do
    test "returns all tracked providers" do
      ProviderHealth.record_success("zerox")
      ProviderHealth.record_success("oneinch")
      all = ProviderHealth.all()
      providers = Enum.map(all, & &1.provider) |> Enum.sort()
      assert "oneinch" in providers
      assert "zerox" in providers
    end
  end

  describe "degraded status" do
    test "mostly successful with some failures is degraded" do
      for _ <- 1..8, do: ProviderHealth.record_success("mixed")
      for _ <- 1..2, do: ProviderHealth.record_failure("mixed", :provider_unavailable)
      state = ProviderHealth.get("mixed")
      assert state.status == :degraded
    end

    test "a single later success does not hide a still-failing provider" do
      for _ <- 1..5, do: ProviderHealth.record_failure("bad", :provider_unavailable)

      ProviderHealth.record_success("bad")

      state = ProviderHealth.get("bad")
      assert state.success_count == 1
      assert state.failure_count == 5
      assert state.status == :failing
    end
  end
end
