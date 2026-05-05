defmodule Bank.Decisions.SwapDispatchSafety do
  @moduledoc """
  Centralized swap dispatch safety gate (#191).

  Single entry point for "is this swap safe to dispatch?". Composes
  the route-shape contract (`Bank.Intents.SwapRoute.validate/2`,
  #189), workspace/chain capability gates already exposed by
  `Bank.Chains` and `Bank.Security`, and the swap-specific
  cross-checks not covered elsewhere.

  Returns `:ok` or `{:error, failure()}`. The atom vocabulary is
  fixed and fail-closed — any unknown shape returns the most
  specific atom we can attribute, never `true` or `:ok`.

  ## Why a single function

  Without this module, every swap dispatch path (plan creation,
  future dispatch worker, future API replay) would have to call
  `SwapRoute.validate/2` *and* the universal pause/mainnet gates
  *and* the route↔intent consistency checks separately. Inevitably
  one of them drifts and an unsafe route gets through. Centralising
  here means there is exactly one function that answers "may this
  route be dispatched?" — drift surfaces as a failing test in this
  module's suite, not as a missed gate in some controller.

  ## Failure-mode atoms

  Delegated atoms from `Bank.Intents.SwapRoute.validate/2`:

    * `:swap_chain_not_supported` / `:swap_chain_id_mismatch` /
      `:swap_asset_not_supported` / `:swap_route_field_missing` /
      `:swap_amount_invalid` / `:swap_slippage_exceeded` /
      `:swap_deadline_expired`

  New atoms owned by this module:

    * `:swap_chain_mismatch_with_intent` — the route's `:chain`
      disagrees with the parent intent's `:chain`. Fail closed so
      a swap intent recorded against base-sepolia can never
      dispatch a route on ethereum.
    * `:swap_amount_mismatch_with_intent` — the route's
      `:input_amount` disagrees with the parent intent's `:amount`
      after canonical decimal normalisation. Prevents an operator
      replaying a route built for a different intent amount.
    * `:swap_native_value_disallowed` — v0.1 swaps are
      ERC20→ERC20 (USDC↔USDC); the route's `:value` (native ETH
      attached to the call) must be zero. Sending native value to
      a router for an ERC20 swap is almost always either a
      misconfigured route or a phishing attempt.

  Universal-gate atoms re-exported (callers may already know these
  but the centralized gate normalises them so a swap caller does
  not have to remember to invoke pause / mainnet separately):

    * `:runtime_paused` — `Bank.Security.paused?(:global)` is true.
    * `:chain_paused` — `Bank.Security.paused?(workspace_id,
      {:chain, route.chain})` is true.
    * `:mainnet_disabled` — workspace mainnet capability gate
      (`Bank.Chains.validate_mainnet_allowed/2`) refused.

  ## Deferred gates

  Acceptance criteria from #191 that depend on data not yet on
  `origin/main` are intentionally NOT faked here. Each is a single
  function call away once the dependency lands; a placeholder is
  worse than an explicit gap.

    * **Smart account ↔ workspace + chain** — depends on #183
      (`Bank.SmartAccounts` schema). Today the runtime resolves the
      executable account through `Bank.Delegations`, which carries
      no `chain` or `workspace_id` link strong enough to enforce
      this gate. A follow-up issue tracks wiring once #183 merges.
    * **Spender / target contract allowlist** — depends on a
      registry that does not exist in v0.1 (see `SwapRoute`
      moduledoc). The route validator accepts operator-supplied
      addresses; a future asset-address registry will resolve and
      re-validate them.
    * **Per-day / cumulative caps** — explicitly out of scope for
      v0.1 (cross-broadcast persistent state).

  ## Test injection

  `validate/3` accepts the same `:caps` and `:now` keyword opts as
  `SwapRoute.validate/2` and forwards them transparently. Tests
  pass these to keep the gate deterministic without mutating
  global `Application` state.
  """

  alias Bank.Chains
  alias Bank.Intents.{AgentIntent, SwapRoute}
  alias Bank.Security

  @type context :: %{
          required(:intent) => AgentIntent.t(),
          required(:workspace_id) => String.t() | nil
        }

  @type failure ::
          SwapRoute.failure()
          | :swap_chain_mismatch_with_intent
          | :swap_amount_mismatch_with_intent
          | :swap_native_value_disallowed
          | :runtime_paused
          | :chain_paused
          | :mainnet_disabled

  @doc """
  Validate `route` for dispatch in the given `context`.

  The check order is intentional: route shape first (so amount/chain
  cross-checks are defended by the structural gate), then route ↔
  intent cross-checks (cheap, no I/O), then universal pause/mainnet
  gates last (single DB read for chain pauses).

  Returns `:ok` or `{:error, failure()}`.
  """
  @spec validate(map(), context(), keyword()) :: :ok | {:error, failure()}
  def validate(route, context, opts \\ [])

  def validate(route, %{intent: %AgentIntent{} = intent, workspace_id: workspace_id}, opts)
      when is_map(route) do
    with :ok <- SwapRoute.validate(route, swap_route_opts(opts)),
         :ok <- validate_chain_matches_intent(route, intent),
         :ok <- validate_amount_matches_intent(route, intent),
         :ok <- validate_native_value(route),
         :ok <- validate_workspace_not_paused(workspace_id, route.chain),
         :ok <- Chains.validate_mainnet_allowed(route.chain, workspace_id) do
      :ok
    end
  end

  # Defensive clause: a non-map route shape is rejected by the
  # structural gate inside `SwapRoute.validate/2`, but if a caller
  # constructs a context without an `AgentIntent` we surface that
  # as a route field-missing failure rather than crashing — the
  # module is supposed to be fail-closed.
  def validate(_route, _context, _opts), do: {:error, :swap_route_field_missing}

  # ---------------------------------------------------------------------------
  # Route ↔ intent cross-checks
  # ---------------------------------------------------------------------------

  defp validate_chain_matches_intent(%{chain: route_chain}, %AgentIntent{chain: intent_chain})
       when is_binary(route_chain) and is_binary(intent_chain) do
    if route_chain == intent_chain,
      do: :ok,
      else: {:error, :swap_chain_mismatch_with_intent}
  end

  defp validate_chain_matches_intent(_route, _intent),
    do: {:error, :swap_chain_mismatch_with_intent}

  defp validate_amount_matches_intent(
         %{input_amount: %Decimal{} = input},
         %AgentIntent{amount: %Decimal{} = intent_amount}
       ) do
    if Decimal.equal?(input, intent_amount),
      do: :ok,
      else: {:error, :swap_amount_mismatch_with_intent}
  end

  # If the intent has no amount (legacy / unscoped intents), or the
  # route's `input_amount` is not a Decimal, the structural gate
  # would have already rejected — but fail closed defensively.
  defp validate_amount_matches_intent(_route, _intent),
    do: {:error, :swap_amount_mismatch_with_intent}

  # v0.1 swaps are ERC20→ERC20. Native value on the call would
  # mean either a wrong route shape (router expects msg.value=0
  # for token swaps) or an exploit (e.g., routing native ETH to
  # an attacker-controlled spender). Fail closed.
  defp validate_native_value(%{value: %Decimal{} = value}) do
    if Decimal.equal?(value, Decimal.new(0)),
      do: :ok,
      else: {:error, :swap_native_value_disallowed}
  end

  defp validate_native_value(_route), do: {:error, :swap_native_value_disallowed}

  # ---------------------------------------------------------------------------
  # Universal gates (pause + mainnet) — re-exported so swap callers
  # have a single function to call.
  # ---------------------------------------------------------------------------

  defp validate_workspace_not_paused(workspace_id, chain) when is_binary(chain) do
    cond do
      Security.paused?(:global) ->
        {:error, :runtime_paused}

      is_binary(workspace_id) and Security.paused?(workspace_id, {:chain, chain}) ->
        {:error, :chain_paused}

      true ->
        :ok
    end
  end

  defp swap_route_opts(opts) do
    Enum.flat_map(opts, fn
      {:caps, caps} -> [caps: caps]
      {:now, now} -> [now: now]
      _ -> []
    end)
  end
end
