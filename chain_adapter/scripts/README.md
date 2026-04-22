# Adapter operator scripts

These are **operator-side templates**, not part of the adapter
runtime. The adapter container deliberately does not ship with the
ZeroDev (or Biconomy) SDK installed — provisioning is a one-shot
procedure run by an operator, not a request-handled action.

The full provisioning runbook lives in the Phoenix repo at
[`docs/provisioning-kernel-v3.md`](../../docs/provisioning-kernel-v3.md).
Read that runbook first; these scripts are referenced inline from
its step list.

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

| Script                                 | What it does                                                                                                          | Tracks    |
| -------------------------------------- | --------------------------------------------------------------------------------------------------------------------- | --------- |
| [`provision-kernel.ts`](provision-kernel.ts) | Deploy a Kernel v3 smart account on Base + install Permission Validator against it. Steps 4–5 of the runbook.          | #84       |
| [`verify-installed-validator.ts`](verify-installed-validator.ts) | Read-only check that the smart account is deployed and the validator is installed. Step 6 of the runbook. Emits a Phoenix-ready receipt for #83 with the validator bytecode hash, Kernel factory, Basescan URL, and vendor artifact source. | #84 / #83 |
| [`check-env.sh`](check-env.sh)         | Runtime env hygiene check: confirms every required adapter env is set and reports whether the adapter is in sentinel-era or Kernel-provisioned mode. | #84       |

## Running them

Each script reads its inputs from environment variables. Each refuses
to run with placeholder values (e.g. `0x_smart_account_placeholder`)
so a half-configured operator workspace fails loud rather than
producing a misleading on-chain side effect.

The expected workflow is:

1. Run `provision-kernel.ts` against a fresh Base Sepolia operator
   workspace. Record the output.
2. Run `verify-installed-validator.ts` against the same workspace.
   Provide `KERNEL_FACTORY_ADDRESS` and `VENDOR_SOURCE`; record the
   full JSON receipt, not just the bytecode hash. The receipt is shaped
   for Phoenix's `Bank.Delegations.Provisioning.validate_receipt/1`
   helper and becomes the handoff from #84 to #83.
3. Set the resulting addresses on the adapter host. Run `check-env.sh`
   to confirm the runtime env is consistent.
4. Run the Phoenix smoke (`mix bank.smoke.transfer`,
   `mix bank.smoke.revoke`) end-to-end.
5. Repeat against Base mainnet only after Sepolia is proven and #58
   has shipped against Sepolia.

## What these scripts do NOT do

- They do not pin the Permission Validator's disable ABI fragment.
  That is #83.
- They do not wire the cryptographic revoke into `executeRevoke`.
  That is #58.
- They do not modify any state in the adapter or Phoenix repos.
  Output is recorded by the operator into the deployment journal
  outside the repos.
