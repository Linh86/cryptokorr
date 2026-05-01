defmodule Bank.Audit.DedupeWindowTest do
  @moduledoc """
  Coverage for `Bank.Audit.DedupeWindow` (#222).
  """

  use ExUnit.Case, async: false

  alias Bank.Audit.DedupeWindow

  setup do
    DedupeWindow.reset()
    :ok
  end

  describe "claim/2" do
    test "first claim wins; subsequent claims for the same key in the same window return false" do
      key = {:test, System.unique_integer([:positive])}

      assert DedupeWindow.claim(key, 60) == true
      assert DedupeWindow.claim(key, 60) == false
      assert DedupeWindow.claim(key, 60) == false
    end

    test "different keys claim independently in the same window" do
      ka = {:test, "a-" <> Integer.to_string(System.unique_integer([:positive]))}
      kb = {:test, "b-" <> Integer.to_string(System.unique_integer([:positive]))}

      assert DedupeWindow.claim(ka, 60) == true
      assert DedupeWindow.claim(kb, 60) == true
      assert DedupeWindow.claim(ka, 60) == false
      assert DedupeWindow.claim(kb, 60) == false
    end

    test "first claim of a stampede wins exactly once" do
      key = {:test, "stampede-" <> Integer.to_string(System.unique_integer([:positive]))}

      results =
        1..50
        |> Task.async_stream(fn _ -> DedupeWindow.claim(key, 60) end,
          max_concurrency: 50,
          ordered: false
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &(&1 == true)) == 1
      assert Enum.count(results, &(&1 == false)) == 49
    end
  end
end
