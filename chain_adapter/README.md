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
| POST   | `/dispatch/revoke_delegation` | Live, **sentinel only** (not a cryptographic revoke — see #31 below) |

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
(GitHub #56) in the Phoenix repo: a **Kernel v3 (ERC-7579)** modular
account on Base, with delegation authority registered as a
**per-delegation permission on a Kernel-compatible Permission Validator
module**. The on-chain authority record is the validator's
`bytes32 permissionId`, and Phoenix's `delegations.delegation_id`
column maps 1:1 to the lowercase hex form of that id.

Status of the implementation:

1. **Smart-account choice — DECIDED in #56.** Kernel v3 modular
   account; Permission Validator module installed once per smart
   account, per-delegation state managed by `permissionId`.
2. **Mapping convention + config key + ERC-7579 outer wrap — LANDED
   in #57 (narrowed scope).** What this means concretely:
   - [`src/chains/base/permission_validator.ts`](src/chains/base/permission_validator.ts)
     pins the `delegation_id` ↔ `permissionId` round trip
     (lowercase 0x-prefixed hex form of `bytes32`, 66 chars total).
   - [`src/chains/base/erc7579.ts`](src/chains/base/erc7579.ts)
     pins the EIP-7579 standard outer envelope
     `execute(bytes32 mode, bytes executionCalldata)` — selector
     `0xe9ae5c53`, all-zeros single-call ModeCode, packed body
     layout. Distinct from the SimpleAccount-shaped
     `execute(address,uint256,bytes)` envelope (selector
     `0xb61d27f6`) the v0.1 paths use today.
   - The env key is `PERMISSION_VALIDATOR_ADDRESS` (optional in
     v0.1; the strict accessor `requirePermissionValidatorAddress`
     fails loudly at revoke time when the live revoke begins
     reading it).
3. **Validator interface pin — DEFERRED to #58.** The Permission
   Validator's own disable function name + selector + ABI fragment
   was deliberately not pinned at #57. Pinning it from a plausible
   reference name without verifying it against an actual deployed
   bytecode would be speculation, and a wrong selector would surface
   as a silent on-chain revert at the first real revoke. The
   verifiable scaffolding above is what #58 will plug a verified
   inner body into.
4. **A deployed Permission Validator on Base — pending operator
   action.** When the validator is deployed, `SMART_ACCOUNT_ADDRESS`
   is migrated to a Kernel-shaped account, and the validator's
   disable interface is captured in a tripwire test, the address
   goes into `PERMISSION_VALIDATOR_ADDRESS` and the env is
   fail-closed without any further code change.
5. **Sentinel → real swap in `executeRevoke` — tracked in #58.** The
   swap is documented inline as a `TODO(#58)` block in
   [`src/chains/base/revoke.ts`](src/chains/base/revoke.ts) with the
   three remaining sub-prereqs spelled out. The tripwire test
   `test/base-revoke-sentinel-pin.test.ts` will fail loudly the
   moment the inner call shape changes, forcing whoever lands #58 to
   update this README, the contract docs, and the runbook.

Phoenix issue #31 stays open until #58 ships end-to-end against a
Kernel-provisioned account.

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
| `PERMISSION_VALIDATOR_ADDRESS` | Optional in v0.1; required for #58. Kernel v3 Permission Validator address bound to `SMART_ACCOUNT_ADDRESS`. The sentinel revoke path does not read it; the cryptographic revoke does, via `requirePermissionValidatorAddress` (fails loudly when unset). |
| `ADAPTER_TLS_CERT_PATH`     | Optional; if set with key, Fastify serves HTTPS instead of plain HTTP. |
| `ADAPTER_TLS_KEY_PATH`      | Optional; partner to cert path above. Both must be set together. |

The two bearer secrets gate the two directions of the trust boundary
independently — see `docs/security.md` (in the Phoenix repo) for the
full model. Inbound dispatch auth is enforced by a Fastify preHandler
on every `/dispatch/*` route; `/health` stays public. Constant-time
comparison is used for the bearer check.

See `.env.example` for defaults and optional vars.

## Provisioning a Kernel v3 smart account (issue #84)

The adapter is a chain execution specialist; it does NOT provision its
own smart account. Standing up the on-chain target the adapter binds
to (a Kernel v3 modular account on Base, with a Permission Validator
module installed against it) is a one-shot operator procedure.

The full step-by-step runbook lives in the Phoenix repo at
[`docs/provisioning-kernel-v3.md`](../docs/provisioning-kernel-v3.md).
Read it first.

Operator-side templates ship under [`scripts/`](scripts/). They are
NOT part of the adapter runtime — `tsconfig.json` excludes them and
`vitest` does not pick them up — and the runtime container does NOT
ship the ZeroDev (or Biconomy) SDK that real provisioning requires.
The expectation is that an operator copies a template into a separate
provisioning workspace, installs the SDK there, fills in the env
placeholders, and runs it once.

| Script                                            | Purpose                                                              |
| ------------------------------------------------- | -------------------------------------------------------------------- |
| [`scripts/provision-kernel.ts`](scripts/provision-kernel.ts) | Deploy a Kernel v3 smart account + install Permission Validator. Two phases gated on `INSTALL_VALIDATOR=true`. |
| [`scripts/verify-installed-validator.ts`](scripts/verify-installed-validator.ts) | Read-only ERC-7579 install check. Outputs a Phoenix-ready receipt with the validator bytecode keccak hash, Kernel factory, Basescan URL, and vendor artifact source for #83. |
| [`scripts/check-env.sh`](scripts/check-env.sh)    | Runtime env hygiene check: confirms every required adapter env is set and reports `SENTINEL-ERA` vs `KERNEL-PROVISIONED` mode. |

The expected end-to-end flow:

1. Run `provision-kernel.ts` against a fresh Base Sepolia operator
   workspace (Phase 1 + Phase 2). Record the smart account address.
2. Run `verify-installed-validator.ts` against the same workspace.
   Provide `KERNEL_FACTORY_ADDRESS` and `VENDOR_SOURCE`; record the
   full JSON receipt, not just the bytecode hash.
3. Set the resulting addresses (`SMART_ACCOUNT_ADDRESS`,
   `PERMISSION_VALIDATOR_ADDRESS`) on the adapter host. Run
   `check-env.sh` to confirm the runtime env is consistent.
4. Run the Phoenix smoke (`mix bank.smoke.transfer`,
   `mix bank.smoke.revoke`) end-to-end. Note that until #58 ships, the
   revoke smoke still exercises the sentinel path.
5. Repeat against Base mainnet only after Sepolia is proven and #58
   has shipped against Sepolia.

What this provisioning step does NOT do:

- It does not pin the validator's disable ABI fragment. That is #83.
- It does not wire the cryptographic revoke into `executeRevoke`.
  That is #58.

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
- **Permission validator** (`test/permission-validator.test.ts`) —
  pins what is verifiable today, independently of any specific
  validator deployment: the `delegation_id` ↔ `permissionId` mapping
  (round trip + rejection of malformed and pre-Kernel placeholder
  inputs) and the strict `requirePermissionValidatorAddress`
  fail-closed accessor for #58.
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
- **Cryptographic delegation revoke at the smart-account level.**
  The current sentinel user-op anchors the revoke on chain and
  exercises the full AA callback plumbing, but it does not disable
  the delegation key at the contract level. The smart-account choice
  (Kernel v3) is decided in #56 and the adapter-side ABI / mapping /
  config scaffolding landed in #57; what remains is deploying a
  Permission Validator and swapping the sentinel inner call for the
  real disable call (#58). The full architectural rationale lives in
  the Phoenix repo at `docs/smart-account-and-revoke-design.md`.
  Phoenix issue #31 stays open until #58 ships end-to-end. See the
  "Revoke delegation" subsection above for the exact swap when #58
  is landed.
- **Paymaster / sponsored flow.** The adapter funds user-ops from
  the smart account itself. Paymaster support remains reserved in
  the contract (`paymaster_denied` abort reason) but no code emits
  it.
- **Confirmation polling.** The current flow waits synchronously on
  `waitForUserOperationReceipt`. Production will use async polling
  with retry.
- **Dispatch endpoint authentication.** `/dispatch/transfer`,
  `/dispatch/swap`, and `/dispatch/revoke_delegation` accept any
  caller — there is no bearer or other auth check on the dispatch
  side. Phoenix does send `Authorization: Bearer …`, but the adapter
  does not validate it. Tracked in Phoenix issue #33.
- **mTLS.** Dev uses a shared bearer secret (outbound callbacks
  only). Production uses mutual TLS per the contract spec; not yet
  wired in either direction.
- **Multi-chain support.** Only Base. Schema is chain-aware but
  runtime rejects non-Base dispatches.
