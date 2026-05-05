defmodule Bank.Quotes.LiveProvider do
  @moduledoc """
  Skeleton for the live (network-backed) quote/simulation provider
  (#173).

  This module is the contract anchor for the *future* live provider
  client (#174). Today it implements `Bank.Quotes.Provider` but
  short-circuits with `{:error, :not_yet_implemented}` for every
  call, so:

    * a deployment that flips
      `config :bank, Bank.Quotes, provider: :live` ahead of #174
      gets a clean, structured failure rather than a cryptic
      `UndefinedFunctionError`;
    * #174 fills in `preview/2`'s body without changing this
      module's behaviour declaration or `Bank.Quotes`'s integration
      seam — the provider abstraction in `Bank.Quotes.preview/2` is
      already the load-bearing seam.

  ## Posture (when #174 lands)

  When this provider is implemented for real, it MUST:

    * issue HTTP via `Req` (per the project's HTTP guideline) with
      a request timeout small enough to fit inside the dispatch
      worker's deadline budget;
    * never broadcast — the live provider produces previews, not
      transactions; broadcast is `Bank.AdapterClient`'s job;
    * never log or surface the provider's API key / Authorization
      header / tokenized URL — same secret-hygiene posture as
      `Bank.Chains.MainnetPreflight` (#179) and
      `Bank.Ops.Health.adapter/0` (#253);
    * produce a `Bank.Quotes.Preview{source: :live, ...}` on
      success;
    * map provider failure shapes onto `Bank.Quotes.error()` —
      `:provider_unavailable` for transport / 5xx,
      `{:simulation_failed, reason}` for explicit dry-run rejects,
      `:stale` if the provider returns a cached / replayed result
      past its TTL.

  Until #174 lands, the only callable behaviour is the failure
  return below.
  """

  @behaviour Bank.Quotes.Provider

  alias Bank.Intents.AgentIntent

  @impl Bank.Quotes.Provider
  def preview(%AgentIntent{} = _intent, _opts \\ []) do
    {:error, :not_yet_implemented}
  end
end
