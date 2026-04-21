defmodule Bank.Stablecoins.Provider do
  @moduledoc """
  Behaviour for stablecoin routing providers.

  Each provider (0x, 1inch, Jupiter, Circle CCTP) implements this
  behaviour with a single `quote/1` callback that accepts a
  validated `%QuoteRequest{}` and returns a normalized
  `%RouteQuote{}` or an error.

  ## Error contract

  Providers return `{:error, reason}` where `reason` is one of:

    * `:unsupported_route` — the provider cannot serve this route kind
    * `:provider_unavailable` — transient network/API failure
    * `:rate_limited` — provider rate limit hit
    * `:no_route_found` — provider found no viable route
    * `{:provider_error, details}` — provider-specific error

  ## Provider identification

  Each module must also implement `provider_id/0` returning a stable
  string identifier used in route quotes and audit trails.
  """

  alias Bank.Stablecoins.{QuoteRequest, RouteQuote}

  @type quote_error ::
          :unsupported_route
          | :provider_unavailable
          | :rate_limited
          | :no_route_found
          | {:provider_error, term()}

  @callback quote(QuoteRequest.t()) :: {:ok, RouteQuote.t()} | {:error, quote_error()}

  @callback provider_id() :: String.t()
end
