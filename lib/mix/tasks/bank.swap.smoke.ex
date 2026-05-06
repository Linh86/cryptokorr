defmodule Mix.Tasks.Bank.Swap.Smoke do
  @shortdoc "Run the MVP 0x swap dispatch smoke (#196) — Phoenix-side validation + safety gate + dispatch envelope shape; no live broadcast"

  @moduledoc """
  MVP 0x swap dispatch smoke (#196).

  Validates the entire Phoenix-side swap-dispatch surface end-to-end
  against an in-memory synthetic Base Sepolia USDC route — no chain
  RPC, no `Bank.Quotes.LiveProvider` HTTP, no adapter dispatch, no
  Oban enqueue. Pairs with
  `docs/runbooks/swap-dispatch.md` (the operator-facing runbook).

  ## What it covers

    * `Bank.Intents.SwapRoute.validate/2` (#189)
    * `Bank.Decisions.SwapRouteArtifacts.from_route/1` and the
      round-trip via `route_from_steps/1` (#190)
    * `Bank.Decisions.SwapDispatchSafety.validate/3` happy-path AND
      mainnet / stale-route / inverted-min rejection paths (#191 +
      #192 P2)
    * The dispatch envelope's route block shape — every field the
      adapter's `DispatchSwapSchema` (#192) consumes
    * Provider-secret hygiene of the dispatch envelope
    * The public audit/replay artifact set (#194) on the persisted
      `steps` map

  Does NOT broadcast. The live broadcast recipe is documented in
  the runbook and runs through the operator's existing
  `Bank.Decisions.request_manual_execution/3` flow against a
  configured TS chain adapter — explicit operator consent rides on
  that flow, not on this smoke.

  Exits 0 on PASS, 1 on FAIL. Idempotent — pure function over an
  in-memory route.

  ## Hard safety boundaries (assertion-tested)

    * Base Sepolia only. `chain: "base"` is rejected closed at the
      safety gate.
    * Exact-input only. The route map carries no `swap_type` field
      (the canonical exact-input shape).
    * USDC asset allowlist (the synthetic route is USDC ↔ USDC).
      USDT and ETH/WETH are documented MVP pairs in the runbook
      but require a `caps: [..., allowed_assets: ...]` override at
      the operator's quote-provider boundary; the smoke uses the
      default cap.
    * No mainnet, no CCTP / 1inch / Jupiter live execution, no
      arbitrary token support, no guaranteed liquidity. The runbook
      drift tests pin this.

  ## Examples

      mix bank.swap.smoke
      # => 10 / 10 PASS

  See `Bank.Swap.Smoke` for the exact contract each check pins, and
  `docs/runbooks/swap-dispatch.md` for the live-broadcast operator
  recipe.
  """

  use Mix.Task

  alias Bank.Swap.Smoke

  @requirements ["app.start"]

  @impl Mix.Task
  def run(_argv) do
    case Smoke.run() do
      {:ok, report} ->
        print_report(report)
        :ok

      {:error, report} ->
        print_report(report)
        exit({:shutdown, 1})
    end
  end

  defp print_report(report) do
    Mix.shell().info("Bank MVP 0x swap dispatch smoke")
    Mix.shell().info("")

    Enum.each(report.checks, fn check ->
      tag =
        case check.status do
          :pass -> "PASS"
          :fail -> "FAIL"
        end

      Mix.shell().info("  #{tag} #{check.name} — #{check.detail}")
    end)

    Mix.shell().info("")
    Mix.shell().info("#{report.passed} / #{report.total} #{result_label(report.status)}")
    Mix.shell().info("Phoenix-side shape only. No chain RPC, no adapter HTTP, no broadcast.")
  end

  defp result_label(:pass), do: "PASS"
  defp result_label(:fail), do: "FAIL"
end
