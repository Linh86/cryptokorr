defmodule Bank.QuotesObservabilityTest do
  @moduledoc """
  End-to-end wiring tests for #176 — `Bank.Quotes.preview/2` updates
  `Bank.Quotes.ProviderHealth` through the existing telemetry hook,
  without ever storing raw upstream data, URLs, or headers in the
  readiness payload.

  `async: false` because `ProviderHealth` is a singleton ETS table
  shared across the process tree; concurrent mutations from parallel
  tests would race.
  """

  use Bank.DataCase, async: false

  import ExUnit.CaptureLog

  alias Bank.Fixtures
  alias Bank.Quotes
  alias Bank.Quotes.{LiveProvider, ProviderHealth, StubProvider}

  setup do
    ProviderHealth.reset()
    :ok
  end

  describe "stub provider" do
    test "successful preview records a :healthy stub state" do
      intent = Fixtures.agent_intent(chain: "base")

      assert {:ok, _preview} = Quotes.preview(intent, provider: StubProvider)

      state = ProviderHealth.get("stub")
      assert state.status == :healthy
      assert state.success_count == 1
      assert state.failure_count == 0
      assert %DateTime{} = state.last_success_at
    end

    test "stub failure records a :failing state with a category atom reason" do
      intent = Fixtures.agent_intent(chain: "base")

      assert {:error, :provider_unavailable} =
               Quotes.preview(intent, provider: StubProvider, outcome: :unavailable)

      state = ProviderHealth.get("stub")
      assert state.status == :failing
      assert state.failure_count == 1
      assert state.last_failure_reason == :provider_unavailable
    end

    test "{:simulation_failed, reason} maps to :simulation_failed atom in health" do
      intent = Fixtures.agent_intent(chain: "base")

      assert {:error, {:simulation_failed, "insufficient_balance"}} =
               Quotes.preview(intent,
                 provider: StubProvider,
                 outcome: {:simulation_failed, "insufficient_balance"}
               )

      state = ProviderHealth.get("stub")
      # Free-form upstream reason string never reaches the health
      # tracker — the result_tag enum collapses it to a category atom.
      assert state.last_failure_reason == :simulation_failed
      refute inspect(state) =~ "insufficient_balance"
    end
  end

  describe "live provider" do
    test "successful live preview records a :healthy tenderly state" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(conn, %{
          "success" => true,
          "trace_id" => "trace-#{System.unique_integer([:positive])}",
          "estimated_gas" => 120_000,
          "estimated_fee" => "0.00015",
          "fee_asset" => "ETH",
          "balance_changes" => %{"USDC" => "-10.5"},
          "failure_conditions" => [],
          "risk_flags" => [],
          "freshness_ttl_seconds" => 30
        })
      end)

      intent = Fixtures.agent_intent(chain: "base")
      assert {:ok, _preview} = Quotes.preview(intent, provider: :live)

      state = ProviderHealth.get("tenderly")
      assert state.status == :healthy
      assert state.success_count == 1
    end

    test "5xx live failure records :failing tenderly state with :provider_unavailable" do
      Req.Test.stub(LiveProvider, fn conn ->
        Plug.Conn.send_resp(conn, 503, "")
      end)

      intent = Fixtures.agent_intent(chain: "base")
      assert {:error, :provider_unavailable} = Quotes.preview(intent, provider: :live)

      state = ProviderHealth.get("tenderly")
      assert state.failure_count == 1
      assert state.last_failure_reason == :provider_unavailable
    end

    test "secret-bearing upstream body never reaches the health state" do
      # Adversarial upstream — the LiveProvider's secret-pattern
      # allowlist already redacts these on Preview construction
      # (#174/#442/#445). The health tracker is the next defensive
      # ring: even if a regression broke the LiveProvider sanitiser,
      # the health state still cannot carry the leaked material
      # because the result_tag enum collapses every failure to a
      # bounded atom.
      Req.Test.stub(LiveProvider, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{
          "Authorization" => "Bearer sk_live_LEAKED",
          "url" => "https://user:pass@host/leak"
        })
      end)

      intent = Fixtures.agent_intent(chain: "base")

      capture_log(fn ->
        assert {:error, :provider_unavailable} =
                 Quotes.preview(intent, provider: :live)
      end)

      state = ProviderHealth.get("tenderly")
      blob = inspect(state)

      refute blob =~ ~r/sk_live_/
      refute blob =~ ~r/authorization|bearer/i
      refute blob =~ ~r{://[^\s/@]+:[^\s/@]+@}
      refute blob =~ "LEAKED"
      assert state.last_failure_reason == :provider_unavailable
    end
  end

  describe "disabled provider" do
    test "disabled mode records the 'disabled' provider id with :provider_disabled" do
      original = Application.get_env(:bank, Bank.Quotes, [])
      Application.put_env(:bank, Bank.Quotes, Keyword.put(original, :provider, :disabled))
      on_exit(fn -> Application.put_env(:bank, Bank.Quotes, original) end)

      intent = Fixtures.agent_intent(chain: "base")
      assert {:error, :provider_disabled} = Quotes.preview(intent)

      state = ProviderHealth.get("disabled")
      assert state.status == :failing
      assert state.last_failure_reason == :provider_disabled
    end
  end

  describe "Bank.Ops.Health.snapshot integration" do
    test "quotes_provider check defaults to :ok when no providers have been observed" do
      ProviderHealth.reset()
      snapshot = Bank.Ops.Health.snapshot()

      assert %{quotes_provider: %{status: :ok, detail: nil, providers: []}} = snapshot.checks
    end

    test "quotes_provider check rolls up to :degraded when one provider is :degraded" do
      # 9 successes + 1 failure = 90% success → :degraded
      for _ <- 1..9, do: ProviderHealth.record_success("tenderly")
      ProviderHealth.record_failure("tenderly", :provider_unavailable)

      snapshot = Bank.Ops.Health.snapshot()
      assert snapshot.checks.quotes_provider.status == :degraded
      assert snapshot.checks.quotes_provider.detail == "provider_tenderly_degraded"
      # Top-level rollup also goes :degraded.
      assert snapshot.status == :degraded
    end

    test "quotes_provider check rolls up to :down when one provider is :failing" do
      for _ <- 1..5, do: ProviderHealth.record_failure("tenderly", :provider_unavailable)

      snapshot = Bank.Ops.Health.snapshot()
      assert snapshot.checks.quotes_provider.status == :down
      assert snapshot.checks.quotes_provider.detail == "provider_tenderly_failing"
      assert snapshot.status == :degraded
    end

    test "providers list rides under the check object" do
      ProviderHealth.record_success("stub")
      ProviderHealth.record_success("tenderly")

      snapshot = Bank.Ops.Health.snapshot()

      provider_ids =
        snapshot.checks.quotes_provider.providers |> Enum.map(& &1.provider) |> Enum.sort()

      assert provider_ids == ["stub", "tenderly"]
    end
  end
end
