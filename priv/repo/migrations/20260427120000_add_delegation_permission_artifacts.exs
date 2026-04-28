defmodule Bank.Repo.Migrations.AddDelegationPermissionArtifacts do
  @moduledoc """
  Add the permission-artifact columns the cryptographic revoke path needs.

  Context: issue #58. The current `revoke` path is a sentinel
  `SimpleAccount.execute(self, 0, 0x)` no-op self-call (see
  `chain_adapter/src/chains/base/revoke.ts`). To swap that for a real
  `Kernel.uninstallValidation(bytes21 vId, bytes deinitData, bytes
  hookDeinitData)` UserOp the adapter has to reconstruct the exact
  permission plugin that was installed at grant-time — which means
  Phoenix must persist the data needed to do that. Per the corrected
  ZeroDev model in `docs/zerodev-permissions-integration.md`,
  `permissionId` is `bytes4`, `validationId` is `bytes21`
  (`0x02 ‖ rightPad(permissionId, 20)`), and the SDK's
  `serializePermissionAccount(...)` produces a base64 blob carrying
  the policy + signer reconstruction parameters.

  All columns are nullable. Legacy sentinel rows already in the table
  do not need backfill — they remain on the sentinel revoke path
  until they reach a terminal state. New rows (post-#58) populate the
  artifact columns at grant-time; the worker's dispatch path branches
  on `permission_blob IS NOT NULL` to decide whether to send the
  cryptographic `permission` block or fall back to the legacy
  sentinel payload.

  Schema choice rationale (see Subagent C's design report under
  `docs/zerodev-permissions-integration.md` planning notes):

    * `permission_blob` — `bytea` carrying the
      `serializePermissionAccount(...)` output (ZeroDev's base64 JSON
      blob). Phoenix never opens it; it is the adapter's contract,
      restored via `deserializePermissionAccount(...)` at revoke-time.
    * `permission_id` — denormalized 4-byte handle for audit lookups
      (operators can paste this into Etherscan to inspect the
      permission). Indexed for diagnostics; not unique, because the
      4-byte hash space is too narrow to architecturally preclude
      collisions across kernel versions or chains.
    * `validation_id` — denormalized 21-byte
      `0x02 ‖ rightPad(permissionId, 20)` value the SDK feeds to
      `uninstallValidation`. Lets the adapter avoid re-deriving it
      from the blob on every revoke.
    * `kernel_version` — pinned at grant-time so a future kernel
      upgrade flagged by `provision-kernel.ts` is not silently
      reconciled against an old blob.
    * `permission_package_version` — `@zerodev/permissions` version
      the blob was produced under. The adapter refuses to
      deserialize a blob whose package the runtime can no longer
      load (`KERNEL_PERMISSION_PIN.zeroDevPermissionsPackageVersion`
      mismatch is a deliberate fail-closed signal).
    * `installed_at_block` / `install_tx_hash` — the install UserOp's
      anchor on chain, useful for operator triage.

  No unique constraint on `permission_id` — the existing
  `delegations_smart_account_active_idx` enforces at-most-one
  non-terminal row per smart account, which is the correctness
  invariant we need.
  """

  use Ecto.Migration

  def change do
    alter table(:delegations) do
      add :permission_blob, :binary
      add :permission_id, :binary
      add :validation_id, :binary
      add :kernel_version, :text
      add :permission_package_version, :text
      add :installed_at_block, :bigint
      add :install_tx_hash, :text
    end

    create index(:delegations, [:permission_id])
  end
end
