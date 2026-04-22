defmodule Bank.Stablecoins.RouteSelectorTest do
  use ExUnit.Case, async: true

  alias Bank.Stablecoins.{QuoteRequest, RouteQuote, RouteLeg, RouteSelector}

  # -- In-test fake providers -----------------------------------------------

  defmodule ProviderA do
    @behaviour Bank.Stablecoins.Provider
    @impl true
    def provider_id, do: "provider_a"
    @impl true
    def quote(%QuoteRequest{} = req) do
      case Process.get(:provider_a_response) do
        nil -> build_quote(req, "99.5")
        {:ok, amount} -> build_quote(req, amount)
        {:error, _} = err -> err
      end
    end

    defp build_quote(req, out) do
      out_amount = Decimal.new(out)
      now = DateTime.utc_now()

      {:ok,
       %RouteQuote{
         provider: provider_id(),
         request: req,
         route_kind: req.route_kind,
         legs: [
           %RouteLeg{
             step: 1,
             kind: req.route_kind,
             source_chain: req.source_chain,
             source_asset: req.source_asset,
             dest_chain: req.dest_chain,
             dest_asset: req.dest_asset,
             input_amount: req.amount,
             output_amount: out_amount
           }
         ],
         input_amount: req.amount,
         output_amount: out_amount,
         quoted_at: now,
         fees: %{
           gas_fee: nil,
           protocol_fee: nil,
           bridge_fee: nil,
           cryptobank_fee: nil,
           total_fee: Decimal.sub(req.amount, out_amount)
         },
         eta_seconds: Process.get(:provider_a_eta)
       }}
    end
  end

  defmodule ProviderB do
    @behaviour Bank.Stablecoins.Provider
    @impl true
    def provider_id, do: "provider_b"
    @impl true
    def quote(%QuoteRequest{} = req) do
      case Process.get(:provider_b_response) do
        nil -> build_quote(req, "99.0")
        {:ok, amount} -> build_quote(req, amount)
        {:error, _} = err -> err
      end
    end

    defp build_quote(req, out) do
      out_amount = Decimal.new(out)
      now = DateTime.utc_now()

      {:ok,
       %RouteQuote{
         provider: provider_id(),
         request: req,
         route_kind: req.route_kind,
         legs: [
           %RouteLeg{
             step: 1,
             kind: req.route_kind,
             source_chain: req.source_chain,
             source_asset: req.source_asset,
             dest_chain: req.dest_chain,
             dest_asset: req.dest_asset,
             input_amount: req.amount,
             output_amount: out_amount
           }
         ],
         input_amount: req.amount,
         output_amount: out_amount,
         quoted_at: now,
         fees: %{
           gas_fee: nil,
           protocol_fee: nil,
           bridge_fee: nil,
           cryptobank_fee: nil,
           total_fee: Decimal.sub(req.amount, out_amount)
         },
         eta_seconds: Process.get(:provider_b_eta)
       }}
    end
  end

  defmodule FailingProvider do
    @behaviour Bank.Stablecoins.Provider
    @impl true
    def provider_id, do: "failing"
    @impl true
    def quote(%QuoteRequest{}) do
      Process.get(:failing_response) || {:error, :provider_unavailable}
    end
  end

  defmodule UnsupportedProvider do
    @behaviour Bank.Stablecoins.Provider
    @impl true
    def provider_id, do: "unsupported"
    @impl true
    def quote(%QuoteRequest{}), do: {:error, :unsupported_route}
  end

  # -- Fixtures -------------------------------------------------------------

  defp build_evm_swap(overrides \\ %{}) do
    defaults = %{
      source_chain: "ethereum",
      source_asset: "USDC",
      dest_chain: "ethereum",
      dest_asset: "USDT",
      amount: Decimal.new("100"),
      metadata: %{taker_address: "0x0000000000000000000000000000000000000abc"}
    }

    {:ok, req} = QuoteRequest.build(Map.merge(defaults, overrides))
    req
  end

  defp build_solana_swap do
    {:ok, req} =
      QuoteRequest.build(%{
        source_chain: "solana",
        source_asset: "USDC",
        dest_chain: "solana",
        dest_asset: "USDT",
        amount: Decimal.new("100")
      })

    req
  end

  defp build_bridge do
    {:ok, req} =
      QuoteRequest.build(%{
        source_chain: "ethereum",
        source_asset: "USDC",
        dest_chain: "base",
        dest_asset: "USDC",
        amount: Decimal.new("1000")
      })

    req
  end

  # -- Best-of-two EVM selection --------------------------------------------

  describe "select/2 — EVM swap best-of-two" do
    test "selects provider with higher output_amount" do
      req = build_evm_swap()

      Process.put(:provider_a_response, {:ok, "99.8"})
      Process.put(:provider_b_response, {:ok, "99.2"})

      assert {:ok, quote, meta} =
               RouteSelector.select(req, providers: [ProviderA, ProviderB])

      assert quote.provider == "provider_a"
      assert Decimal.equal?(quote.output_amount, Decimal.new("99.8"))
      assert meta.considered == 2
      assert meta.errors == []
      assert length(meta.all_quotes) == 2
    end

    test "selects provider B when it has higher output" do
      req = build_evm_swap()

      Process.put(:provider_a_response, {:ok, "98.5"})
      Process.put(:provider_b_response, {:ok, "99.7"})

      assert {:ok, quote, _meta} =
               RouteSelector.select(req, providers: [ProviderA, ProviderB])

      assert quote.provider == "provider_b"
    end

    test "returns single successful quote when one provider fails" do
      req = build_evm_swap()

      Process.put(:provider_a_response, {:ok, "99.5"})
      Process.put(:provider_b_response, {:error, :provider_unavailable})

      assert {:ok, quote, meta} =
               RouteSelector.select(req, providers: [ProviderA, FailingProvider])

      assert quote.provider == "provider_a"
      assert length(meta.errors) == 1
      assert hd(meta.errors).provider == FailingProvider
      assert hd(meta.errors).error == :provider_unavailable
    end

    test "returns quote when one provider returns unsupported_route" do
      req = build_evm_swap()

      Process.put(:provider_a_response, {:ok, "99.5"})

      assert {:ok, quote, meta} =
               RouteSelector.select(req, providers: [ProviderA, UnsupportedProvider])

      assert quote.provider == "provider_a"
      assert meta.errors == []
      assert meta.considered == 1
    end
  end

  # -- Tie-breaking ---------------------------------------------------------

  describe "select/2 — tie-breaking" do
    test "same output: selects lower total_fee" do
      req = build_evm_swap()

      Process.put(:provider_a_response, {:ok, "99.5"})
      Process.put(:provider_b_response, {:ok, "99.5"})

      assert {:ok, quote, _meta} =
               RouteSelector.select(req, providers: [ProviderA, ProviderB])

      assert quote.provider in ["provider_a", "provider_b"]
    end

    test "same output and fees: selects lower eta_seconds" do
      req = build_evm_swap()

      Process.put(:provider_a_response, {:ok, "99.5"})
      Process.put(:provider_b_response, {:ok, "99.5"})
      Process.put(:provider_a_eta, 30)
      Process.put(:provider_b_eta, 15)

      assert {:ok, quote, _meta} =
               RouteSelector.select(req, providers: [ProviderA, ProviderB])

      assert quote.provider == "provider_b"
    after
      Process.delete(:provider_a_eta)
      Process.delete(:provider_b_eta)
    end

    test "all equal: uses stable provider priority" do
      req = build_evm_swap()

      Process.put(:provider_a_response, {:ok, "99.5"})
      Process.put(:provider_b_response, {:ok, "99.5"})

      {:ok, quote1, _} = RouteSelector.select(req, providers: [ProviderA, ProviderB])
      {:ok, quote2, _} = RouteSelector.select(req, providers: [ProviderB, ProviderA])

      assert quote1.provider == quote2.provider
    end
  end

  # -- Solana routing -------------------------------------------------------

  describe "select/2 — Solana swap" do
    test "routes to single provider" do
      req = build_solana_swap()

      Process.put(:provider_a_response, {:ok, "99.5"})

      assert {:ok, quote, meta} =
               RouteSelector.select(req, providers: [ProviderA])

      assert quote.provider == "provider_a"
      assert meta.considered == 1
    end
  end

  # -- Bridge routing -------------------------------------------------------

  describe "select/2 — bridge route" do
    test "returns CCTP quote for cross-chain USDC" do
      req = build_bridge()

      Process.put(:provider_a_response, {:ok, "1000"})

      assert {:ok, quote, _meta} =
               RouteSelector.select(req, providers: [ProviderA])

      assert Decimal.equal?(quote.output_amount, Decimal.new("1000"))
    end
  end

  # -- Unsupported routes ---------------------------------------------------

  describe "select/2 — unsupported routes" do
    test "swap_plus_bridge returns unsupported_route" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "base",
          dest_asset: "USDT",
          amount: Decimal.new("100"),
          metadata: %{taker_address: "0x0000000000000000000000000000000000000abc"}
        })

      assert {:error, :unsupported_route} = RouteSelector.select(req)
    end
  end

  # -- All providers fail ---------------------------------------------------

  describe "select/2 — all providers fail" do
    test "returns aggregate error with per-provider detail" do
      req = build_evm_swap()

      Process.put(:failing_response, {:error, :provider_unavailable})

      assert {:error, {:no_quotes, errors}} =
               RouteSelector.select(req, providers: [FailingProvider])

      assert length(errors) == 1
      assert hd(errors).provider == FailingProvider
      assert hd(errors).error == :provider_unavailable
    end

    test "returns no_quotes when both providers fail with different errors" do
      req = build_evm_swap()

      Process.put(:provider_a_response, {:error, :rate_limited})
      Process.put(:provider_b_response, {:error, :provider_unavailable})

      assert {:error, {:no_quotes, errors}} =
               RouteSelector.select(req, providers: [FailingProvider, FailingProvider])

      assert length(errors) >= 1
    end

    test "all unsupported_route returns no_quotes with empty errors" do
      req = build_evm_swap()

      assert {:error, {:no_quotes, errors}} =
               RouteSelector.select(req, providers: [UnsupportedProvider])

      assert errors == []
    end
  end

  # -- Metadata preservation ------------------------------------------------

  describe "select/2 — metadata" do
    test "metadata includes all successful quotes" do
      req = build_evm_swap()

      Process.put(:provider_a_response, {:ok, "99.8"})
      Process.put(:provider_b_response, {:ok, "99.2"})

      {:ok, _quote, meta} = RouteSelector.select(req, providers: [ProviderA, ProviderB])

      assert meta.considered == 2
      providers = Enum.map(meta.all_quotes, & &1.provider) |> Enum.sort()
      assert providers == ["provider_a", "provider_b"]
    end

    test "metadata includes errors from failed providers" do
      req = build_evm_swap()

      Process.put(:provider_a_response, {:ok, "99.5"})
      Process.put(:failing_response, {:error, :rate_limited})

      {:ok, _quote, meta} = RouteSelector.select(req, providers: [ProviderA, FailingProvider])

      assert length(meta.errors) == 1
      assert hd(meta.errors).error == :rate_limited
    end

    test "metadata errors exclude unsupported_route" do
      req = build_evm_swap()

      Process.put(:provider_a_response, {:ok, "99.5"})

      {:ok, _quote, meta} =
        RouteSelector.select(req, providers: [ProviderA, UnsupportedProvider])

      assert meta.errors == []
    end
  end

  # -- Default provider routing (no :providers opt) -------------------------

  describe "select/2 — default provider routing" do
    test "swap_plus_bridge returns unsupported_route with defaults" do
      {:ok, req} =
        QuoteRequest.build(%{
          source_chain: "ethereum",
          source_asset: "USDC",
          dest_chain: "base",
          dest_asset: "USDT",
          amount: Decimal.new("100"),
          metadata: %{taker_address: "0x0000000000000000000000000000000000000abc"}
        })

      assert {:error, :unsupported_route} = RouteSelector.select(req)
    end
  end

  # -- Empty provider list --------------------------------------------------

  describe "select/2 — edge cases" do
    test "empty provider list returns unsupported_route" do
      req = build_evm_swap()

      assert {:error, :unsupported_route} = RouteSelector.select(req, providers: [])
    end
  end
end
