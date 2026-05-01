defmodule Bank.RateLimitTest do
  @moduledoc """
  Coverage for `Bank.RateLimit` (#221, first slice).

  Tests use small explicit thresholds passed to `check/3` rather than
  fiddling with config — the function takes max_requests and
  window_seconds as arguments, so each test bucket-isolates by using
  a unique `api_key_id`.
  """

  use ExUnit.Case, async: false

  alias Bank.RateLimit

  setup do
    RateLimit.reset()
    :ok
  end

  describe "check/3" do
    test "admits under the limit and refuses at the limit + 1" do
      key_id = "k-" <> Integer.to_string(System.unique_integer([:positive]))

      # 5 requests fit under a 5/60s budget.
      for _ <- 1..5 do
        assert :ok = RateLimit.check(key_id, 5, 60)
      end

      # 6th must refuse.
      assert {:error, :rate_limited, retry_after} = RateLimit.check(key_id, 5, 60)
      assert is_integer(retry_after)
      assert retry_after >= 1
      assert retry_after <= 60
    end

    test "two distinct api_key_ids do not share a bucket" do
      key_a = "ka-" <> Integer.to_string(System.unique_integer([:positive]))
      key_b = "kb-" <> Integer.to_string(System.unique_integer([:positive]))

      # Burn key A's budget.
      for _ <- 1..3 do
        assert :ok = RateLimit.check(key_a, 3, 60)
      end

      assert {:error, :rate_limited, _} = RateLimit.check(key_a, 3, 60)

      # Key B is unaffected.
      for _ <- 1..3 do
        assert :ok = RateLimit.check(key_b, 3, 60)
      end
    end

    test "is concurrent-safe under a stampede" do
      key_id = "race-" <> Integer.to_string(System.unique_integer([:positive]))

      # 50 parallel callers, budget 20. Exactly 20 must see :ok and
      # the rest must see :rate_limited. ETS update_counter atomicity
      # guarantees the count is exactly the number of calls.
      results =
        1..50
        |> Task.async_stream(fn _ -> RateLimit.check(key_id, 20, 60) end,
          max_concurrency: 50,
          ordered: false
        )
        |> Enum.map(fn {:ok, r} -> r end)

      successes = Enum.count(results, &(&1 == :ok))

      rate_limits =
        Enum.count(results, fn
          {:error, :rate_limited, _} -> true
          _ -> false
        end)

      assert successes == 20
      assert rate_limits == 30
    end
  end

  describe "claim_audit/2" do
    test "first claim wins; subsequent claims for the same window return false" do
      key_id = "audit-" <> Integer.to_string(System.unique_integer([:positive]))
      window_start = System.system_time(:second)

      assert RateLimit.claim_audit(key_id, window_start) == true
      assert RateLimit.claim_audit(key_id, window_start) == false
      assert RateLimit.claim_audit(key_id, window_start) == false
    end

    test "different (key, window) pairs claim independently" do
      key_id = "audit-" <> Integer.to_string(System.unique_integer([:positive]))
      window = System.system_time(:second)

      assert RateLimit.claim_audit(key_id, window) == true
      # Different window — fresh claim.
      assert RateLimit.claim_audit(key_id, window + 60) == true

      other_key = "audit-other-" <> Integer.to_string(System.unique_integer([:positive]))
      # Different key — fresh claim.
      assert RateLimit.claim_audit(other_key, window) == true
    end
  end
end
