defmodule Bank.Quotes.Provider do
  @moduledoc """
  Behaviour implemented by quote / simulation providers.

  A provider translates an `%AgentIntent{}` into a `%Bank.Quotes.Preview{}`
  or a structured error. Implementations must not raise for expected
  failure modes — raising bubbles to `Bank.Quotes.preview/2` which
  re-wraps as `{:error, :provider_unavailable}`, but explicit return
  values preserve diagnostic information.

  ## Preview shape contract (#173)

  Implementations MUST set the following fields on a successfully
  returned `%Preview{}`:

    * `:source` — `:stub` for deterministic in-process providers,
      `:live` for network-backed providers. The decision pipeline
      uses this to apply different autonomy rules per source kind
      without parsing the human-readable `:provider` string.
    * `:provider` — short human-readable identifier (e.g.
      `"stub"`, `"tenderly"`).
    * `:generated_at` — wall-clock timestamp at preview time.
    * `:freshness_ttl_seconds` — how many seconds the preview can
      be trusted before it is `stale?/2`.

  Optional preview fields (the provider populates them when it has
  the data):

    * `:risk_flags` — list of short fixed-allowlist strings (e.g.
      `"wide_slippage_band"`, `"low_liquidity_pool"`). Defaults to
      `[]` when the provider sees no risk signals.
    * `:failure_reason` — short tag (or `nil`) when the provider
      surfaces a soft failure through the preview path; distinct
      from the error tuple a hard failure returns.

  ## Error shape contract

  When the provider cannot produce a `%Preview{}`, it returns
  `{:error, reason}` where `reason` is one of `Bank.Quotes.error()`:

    * `:provider_unavailable` — transport / 5xx / timeout. The
      caller should hold or block, never auto-execute.
    * `{:simulation_failed, reason_string}` — the provider answered
      but the dry-run itself rejected (revert, insufficient balance,
      etc).
    * `:stale` — the cached preview is past TTL and a fresh one is
      not yet available.
    * `:not_yet_implemented` — the provider module is a skeleton
      (e.g. `Bank.Quotes.LiveProvider` pre-#174).
    * `{:unsupported, reason_string}` — the chain or asset is not
      supported by this provider.

  Other Bank.Quotes-level error atoms (`:provider_disabled`,
  `{:provider_exception, _}`) are produced by `Bank.Quotes.preview/2`
  itself, not by individual providers.

  ## Secret hygiene

  Providers MUST NOT carry raw URLs, Authorization headers, API
  keys, tokenized RPC URLs, or provider secrets onto the returned
  preview. The `:provider_trace_ref` field is for non-sensitive,
  provider-side debug ids only — same posture as
  `Bank.Chains.MainnetPreflight` (#179). Tests under
  `test/bank/quotes_test.exs` pin this for the stub provider.
  """

  alias Bank.Intents.AgentIntent
  alias Bank.Quotes.Preview

  @callback preview(intent :: AgentIntent.t(), opts :: keyword()) ::
              {:ok, Preview.t()} | {:error, Bank.Quotes.error()}

  @doc """
  Stable, human-readable identifier for the provider implementation
  (e.g. `"stub"`, `"tenderly"`). Matches the value the provider sets
  on `Preview.provider` for successful previews; the decision pipeline
  records it on failed `SimulationReport`s so the
  attempted-provider-on-failure path is observable
  (#175 — failed previews should not look like stub failures).
  """
  @callback provider_id() :: String.t()

  @optional_callbacks provider_id: 0
end
