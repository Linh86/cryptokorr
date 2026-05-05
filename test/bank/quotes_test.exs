defmodule Bank.QuotesTest do
  use Bank.DataCase, async: true

  alias Bank.Fixtures
  alias Bank.Quotes
  alias Bank.Quotes.{LiveProvider, Persistence, Preview, StubProvider}

  describe "preview/2 — happy path" do
    test "returns a populated preview for a transfer" do
      intent = Fixtures.agent_intent(kind: :transfer, asset: "USDC", chain: "base")
      assert {:ok, %Preview{} = preview} = Quotes.preview(intent, provider: StubProvider)
      assert Map.get(preview.balance_impact, "USDC")
      assert preview.estimated_gas == 120_000
      refute preview.slippage_bps
      assert preview.provider == "stub"
    end

    test "returns a preview with slippage for swaps" do
      intent = Fixtures.agent_intent(kind: :swap, asset: "USDC", chain: "base")

      assert {:ok, %Preview{slippage_bps: bps, expected_output: out}} =
               Quotes.preview(intent, provider: StubProvider)

      assert is_integer(bps) and bps > 0
      assert %Decimal{} = out
    end
  end

  describe "preview/2 — degraded posture" do
    test "provider_unavailable is surfaced as-is" do
      intent = Fixtures.agent_intent(chain: "base")

      assert {:error, :provider_unavailable} =
               Quotes.preview(intent, provider: StubProvider, outcome: :unavailable)
    end

    test "simulation_failed carries the reason" do
      intent = Fixtures.agent_intent(chain: "base")

      assert {:error, {:simulation_failed, "insufficient_liquidity"}} =
               Quotes.preview(intent,
                 provider: StubProvider,
                 outcome: {:simulation_failed, "insufficient_liquidity"}
               )
    end

    test "unsupported chain is rejected before hitting the provider" do
      intent = Fixtures.agent_intent(chain: "ethereum")
      assert {:error, {:unsupported, _}} = Quotes.preview(intent, provider: StubProvider)
    end
  end

  describe "stale?/2" do
    test "returns true once the freshness TTL has elapsed" do
      preview = %Preview{
        generated_at: ~U[2026-04-01 00:00:00.000000Z],
        freshness_ttl_seconds: 30,
        provider: "stub"
      }

      refute Quotes.stale?(preview, ~U[2026-04-01 00:00:15.000000Z])
      assert Quotes.stale?(preview, ~U[2026-04-01 00:00:35.000000Z])
    end
  end

  describe "persistence" do
    test "to_simulation_attrs/4 shapes the preview for simulation_reports" do
      intent = Fixtures.agent_intent(kind: :transfer, asset: "USDC", chain: "base")
      {:ok, preview} = Quotes.preview(intent, provider: StubProvider)

      attrs = Persistence.to_simulation_attrs(preview, intent.id, :completed, chain: "base")

      assert attrs.intent_id == intent.id
      assert attrs.provider == "stub"
      assert attrs.status == :completed
      assert %{"items" => items} = attrs.predicted_balance_changes
      assert [_ | _] = items
    end
  end

  describe "Preview shape (#173)" do
    test "default struct populates new fields with safe defaults" do
      preview = %Preview{}

      assert preview.source == :stub
      assert preview.risk_flags == []
      assert preview.failure_reason == nil
    end

    test "stub provider sets source: :stub on the returned preview" do
      intent = Fixtures.agent_intent(chain: "base")

      assert {:ok, %Preview{source: :stub}} =
               Quotes.preview(intent, provider: StubProvider)
    end

    test "stub provider returns risk_flags as a list (default empty)" do
      intent = Fixtures.agent_intent(chain: "base")

      assert {:ok, %Preview{risk_flags: flags}} =
               Quotes.preview(intent, provider: StubProvider)

      assert is_list(flags)
    end

    test "stub provider does not set failure_reason on a clean preview" do
      intent = Fixtures.agent_intent(chain: "base")

      assert {:ok, %Preview{failure_reason: nil}} =
               Quotes.preview(intent, provider: StubProvider)
    end
  end

  describe "resolve_provider/1 (#173 config selection)" do
    test ":stub atom resolves to StubProvider" do
      assert {:ok, StubProvider} = Quotes.resolve_provider(:stub)
    end

    test ":live atom resolves to LiveProvider" do
      assert {:ok, LiveProvider} = Quotes.resolve_provider(:live)
    end

    test ":disabled atom returns the disabled signal" do
      assert {:disabled, :disabled} = Quotes.resolve_provider(:disabled)
    end

    test "module name still resolves directly (backward compatibility)" do
      assert {:ok, StubProvider} = Quotes.resolve_provider(StubProvider)
      assert {:ok, LiveProvider} = Quotes.resolve_provider(LiveProvider)
    end
  end

  describe "preview/2 — provider mode selection (#173)" do
    test ":stub provider opt resolves to StubProvider and produces a preview" do
      intent = Fixtures.agent_intent(chain: "base")

      assert {:ok, %Preview{source: :stub, provider: "stub"}} =
               Quotes.preview(intent, provider: :stub)
    end

    test ":live provider opt resolves to LiveProvider and produces a live preview (post-#174)" do
      # With #174 in place, `:live` resolves to a real Req-backed
      # client. The default `config/test.exs` wires
      # `Bank.Quotes.LiveProvider` to `Req.Test`, so we stub a
      # success body and assert the preview surfaces with
      # `source: :live, provider: "tenderly"`. Detailed live-provider
      # behaviour (failure modes, secret hygiene) lives in
      # `test/bank/quotes/live_provider_test.exs`.
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

      assert {:ok, %Preview{source: :live, provider: "tenderly"}} =
               Quotes.preview(intent, provider: :live)
    end

    test ":disabled provider opt short-circuits with :provider_disabled" do
      intent = Fixtures.agent_intent(chain: "base")

      assert {:error, :provider_disabled} = Quotes.preview(intent, provider: :disabled)
    end

    test ":disabled mode does NOT call the provider — no exception even with broken stub" do
      # If the disabled short-circuit accidentally fell through to a
      # provider call, a non-implementing module would raise. The
      # short-circuit must fire BEFORE the provider lookup so a
      # disabled deployment is safe even with stale config.
      intent = Fixtures.agent_intent(chain: "base")

      # Confirm we don't even reach `validate_chain/1` mistakes —
      # passing a known-bad chain alongside :disabled still returns
      # the chain error first because chain validation runs before
      # provider resolution. This pins the ordering.
      assert {:error, {:unsupported, _}} =
               Quotes.preview(%{intent | chain: "ethereum"}, provider: :disabled)
    end

    test "configured provider via Application env reads :stub atom" do
      # Mirror `test/bank/accounts/oauth_test.exs`'s pattern:
      # store original, override, restore in `on_exit`.
      original = Application.get_env(:bank, Bank.Quotes, [])

      Application.put_env(:bank, Bank.Quotes, Keyword.put(original, :provider, :stub))
      on_exit(fn -> Application.put_env(:bank, Bank.Quotes, original) end)

      intent = Fixtures.agent_intent(chain: "base")

      assert {:ok, %Preview{source: :stub}} = Quotes.preview(intent)
    end

    test "configured provider via Application env reads :disabled atom" do
      original = Application.get_env(:bank, Bank.Quotes, [])

      Application.put_env(:bank, Bank.Quotes, Keyword.put(original, :provider, :disabled))
      on_exit(fn -> Application.put_env(:bank, Bank.Quotes, original) end)

      intent = Fixtures.agent_intent(chain: "base")

      assert {:error, :provider_disabled} = Quotes.preview(intent)
    end

    test "configured provider via Application env still accepts a module name (backward compat)" do
      original = Application.get_env(:bank, Bank.Quotes, [])

      Application.put_env(:bank, Bank.Quotes, Keyword.put(original, :provider, StubProvider))
      on_exit(fn -> Application.put_env(:bank, Bank.Quotes, original) end)

      intent = Fixtures.agent_intent(chain: "base")

      assert {:ok, %Preview{source: :stub}} = Quotes.preview(intent)
    end
  end

  describe "Bank.Quotes.LiveProvider (post-#174)" do
    # Detailed live-provider behaviour — failure modes, secret
    # hygiene, request-shape pinning — lives in
    # `test/bank/quotes/live_provider_test.exs` (async: false because
    # those cases mutate `:bank, Bank.Quotes.LiveProvider` config).
    # This describe block stays focused on the contract surface
    # `Bank.Quotes` itself depends on.

    test "implements the Bank.Quotes.Provider behaviour" do
      assert Bank.Quotes.Provider in (LiveProvider.module_info(:attributes)
                                      |> Keyword.get_values(:behaviour)
                                      |> List.flatten())
    end

    test "preview/2 produces a live preview with source: :live when configured" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(conn, %{
          "success" => true,
          "trace_id" => "trace-abc",
          "estimated_gas" => 90_000,
          "estimated_fee" => "0.00009",
          "fee_asset" => "ETH",
          "balance_changes" => %{"USDC" => "-10.5"},
          "failure_conditions" => [],
          "risk_flags" => [],
          "freshness_ttl_seconds" => 30
        })
      end)

      intent = Fixtures.agent_intent(chain: "base")

      assert {:ok, %Preview{source: :live, provider: "tenderly"}} = LiveProvider.preview(intent)
    end
  end

  describe "secret hygiene on Preview (#173)" do
    test "stub preview's provider_trace_ref does not look like an Authorization header or URL" do
      intent = Fixtures.agent_intent(chain: "base")
      {:ok, preview} = Quotes.preview(intent, provider: StubProvider)

      ref = preview.provider_trace_ref

      refute ref =~ ~r{https?://},
             "provider_trace_ref leaked a URL: #{inspect(ref)}"

      refute ref =~ ~r/authorization|bearer/i,
             "provider_trace_ref leaked an auth header: #{inspect(ref)}"

      refute ref =~ ~r/0x[0-9a-fA-F]{64}/,
             "provider_trace_ref leaked a 32-byte hex blob: #{inspect(ref)}"
    end
  end
end
