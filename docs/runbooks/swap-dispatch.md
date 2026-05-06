# MVP 0x swap dispatch on Base Sepolia

> Status: ships with #196 (`mix bank.swap.smoke` + this runbook).
> Sits on top of #190 / #192 / #193 / #194 / #195. Live execution is
> Base Sepolia + 0x router only. Mainnet is post-MVP.

This runbook covers the three operator surfaces around the MVP 0x
swap dispatch path:

  1. **Quote-only** — read-only `Bank.Quotes.preview/2` against the
     stub or live provider; never broadcasts.
  2. **Dry-run** — `mix bank.swap.smoke` validates the entire
     Phoenix-side dispatch surface against an in-memory route. No
     chain RPC, no adapter HTTP, no broadcast.
  3. **Live broadcast** — operator-confirmed Base Sepolia broadcast
     via the existing `request_manual_execution` flow. Documented
     here as a manual procedure with explicit `--confirm`-style
     consent on the operator's request.

## Hard safety boundaries (MVP)

  * **Chain:** Base Sepolia only. `chain: "base"` (mainnet) is
    rejected closed at three independent layers (#192 P2):
    `Bank.Decisions.SwapDispatchSafety.validate/3`, the adapter's
    `isSupportedSwapChain/1`, and the deployment's `BASE_CHAIN_ID`
    env contract.
  * **Live router:** 0x only. `route.route_provider` ∈
    `["zerox", "0x"]`. Other route providers are quote/planning
    only — see "Quote / planning only" below.
  * **Swap type:** exact-input only. No exact-output, no
    multi-hop-with-on-chain-quote.
  * **Asset pairs:** USDC ↔ USDT, USDC ↔ ETH (MVP). Other pairs
    fail the `Bank.Intents.SwapRoute` `:allowed_assets` cap.
  * **No arbitrary token support.** Token addresses are
    operator-supplied at the `SwapRoute` boundary and are
    cross-checked at three layers (route validator, safety gate,
    adapter dispatch envelope shape).
  * **No guaranteed testnet liquidity.** The 0x router on Base
    Sepolia may return `INSUFFICIENT_OUTPUT_AMOUNT` revert reasons
    on tight-liquidity pairs — the safety gate is shape-only and
    cannot predict on-chain liquidity. Operators verify against
    the testnet pool depth before broadcast.
  * **Quote / planning only:** 1inch, CCTP, and Jupiter providers
    surface preview / planning data only. Live execution flows
    through the 0x route on Base Sepolia.
  * **Mainnet, real funds, agent-initiated mainnet swap:**
    POST-MVP.

## Quote-only path

Pure read-only. Use this to inspect what the provider would return
without producing any plan or audit row:

```elixir
intent = %Bank.Intents.AgentIntent{
  id: Ecto.UUID.generate(),
  chain: "base-sepolia",
  kind: :swap,
  asset: "USDC",
  amount: Decimal.new("1.0"),
  submitted_at: DateTime.utc_now()
}

# Stub provider — deterministic, no network.
{:ok, preview} = Bank.Quotes.preview(intent, provider: :stub)

# Live provider — real Tenderly call (requires staging env wiring).
{:ok, preview} = Bank.Quotes.preview(intent, provider: :live)
```

`mix bank.quotes.smoke` covers the same surface end-to-end (#177).
`/v1/health/deep` exposes the per-provider health rollup under the
`quotes_provider` block (#176).

## Dry-run smoke

Validates the entire Phoenix-side swap dispatch surface against an
in-memory synthetic Base Sepolia USDC route. No chain RPC, no
adapter HTTP, no broadcast. Idempotent.

```sh
mix bank.swap.smoke
```

Expected output:

```text
Bank MVP 0x swap dispatch smoke

  PASS swap.route_validation — synthetic Base Sepolia USDC route passes SwapRoute.validate/2
  PASS swap.route_artifacts — deterministic route_hash + JSON-friendly steps + audit_metadata produced
  PASS swap.route_round_trip — from_route → route_from_steps preserves every load-bearing field
  PASS swap.safety_gate_accepts — SwapDispatchSafety.validate/3 accepts the synthetic route + matching intent
  PASS swap.safety_gate_rejects_mainnet — safety gate rejects chain="base" (mainnet) with :swap_chain_not_supported
  PASS swap.safety_gate_rejects_stale_route — safety gate rejects past-deadline route with :swap_deadline_expired
  PASS swap.safety_gate_rejects_minimum_above_expected — safety gate rejects min > expected with :swap_amount_invalid
  PASS swap.dispatch_envelope_shape — envelope carries every #192 DispatchSwapSchema route field
  PASS swap.secret_hygiene — dispatch envelope carries no Authorization/Bearer/sk_/pk_/credentialed-URL/PEM markers
  PASS swap.public_artifact_set — steps carry every public audit/replay artifact (#194) — route_hash, route_provider, expected_output_amount, minimum_output_amount, slippage_bps, deadline, quote_timestamp

10 / 10 PASS
Phoenix-side shape only. No chain RPC, no adapter HTTP, no broadcast.
```

Exit code is 0 on PASS, 1 on FAIL — CI can read the exit status
without parsing stdout. The smoke is the dry-run guard you run
before any live broadcast attempt.

## Live broadcast (operator-confirmed)

Live broadcast on Base Sepolia is operator-driven through the
existing `Bank.Decisions.request_manual_execution/3` flow. Explicit
operator consent rides on the request itself — there is no Mix
task that broadcasts directly. This avoids accidental invocation
from CI or a misclick.

### Pre-flight checklist

Before broadcasting:

  1. **Phoenix-side env present** (presence-check only; values
     never printed):
     - `Bank.AdapterClient :base_url`
     - `Bank.AdapterClient :dispatch_secret`
     - `Bank.AdapterClient :callback_secret`
  2. **TS chain_adapter is running** and configured for Base
     Sepolia:
     - `BASE_CHAIN_ID = 84532`
     - `BASE_RPC_URL` and `BUNDLER_RPC_URL` set
     - Smart account funded with USDC and ETH for gas
     - The adapter's `isSupportedSwapChain/1` accepts `"base-sepolia"`
       only (#192 P2 — mainnet rejected closed)
  3. **Quote provider configured** so the autonomy decision
     pipeline can produce a `SimulationReport` whose
     `routing_path` carries the full `SwapRoute` shape (#190).
     `mix bank.quotes.smoke` is the pre-flight for this.
  4. **`mix bank.swap.smoke` reports 10 / 10 PASS** locally — this
     is the Phoenix-side shape gate.
  5. **Workspace pause state is `:running`**. Pause (kill switch)
     is the rollback path; see "Kill switch / rollback" below.

### Broadcast steps

  1. Submit a swap intent (operator UI or `Bank.Intents.submit/2`):

     ```elixir
     {:ok, %{intent: intent}} =
       Bank.Intents.submit(
         %{
           "agent_id" => "swap-smoke-agent",
           "source" => "operator",
           "idempotency_key" => "swap-smoke-#{System.unique_integer([:positive])}",
           "kind" => "swap",
           "asset" => "USDC",
           "chain" => "base-sepolia",
           "amount" => "1",
           "target" => %{"raw_address" => "<router or counterparty>"}
         },
         workspace_id: workspace_id
       )
     ```

  2. Evaluate the intent. The decision pipeline calls the
     configured quote provider; the resulting `SimulationReport`'s
     `routing_path` becomes the `SwapRoute` map persisted on the
     plan steps (via `Bank.Decisions.SwapRouteArtifacts.from_route/1`).

     ```elixir
     {:ok, %{decision: envelope}} = Bank.Decisions.evaluate_intent(intent)
     ```

  3. If the decision outcome is `:approval_required`, record
     operator approval:

     ```elixir
     {:ok, approved, _} =
       Bank.Decisions.approve(envelope.id,
         actor_id: operator_user_id,
         reason: "swap_smoke_broadcast"
       )
     ```

  4. Create the execution plan. The `request_manual_execution/3`
     call is the explicit operator consent for the broadcast.

     ```elixir
     {:ok, plan} =
       Bank.Decisions.request_manual_execution(approved.id, smart_account_id,
         reason: "swap_smoke_broadcast"
       )
     ```

  5. Run the dispatch worker. `Bank.Runtime.Workers.RunExecution`
     loads the plan, re-runs the safety gate
     (`Bank.Decisions.SwapDispatchSafety.validate/3`), and calls
     `Bank.AdapterClient.dispatch_swap/2`.

  6. Wait for the adapter callback. The TS adapter broadcasts the
     UserOperation via the configured bundler, then posts back via
     `POST /internal/adapter/callback` with the on-chain receipt.

### Public artifacts to capture

On a successful broadcast, capture these from the plan + audit
trail (none of them are secrets — they are explicitly safe to
share in deployment logs):

  * `intent_id` — the swap intent UUID.
  * `decision_id` — the decision envelope UUID.
  * `plan_id` — the execution plan UUID.
  * `route_hash` — SHA256 of the canonical route fields
    (#190; `Bank.Decisions.SwapRouteArtifacts.route_hash/1`).
  * `route_provider` — `"zerox"` for the MVP.
  * `expected_output_amount`, `minimum_output_amount`,
    `slippage_bps` — the route's exact-input contract.
  * `actual_output_amount` — written by the adapter callback when
    the on-chain receipt lands.
  * `tx_refs` — the userop hash + on-chain transaction hash array
    on `ExecutionPlan.tx_refs`.
  * `block_number` — the on-chain block the swap landed in.

`Bank.Audit.replay/1` joins these under the `swap_route_evidence`
slice (#194). The `simulation` payload on the simulate endpoint
also surfaces the active provider via `provider` /
`provider_trace_ref` (#175).

### Failure modes

  * `:swap_chain_not_supported` — chain isn't in the
    `:allowed_chains` allowlist. Default is `["base-sepolia"]`.
  * `:swap_chain_id_mismatch` — `chain` and `chain_id` disagree.
  * `:swap_chain_mismatch_with_intent` — route.chain ≠ intent.chain.
  * `:swap_asset_not_supported` — asset outside the
    `:allowed_assets` cap.
  * `:swap_amount_mismatch_with_intent` — route.input_amount ≠
    intent.amount.
  * `:swap_amount_invalid` — non-positive amount, or
    minimum > expected.
  * `:swap_slippage_exceeded` — slippage above the cap (default
    100 bps = 1.00%).
  * `:swap_deadline_expired` — quote past its `deadline` at
    broadcast time.
  * `:swap_native_value_disallowed` — `route.value ≠ 0` (v0.1 is
    ERC20 → ERC20 only).
  * `:runtime_paused` / `:chain_paused` — pause gate is active.
  * `:mainnet_disabled` — the workspace doesn't have mainnet
    capability (and won't until post-MVP).
  * Adapter-side: `bundler_rejected:`, `bundler_hash_mismatch:`,
    `confirmation_failed:`, `swap_route_incomplete:`,
    `unsupported_provider:`, `unsupported_input_asset:`,
    `unsupported_output_asset:`, `native_input_not_implemented`,
    `stale_route`, `non_zero_value_with_erc20_input`,
    `chain_clients_unavailable`. See the adapter's
    `chain_adapter/src/chains/base/swap.ts` for the canonical
    allowlist.

## Kill switch / rollback

  * **Pause the workspace** (operator surface):
    `Bank.Security.PauseState` records the active pause for a
    workspace + chain. Once paused, `SwapDispatchSafety` rejects
    every new swap with `:chain_paused` (or `:runtime_paused` for
    a global pause). In-flight `RunExecution` workers checking
    the gate before adapter dispatch fail closed. Already-
    broadcast UserOps continue settling on chain — pause does NOT
    cancel mempool entries.
  * **Rollback an in-flight plan**: there is no "unbroadcast"
    primitive. If a UserOp is already in the bundler's mempool,
    the recovery path is operator-driven: wait for the receipt,
    then act on the on-chain outcome. The runtime path is
    fail-closed — a paused workspace cannot dispatch new swaps,
    but cannot retract a broadcast UserOp.
  * **Mainnet is rejected closed at every layer.** Even with
    pause off and adapter env set, `chain: "base"` swap dispatch
    fails with `:swap_chain_not_supported`. Re-enabling mainnet
    is a post-MVP product decision, not an operator runtime
    toggle.

## Quote / planning only

The following providers/flows produce preview metadata only — they
do NOT broadcast in the v0.1 MVP:

  * **1inch** — quote/planning only. Live swap execution is via
    the 0x router on Base Sepolia.
  * **CCTP (Cross-Chain Transfer Protocol)** — quote/planning
    only. There is no live cross-chain bridge execution in the
    MVP.
  * **Jupiter** — quote/planning only. Solana execution is
    out of scope; Base Sepolia is the only live chain.

The simulate endpoint (`POST /v1/intents/:id/simulate`) returns
the configured provider's preview but does not enqueue a dispatch.
The dispatch path is reachable only via
`request_manual_execution/3` once the decision pipeline has
produced a plan with a 0x route artifact.

## Limitations recap

  * Base Sepolia only. No live mainnet.
  * 0x router only for live swap execution.
  * USDC ↔ USDT and USDC ↔ ETH MVP pairs only.
  * Exact-input only.
  * No arbitrary token support — tokens are operator-supplied at
    the route boundary and cross-checked at every layer.
  * No guaranteed testnet liquidity — operators verify pool depth
    before broadcast.
  * 1inch / CCTP / Jupiter are quote/planning only.
  * No automatic broadcast retries — `Bank.Quotes.LiveProvider`
    is configured `retry: false`; re-simulation is operator- or
    autonomy-driven via `simulate(reason: "refresh")`.
  * Pause stops new dispatches but cannot retract a broadcast
    UserOp.
