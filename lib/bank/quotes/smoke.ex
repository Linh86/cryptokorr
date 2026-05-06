defmodule Bank.Quotes.Smoke do
  @moduledoc """
  Quote provider smoke runner (#177).

  Drives every read-only quote/simulation surface a fresh reviewer
  needs to inspect locally and reports a per-check pass/fail. The
  automated counterpart to
  [`docs/runbooks/quote-provider-degraded-mode.md`](../../../docs/runbooks/quote-provider-degraded-mode.md):
  a single command produces a deterministic outcome that mirrors
  what the runbook prose describes.

  ## What it verifies

    * `quotes.stub_success` — `Bank.Quotes.preview/2` with the
      `:stub` provider returns `{:ok, %Preview{source: :stub,
      provider: "stub"}}` and the bundled struct carries the
      contract fields (`generated_at`, `freshness_ttl_seconds`).
    * `quotes.attempted_provider_id` — `Bank.Quotes.attempted_provider_id/1`
      returns the same string each provider sets on
      `Preview.provider` (`"stub"`, `"tenderly"`, `"disabled"`)
      so live/stub/disabled deployments record the right value
      on persisted `SimulationReport.provider`.
    * `quotes.health_recorded_after_success` —
      `Bank.Quotes.ProviderHealth.get("stub")` is `:healthy`
      after a successful preview.
    * `quotes.health_recorded_after_failure` — a forced
      `outcome: :unavailable` stub returns
      `{:error, :provider_unavailable}` and `ProviderHealth`
      records `:failing` with `last_failure_reason: :provider_unavailable`.
    * `quotes.health_snapshot_rollup` —
      `Bank.Ops.Health.snapshot/0` exposes a `quotes_provider`
      check whose status downgrades to `:down` once a stub
      provider is in `:failing` state.
    * `quotes.secret_hygiene` — every `Bank.Quotes.ProviderHealth`
      state row inspects clean of `Authorization` / `Bearer` /
      `sk_(live|test)_` / `pk_(live|test)_` / credentialed-URL /
      PEM markers. Pins the redaction surface against future
      regressions.
    * `quotes.live_provider_disabled_default` — without explicit
      configuration, the default deployment runs `:stub`. Live
      provider is opt-in via `config :bank, Bank.Quotes,
      provider: :live`.

  ## Side-effect contract

    * No `.env`, no `ADAPTER_*`, no `RPC_*`, no `TENDERLY_*`
      environment reads.
    * No `Bank.Quotes.LiveProvider` HTTP — the smoke only
      exercises the in-process `Bank.Quotes.StubProvider`.
    * No DB writes outside the resettable
      `Bank.Quotes.ProviderHealth` ETS table. No `simulation_reports`
      inserts (the smoke calls `Quotes.preview/2` directly, never
      `Bank.Decisions.evaluate_intent/2`).
    * No Oban jobs enqueued.
    * Idempotent: the smoke resets `ProviderHealth` at start and
      restores it at end so re-runs do not pollute the operator's
      readiness payload.

  Returns `{:ok, report}` on PASS and `{:error, report}` on FAIL.
  The Mix task wrapper (`mix bank.quotes.smoke`) exits 0/1 from
  this tuple so a CI step can pick up the outcome without
  parsing stdout.
  """

  alias Bank.Intents.AgentIntent
  alias Bank.Ops.Health
  alias Bank.Quotes
  alias Bank.Quotes.{LiveProvider, Preview, ProviderHealth, StubProvider}

  @secret_marker_patterns [
    ~r/Authorization\s*:\s*Bearer/i,
    ~r/Bearer\s+sk_/i,
    ~r/\bsk_(live|test)_/,
    ~r/\bpk_(live|test)_/,
    ~r{://[^\s/@]+:[^\s/@]+@},
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/
  ]

  @type check_result :: %{
          name: String.t(),
          status: :pass | :fail,
          detail: String.t()
        }

  @type report :: %{
          status: :pass | :fail,
          checks: [check_result()],
          passed: non_neg_integer(),
          total: non_neg_integer()
        }

  @spec run() :: {:ok, report()} | {:error, report()}
  def run do
    saved = ProviderHealth.all()
    ProviderHealth.reset()

    try do
      checks = run_checks()
      passed = Enum.count(checks, &(&1.status == :pass))
      total = length(checks)
      status = if passed == total, do: :pass, else: :fail

      report = %{status: status, checks: checks, passed: passed, total: total}

      case status do
        :pass -> {:ok, report}
        :fail -> {:error, report}
      end
    after
      # Restore prior provider-health state so the smoke does not
      # bleed into a long-running deployment's readiness payload.
      ProviderHealth.reset()

      Enum.each(saved, fn state ->
        cond do
          state.success_count > 0 -> ProviderHealth.record_success(state.provider)
          state.failure_count > 0 -> ProviderHealth.record_failure(state.provider, :error)
          true -> :ok
        end
      end)
    end
  end

  defp run_checks do
    intent = build_intent()

    [
      check_stub_success(intent),
      check_attempted_provider_id(),
      check_health_recorded_after_success(intent),
      check_health_recorded_after_failure(intent),
      check_health_snapshot_rollup(intent),
      check_secret_hygiene(intent),
      check_live_provider_disabled_default()
    ]
  end

  defp build_intent do
    %AgentIntent{
      id: Ecto.UUID.generate(),
      chain: "base",
      kind: :transfer,
      asset: "USDC",
      amount: Decimal.new("10.5"),
      submitted_at: DateTime.utc_now()
    }
  end

  defp check_stub_success(intent) do
    case Quotes.preview(intent, provider: :stub) do
      {:ok, %Preview{source: :stub, provider: "stub"} = preview} ->
        cond do
          preview.generated_at == nil ->
            fail("quotes.stub_success", "preview missing generated_at")

          (preview.freshness_ttl_seconds || 0) <= 0 ->
            fail("quotes.stub_success", "preview missing freshness_ttl_seconds")

          true ->
            pass(
              "quotes.stub_success",
              "stub returned %Preview{source: :stub, provider: \"stub\"}"
            )
        end

      other ->
        fail("quotes.stub_success", "expected {:ok, %Preview{}} got #{inspect(other)}")
    end
  end

  defp check_attempted_provider_id do
    cases = [
      {[provider: :stub], "stub"},
      {[provider: :live], "tenderly"},
      {[provider: :disabled], "disabled"},
      {[provider: StubProvider], "stub"},
      {[provider: LiveProvider], "tenderly"}
    ]

    mismatched =
      Enum.reduce(cases, [], fn {opts, expected}, acc ->
        actual = Quotes.attempted_provider_id(opts)
        if actual == expected, do: acc, else: [{opts, expected, actual} | acc]
      end)

    case mismatched do
      [] ->
        pass(
          "quotes.attempted_provider_id",
          "stub/live/disabled atoms + module forms resolve to expected ids"
        )

      mismatches ->
        fail(
          "quotes.attempted_provider_id",
          "mismatched id mappings: #{inspect(mismatches)}"
        )
    end
  end

  defp check_health_recorded_after_success(intent) do
    ProviderHealth.reset()
    {:ok, _} = Quotes.preview(intent, provider: :stub)
    state = ProviderHealth.get("stub")

    cond do
      state.status != :healthy ->
        fail(
          "quotes.health_recorded_after_success",
          "expected :healthy, got #{inspect(state.status)}"
        )

      state.success_count != 1 ->
        fail(
          "quotes.health_recorded_after_success",
          "expected success_count 1, got #{state.success_count}"
        )

      state.last_success_at == nil ->
        fail(
          "quotes.health_recorded_after_success",
          "last_success_at not set after a successful preview"
        )

      true ->
        pass(
          "quotes.health_recorded_after_success",
          ":healthy with success_count=1 after stub preview"
        )
    end
  end

  defp check_health_recorded_after_failure(intent) do
    ProviderHealth.reset()

    {:error, :provider_unavailable} =
      Quotes.preview(intent, provider: :stub, outcome: :unavailable)

    state = ProviderHealth.get("stub")

    cond do
      state.status != :failing ->
        fail(
          "quotes.health_recorded_after_failure",
          "expected :failing, got #{inspect(state.status)}"
        )

      state.last_failure_reason != :provider_unavailable ->
        fail(
          "quotes.health_recorded_after_failure",
          "expected :provider_unavailable atom, got #{inspect(state.last_failure_reason)}"
        )

      true ->
        pass(
          "quotes.health_recorded_after_failure",
          ":failing with last_failure_reason=:provider_unavailable"
        )
    end
  end

  defp check_health_snapshot_rollup(intent) do
    ProviderHealth.reset()

    {:error, :provider_unavailable} =
      Quotes.preview(intent, provider: :stub, outcome: :unavailable)

    snapshot = Health.snapshot()
    quotes_check = Map.get(snapshot.checks, :quotes_provider)

    cond do
      quotes_check == nil ->
        fail("quotes.health_snapshot_rollup", "snapshot missing :quotes_provider check")

      quotes_check.status != :down ->
        fail(
          "quotes.health_snapshot_rollup",
          "expected :down rollup with one :failing provider, got #{inspect(quotes_check.status)}"
        )

      quotes_check.detail != "provider_stub_failing" ->
        fail(
          "quotes.health_snapshot_rollup",
          "expected detail \"provider_stub_failing\", got #{inspect(quotes_check.detail)}"
        )

      true ->
        pass(
          "quotes.health_snapshot_rollup",
          "/v1/health/deep `quotes_provider` rolls up to :down on stub failure"
        )
    end
  end

  defp check_secret_hygiene(intent) do
    ProviderHealth.reset()

    {:error, :provider_unavailable} =
      Quotes.preview(intent, provider: :stub, outcome: :unavailable)

    blob =
      ProviderHealth.all()
      |> Enum.map_join("\n", &inspect/1)

    leaked =
      Enum.find(@secret_marker_patterns, fn pattern -> Regex.match?(pattern, blob) end)

    case leaked do
      nil ->
        pass(
          "quotes.secret_hygiene",
          "ProviderHealth state carries no Authorization/sk_/pk_/credentialed-URL/PEM markers"
        )

      pattern ->
        fail(
          "quotes.secret_hygiene",
          "ProviderHealth state matched secret marker pattern #{inspect(pattern)}"
        )
    end
  end

  defp check_live_provider_disabled_default do
    # `attempted_provider_id/0` reads `configured_provider/0` which
    # defaults to `Bank.Quotes.StubProvider` when no app env entry
    # is set. Live provider stays opt-in.
    original = Application.get_env(:bank, Bank.Quotes, [])

    try do
      Application.put_env(:bank, Bank.Quotes, Keyword.delete(original, :provider))
      actual = Quotes.attempted_provider_id()

      if actual == "stub" do
        pass(
          "quotes.live_provider_disabled_default",
          "default deployment without `provider:` config resolves to \"stub\""
        )
      else
        fail(
          "quotes.live_provider_disabled_default",
          "expected \"stub\" default, got #{inspect(actual)}"
        )
      end
    after
      Application.put_env(:bank, Bank.Quotes, original)
    end
  end

  defp pass(name, detail), do: %{name: name, status: :pass, detail: detail}
  defp fail(name, detail), do: %{name: name, status: :fail, detail: detail}
end
