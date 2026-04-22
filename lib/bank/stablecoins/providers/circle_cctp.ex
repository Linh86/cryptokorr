defmodule Bank.Stablecoins.Providers.CircleCCTP do
  @moduledoc """
  Circle CCTP adapter for cross-chain USDC bridge routes.

  Implements `Bank.Stablecoins.Provider` for Cross-Chain Transfer
  Protocol (CCTP) v2 bridge quotes. CCTP is a native burn-and-mint
  protocol operated by Circle — burn USDC on the source chain, obtain
  an attestation from Circle's attestation service, then mint USDC on
  the destination chain.

  This adapter models a CCTP v2 Standard Transfer quote only. Unlike
  swap aggregator adapters, standard CCTP quotes are deterministic:
  output equals input (1:1 bridge, no slippage). Gas is paid in
  the native chain token and is not reflected in the bridge fee. No
  HTTP call is needed at quote time.

  It does not quote CCTP Fast Transfer liquidity or fees. If we add
  Fast Transfer later, that should be a separate provider mode with an
  explicit fee model rather than silently changing this standard route.

  Supported route kind: `:bridge` only.
  Supported asset: USDC only (canonical, `:active` status).
  Supported chains: ethereum, base, arbitrum, optimism, polygon, solana.

  ## CCTP domain mapping

      ethereum  → 0
      optimism  → 2
      arbitrum  → 3
      solana    → 5
      base      → 6
      polygon   → 7

  ## Execution flow (not performed by this adapter)

      1. Burn USDC on source chain via TokenMessenger.depositForBurn
      2. Wait for standard attestation from Circle's Iris attestation service
      3. Mint USDC on dest chain via MessageTransmitter.receiveMessage

  The adapter preserves CCTP domain IDs, protocol version, and
  execution flow metadata in `provider_metadata` so the execution
  layer can perform the burn → attestation → mint sequence.
  """

  @behaviour Bank.Stablecoins.Provider

  alias Bank.Stablecoins.{QuoteRequest, RouteLeg, RouteQuote}

  @cctp_domains %{
    "ethereum" => 0,
    "optimism" => 2,
    "arbitrum" => 3,
    "solana" => 5,
    "base" => 6,
    "polygon" => 7
  }

  @eta_seconds %{
    "ethereum" => 780,
    "optimism" => 120,
    "arbitrum" => 120,
    "solana" => 60,
    "base" => 120,
    "polygon" => 300
  }

  @attestation_url "https://iris-api.circle.com/v2/attestations"

  @impl true
  def provider_id, do: "circle_cctp"

  @impl true
  def quote(%QuoteRequest{route_kind: :bridge} = req) do
    with :ok <- validate_cctp_route(req) do
      build_bridge_quote(req)
    end
  end

  def quote(%QuoteRequest{}), do: {:error, :unsupported_route}

  # -- Route validation -----------------------------------------------------

  defp validate_cctp_route(req) do
    with :ok <- validate_usdc_only(req),
         :ok <- validate_chain(req.source_chain),
         :ok <- validate_chain(req.dest_chain),
         :ok <- validate_cctp_token(req.source_token, req.source_chain),
         :ok <- validate_cctp_token(req.dest_token, req.dest_chain) do
      :ok
    end
  end

  defp validate_usdc_only(%QuoteRequest{source_asset: "USDC", dest_asset: "USDC"}), do: :ok
  defp validate_usdc_only(_), do: {:error, :unsupported_route}

  defp validate_chain(chain) do
    if Map.has_key?(@cctp_domains, chain), do: :ok, else: {:error, :unsupported_route}
  end

  defp validate_cctp_token(
         %{chain: chain, asset: "USDC", status: :active, canonical: true},
         chain
       ),
       do: :ok

  defp validate_cctp_token(_, _), do: {:error, :unsupported_route}

  # -- Quote building -------------------------------------------------------

  defp build_bridge_quote(req) do
    now = DateTime.utc_now()
    eta = bridge_eta(req.source_chain, req.dest_chain)
    source_domain = Map.fetch!(@cctp_domains, req.source_chain)
    dest_domain = Map.fetch!(@cctp_domains, req.dest_chain)

    leg = %RouteLeg{
      step: 1,
      kind: :bridge,
      source_chain: req.source_chain,
      source_asset: req.source_asset,
      source_address: req.source_token.address,
      dest_chain: req.dest_chain,
      dest_asset: req.dest_asset,
      dest_address: req.dest_token.address,
      input_amount: req.amount,
      output_amount: req.amount,
      protocol: "Circle CCTP",
      eta_seconds: eta,
      metadata: %{
        "source_domain" => source_domain,
        "dest_domain" => dest_domain,
        "transfer_type" => "standard"
      }
    }

    {:ok,
     %RouteQuote{
       provider: provider_id(),
       request: req,
       route_kind: :bridge,
       legs: [leg],
       input_amount: req.amount,
       output_amount: req.amount,
       quoted_at: now,
       expires_at: nil,
       fees: %{
         gas_fee: nil,
         protocol_fee: nil,
         bridge_fee: nil,
         cryptobank_fee: nil,
         total_fee: Decimal.new(0)
       },
       eta_seconds: eta,
       risk_flags: [],
       explanation:
         "USDC bridge via Circle CCTP: #{req.source_chain} (domain #{source_domain}) → #{req.dest_chain} (domain #{dest_domain})",
       provider_metadata: %{
         "source_domain" => source_domain,
         "dest_domain" => dest_domain,
         "protocol_version" => "v2",
         "transfer_type" => "standard",
         "fast_transfer" => false,
         "fee_model" => "standard transfer only; no Circle fast-transfer fee quoted",
         "attestation_url" => @attestation_url,
         "execution_flow" => "burn → standard_attestation → mint"
       }
     }}
  end

  defp bridge_eta(source_chain, dest_chain) do
    source_eta = Map.get(@eta_seconds, source_chain, 300)
    dest_eta = Map.get(@eta_seconds, dest_chain, 300)
    max(source_eta, dest_eta)
  end
end
