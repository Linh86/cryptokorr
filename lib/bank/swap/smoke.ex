defmodule Bank.Swap.Smoke do
  @moduledoc """
  Phoenix-side end-to-end shape smoke for the MVP 0x swap dispatch
  path (#196).

  Drives every read-only Phoenix-side surface a fresh reviewer needs
  to inspect locally and reports a per-check pass/fail. The
  automated counterpart to
  [`docs/runbooks/swap-dispatch.md`](../../../docs/runbooks/swap-dispatch.md):
  a single command produces a deterministic outcome that mirrors
  what the runbook prose describes.

  ## What it verifies

    * `swap.route_validation` — a synthetic Base Sepolia 0x USDC
      route passes `Bank.Intents.SwapRoute.validate/2`.
    * `swap.route_artifacts` — `Bank.Decisions.SwapRouteArtifacts.from_route/1`
      produces a deterministic `route_hash` + JSON-friendly `steps`
      + `audit_metadata` carrying `route_provider`.
    * `swap.route_round_trip` —
      `SwapRouteArtifacts.route_from_steps(steps) == {:ok, route}`,
      so the persisted plan can rehydrate the same route bytes the
      operator approved.
    * `swap.safety_gate_accepts` —
      `Bank.Decisions.SwapDispatchSafety.validate/3` passes for the
      synthetic route + a matching synthetic intent (chain, amount,
      ERC20-only `value`).
    * `swap.safety_gate_rejects_mainnet` — re-running the safety
      gate with `chain: "base"` rejects with the expected atom.
      Pins the post-MVP boundary so a future regression flipping
      mainnet on for the live swap path fails this check.
    * `swap.safety_gate_rejects_stale_route` — a route whose
      `deadline` is in the past rejects with
      `:swap_deadline_expired`.
    * `swap.safety_gate_rejects_minimum_above_expected` — a route
      whose `minimum_output_amount > expected_output_amount`
      rejects with `:swap_amount_invalid`.
    * `swap.dispatch_envelope_shape` — the dispatch envelope built
      from the synthetic plan steps carries every field the
      adapter's `DispatchSwapSchema` (#192) consumes:
      `route_provider`, `swap_target_contract`, `spender`,
      `calldata`, `source_token_address`,
      `destination_token_address`, `minimum_output_amount`, `value`,
      `deadline`. Shape is asserted directly against
      `AdapterClient.build_swap_payload/1` (private; the smoke uses
      a structurally-equivalent reconstructor that mirrors the
      payload field-for-field).
    * `swap.secret_hygiene` — the constructed dispatch envelope
      inspects clean of provider secret markers (`Authorization`,
      `Bearer`, `sk_(live|test)_*`, `pk_(live|test)_*`,
      credentialed URLs, PEM blocks).
    * `swap.public_artifact_set` — the steps map carries the public
      artifact fields the audit/replay slice (#194) joins:
      `route_hash`, `route_provider`, `expected_output_amount`,
      `minimum_output_amount`, `slippage_bps`, `deadline`,
      `quote_timestamp`. None of the load-bearing-but-not-public
      fields (`calldata`, `spender`, `swap_target_contract`,
      `source_token_address`, `destination_token_address`,
      `value`) are required to surface to a reviewer.

  ## Side-effect contract

    * No `.env`, no `ADAPTER_*`, no `RPC_*`, no `TENDERLY_*`,
      no `BUNDLER_*` reads.
    * No `Bank.AdapterClient` HTTP. No `Bank.Quotes.LiveProvider`
      HTTP. No chain RPC.
    * No DB writes. No Oban enqueue.
    * No live broadcast. The smoke validates the Phoenix-side
      shape only — the live broadcast recipe lives in the runbook
      under the operator's `request_manual_execution` flow.
    * Idempotent. Pure `run/0` over an in-memory synthetic route.

  Returns `{:ok, report}` on PASS and `{:error, report}` on FAIL.
  The Mix task wrapper (`mix bank.swap.smoke`) exits 0/1 from this
  tuple.
  """

  alias Bank.Decisions.{SwapDispatchSafety, SwapRouteArtifacts}
  alias Bank.Intents.{AgentIntent, SwapRoute}

  # Base Sepolia testnet token addresses used by #192's adapter
  # fixture. Public-knowledge contract addresses; safe to hard-code.
  @usdc_sepolia "0x036CbD53842c5426634e7929541eC2318f3dCF7e"
  @zerox_router "0x0000000000001fF3684f28c67538d4D072C22734"
  @illustrative_calldata "0xdeadbeef"

  # Allowlist of secret-shaped patterns the dispatch envelope MUST
  # NOT match. Mirrors `Bank.Quotes.LiveProvider`'s allowlist
  # (#174 / #442 / #445) so the secret-hygiene contract is
  # consistent across the live-provider and dispatch surfaces.
  @secret_marker_patterns [
    ~r/Authorization\s*:\s*Bearer/i,
    ~r/Bearer\s+sk_/i,
    ~r/\bsk_(live|test)_/,
    ~r/\bpk_(live|test)_/,
    ~r{://[^\s/@]+:[^\s/@]+@},
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/
  ]

  @public_artifact_keys ~w(
    route_hash
    route_provider
    expected_output_amount
    minimum_output_amount
    slippage_bps
    deadline
    quote_timestamp
  )

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
    checks = run_checks()
    passed = Enum.count(checks, &(&1.status == :pass))
    total = length(checks)
    status = if passed == total, do: :pass, else: :fail
    report = %{status: status, checks: checks, passed: passed, total: total}

    case status do
      :pass -> {:ok, report}
      :fail -> {:error, report}
    end
  end

  defp run_checks do
    route = synthetic_route()
    intent = synthetic_intent(route)

    [
      check_route_validation(route),
      check_route_artifacts(route),
      check_route_round_trip(route),
      check_safety_gate_accepts(route, intent),
      check_safety_gate_rejects_mainnet(route, intent),
      check_safety_gate_rejects_stale_route(route, intent),
      check_safety_gate_rejects_minimum_above_expected(route, intent),
      check_dispatch_envelope_shape(route),
      check_secret_hygiene(route),
      check_public_artifact_set(route)
    ]
  end

  @doc """
  Synthetic Base Sepolia 0x USDC route used by every check.

  Deliberately USDC ↔ USDC so the route passes the default
  `SwapRoute` `:allowed_assets` cap (`["USDC"]`) without requiring
  any test-side cap override. The structural validation, hashing,
  safety-gate cross-checks, and dispatch-envelope construction all
  exercise end-to-end; the asset pair's economic meaningfulness is
  out of scope for a Phoenix-side shape smoke.

  Exposed for tests so the runbook drift suite can pin specific
  field values without re-deriving the synthetic route.
  """
  @spec synthetic_route() :: SwapRoute.t()
  def synthetic_route do
    now = DateTime.utc_now()

    %{
      source_asset: "USDC",
      source_token_address: @usdc_sepolia,
      destination_asset: "USDC",
      destination_token_address: @usdc_sepolia,
      input_amount: Decimal.new("1.0"),
      expected_output_amount: Decimal.new("0.99"),
      minimum_output_amount: Decimal.new("0.985"),
      spender: @zerox_router,
      swap_target_contract: @zerox_router,
      calldata: @illustrative_calldata,
      value: Decimal.new("0"),
      route_provider: "zerox",
      quote_timestamp: now,
      deadline: DateTime.add(now, 600, :second),
      chain: "base-sepolia",
      chain_id: 84_532,
      slippage_bps: 50
    }
  end

  defp synthetic_intent(route) do
    %AgentIntent{
      id: Ecto.UUID.generate(),
      chain: route.chain,
      kind: :swap,
      asset: route.source_asset,
      amount: route.input_amount,
      submitted_at: DateTime.utc_now()
    }
  end

  defp check_route_validation(route) do
    case SwapRoute.validate(route) do
      :ok ->
        pass(
          "swap.route_validation",
          "synthetic Base Sepolia USDC route passes SwapRoute.validate/2"
        )

      {:error, reason} ->
        fail(
          "swap.route_validation",
          "synthetic route rejected by SwapRoute.validate/2: #{inspect(reason)}"
        )
    end
  end

  defp check_route_artifacts(route) do
    artifacts = SwapRouteArtifacts.from_route(route)

    cond do
      not is_binary(artifacts.route_hash) or byte_size(artifacts.route_hash) < 32 ->
        fail(
          "swap.route_artifacts",
          "route_hash missing or too short: #{inspect(artifacts.route_hash)}"
        )

      not is_map(artifacts.steps) or Map.get(artifacts.steps, "kind") != "swap" ->
        fail(
          "swap.route_artifacts",
          "steps map missing kind=swap marker: #{inspect(artifacts.steps)}"
        )

      Map.get(artifacts.audit_metadata, :route_provider) != "zerox" ->
        fail(
          "swap.route_artifacts",
          "audit_metadata route_provider mismatch: #{inspect(artifacts.audit_metadata)}"
        )

      true ->
        pass(
          "swap.route_artifacts",
          "deterministic route_hash + JSON-friendly steps + audit_metadata produced"
        )
    end
  end

  defp check_route_round_trip(route) do
    %{steps: steps} = SwapRouteArtifacts.from_route(route)

    case SwapRouteArtifacts.route_from_steps(steps) do
      {:ok, recovered} ->
        if routes_equivalent?(route, recovered) do
          pass(
            "swap.route_round_trip",
            "from_route → route_from_steps preserves every load-bearing field"
          )
        else
          fail(
            "swap.route_round_trip",
            "round-trip drift: original=#{inspect(route)} recovered=#{inspect(recovered)}"
          )
        end

      {:error, reason} ->
        fail(
          "swap.route_round_trip",
          "route_from_steps refused the round-tripped steps: #{inspect(reason)}"
        )
    end
  end

  defp check_safety_gate_accepts(route, intent) do
    context = %{intent: intent, workspace_id: nil}

    case SwapDispatchSafety.validate(route, context) do
      :ok ->
        pass(
          "swap.safety_gate_accepts",
          "SwapDispatchSafety.validate/3 accepts the synthetic route + matching intent"
        )

      {:error, reason} ->
        fail(
          "swap.safety_gate_accepts",
          "safety gate rejected the synthetic route: #{inspect(reason)}"
        )
    end
  end

  defp check_safety_gate_rejects_mainnet(route, intent) do
    # Both route AND intent must claim mainnet — the safety gate
    # also enforces `route.chain == intent.chain`, so flipping only
    # the route would trip `:swap_chain_mismatch_with_intent`
    # before reaching the chain allowlist.
    mainnet_route = %{route | chain: "base", chain_id: 8453}
    mainnet_intent = %{intent | chain: "base"}
    context = %{intent: mainnet_intent, workspace_id: nil}

    case SwapDispatchSafety.validate(mainnet_route, context) do
      {:error, :swap_chain_not_supported} ->
        pass(
          "swap.safety_gate_rejects_mainnet",
          "safety gate rejects chain=\"base\" (mainnet) with :swap_chain_not_supported"
        )

      :ok ->
        fail(
          "swap.safety_gate_rejects_mainnet",
          "safety gate ACCEPTED mainnet route — MVP boundary regressed"
        )

      {:error, other} ->
        fail(
          "swap.safety_gate_rejects_mainnet",
          "safety gate rejected mainnet for the wrong reason: #{inspect(other)}"
        )
    end
  end

  defp check_safety_gate_rejects_stale_route(route, intent) do
    stale = %{route | deadline: DateTime.add(DateTime.utc_now(), -60, :second)}
    context = %{intent: intent, workspace_id: nil}

    case SwapDispatchSafety.validate(stale, context) do
      {:error, :swap_deadline_expired} ->
        pass(
          "swap.safety_gate_rejects_stale_route",
          "safety gate rejects past-deadline route with :swap_deadline_expired"
        )

      other ->
        fail(
          "swap.safety_gate_rejects_stale_route",
          "expected :swap_deadline_expired, got #{inspect(other)}"
        )
    end
  end

  defp check_safety_gate_rejects_minimum_above_expected(route, intent) do
    inverted = %{route | minimum_output_amount: Decimal.new("1.5")}
    context = %{intent: intent, workspace_id: nil}

    case SwapDispatchSafety.validate(inverted, context) do
      {:error, :swap_amount_invalid} ->
        pass(
          "swap.safety_gate_rejects_minimum_above_expected",
          "safety gate rejects min > expected with :swap_amount_invalid"
        )

      other ->
        fail(
          "swap.safety_gate_rejects_minimum_above_expected",
          "expected :swap_amount_invalid, got #{inspect(other)}"
        )
    end
  end

  defp check_dispatch_envelope_shape(route) do
    envelope = build_synthetic_dispatch_envelope(route)
    route_block = envelope.route

    required = [
      :route_provider,
      :swap_target_contract,
      :spender,
      :calldata,
      :source_token_address,
      :destination_token_address,
      :minimum_output_amount,
      :value,
      :deadline
    ]

    missing =
      Enum.reject(required, fn key ->
        case Map.get(route_block, key) do
          nil -> false
          "" -> false
          _ -> true
        end
      end)

    cond do
      missing != [] ->
        fail(
          "swap.dispatch_envelope_shape",
          "dispatch envelope missing route fields: #{inspect(missing)}"
        )

      envelope.action != "swap" ->
        fail(
          "swap.dispatch_envelope_shape",
          "dispatch envelope action != \"swap\": #{inspect(envelope.action)}"
        )

      envelope.chain != "base-sepolia" ->
        fail(
          "swap.dispatch_envelope_shape",
          "dispatch envelope chain != \"base-sepolia\": #{inspect(envelope.chain)}"
        )

      true ->
        pass(
          "swap.dispatch_envelope_shape",
          "envelope carries every #192 DispatchSwapSchema route field"
        )
    end
  end

  defp check_secret_hygiene(route) do
    blob = route |> build_synthetic_dispatch_envelope() |> inspect()
    leaked = Enum.find(@secret_marker_patterns, &Regex.match?(&1, blob))

    case leaked do
      nil ->
        pass(
          "swap.secret_hygiene",
          "dispatch envelope carries no Authorization/Bearer/sk_/pk_/credentialed-URL/PEM markers"
        )

      pattern ->
        fail(
          "swap.secret_hygiene",
          "dispatch envelope matched secret marker pattern #{inspect(pattern)}"
        )
    end
  end

  defp check_public_artifact_set(route) do
    %{steps: steps} = SwapRouteArtifacts.from_route(route)

    missing =
      Enum.reject(@public_artifact_keys, fn key ->
        case Map.get(steps, key) do
          nil -> false
          "" -> false
          _ -> true
        end
      end)

    case missing do
      [] ->
        pass(
          "swap.public_artifact_set",
          "steps carry every public audit/replay artifact (#194) — #{Enum.join(@public_artifact_keys, ", ")}"
        )

      keys ->
        fail(
          "swap.public_artifact_set",
          "steps missing public artifacts: #{inspect(keys)}"
        )
    end
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  # Decimals canonicalise across the round-trip (`"1.0"` becomes
  # `"1"`); compare by value, not by struct. Datetimes round-trip
  # to microsecond precision via `DateTime.to_iso8601/1`; tolerate
  # sub-second drift just in case.
  defp routes_equivalent?(a, b) do
    keys = Map.keys(a) ++ Map.keys(b)
    keys = Enum.uniq(keys)
    Enum.all?(keys, fn k -> values_equivalent?(Map.get(a, k), Map.get(b, k)) end)
  end

  defp values_equivalent?(%Decimal{} = a, %Decimal{} = b), do: Decimal.equal?(a, b)

  defp values_equivalent?(%DateTime{} = a, %DateTime{} = b),
    do: abs(DateTime.diff(a, b, :microsecond)) < 1_000_000

  defp values_equivalent?(a, b), do: a == b

  # Mirrors `Bank.AdapterClient.build_swap_payload/1` (the function
  # is private; this helper is structurally equivalent and pinned by
  # the dispatch_envelope_shape check). Drift between the two is
  # caught by the runbook drift tests, which read both files and
  # assert their field sets agree.
  defp build_synthetic_dispatch_envelope(route) do
    %{steps: steps} = SwapRouteArtifacts.from_route(route)
    plan_id = Ecto.UUID.generate()
    intent_id = Ecto.UUID.generate()

    %{
      contract_version: 1,
      action: "swap",
      execution_plan_id: plan_id,
      intent_id: intent_id,
      smart_account_id: "sa_swap_smoke",
      chain: route.chain,
      input_asset: Map.get(steps, "source_asset"),
      output_asset: Map.get(steps, "destination_asset"),
      input_amount: Map.get(steps, "input_amount"),
      expected_output: Map.get(steps, "expected_output_amount"),
      slippage_bps: Map.get(steps, "slippage_bps"),
      route: %{
        venue: Map.get(steps, "route_provider"),
        path: [
          Map.get(steps, "source_asset"),
          Map.get(steps, "destination_asset")
        ],
        route_provider: Map.get(steps, "route_provider"),
        swap_target_contract: Map.get(steps, "swap_target_contract"),
        spender: Map.get(steps, "spender"),
        calldata: Map.get(steps, "calldata"),
        source_token_address: Map.get(steps, "source_token_address"),
        destination_token_address: Map.get(steps, "destination_token_address"),
        minimum_output_amount: Map.get(steps, "minimum_output_amount"),
        value: Map.get(steps, "value"),
        deadline: Map.get(steps, "deadline")
      },
      signing_requirements: %{
        delegation_id: "del_smoke",
        scope: %{}
      },
      correlation_id: intent_id,
      emitted_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp pass(name, detail), do: %{name: name, status: :pass, detail: detail}
  defp fail(name, detail), do: %{name: name, status: :fail, detail: detail}
end
