# Salvage report — `codex/swap-mvp-wip-snapshot`

**Generated:** 2026-05-14 (post-closure-commit `066cd76`)
**Mode:** Read-only analysis. No working-tree modifications.

---

## 1. Status snapshot

| Side | Tip | Commits since merge-base | Note |
|------|------|---------------------------|------|
| `main` | `066cd76 Finalize policy gates, executable swap proof, and Test Intent flow` | 2 (this turn) | Includes today's `8ce0086` Path A browser install + `066cd76` closure bundle. |
| `codex/swap-mvp-wip-snapshot` | `d937b87 WIP snapshot: swap MVP, browser install, ZeroDev runtime` | 1 | 3-day-old single-commit snapshot. |
| Merge base | `aeae0a8 Wire shared wallet provider registry into install flow + bundler URL` | — | The shared starting point. |

**Files touched by the snapshot vs merge-base: 145.**
Of these: **52 are A-only** (truly missing in main — clean cherry-pick candidates with zero conflict risk), **~90 are M-only** (parallel divergence with main — high conflict risk, direct cherry-pick will fight today's commits).

> **Do not** `git cherry-pick d937b87` whole. The user previously confirmed 73 merge-tree problem spots; that's the M-file divergence, not the A-file additions.

---

## 2. The Path A / Path B context (important for triage)

The closure-bundle commit `066cd76` and the prior `8ce0086` ("Path A browser install: end-to-end working on Base Sepolia") implement browser-mediated ZeroDev session-permission install **a different way** than this snapshot did.

| Concern | What main has today | What the snapshot has |
|---|---|---|
| Browser install glue | `assets/js/hooks/install_zerodev_client.js` + `install_envelope_client.js` calling `signerToEcdsaValidator` against viem walletClient | The same hook files (M), **plus** an adapter-side dispatch path: `chain_adapter/src/dispatch/browser_install.ts`, `src/chains/base/browser_install.ts`, `src/chains/base/permission_account.ts` |
| Adapter session signer | `chain_adapter/src/install/session_signer.ts` (NEW in `8ce0086`) | None |
| E2E simulator | `chain_adapter/scripts/install-e2e-simulator.ts` (NEW in `8ce0086`) | `sim-adapter-mediated-install.mjs` (703 LOC), `sim-browser-install.mjs` (618 LOC), `sim-runtime-userop.mjs` (500 LOC) — three older simulators |
| Mix task surface | `mix bank.browser_install.e2e`, `mix bank.browser_install.smoke` | Same task names exist on M side but diverge |

**Conclusion:** the snapshot's browser-install path is a parallel/earlier exploration. Path A in main is the surviving design. → see §6.

---

## 3. High-value cherry-pick targets (A-only, no main analogue)

Categories are roughly self-contained. Each category lists **all** files that need to travel together to make sense.

### 3.1 — Stablecoins ProviderRegistry + Odos + RoutePolicy executable gate

**Why valuable:** introduces a single source of truth for stablecoin route providers, splits the ZeroX/1inch/Odos route-quote vs execute gate, and pins the Phoenix↔adapter executable-provider allowlist with a tripwire test. Whole architecture; main has none of it (today's `provider_registry` references in `aeae0a8` are about *wallet* providers, not *route* providers).

**Files (A-only, ~3,600 LOC total):**
- `lib/bank/stablecoins/provider_registry.ex` (384 LOC) — registry of route providers with `:execution => :executable | :quote_only`.
- `lib/bank/stablecoins/providers/odos.ex` (359 LOC) — `Bank.Stablecoins.Provider` impl for Odos v3, quote-only.
- `lib/bank/quotes/stablecoin_route_provider.ex` (415 LOC) — bridges `Bank.Quotes.preview/2` → `Bank.Stablecoins.RouteSelector`.
- `lib/mix/tasks/bank.swap.odos.smoke.ex` (103 LOC) — operator smoke task.
- `lib/mix/tasks/bank.swap.oneinch.smoke.ex` (96 LOC) — operator smoke task.
- `test/bank/stablecoins/provider_registry_test.exs` (394 LOC) — includes the byte-for-byte tripwire vs adapter allowlist.
- `test/bank/stablecoins/providers/odos_test.exs` (372 LOC).
- `test/bank/quotes/stablecoin_route_provider_test.exs` (533 LOC).
- `test/bank/adapter_client_swap_executable_gate_test.exs` (151 LOC) — Phoenix-side fail-closed at `Bank.AdapterClient.dispatch_swap/2` for `:quote_only` plans.

**Dependencies on M files:** this category will not stand alone — it expects updates in `lib/bank/stablecoins/registry.ex`, `route_policy.ex`, `route_selector.ex`, `providers/zero_x.ex`, `quotes.ex`, `quotes/preview.ex` (all M-only in snapshot). Picking just the A files will leave compile errors. Plan: pick A files, then diff-merge each M companion **by hand** against current main.

### 3.2 — Chain adapter swap_strategies (per-provider envelope + calldata)

**Why valuable:** locks each route provider to its own envelope shape and calldata builder. Today's `chain_adapter/src/chains/base/swap.ts` (M) already hardcodes a ZeroX-only allowlist. The `swap_strategies/` directory generalises that gate so adding Odos/1inch execution becomes a one-file PR.

**Files (A-only, 493 LOC total):**
- `chain_adapter/src/chains/base/swap_strategies/index.ts` (166 LOC) — strategy dispatcher + `SUPPORTED_ROUTE_PROVIDERS` export.
- `chain_adapter/src/chains/base/swap_strategies/zerox.ts` (159 LOC) — `canExecute: true`.
- `chain_adapter/src/chains/base/swap_strategies/odos.ts` (88 LOC) — `canExecute: false` (needs `/sor/assemble`).
- `chain_adapter/src/chains/base/swap_strategies/oneinch.ts` (80 LOC) — `canExecute: false`.

**Dependencies on M files:** `chain_adapter/src/chains/base/swap.ts` (M) must be re-routed through the strategies dispatcher. Diff-merge required.

### 3.3 — Playwright E2E suite

**Why valuable:** catches CSS / JS / WebSocket regressions that `Phoenix.LiveViewTest` cannot. Lives in response to the DaisyUI `.modal` collision that hid the confirm-stop dialog under `visibility: hidden`. Today main has no browser-level regression coverage of the LiveView surface.

**Files (A-only, ~1,440 LOC total):**
- `assets/playwright/README.md` (81 LOC).
- `assets/playwright/global-setup.js` (129 LOC) — runs `mix bank.e2e.seed_operator` once, stashes login URL under `.auth/login-url.txt`.
- `assets/playwright/playwright.config.js` (82 LOC) — exports `BANK_E2E_DEV=1` to spawned `webServer`.
- `assets/playwright/install_authorization.spec.js` (339 LOC).
- `assets/playwright/preview.spec.js` (177 LOC).
- `assets/playwright/revoke.spec.js` (168 LOC) — the original modal-regression test.
- `assets/playwright/swap_run.spec.js` (239 LOC).
- `assets/playwright/test_intent_ui.spec.js` (128 LOC).

**Required plumbing (A-only, ~1,280 LOC total) — these are dependencies of the Playwright suite:**
- `lib/bank_web/controllers/e2e_auth_controller.ex` (670 LOC) — dev-only `/dev/__e2e/login_as/:id` login bypass behind double-gate (`Application.compile_env(:bank, :dev_routes)` AND runtime `BANK_E2E_DEV=1`).
- `lib/bank_web/plugs/e2e_adapter_dispatch_fixture.ex` (138 LOC) — captures adapter dispatch payloads for fixture E2E.
- `lib/bank_web/plugs/e2e_stablecoin_provider_fixture.ex` (227 LOC) — in-process stablecoin route fixture so previews reach `:ready` without external HTTP.
- `lib/mix/tasks/bank.e2e.seed_operator.ex` (246 LOC) — idempotent `e2e-operator@cryptobank.local` seeder.
- `assets/js/hooks/__tests__/session_permission_install.test.js` (466 LOC) — Vitest unit tests for the install hook's gating (account-vs-owner pin, chain check, bundler url). **May not compile** against today's `session_permission_install.js` (Path A rewrite); diff first.

**Dependencies on M files:** `lib/bank_web/router.ex` (M) needs the dev-only routes wired; `lib/bank_web/plugs/put_csp.ex` (M) needs the playwright origin allowed; `config/test.exs` (M) needs the fixture plugs registered.

### 3.4 — PreviewCard + the StablecoinRouteProvider bridge

**Why valuable:** operator-visible "estimated cost" UI for swap intents. Renders `:idle / :loading / :ready / :error` states with executable-vs-quote-only badge (green for `zerox`, amber for Odos/1inch). Today main's `agent_live.ex` (M) and `test_intent_card.ex` (M, just rewritten in `066cd76`) do not surface a preview card.

**Files (A-only, ~1,330 LOC total):**
- `lib/bank_web/live/agent_live/preview_card.ex` (238 LOC) — render-only function component, all state in `BankWeb.AgentLive`.
- `test/bank_web/live/agent_live/preview_card_test.exs` (945 LOC).
- `test/bank/quotes/preview_for_payload_test.exs` (89 LOC) — tests `Quotes.preview/2` for swap payloads.
- `test/bank/intents/build_transient_test.exs` (61 LOC).

**Dependencies on M files:** `agent_live.ex` needs the `:preview_state`/`:preview`/`:preview_error` assigns + a Task pipeline to call `Quotes.preview/2`. That's a substantial M-side change that overlaps with today's agent_live changes — manual diff-merge required.

### 3.5 — 0x swap MVP docs & runbooks

**Why valuable:** the most coherent design write-up of the swap-execution roadmap in the repo. Useful even if the code is never picked.

**Files (A-only, ~1,750 LOC total):**
- `docs/design/0x-swap-mvp-plan.md` (856 LOC) — Phase 0–7 roadmap; the canonical plan referenced by every other file in this category.
- `docs/design/0x-swap-mvp-phase-3-runbook.md` (318 LOC) — on-chain runtime simulator step-through.
- `docs/design/0x-swap-mvp-phase-7-real-chain-runbook.md` (169 LOC).
- `docs/runbooks/option-a-install-proof.md` (273 LOC) — clarifies "Path A (fixture E2E) vs Path B (real adapter on Base Sepolia)" terminology used in the snapshot. **Note** main's `8ce0086` commit reuses the name "Path A" for what this doc calls "Path B" — terminology conflict to flag if both land.
- `docs/swap-funding.md` (130 LOC) — operational funding requirements for swap dispatch.

**No code dependency** — docs land cleanly. Lowest-friction pick of the bunch.

### 3.6 — Misc tests + support

**Files (A-only, ~700 LOC total):**
- `test/bank/integration/swap_lifecycle_test.exs` (647 LOC) — end-to-end intent → preview → plan → dispatch lifecycle test.
- `test/support/process_dict_lookup.ex` (49 LOC) — test helper used by the lifecycle test.

**Dependencies:** test relies on §3.1's ProviderRegistry + the M-side `RoutePolicy` changes; will not compile in isolation.

---

## 4. Probably-useful (re-evaluate, may stand alone)

### 4.1 — `chain_adapter/src/lib/bundler_errors.ts` (136 LOC) + tests (146 LOC)

Maps bundler errors (Pimlico/ZeroDev/Stackup) to a stable atom allowlist (`insufficient_account_prefund`, `session_signer_invalid`, `permission_validation_failed`, etc.) for Phoenix's `execution.aborted` callback.

**Why "probably useful":** main today has `classifySendError` only in **frontend** (`assets/js/hooks/install_zerodev_client.js`). The TS adapter side has no equivalent classifier — bundler errors go through as whatever raw shape the bundler returns. If a future swap-dispatch fail-closed path wants stable atoms, this file is the right shape.

**Files:**
- `chain_adapter/src/lib/bundler_errors.ts` (136 LOC).
- `chain_adapter/test/bundler-errors.test.ts` (105 LOC).
- `chain_adapter/test/bundler-errors-wiring.test.ts` (41 LOC) — pins that `dispatch/swap` (or wherever) actually consults the classifier.

**Caveat:** the wiring test will likely fail if main's `dispatch/swap.ts` (M) hasn't been threaded through `mapBundlerError`. Plan: pick the classifier + its unit test; skip the wiring test until the dispatch path is updated.

---

## 5. Likely obsolete (do not pick)

### 5.1 — Path B browser-install adapter files

Superseded by Path A in `8ce0086`. Picking these would create a parallel install path nobody runs and conflict with `install_zerodev_client.js` semantics.

- `chain_adapter/src/chains/base/browser_install.ts` (490 LOC).
- `chain_adapter/src/chains/base/permission_account.ts` (257 LOC).
- `chain_adapter/src/dispatch/browser_install.ts` (117 LOC).
- `chain_adapter/test/dispatch-browser-install.test.ts` (360 LOC).
- `chain_adapter/test/permission-account-blob.test.ts` (85 LOC).
- `chain_adapter/test/permission-account-runtime.test.ts` (660 LOC).
- `chain_adapter/test/runtime-gap-browser-kernel.test.ts` (208 LOC).
- `chain_adapter/test/fixtures/keyless_permission_blob.ts` (197 LOC).
- `chain_adapter/test/fixtures/runtime_dispatch_payload.json` (56 LOC).
- `priv/adapter/fixtures/dispatch_browser_permission_install.json` (18 LOC).

### 5.2 — Older simulators

Superseded by `chain_adapter/scripts/install-e2e-simulator.ts` (12 KB, added in `8ce0086`).

- `chain_adapter/scripts/sim-adapter-mediated-install.mjs` (703 LOC).
- `chain_adapter/scripts/sim-browser-install.mjs` (618 LOC).
- `chain_adapter/scripts/sim-runtime-userop.mjs` (500 LOC).

---

## 6. The ~90 M-side files (parallel divergence)

These were modified on **both** main (since merge-base) and the snapshot. Direct cherry-pick will conflict. Strategy options:

1. **Skip them entirely.** Cleanest. Loses snapshot improvements that don't fit any A-file category.
2. **Diff-merge per file by hand.** Required for any A-file category whose dependencies are listed in §3 as M-only (every category except §3.5 docs).
3. **Three-way merge driver per file:** `git show codex/swap-mvp-wip-snapshot:<path> > /tmp/snap` and compare against current main. Useful when the snapshot's version reads cleaner than today's.

**Highest-value M files** (where the snapshot likely improves on main):
- `chain_adapter/src/chains/base/swap.ts` — strategies dispatcher rewrite (needed to make §3.2 work).
- `lib/bank/quotes.ex`, `lib/bank/quotes/preview.ex` — preview pipeline for the bridge in §3.1.
- `lib/bank/stablecoins/registry.ex`, `route_policy.ex`, `route_selector.ex`, `providers/zero_x.ex` — registry hookup for §3.1.
- `lib/bank_web/router.ex`, `plugs/put_csp.ex` — dev routes + CSP for Playwright (§3.3).
- `config/test.exs` — fixture plug registration for Playwright (§3.3).

**Lowest-value M files** (skip):
- `lib/bank_web/live/agent_live.ex`, `test_intent_card.ex`, `wallet_card.ex` — main has heavy rewrites in today's `066cd76` commit. The snapshot's version is older and will fight.
- `lib/bank/decisions.ex`, `swap_route_artifacts.ex`, `swap_dispatch_safety.ex` — same: today's closure bundle rewrote these.
- `lib/bank/demo.ex`, `delegations.ex`, `intents.ex`, `runtime/workers/*` — closure-bundle territory.

---

## 7. Recommended pick order

If you decide to salvage, **lowest-risk first**:

1. **§3.5 — docs only.** Zero code coupling. 5 markdown files, ~1,750 LOC of documentation, no compile risk. Single commit on a new branch.
2. **§4.1 — bundler_errors.ts + unit test only** (skip the wiring test). Compiles standalone. Single commit.
3. **§3.5+§4.1 verified.** Now decide whether the bigger architectural picks are worth it.
4. **§3.2 — swap_strategies/ + the M-side swap.ts rewrite.** Pick 4 A-files + diff-merge `swap.ts`. Verify with `npm test --prefix chain_adapter`.
5. **§3.1 — ProviderRegistry stack.** This is the largest and most coupled pick. Bring in all 9 A-files **plus** hand-merge `registry.ex`, `route_policy.ex`, `route_selector.ex`, `providers/zero_x.ex`, `quotes.ex`, `quotes/preview.ex`. Expect a 1-day effort with `mix test` runs between steps. The tripwire test in `provider_registry_test.exs` is the success gate.
6. **§3.4 — PreviewCard.** Bring `preview_card.ex` + tests, then hand-merge `agent_live.ex` deltas for `:preview_state` assigns + the Task pipeline. Highest collision risk against today's closure-bundle changes; do it last so any agent_live rebase is fresh in mind.
7. **§3.3 — Playwright + e2e plumbing.** Largest single category by LOC and the only one that adds a runtime (`npx playwright install`). Worth it if browser regressions still matter post-closure; skippable otherwise.

---

## 8. What this report does NOT do

- Does not run `git cherry-pick` or any write operation.
- Does not modify `codex/swap-mvp-wip-snapshot` (read-only).
- Does not touch stashes `stash@{0..2}` (per user instruction).
- Does not propose any branch deletion. The snapshot branch is still the canonical archive.

---

## Appendix A — Full A-only file list (52 files)

```
assets/js/hooks/__tests__/session_permission_install.test.js
assets/playwright/README.md
assets/playwright/global-setup.js
assets/playwright/install_authorization.spec.js
assets/playwright/playwright.config.js
assets/playwright/preview.spec.js
assets/playwright/revoke.spec.js
assets/playwright/swap_run.spec.js
assets/playwright/test_intent_ui.spec.js
chain_adapter/scripts/sim-adapter-mediated-install.mjs           [obsolete]
chain_adapter/scripts/sim-browser-install.mjs                    [obsolete]
chain_adapter/scripts/sim-runtime-userop.mjs                     [obsolete]
chain_adapter/src/chains/base/browser_install.ts                 [obsolete: Path B]
chain_adapter/src/chains/base/permission_account.ts              [obsolete: Path B]
chain_adapter/src/chains/base/swap_strategies/index.ts
chain_adapter/src/chains/base/swap_strategies/odos.ts
chain_adapter/src/chains/base/swap_strategies/oneinch.ts
chain_adapter/src/chains/base/swap_strategies/zerox.ts
chain_adapter/src/dispatch/browser_install.ts                    [obsolete: Path B]
chain_adapter/src/lib/bundler_errors.ts
chain_adapter/test/bundler-errors-wiring.test.ts                 [needs dispatch wiring]
chain_adapter/test/bundler-errors.test.ts
chain_adapter/test/dispatch-browser-install.test.ts              [obsolete: Path B]
chain_adapter/test/fixtures/keyless_permission_blob.ts           [obsolete: Path B]
chain_adapter/test/fixtures/runtime_dispatch_payload.json        [obsolete: Path B]
chain_adapter/test/permission-account-blob.test.ts               [obsolete: Path B]
chain_adapter/test/permission-account-runtime.test.ts            [obsolete: Path B]
chain_adapter/test/runtime-gap-browser-kernel.test.ts            [obsolete: Path B]
docs/design/0x-swap-mvp-phase-3-runbook.md
docs/design/0x-swap-mvp-phase-7-real-chain-runbook.md
docs/design/0x-swap-mvp-plan.md
docs/runbooks/option-a-install-proof.md
docs/swap-funding.md
lib/bank/quotes/stablecoin_route_provider.ex
lib/bank/stablecoins/provider_registry.ex
lib/bank/stablecoins/providers/odos.ex
lib/bank_web/controllers/e2e_auth_controller.ex
lib/bank_web/live/agent_live/preview_card.ex
lib/bank_web/plugs/e2e_adapter_dispatch_fixture.ex
lib/bank_web/plugs/e2e_stablecoin_provider_fixture.ex
lib/mix/tasks/bank.e2e.seed_operator.ex
lib/mix/tasks/bank.swap.odos.smoke.ex
lib/mix/tasks/bank.swap.oneinch.smoke.ex
priv/adapter/fixtures/dispatch_browser_permission_install.json   [obsolete: Path B]
test/bank/adapter_client_swap_executable_gate_test.exs
test/bank/integration/swap_lifecycle_test.exs
test/bank/intents/build_transient_test.exs
test/bank/quotes/preview_for_payload_test.exs
test/bank/quotes/stablecoin_route_provider_test.exs
test/bank/stablecoins/provider_registry_test.exs
test/bank/stablecoins/providers/odos_test.exs
test/bank_web/live/agent_live/preview_card_test.exs
test/support/process_dict_lookup.ex
```

## Appendix B — Reproduce these findings

```sh
# Merge base
git merge-base main codex/swap-mvp-wip-snapshot
# → aeae0a8

# A-only files
git diff --name-status aeae0a8..codex/swap-mvp-wip-snapshot | awk '$1=="A"{print $2}'

# M-only files
git diff --name-status aeae0a8..codex/swap-mvp-wip-snapshot | awk '$1=="M"{print $2}'

# View any snapshot file
git show codex/swap-mvp-wip-snapshot:<path>
```
