defmodule BankWeb.QueueLiveFormatHygieneTest do
  @moduledoc """
  Regression guard for issue #469.

  The HEEx formatter was non-idempotent on a single-line vault-name
  span in `lib/bank_web/live/queue_live.ex`: each `mix format` run
  inserted one extra space between the `}}` interpolation close and
  the `&middot;` HTML entity, indefinitely.

  The fix splits the span across multiple lines so the interpolation
  and the HTML entity are not adjacent in the same template fragment.
  This test pins that shape so a future edit can't re-introduce the
  oscillation. CI's `mix format --check-formatted` step is the
  upstream enforcement; this test is the cheap, fast, explanatory
  guard that names the bug.
  """

  use ExUnit.Case, async: true

  @file_path Path.expand("../../../lib/bank_web/live/queue_live.ex", __DIR__)

  setup_all do
    {:ok, source: File.read!(@file_path)}
  end

  test "queue_live.ex source exists at the documented path" do
    assert File.exists?(@file_path), "queue_live.ex missing at #{@file_path}"
  end

  test "no `}}  &middot;  </span>` adjacency on a single line", %{source: source} do
    # The bug pattern: `<span ...>{@some["thing"]} &middot; </span>`
    # all on the SAME LINE — interpolation + entity + closing tag.
    # Each `mix format` run inserted one more space between `}` and
    # `&` in this exact shape (#469). The fix splits the span
    # across multiple lines, so the broken shape only appears when
    # the regression returns. Using `[^\n]*` keeps the match on a
    # single line so it can't accidentally hit the multi-line fix.
    refute source =~ ~r/\{@\w+\["[^"]+"\]\}[^\n]*&middot;[^\n]*<\/span>/,
           "queue_live.ex re-introduced the #469 oscillation pattern: " <>
             "interpolation, `&middot;`, and `</span>` all on the same line"
  end

  test "vault-name span carries the multi-line workaround shape", %{source: source} do
    # The fix pulls the interpolation and the entity onto their own
    # line inside a multi-line `<span>` so the HEEx formatter has no
    # ambiguity about whitespace between them.
    assert source =~
             ~r{<span :if=\{@explanation\["vault_name"\]\}>\s*\n\s*\{@explanation\["vault_name"\]\} &middot;\s*\n\s*</span>},
           "queue_live.ex vault-name span shape changed; verify mix format --check-formatted is still idempotent (#469)"
  end
end
