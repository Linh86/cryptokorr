/**
 * Kernel v3 provisioning template — DEFERRED, awaiting ZeroDev SDK
 * integration.
 *
 * An earlier version of this script was a template for "deploy a
 * Kernel v3 smart account, then install a Permission Validator
 * module against it" with a `PERMISSION_VALIDATOR_ADDRESS` env var
 * captured from the install step. That model was wrong:
 * `@zerodev/permissions` does not have a single deployable
 * Permission Validator contract — `toPermissionValidator()` returns
 * a plugin object whose `.address === zeroAddress`, and permissions
 * compose from CREATE2 signer + policy modules and a 4-byte
 * `permissionId`. See `docs/zerodev-permissions-integration.md` for
 * the corrected model.
 *
 * What an actual ZeroDev provisioning script needs (high-level):
 *
 *   - `@zerodev/sdk` and `@zerodev/permissions` runtime deps
 *     (currently absent from `chain_adapter/package.json`),
 *   - a kernel-account ECDSAValidator + sudo signer EOA,
 *   - per-permission `toPermissionValidator()` calls binding the
 *     chosen signer + policies (see `ECDSA_SIGNER_CONTRACT`,
 *     `CALL_POLICY_CONTRACT_V0_0_5`, `GAS_POLICY_CONTRACT`, etc.),
 *   - install via `Kernel.installValidations(...)` on the smart
 *     account, signed by the sudo signer through a bundler,
 *   - persistence of `serializePermissionAccount(...)` so the
 *     adapter can reconstruct the plugin at revoke-time.
 *
 * None of those are decided in this repo yet. The script refuses
 * to run so an operator does not invoke a wrong-model template.
 */

const message = [
  "chain_adapter/scripts/provision-kernel.ts is DEFERRED.",
  "",
  "The earlier 'install a single Permission Validator' template was",
  "wrong-model — ZeroDev's @zerodev/permissions does not have a",
  "single deployable validator contract. See",
  "docs/zerodev-permissions-integration.md for the corrected model",
  "and the hard-blocker list before any provisioning template can",
  "ship.",
].join("\n");

console.error(message);
process.exit(1);
