defmodule Bank.Quotes.LiveProvider do
  @moduledoc """
  Live (network-backed) quote/simulation provider for #174.

  Issues an HTTP simulation request to a Tenderly-style simulate
  endpoint and translates the response into a `%Bank.Quotes.Preview{}`
  carrying `source: :live` and `provider: "tenderly"`. Failures map
  onto a small `Bank.Quotes.error()` allowlist so the decision
  pipeline can degrade toward caution without ever inspecting raw
  response bodies / URLs / Authorization headers.

  ## Provider target (v0.1)

  Tenderly's simulate API is the v0.1 deterministic-in-test target.
  The exact upstream endpoint shape is intentionally not hard-coded
  to a single Tenderly account/project tuple — instead the provider
  hits `POST {base_url}/v1/simulate` and authenticates via the
  Tenderly-style `X-Access-Key` header. Operators wire `base_url`
  and `api_key` through env vars in `config/runtime.exs`. Real
  network calls are gated under tests via `Req.Test`.

  ## Configuration

      config :bank, Bank.Quotes.LiveProvider,
        base_url: "https://api.tenderly.co/api",
        api_key: "<TENDERLY_API_KEY>",
        # Optional: extra options merged into the Req call (e.g.
        # `plug: {Req.Test, Bank.Quotes.LiveProvider}` under :test).
        req_options: []

  Tests override `:req_options` with
  `[plug: {Req.Test, Bank.Quotes.LiveProvider}]` and stub via
  `Req.Test.stub/2`. No live network call escapes the test pool.

  ## Error mapping

    * Transport error (DNS, connection refused, TLS) →
      `{:error, :provider_unavailable}`.
    * Receive timeout → `{:error, :provider_unavailable}`.
    * 5xx → `{:error, :provider_unavailable}`.
    * 4xx whose body declares `code: "simulation_failed"` →
      `{:error, {:simulation_failed, reason_tag}}`. The reason tag
      is drawn from a small allowlist (or falls back to
      `"upstream_dry_run_rejected"` if the upstream omits one).
    * Other 4xx → `{:error, :provider_unavailable}` (we treat
      unknown 4xx as opaque transport state and let the autonomy
      layer fail closed).
    * Malformed JSON / unexpected 2xx body shape →
      `{:error, :provider_unavailable}`.
    * No API key / no base_url configured →
      `{:error, :provider_unavailable}`.

  ## Secret hygiene

  Same posture as `Bank.Chains.MainnetPreflight` (#179) and
  `Bank.AdapterClient` (#253):

    * Logs collapse the failure mode onto a fixed-allowlist
      category label (`:timeout` / `:econnrefused` / `:nxdomain` /
      `:transport_error` / `:http_5xx` / `:http_4xx` /
      `:invalid_response` / `:simulation_failed` /
      `:not_configured`). The raw `Req.TransportError` struct,
      response body, request URL, and Authorization-style headers
      are never `inspect/1`-ed.
    * `provider_trace_ref` carries the upstream-supplied trace id
      only — never the request URL, never any header, never the
      API key. Tests pin this with regex assertions.
    * The returned `%Preview{}` never contains the raw response
      body; only the normalized fields the Preview contract calls
      out are populated.

  ## No broadcast

  This provider produces previews, not transactions. There is no
  signing material here, no bundler interaction. Broadcast remains
  `Bank.AdapterClient`'s responsibility.
  """

  @behaviour Bank.Quotes.Provider

  require Logger

  alias Bank.Intents.AgentIntent
  alias Bank.Quotes.Preview

  @endpoint "/v1/simulate"
  @default_timeout_ms 5_000
  @default_freshness_ttl_seconds 30
  @provider_id "tenderly"

  # Base mainnet — the only chain v0.1 supports. Mirrors
  # `Bank.Chains.MainnetPreflight.base_mainnet_chain_id/0`. We
  # don't import the constant to keep this module decoupled from
  # the preflight pipeline, but the value MUST match.
  @base_chain_id 8453

  # Risk-flag allowlist enforced at the boundary so a malicious
  # upstream cannot inject arbitrary string into a Preview that's
  # later rendered to operator surfaces. Mirrors the
  # `Bank.Stablecoins.RouteQuote.risk_flags` posture (#173).
  @risk_flag_allowlist ~w(
    wide_slippage_band
    low_liquidity_pool
    router_partial_fill
    high_gas
    cached_quote
    new_route
  )

  # Simulation-failed reason tags the upstream may surface. Anything
  # outside this allowlist collapses to `"upstream_dry_run_rejected"`
  # so a free-form upstream string can never reach a structured
  # error tuple.
  @simulation_failed_reason_allowlist ~w(
    insufficient_balance
    revert
    insufficient_liquidity
    slippage_exceeded
    nonce_conflict
    unsupported_asset
    unsupported_chain
    upstream_dry_run_rejected
  )

  # Secret-pattern allowlist enforced at the upstream boundary. The
  # provider-controlled `trace_id`, `route`, and `failure_conditions`
  # ride straight into a `%Preview{}` and then into the persisted
  # `simulation_reports` row; a malicious or buggy upstream that
  # smuggles `Authorization: Bearer ...`, an `sk_live_...` key, a
  # credentialed `https://user:pass@host` URL, or PEM private-key
  # text into one of those fields would otherwise survive the #174
  # log-redaction boundary on its way to operator surfaces and the
  # decision audit trail. Any string matching one of these patterns
  # is dropped (trace_id, failure_conditions) or replaced with
  # `"[REDACTED]"` (nested route values).
  @secret_patterns [
    ~r/Authorization\s*:\s*Bearer/i,
    ~r/Bearer\s+sk_/i,
    ~r/\bsk_(live|test)_/,
    ~r/\bpk_(live|test)_/,
    ~r{://[^\s/@]+:[^\s/@]+@},
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/
  ]

  @secret_redaction_marker "[REDACTED]"

  @impl Bank.Quotes.Provider
  def preview(%AgentIntent{} = intent, opts \\ []) do
    case Application.get_env(:bank, __MODULE__, []) do
      [] ->
        log_unavailable(:not_configured)
        {:error, :provider_unavailable}

      config ->
        do_preview(intent, config, opts)
    end
  end

  # --- request / response orchestration -----------------------------------

  defp do_preview(%AgentIntent{} = intent, config, opts) do
    with {:ok, base_url} <- fetch_base_url(config),
         {:ok, api_key} <- fetch_api_key(config),
         {:ok, payload} <- build_payload(intent) do
      req_opts =
        [
          base_url: base_url,
          url: @endpoint,
          method: :post,
          headers: [
            {"x-access-key", api_key},
            {"content-type", "application/json"},
            {"accept", "application/json"}
          ],
          json: payload,
          receive_timeout: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
          retry: false
        ]
        |> Keyword.merge(Keyword.get(config, :req_options, []))
        |> Keyword.merge(Keyword.get(opts, :req_options, []))

      req_opts
      |> Req.request()
      |> classify_response(intent)
    end
  end

  defp fetch_base_url(config) do
    case Keyword.get(config, :base_url) do
      url when is_binary(url) and url != "" ->
        {:ok, url}

      _ ->
        log_unavailable(:not_configured)
        {:error, :provider_unavailable}
    end
  end

  defp fetch_api_key(config) do
    case Keyword.get(config, :api_key) do
      key when is_binary(key) and key != "" ->
        {:ok, key}

      _ ->
        log_unavailable(:not_configured)
        {:error, :provider_unavailable}
    end
  end

  # The outbound payload mirrors a Tenderly-style simulate request
  # in spirit while staying small enough that future upstreams
  # (different live providers) can be added without restructuring
  # the call site. JSON-only — no signing material, no Authorization
  # header echoing.
  defp build_payload(%AgentIntent{} = intent) do
    {:ok,
     %{
       "chain_id" => @base_chain_id,
       "kind" => Atom.to_string(intent.kind),
       "asset" => intent.asset,
       "amount" => decimal_to_string(intent.amount),
       "intent_id" => intent.id,
       "submitted_at" => isoformat(intent.submitted_at)
     }}
  end

  # --- response classification --------------------------------------------

  defp classify_response({:ok, %Req.Response{status: status, body: body}}, _intent)
       when status in 200..299 do
    case parse_success(body) do
      {:ok, fields} ->
        {:ok, build_preview(fields)}

      :error ->
        log_unavailable(:invalid_response)
        {:error, :provider_unavailable}
    end
  end

  defp classify_response({:ok, %Req.Response{status: status, body: body}}, _intent)
       when status in 400..499 do
    case simulation_failed_reason(body) do
      {:ok, reason} ->
        # `:simulation_failed` is a deterministic upstream rejection;
        # log only the controlled tag, never the raw body / URL.
        Logger.warning(
          "Bank.Quotes.LiveProvider simulation rejected (category=simulation_failed reason=#{reason})"
        )

        {:error, {:simulation_failed, reason}}

      :error ->
        log_unavailable(:http_4xx)
        {:error, :provider_unavailable}
    end
  end

  defp classify_response({:ok, %Req.Response{status: status}}, _intent) when status >= 500 do
    log_unavailable(:http_5xx)
    {:error, :provider_unavailable}
  end

  defp classify_response({:ok, %Req.Response{}}, _intent) do
    log_unavailable(:invalid_response)
    {:error, :provider_unavailable}
  end

  defp classify_response({:error, reason}, _intent) do
    log_unavailable(reason_category(reason))
    {:error, :provider_unavailable}
  end

  # --- success body parsing -----------------------------------------------

  # The upstream is JSON-decoded by Req. We only accept a map with the
  # documented success envelope; anything else collapses to
  # `:provider_unavailable` via the `:invalid_response` branch.
  defp parse_success(%{"success" => true} = body) do
    with {:ok, balance_impact} <- parse_balance_impact(Map.get(body, "balance_changes")),
         {:ok, fee_asset} <- parse_string_or_nil(Map.get(body, "fee_asset")),
         {:ok, route} <- parse_map_or_nil(Map.get(body, "route")) do
      fields = %{
        balance_impact: balance_impact,
        estimated_gas: parse_integer_or_nil(Map.get(body, "estimated_gas")),
        estimated_fee: parse_decimal_or_nil(Map.get(body, "estimated_fee")),
        fee_asset: fee_asset,
        expected_output: parse_decimal_or_nil(Map.get(body, "expected_output")),
        slippage_bps: parse_integer_or_nil(Map.get(body, "slippage_bps")),
        route: route,
        failure_conditions: parse_string_list(Map.get(body, "failure_conditions")),
        risk_flags: parse_risk_flags(Map.get(body, "risk_flags")),
        provider_trace_ref: parse_trace_ref(Map.get(body, "trace_id")),
        freshness_ttl_seconds: parse_ttl(Map.get(body, "freshness_ttl_seconds"))
      }

      {:ok, fields}
    end
  end

  defp parse_success(_), do: :error

  defp build_preview(fields) do
    %Preview{
      balance_impact: fields.balance_impact,
      estimated_gas: fields.estimated_gas,
      estimated_fee: fields.estimated_fee,
      fee_asset: fields.fee_asset,
      expected_output: fields.expected_output,
      slippage_bps: fields.slippage_bps,
      route: fields.route,
      failure_conditions: fields.failure_conditions,
      failure_reason: nil,
      risk_flags: fields.risk_flags,
      source: :live,
      provider: @provider_id,
      provider_trace_ref: fields.provider_trace_ref,
      generated_at: DateTime.utc_now(),
      freshness_ttl_seconds: fields.freshness_ttl_seconds
    }
  end

  # --- simulation-failed extraction ---------------------------------------

  # The upstream signals an explicit dry-run rejection via either
  # `code == "simulation_failed"` at the top level or under an
  # `error` envelope. Anything else under 4xx is treated as opaque
  # transport state.
  defp simulation_failed_reason(%{"code" => "simulation_failed"} = body) do
    {:ok, normalize_reason(Map.get(body, "reason"))}
  end

  defp simulation_failed_reason(%{"error" => %{"code" => "simulation_failed"} = err}) do
    {:ok, normalize_reason(Map.get(err, "reason"))}
  end

  defp simulation_failed_reason(_), do: :error

  defp normalize_reason(reason) when is_binary(reason) do
    if reason in @simulation_failed_reason_allowlist do
      reason
    else
      "upstream_dry_run_rejected"
    end
  end

  defp normalize_reason(_), do: "upstream_dry_run_rejected"

  # --- field parsers ------------------------------------------------------

  defp parse_balance_impact(nil), do: {:ok, %{}}

  defp parse_balance_impact(map) when is_map(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn
      {asset, raw}, {:ok, acc} when is_binary(asset) ->
        case parse_decimal_or_nil(raw) do
          %Decimal{} = d -> {:cont, {:ok, Map.put(acc, asset, d)}}
          nil -> {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  defp parse_balance_impact(_), do: :error

  defp parse_decimal_or_nil(nil), do: nil

  defp parse_decimal_or_nil(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = d, ""} -> d
      _ -> nil
    end
  end

  defp parse_decimal_or_nil(value) when is_integer(value), do: Decimal.new(value)

  defp parse_decimal_or_nil(%Decimal{} = d), do: d

  defp parse_decimal_or_nil(_), do: nil

  defp parse_integer_or_nil(value) when is_integer(value) and value >= 0, do: value

  defp parse_integer_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp parse_integer_or_nil(_), do: nil

  defp parse_string_or_nil(nil), do: {:ok, nil}
  defp parse_string_or_nil(value) when is_binary(value), do: {:ok, value}
  defp parse_string_or_nil(_), do: :error

  defp parse_map_or_nil(nil), do: {:ok, nil}
  defp parse_map_or_nil(map) when is_map(map), do: {:ok, sanitize_value(map)}
  defp parse_map_or_nil(_), do: :error

  defp parse_string_list(nil), do: []

  defp parse_string_list(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&contains_secret?/1)
  end

  defp parse_string_list(_), do: []

  defp parse_risk_flags(nil), do: []

  defp parse_risk_flags(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.filter(&(&1 in @risk_flag_allowlist))
    |> Enum.uniq()
  end

  defp parse_risk_flags(_), do: []

  defp parse_ttl(value) when is_integer(value) and value > 0, do: value
  defp parse_ttl(_), do: @default_freshness_ttl_seconds

  # `provider_trace_ref` is forwarded only when the upstream
  # surfaced a non-empty string. We drop any value carrying a
  # secret-shaped marker (Authorization header, sk_/pk_ key prefix,
  # credentialed URL, PEM block) before clamping length to 128 chars
  # so a maliciously long header-style payload smuggled into the
  # trace field can never hit the operator UI or `simulation_reports`.
  defp parse_trace_ref(value) when is_binary(value) and value != "" do
    if contains_secret?(value) do
      nil
    else
      String.slice(value, 0, 128)
    end
  end

  defp parse_trace_ref(_), do: nil

  # --- amount + time helpers ---------------------------------------------

  defp decimal_to_string(nil), do: nil

  defp decimal_to_string(%Decimal{} = d),
    do: d |> Decimal.normalize() |> Decimal.to_string(:normal)

  defp decimal_to_string(other), do: to_string(other)

  defp isoformat(nil), do: nil
  defp isoformat(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp isoformat(other), do: to_string(other)

  # --- upstream-payload secret hygiene ------------------------------------

  # `true` when `value` carries one of the @secret_patterns markers.
  # Used at the upstream boundary on `trace_id` and `failure_conditions`.
  defp contains_secret?(value) when is_binary(value) do
    Enum.any?(@secret_patterns, &Regex.match?(&1, value))
  end

  defp contains_secret?(_), do: false

  # Recursively walks any JSON-decoded value (map / list / string /
  # other) and replaces string leaves carrying a secret marker with
  # `@secret_redaction_marker`. Used on the upstream `route` map,
  # whose shape is provider-defined — we keep the structural skeleton
  # so downstream consumers (operator UI, decision report) can still
  # see the route's shape, but no marker survives to the persisted row.
  #
  # Map keys are also untrusted: a malicious upstream could send
  # `%{"Authorization: Bearer sk_live_x" => "ok"}` and survive a
  # value-only sanitiser even after #442. Entries whose key is a
  # binary matching one of the secret patterns are dropped entirely
  # — the value attached to a secret-shaped key carries no operator-
  # readable meaning once its key is gone, and dropping (rather than
  # redacting the key to `"[REDACTED]"`) avoids key collisions when
  # the upstream uses several distinct secret-bearing keys. Non-binary
  # keys (atoms, integers) cannot carry our pattern and are kept.
  defp sanitize_value(value) when is_binary(value) do
    if contains_secret?(value), do: @secret_redaction_marker, else: value
  end

  defp sanitize_value(value) when is_map(value) do
    value
    |> Enum.reject(fn {k, _v} -> contains_secret?(k) end)
    |> Map.new(fn {k, v} -> {k, sanitize_value(v)} end)
  end

  defp sanitize_value(value) when is_list(value) do
    Enum.map(value, &sanitize_value/1)
  end

  defp sanitize_value(value), do: value

  # --- log sanitization ---------------------------------------------------

  defp log_unavailable(category) do
    Logger.warning("Bank.Quotes.LiveProvider #{@endpoint} unavailable (category=#{category})")
  end

  # Mirrors `Bank.AdapterClient.reason_category/1`. Maps a Req
  # transport reason onto a fixed-allowlist atom so the operator
  # log NEVER carries the raw struct (which would surface the
  # request URL, transport options, and TLS material).
  defp reason_category(%Req.TransportError{reason: :timeout}), do: :timeout
  defp reason_category(%Req.TransportError{reason: :econnrefused}), do: :econnrefused
  defp reason_category(%Req.TransportError{reason: :nxdomain}), do: :nxdomain
  defp reason_category(%Req.TransportError{}), do: :transport_error
  defp reason_category(:timeout), do: :timeout
  defp reason_category(:econnrefused), do: :econnrefused
  defp reason_category(:nxdomain), do: :nxdomain
  defp reason_category(_), do: :transport_error
end
