# CryptoBank chain adapter

TypeScript chain adapter for Bank v0.1 — Base + USDC execution.

## What this service owns

The adapter is the chain execution specialist. It owns:

- **Base-specific calldata / transaction assembly** — ERC-20 transfer
  encoding wrapped in `SimpleAccount.execute(target, value, data)` via
  viem.
- **ERC-4337 v0.7 UserOperation assembly + signing** — fetches the
  EntryPoint nonce, asks the bundler to estimate gas, signs the
  canonical v0.7 user-op hash with the delegation key, submits
  through the bundler.
- **Bundler interaction** — uses `viem/account-abstraction` (
  `createBundlerClient`, `sendUserOperation`,
  `waitForUserOperationReceipt`). The bundler's returned user-op
  hash is adopted as authoritative for audit callbacks.
- **Callback delivery to Phoenix** — every execution outcome is
  reported through `POST {phoenix_base}/internal/adapter/callback`.
- **Execution status mapping** — maps chain-level reality
  (confirmed / reverted / bundler rejection / confirmation timeout)
  into contract callback kinds.

## What Phoenix owns

The adapter never writes to the Phoenix database. Phoenix owns:

- Intents, policy evaluation, trust engine / trust assessments
- Approvals, decisions, audit trail
- Operator UI and all external `/v1/` API surface
- The authoritative record of every domain object

The adapter receives work items and posts callbacks. Phoenix is the
system of record for everything except live chain state.

## Contract

The Phoenix ↔ Adapter contract is defined in the Phoenix repo:

- Spec: `CryptoBank/priv/adapter/contract.md`
- Fixtures: `CryptoBank/priv/adapter/fixtures/*.json`

This adapter validates all incoming requests and outgoing callbacks
against Zod schemas derived from those fixtures. Contract drift is
caught at build time by the contract test suite.

## Dispatch endpoints

