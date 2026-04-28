defmodule Bank.Repo.Migrations.AddDelegationSessionSignerAddress do
  @moduledoc """
  Add the `session_signer_address` column to `delegations`.

  Context: issue #58 grant flow follow-up. The cryptographic revoke
  path (`Kernel.uninstallValidation(...)`) must reconstruct the same
  permission plugin the grant flow installed. ZeroDev's
  `deserializePermissionAccount(...)` accepts EITHER a `privateKey`
  embedded in the serialized blob OR an externally provided
  `modularSigner`.

  Subagent D's security review (PR #129's grant-flow follow-up)
  confirmed that `serializePermissionAccount(account, privateKey)`
  embeds the session ECDSA private key VERBATIM in the base64 JSON
  blob. Persisting that blob in Phoenix would make the control plane
  hold a signing key — a hard violation of CryptoBank's threat model
  (adapter-only signing keys, Phoenix is the control plane).

  The fix: at grant time the adapter calls
  `serializePermissionAccount(account, undefined)` (no privateKey
  argument), producing a KEYLESS blob. At revoke time the adapter
  rebuilds a stub `ModularSigner` whose only correct field is
  `account.address` — `getEnableData` reads only that address (no
  signing happens during revoke). The `session_signer_address`
  column persists exactly that 20-byte EOA address so the stub can
  be reconstructed.

  The column is nullable. Pre-#58-grant rows have it NULL and stay
  on the sentinel revoke path. New cryptographic grants populate
  it; the row's
  `Bank.Delegations.Delegation.cryptographically_revocable?/1`
  guard already requires the full wire-shape (now including this
  field) so a half-populated row never selects the crypto branch.
  """

  use Ecto.Migration

  def change do
    alter table(:delegations) do
      add :session_signer_address, :text
    end
  end
end
