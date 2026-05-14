# Base mainnet fork proof — 0x swap path

**Goal:** prove the adapter's 0x swap execution path works against
real Base mainnet contracts (USDC, USDT, the 0x router, EntryPoint
v0.7) with real 0x quote calldata, **without** broadcasting to public
Base mainnet and **without** risking real funds.

This is a fork proof, **not** a real mainnet canary. It uses:

* a local Anvil fork of Base mainnet (chain id 8453),
* real Base mainnet contract bytecode/state copied lazily by the fork,
* real 0x v2 `/swap/permit2/quote` calldata,
* a test private key whose only role is signing the v0.7
  UserOperation hash on the fork,
* `EntryPoint.handleOps` simulated via `eth_call` (no commit).

What it does **not** prove:

* `eth_sendUserOperation` against a real bundler (anvil isn't a
  fork-aware bundler — that hop is post-milestone).
* Phoenix's `AgentLive` flow on Base mainnet (the LiveView still
  pins `chain: "base-sepolia"` for safety; promoting it is an
  operator-gated change that follows this proof).

---

## Phase A — Prerequisites

| Tool                  | Install                                                                   |
|-----------------------|---------------------------------------------------------------------------|
| Node ≥ 22             | already in repo                                                           |
| Foundry (anvil)       | `curl -L https://foundry.paradigm.xyz \| bash` then `foundryup`           |
| Base mainnet RPC URL  | e.g. Alchemy, Quicknode, Infura — needed only as the **fork upstream**    |
| `ZEROX_API_KEY`       | free key from <https://0x.org/docs/api>                                   |

`anvil --version` should print after `foundryup`. The fork won't
broadcast anything to the upstream RPC — anvil reads from it on
demand to materialise touched state. You can use any read-capable
endpoint.

---

## Phase B — Start the fork

```bash
anvil \
  --fork-url $BASE_MAINNET_RPC_URL \
  --chain-id 8453 \
  --port 8545 \
  --block-time 2
```

Notes:

* `--chain-id 8453` matches Base mainnet's id so the EIP-712 / v0.7
  UserOp preimages hash correctly.
* `--block-time 2` matches Base's block time so any `block.timestamp`
  arithmetic the 0x router does on-chain behaves naturally.
* The fork captures state at the latest upstream block; EntryPoint
  v0.7, USDC, USDT, and the 0x router are all live on Base mainnet
  today so their state is available.

Keep this terminal open. The fork lives in process memory.

---

## Phase C — Provision a smart account on the fork

The fork doesn't carry an account you control — the script needs a
deployed Kernel whose session validator was bound to the delegation
signer it will use.

Easiest path: run the existing `provision-kernel.ts` script against
the fork:

```bash
# In a second terminal:
cd chain_adapter

export BASE_RPC_URL=http://localhost:8545
export BASE_CHAIN_ID=8453
export BUNDLER_RPC_URL=http://localhost:8545
export DELEGATION_SIGNER_KEY=0x$(openssl rand -hex 32)  # FORK-ONLY test key
export OPERATOR_PRIVATE_KEY=0x$(openssl rand -hex 32)   # FORK-ONLY test key
# Make sure the two derived addresses differ — provision-kernel enforces this.

npx tsx scripts/provision-kernel.ts
```

The script prints the deployed kernel address. Save it:

```bash
export FORK_SMART_ACCOUNT_ADDRESS=0x...   # from provision-kernel output
export FORK_DELEGATION_SIGNER_KEY=$DELEGATION_SIGNER_KEY
export FORK_BASE_RPC_URL=http://localhost:8545
export ZEROX_API_KEY=<your key>
```

> **Refusal rule.** The fork-proof script refuses to run if the RPC
> doesn't expose the `anvil_metadata` cheat. This is the guard that
> stops a typo-ed `FORK_BASE_RPC_URL=https://mainnet.base.org` from
> turning the proof into a real broadcast.

---

## Phase D — Run the fork proof

```bash
cd chain_adapter
npx tsx scripts/fork-proof-swap.ts
```

Expected output (eight numbered steps, each ending in `✓`):

```text
--- Base mainnet fork proof ----------------------------------------
  RPC:                 http://localhost:8545
  smart account:       0x...
  delegation signer:   0x...
  swap:                10 USDC → USDT @ 50bps slippage
  fork tooling:        anvil (Base mainnet upstream, chain id 8453)
  NO public mainnet broadcast — fork-only proof.

[1/8] verifying anvil fork
  ✓ chain id == 8453, anvil cheats available, EntryPoint v0.7 deployed
[2/8] verifying smart account deployed on fork
  ✓ smart account bytecode present
[3/8] funding smart account on fork
  ✓ ETH balance set to 1 ETH
  ✓ USDC funded via whale impersonation: whale=0x... new balance=20000000
[4/8] fetching real 0x v2 quote on Base mainnet contracts
  ✓ quote received: target=0x... calldata=0xfae353fe…2c20 (len=842) ...
[5/8] converting quote → DispatchSwap envelope
  ✓ conversion clean (no synthetic calldata; real spender + target)
[6/8] running DispatchSwapSchema.parse (adapter contract gate)
  ✓ envelope passes adapter schema
[7/8] building approve+swap executeBatch calldata (production path)
  ✓ executeBatch calldata built: 0xe9ae5c53…0000 (len=1284)
[8/8] signing UserOp + simulating EntryPoint dispatch on fork
  ✓ UserOp signed: userOpHash=0x...
  ✓ EntryPoint.handleOps simulation returned without revert: result=0x
  ✓ post-simulation balance delta (simulated; not committed): USDT_before=0 USDT_after=0 delta=0

--- PROOF COMPLETE ---
Real 0x quote calldata, real Base mainnet contracts, fork-only execution.
No public mainnet broadcast occurred.
```

