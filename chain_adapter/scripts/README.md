# Adapter operator scripts

These are **operator-side templates**, not part of the adapter
runtime. The adapter container deliberately does not ship with the
ZeroDev SDK installed — provisioning is a one-shot procedure run by
an operator, not a request-handled action.

## Status — DEFERRED on the corrected ZeroDev model

Two of the three scripts here (`provision-kernel.ts`,
`verify-installed-validator.ts`) were templates for a wrong model:
"deploy a single Permission Validator contract, capture its address
into `PERMISSION_VALIDATOR_ADDRESS`, and verify its bytecode hash."
That model does not match `@zerodev/permissions@5.6.3`, where
`toPermissionValidator()` returns a plugin object with
`.address === zeroAddress` and the on-chain primitives are CREATE2
signer + policy modules plus a per-permission `permissionId`. See
[`docs/zerodev-permissions-integration.md`](../../docs/zerodev-permissions-integration.md)
for the corrected model and the full hard-blocker list.

Both scripts have been replaced with stubs that print a deferred
message and exit non-zero so an operator does not invoke a
wrong-model template. They will be rewritten alongside the real
SDK integration.

`check-env.sh` is still useful: it validates the env vars the
adapter actually reads, with no network calls, and is unaffected by
the model correction (the addresses it checks for shape are stable).

## Why these are templates and not runnable as-is

The repo's `package.json` keeps runtime dependencies lean (`viem`,
`fastify`, `zod`). Adding `@zerodev/sdk` (or `@biconomy/nexus`) just
to host a one-shot provisioning script would bloat the runtime image
and create the false impression that an operator could provision
from inside a production container. Instead, the operator copies a
template into a separate workspace, installs the SDK there, fills in
the env-driven placeholders, and runs it once.

`tsconfig.json` only `include`s `src`, so nothing in this directory
participates in the runtime build, and `vitest` only matches
`*.test.ts` so nothing here runs in CI either. Both are deliberate:
these scripts are documentation that happens to be executable, not
production code.

## Inventory

| Script | What it does | Status |
| --- | --- | --- |
| [`provision-kernel.ts`](provision-kernel.ts) | (deferred) Was a Kernel v3 + single-validator install template. | **DEFERRED — see integration doc** |
| [`verify-installed-validator.ts`](verify-installed-validator.ts) | (deferred) Was a single-validator bytecode verification template. | **DEFERRED — see integration doc** |
| [`check-env.sh`](check-env.sh) | Adapter runtime env hygiene check: validates every required adapter env is present, non-placeholder, well-shaped (addresses are 0x+20 bytes, no trailing whitespace). Makes no network calls. | live |

## What `check-env.sh` verifies locally

The script is intentionally **no-secret, no-network**. It reads only
`process.env`. For every required env it flags:

- `MISSING`   — unset.
- `PLACEHOLD` — literal placeholder value like `0x_smart_account_placeholder`.
- `WHITESPCE` — trailing space, tab, or newline (common when an
  operator pastes a secret from a UI that includes a trailing
  character). Silent-breakage-class.
- `MALFORMED` — for address-typed envs (`SMART_ACCOUNT_ADDRESS`,
  `USDC_CONTRACT_ADDRESS`, `ENTRY_POINT_ADDRESS`): not `0x`-prefixed
  + 40 hex chars. EIP-55 checksum is deliberately not enforced here —
  viem's `isAddress` accepts any-case hex.
- `ok`        — present and well-shaped; value is masked for
  secret-shaped names (`*SECRET*`, `*KEY`, `*PRIVATE*`, `*TOKEN*`).

The script reports the runtime mode as `sentinel-era (awaiting
ZeroDev SDK integration)`. There used to be a tri-state mode
(`sentinel-era` / `straddle` / `kernel-provisioned`) keyed on
`PERMISSION_VALIDATOR_ADDRESS` and a parsed
`KERNEL_PERMISSION_VALIDATOR_PIN` source-file constant; both inputs
were artifacts of the wrong model and have been removed.

## What these scripts do NOT do

- They do not provision a ZeroDev Kernel account; the templates were
  wrong-model and are now stubs. The corrected provisioning flow
  lives in [`docs/zerodev-permissions-integration.md`](../../docs/zerodev-permissions-integration.md).
- They do not pin any ABI fragment. The corrected pin shape is
  documented on `KernelPermissionPin` in
  `src/chains/base/permission_validator.ts`; populating it is part
  of #83 once the SDK integration lands.
- They do not modify any state in the adapter or Phoenix repos.
- `check-env.sh` makes NO network calls and does NOT verify any
  on-chain bytecode.
