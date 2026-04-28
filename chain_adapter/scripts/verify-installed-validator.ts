/**
 * Permission Validator verification template — DEFERRED, awaiting
 * ZeroDev SDK integration.
 *
 * An earlier version of this script read the live bytecode at a
 * `PERMISSION_VALIDATOR_ADDRESS`, computed `keccak256`, and emitted
 * a JSON receipt with `permission_validator_address`,
 * `permission_validator_bytecode_keccak256`, etc. fields for the
 * Phoenix-side `mix bank.kernel.receipt.check` task. The whole
 * model was wrong: `@zerodev/permissions` does not have a single
 * Permission Validator contract — `toPermissionValidator()`
 * returns a plugin with `.address === zeroAddress`, and the
 * primitives that DO have addresses are CREATE2 signer + policy
 * modules pinned in the ZeroDev package itself.
 *
 * See `docs/zerodev-permissions-integration.md` for the corrected
 * model. The eventual verification script will check whichever
 * subset of (kernel implementation bytecode hash, signer/policy
 * module addresses, kernel `permissionConfig(pId)` storage slot
 * non-zero, `@zerodev/permissions` package version range) the
 * runtime ends up pinning.
 */

const message = [
  "chain_adapter/scripts/verify-installed-validator.ts is DEFERRED.",
  "",
  "The earlier 'verify a single Permission Validator address +",
  "bytecode hash' template was wrong-model — ZeroDev's permissions",
  "system has no such single contract. See",
  "docs/zerodev-permissions-integration.md for the corrected model",
  "and the hard-blocker list before any verification template can",
  "ship.",
].join("\n");

console.error(message);
process.exit(1);