| Method | Path                          | Status      |
|--------|-------------------------------|-------------|
| GET    | `/health`                     | Live        |
| POST   | `/dispatch/transfer`          | Live        |
| POST   | `/dispatch/swap`              | Scaffolded  |
| POST   | `/dispatch/grant_delegation`  | Live (#58 grant flow — confirmed on Base Sepolia by PR #132; see "Cryptographic grant + revoke status" below) |
| POST   | `/dispatch/revoke_delegation` | Live, cryptographic when the dispatch carries a `permission` block (default for rows granted under #58) and sentinel for legacy rows without artifacts |

**Transfer** is the first real execution path. It builds a USDC
ERC-20 transfer on Base wrapped in a `SimpleAccount.execute` call,
assembles an ERC-4337 v0.7 UserOperation, signs it with the
delegation key, submits to the bundler, and delivers the full
callback lifecycle (`execution.broadcast` → `execution.confirmed`
or `execution.reverted`). Callbacks carry both the `userop_hash`
(EntryPoint identity) and — on confirmation — the chain-level `hash`
along with `nonce` (hex string), `bundler` label, and
`block_number`.

**Swap** validates the request shape and explicitly aborts. Phoenix
receives an `execution.aborted` callback with a clear reason. No fake
success is ever produced.

**Revoke delegation** validates the request, emits a `revoking`
callback, then submits a **sentinel UserOperation** whose inner call
is `SimpleAccount.execute(self, 0, 0x)` — a no-op self-call with
zero value and zero calldata. On confirmation it emits a terminal
`revoked` callback carrying the same AA-shaped `tx_refs` as transfers
(`chain`, `userop_hash`, `hash`, `nonce`, `bundler`, `block_number`,
`status`).

**Failure paths never emit `revoked`.** On any failure branch
(`userop_build_failed`, `bundler_rejected`, `confirmation_failed`,
`sentinel_reverted`) the adapter emits a terminal `revoke_failed`
callback with a diagnostic `reason`, so Phoenix can distinguish a
confirmed revoke from an attempt that did not complete. Phoenix
treats `revoke_failed` as non-terminal, non-executable, and
retryable; an operator may re-dispatch the revoke from the control
tower.

A duplicate dispatch while one is in flight re-emits `revoking` but
does not submit a second user-op.

The sentinel user-op is a real on-chain anchor — real user-op hash,
real receipt, real failure modes — but it is **not** a cryptographic
revocation of the delegation key at the contract level. The
delegation key can still sign another user-op until the chosen
permission-module surface is wired in.

The architectural decision is recorded in
[`docs/smart-account-and-revoke-design.md`](../docs/smart-account-and-revoke-design.md)
(GitHub #56): a **Kernel v3 (ERC-7579)** modular account on Base.
ZeroDev's permissions compose from CREATE2-deployed signer + policy
modules and a 4-byte `permissionId`; revoke is a kernel-account
method, not a call into a separate validator contract. See
[`docs/zerodev-permissions-integration.md`](../docs/zerodev-permissions-integration.md)
for the corrected on-chain model and the hard blockers. (An
earlier revision of this README described a single Permission
Validator module bound to one address — that framing was wrong
and has been removed.)

Status of the implementation:

1. **Smart-account choice — DECIDED in #56.** Kernel v3 modular
   account on Base. Independent of the permission-model correction
   below.
2. **ERC-7579 outer wrap — LANDED in #57 (still valid).**
   [`src/chains/base/erc7579.ts`](src/chains/base/erc7579.ts) pins
   the EIP-7579 normative outer envelope
   `execute(bytes32 mode, bytes executionCalldata)` — selector
   `0xe9ae5c53`, all-zeros single-call ModeCode, packed body
   layout. Distinct from the SimpleAccount-shaped
   `execute(address,uint256,bytes)` envelope (selector
   `0xb61d27f6`) the sentinel still uses. Independent of the
   permission system above it; survives the model correction.
3. **Permission pin — LANDED in #83.**
   [`src/chains/base/permission_validator.ts`](src/chains/base/permission_validator.ts)
   exports `KERNEL_PERMISSION_PIN` populated with the canonical
   ECDSA signer + six modern policy modules from
   `@zerodev/permissions@5.6.3` (CALL v0.0.5, GAS, RATE_LIMIT,
   SIGNATURE, SUDO, TIMESTAMP) and the
   `uninstallValidation(bytes21,bytes,bytes)` ABI fragment from
   `KernelV3_1AccountAbi` in `@zerodev/sdk@5.5.10`. Both halves
   are verified byte-for-byte by
   [`test/permission-validator-pin.test.ts`](test/permission-validator-pin.test.ts)
   so a future package bump that drifts cannot land silently.
4. **Provisioning + verification templates — LANDED in #84.**
   [`scripts/provision-kernel.ts`](scripts/provision-kernel.ts) and
   [`scripts/verify-installed-validator.ts`](scripts/verify-installed-validator.ts)
   are real, no-secret-safe templates targeting Kernel v3.1.
   Operator runbook:
   [`docs/provisioning-kernel-v3.md`](../docs/provisioning-kernel-v3.md).
   A real Kernel v3.1 smart account was deployed on Base Sepolia
   at `0xacb3390BF0E13eB0755317Fbb2C73Ed185F4142C`.
5. **Cryptographic grant + revoke — LIVE on Base Sepolia (#58
   + #31 closed by PR #132).** Both paths run end-to-end on
   chain:
   - Grant: `executeGrant` in
     [`src/chains/base/grant.ts`](src/chains/base/grant.ts) builds
     a `PermissionPlugin` via `toPermissionValidator(...)` (session
     signer = `DELEGATION_SIGNER_KEY`, sudo = `OPERATOR_PRIVATE_KEY`),
     installs it via the SDK's first-UserOp enable-signature flow,
     calls `serializePermissionAccount(account, undefined)` (KEYLESS
     by design — no session privateKey embedded), and emits a
     `delegation.state_changed{state: "granted"}` callback whose
     `permission` block carries the artifact set Phoenix needs.
   - Revoke: `executeCryptographicRevoke` in
     [`src/chains/base/revoke.ts`](src/chains/base/revoke.ts) runs
     when the dispatch carries a `permission` block; rebuilds a
     stub `ModularSigner` from `permission.session_signer_address`
     to satisfy the keyless-blob deserializer (no signing happens
     during revoke), then dispatches
     `Kernel.uninstallValidation(bytes21,bytes,bytes)` via the
     SDK's `uninstallPlugin` action signed by
     `OPERATOR_PRIVATE_KEY`.
   - Sentinel revoke (`SimpleAccount.execute(self, 0, 0x)`) stays
     as the LEGACY fallback for rows whose grant predates
     `permission` artifacts. The tripwire test
     `test/base-revoke-sentinel-pin.test.ts` still pins the
     sentinel body so any drift surfaces loudly.

   **Public proof (PR #132):** smart account
   `0xacb3390BF0E13eB0755317Fbb2C73Ed185F4142C` on Base Sepolia,
   permission id `0xbb2f68d9`, install tx
   `0xbbb3a2e8ae78e6c7c4ce6fb5c69f735baaf3af346ffd5b2ff7954724db39891a`,
   revoke tx
   `0xf81c969dafc25eccd0dccad0379317ec64b66916a45cdb9fae8c38e31d795ceb`,
   block `40820243`. The operator smoke runbook lives in
   [`docs/mvp-smoke-runbook.md`](../docs/mvp-smoke-runbook.md);
   the integration model is in
   [`docs/zerodev-permissions-integration.md`](../docs/zerodev-permissions-integration.md).

## Local setup

Prerequisites: Node.js 22+, npm.

```bash
cp .env.example .env
# Edit .env with your Base RPC URL and delegation key

npm install
npm run typecheck
npm test
npm run dev        # starts on PORT from .env (default 4100)
```

## Required env vars

| Variable                    | Description                              |
|-----------------------------|------------------------------------------|
| `ADAPTER_DISPATCH_SECRET`   | Bearer the adapter REQUIRES on inbound `POST /dispatch/*`. Phoenix sends this. |
| `PHOENIX_BASE_URL`          | Phoenix control plane URL                |
| `ADAPTER_CALLBACK_SECRET`   | Bearer the adapter SENDS on outbound callbacks; Phoenix validates it. |
| `BASE_RPC_URL`              | Base chain RPC endpoint                  |
| `BUNDLER_RPC_URL`           | ERC-4337 v0.7 bundler RPC endpoint       |
| `SMART_ACCOUNT_ADDRESS`     | Smart-account (sender) address on Base   |
| `DELEGATION_SIGNER_KEY`     | Private key for delegation signing       |
| `USDC_CONTRACT_ADDRESS`     | USDC contract on Base                    |
| `ENTRY_POINT_ADDRESS`       | Optional; defaults to EntryPoint v0.7    |
| `ADAPTER_TLS_CERT_PATH`     | Optional; if set with key, Fastify serves HTTPS instead of plain HTTP. |
| `ADAPTER_TLS_KEY_PATH`      | Optional; partner to cert path above. Both must be set together. |

The two bearer secrets gate the two directions of the trust boundary
independently — see `docs/security.md` (in the Phoenix repo) for the
full model. Inbound dispatch auth is enforced by a Fastify preHandler
on every `/dispatch/*` route; `/health` stays public. Constant-time
comparison is used for the bearer check.

See `.env.example` for defaults and optional vars.

## Provisioning a Kernel v3 smart account (issue #84)

The adapter is a chain execution specialist; it does NOT provision
its own smart account. Standing up the on-chain target the adapter
binds to (a Kernel v3 modular account on Base) is a one-shot
operator procedure.

The full step-by-step runbook lives at
[`docs/provisioning-kernel-v3.md`](../docs/provisioning-kernel-v3.md).
Read it first.

Operator-side templates ship under [`scripts/`](scripts/). They
are NOT part of the adapter runtime — `tsconfig.json` excludes
them and `vitest` does not pick them up. The ZeroDev SDK packages
they reuse (`@zerodev/sdk`, `@zerodev/ecdsa-validator`,
`@zerodev/permissions`) live in `dependencies` (not
`devDependencies`) of `chain_adapter/package.json` because the
runtime cryptographic grant + revoke paths import them at
dispatch time, so a production install via `npm ci --omit=dev`
ships them. An operator running these templates from a separate
provisioning workspace can either reuse the adapter's installed
tree or `npm install` the same pinned versions there.

| Script | Purpose | Modes |
| --- | --- | --- |
| [`scripts/provision-kernel.ts`](scripts/provision-kernel.ts) | Derives the deterministic Kernel v3.1 smart-account address for `(OPERATOR_ADDRESS, KERNEL_ACCOUNT_INDEX)`. With `--broadcast`, signs + submits the deploy UserOp through the bundler. Per-permission install is NOT in scope here; see the integration doc. | dry-run (default) / `--broadcast` |
| [`scripts/verify-installed-validator.ts`](scripts/verify-installed-validator.ts) | Read-only RPC checks against the configured `SMART_ACCOUNT_ADDRESS`: deployed bytecode, kernel implementation, kernel version, root validator, current nonce. | always read-only |
| [`scripts/check-env.sh`](scripts/check-env.sh) | Runtime env hygiene check: confirms every required adapter env is set, non-placeholder, well-shaped. No network calls. | always offline |

The expected end-to-end flow today:

1. Deploy a Kernel v3 smart account on Base Sepolia using
   `provision-kernel.ts --broadcast` (real, no-secret-safe template
   targeting Kernel v3.1). Record the address.
2. Set `SMART_ACCOUNT_ADDRESS`, `KERNEL_FACTORY_ADDRESS`,
   `DELEGATION_SIGNER_KEY`, and the kernel-root pair
   (`OPERATOR_PRIVATE_KEY` + `OPERATOR_ADDRESS`) on the adapter
   host. Run `check-env.sh` to confirm the runtime env is
   consistent.
3. Run the MVP smoke runbook
   ([`docs/mvp-smoke-runbook.md`](../docs/mvp-smoke-runbook.md))
   to exercise the cryptographic grant + revoke path end-to-end.
   The legacy sentinel smokes
   (`mix bank.smoke.transfer`, `mix bank.smoke.revoke`) still
   work for rows without `permission` artifacts.
4. Promote to Base mainnet only after Sepolia is proven
   end-to-end (cryptographic grant + revoke confirmed on chain
   per #58 / #31, closed by PR #132).

What this provisioning step does NOT do:

- It does not install ZeroDev permissions on the smart account.
  That happens in the adapter runtime via
  `POST /dispatch/grant_delegation` (`executeGrant`).
- It does not run the cryptographic revoke. That happens in the
  adapter runtime via `POST /dispatch/revoke_delegation` when
  Phoenix attaches a `permission` block (`executeCryptographicRevoke`).

## Tests

```bash
npm test           # run all tests
npm run test:watch # watch mode
```

Test suites:

- **Contract tests** (`test/contracts.test.ts`) — validate Zod schemas
  against the canonical Phoenix fixtures. If these fail, the contract
  has drifted.
- **Health test** (`test/health.test.ts`) — endpoint returns service
  metadata.
- **Transfer dispatch** (`test/dispatch-transfer.test.ts`) — request
  validation, chain/asset support checks, error shapes.
- **Swap dispatch** (`test/dispatch-swap.test.ts`) — validates input,
  verifies explicit abort + callback delivery.
- **Revoke dispatch** (`test/dispatch-revoke.test.ts`) — validates
  input, verifies the `revoking` → `revoked` callback sequence on
  success and the `revoking` → `revoke_failed` sequence on each
  failure branch (send / confirmation / revert), and asserts
  in-flight idempotency.
- **Base transfer** (`test/base-transfer.test.ts`) — unit tests for
  `executeTransfer` directly: asserts the AA-shaped callback lifecycle
  (`execution.broadcast` carrying `userop_hash` + `nonce` + `bundler`;
  `execution.confirmed` adding `hash` + `block_number`) and the
  full failure taxonomy (bundler rejection, confirmation timeout,
  on-chain revert).
- **Base revoke** (`test/base-revoke.test.ts`) — unit tests for
  `executeRevoke` directly: asserts that the sentinel UserOperation
  is submitted through the bundler, that the terminal `revoked`
  callback carries AA-shaped `tx_refs` (userop_hash, tx hash, hex
  nonce, bundler label), and that every failure path emits
  `state: revoke_failed` (never `revoked`).
- **Permission pin tripwire** (`test/permission-validator-pin.test.ts`) —
  imports the canonical signer + policy module addresses from
  `@zerodev/permissions@5.6.3` and the `uninstallValidation` ABI
  fragment from `KernelV3_1AccountAbi` in `@zerodev/sdk@5.5.10`,
  asserts each matches `KERNEL_PERMISSION_PIN` byte-for-byte, and
  pins the structural shape so a future package bump that drifts
  surfaces immediately.
- **ERC-7579 outer wrap** (`test/erc7579.test.ts`) — pins the
  EIP-7579 normative `execute(bytes32 mode, bytes executionCalldata)`
  ABI shape, the selector `0xe9ae5c53`, the all-zeros single-call
  ModeCode constant, the packed body layout, and the structural
  distinction from the SimpleAccount envelope (selector `0xb61d27f6`).
  Pinned at #57 so #58 cannot accidentally regress to wrapping a
  Kernel call with the v0.1 SimpleAccount envelope.
- **Callbacks** (`test/callbacks.test.ts`) — payload shaping,
  self-validation, monotonic id generation.
- **Assets** (`test/assets.test.ts`) — amount parsing, asset/chain
  support checks.

## What is intentionally deferred

- **Real swap execution.** Router integration (Uniswap, CoW, etc.) is
  not wired. The handler validates and aborts safely.
- **Sentinel revoke as legacy fallback.** Cryptographic revoke
  is the default for rows with `permission` artifacts (#58 /
  #31, closed by PR #132). The sentinel
  `SimpleAccount.execute(self, 0, 0x)` user-op continues to
  anchor revokes for legacy rows that were granted before the
  permission block was wired through; on those rows
  `state: revoked` still means "on-chain anchored, trust
  downgraded" rather than "cryptographically disabled". See
  the "Revoke delegation" subsection above.
- **Paymaster / sponsored flow.** The adapter funds user-ops from
  the smart account itself. Paymaster support remains reserved in
  the contract (`paymaster_denied` abort reason) but no code emits
  it.
- **Confirmation polling.** The current flow waits synchronously on
  `waitForUserOperationReceipt`. Production will use async polling
  with retry.
- **mTLS.** Dev uses a shared bearer secret in both directions:
  inbound `/dispatch/*` requires `Authorization: Bearer
  $ADAPTER_DISPATCH_SECRET` (enforced in `src/app.ts` by
  `verifyDispatchAuth`, constant-time compared), and outbound
  callbacks sign with `$ADAPTER_CALLBACK_SECRET`. Production will
  add mutual TLS per the contract spec; not yet wired in either
  direction.
- **Multi-chain support.** Only Base. Schema is chain-aware but
  runtime rejects non-Base dispatches.