> **Why `delta=0`?** Step 8 simulates via `eth_call` which does **not**
> commit state. If you want to see committed balance changes, replace
> the `eth_call` with an actual `sendTransaction` from the
> impersonated beneficiary — but then the change is committed to
> the fork (still local, still safe). The simulation path is
> intentionally non-committing so the proof is idempotent.

---

## Phase E — Failure modes

| Failure                                                            | Likely cause                                                             | Action |
|---|---|---|
| `Refusing to run: RPC chain id is N, expected 8453`                | `FORK_BASE_RPC_URL` points somewhere other than the local anvil fork    | Restart anvil with `--chain-id 8453` |
| `Refusing to run: RPC does not expose anvil_metadata cheat`        | `FORK_BASE_RPC_URL` is a public RPC, not anvil                          | Point at your local anvil. **This is a safety guard.** |
| `EntryPoint v0.7 has no bytecode on the fork`                      | fork pinned at a block before EntryPoint deployment                     | Drop `--fork-block-number`, fork at latest |
| `Smart account ... has no bytecode on the fork`                    | Kernel wasn't provisioned on this fork                                  | Re-run Phase C in the same anvil session |
| `Could not fund recipient: no configured whale had enough USDC`    | The hard-coded whales drifted                                            | Pass `--whale 0x...` (any Base USDC holder) — TODO: CLI flag |
| `0x quote request failed: HTTP 401`                                | bad/missing `ZEROX_API_KEY`                                              | Re-export the key |
| `0x quote request failed: HTTP 422 INSUFFICIENT_ASSET_LIQUIDITY`   | 0x can't quote your pair right now                                       | Try a different stablecoin pair or wait |
| `EntryPoint.handleOps simulation reverted`                         | gas limits too low, signature mismatch, or token allowance issue        | Bump gas limits; verify the kernel's session validator binds to `FORK_DELEGATION_SIGNER_KEY` |

---

## Phase F — Safety invariants

These should hold **every time** the script runs:

1. The script aborts before any cheat call if `anvil_metadata` fails.
2. `BASE_CHAIN_ID` in the adapter's `.env` is untouched — the proof
   reads only its own `FORK_*` env vars.
3. Phoenix's `lib/bank_web/live/agent_live.ex` still pins
   `chain: "base-sepolia"` (the LiveView is **not** wired to
   mainnet by this proof).
4. The HTTP `POST /dispatch/swap` path (`handleSwapDispatch`) still
   rejects `chain: "base"` with `unsupported_swap_chain`
   (`chain_adapter/src/config/chains.ts:isSupportedSwapChain`). The
   proof bypasses this HTTP guard by importing `executeSwap`'s
   helpers directly, **not** by relaxing the allowlist.
5. The synthetic `"0xdeadbeef"` calldata is rejected at two
   independent layers: `quoteToDispatch()` (converter) and
   `Bank.Decisions.SwapRouteResolver` (Phoenix). Neither has been
   relaxed.

---

## Phase G — What remains before a real Base mainnet canary

1. **Bundler integration.** Wire a fork-aware bundler (Pimlico
   `permissionless` library or a custom shim) so step 8 exercises
   `eth_sendUserOperation` instead of `eth_call`.
2. **Phoenix flow on Base.** Add an explicit operator gate (e.g. a
   feature flag + audit event) before allowing `AgentLive` to submit
   swap intents with `chain: "base"`. The current swap-mode test
   intent is `base-sepolia`-only by design.
3. **Adapter HTTP swap allowlist.** Promote `"base"` from
   `isSupportedSwapChain`'s rejection list only after (1) and (2) are
   green, **and** the operator can demonstrate a tiny-value (e.g.
   1 USDC) canary on Base mainnet with paused-by-default semantics.
4. **Smart account model.** Decide whether the production Kernel is
   per-user (preferred) or operator-shared, and how
   `smart_account_address` is stamped on `Bank.Delegations.scope`
   so the Phoenix resolver uses the correct 0x `taker`.
5. **Token registry status.** USDT on Base is `status: :approval_only`
   in `Bank.Stablecoins.Registry`; the canary should either flip it
   to `:active` (requires bridge-provenance review) or restrict the
   first canary to USDC↔USDC bridge pairs only.

---

## Known caveat

`mix precommit` may fail at `mix deps.audit` because the current
HEAD pins Phoenix 1.8.5 with a known advisory patched in 1.8.6. The
fork proof itself is unaffected.
