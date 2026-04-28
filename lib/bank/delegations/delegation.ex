defmodule Bank.Delegations.Delegation do
  @moduledoc """
  Durable representation of a smart-account delegation state.

  This is the Phoenix-side projection of what lives on-chain. The row
  is mutable (unlike policy rules) because it's a cache projection,
  not an auditable domain object. Audit coverage comes from
  `audit_events` with `subject_type = "delegation"`.

  ## State machine

      pending ──grant──▶ active ──revoke_requested──▶ revoking
                           │                             │
                           │                             ├──success──▶ revoked
                           │                             │
                           │                             └──failure──▶ revoke_failed ──retry──▶ revoking
                           │
                           └──expire──▶ expired

  Terminal states: `:revoked`, `:expired`. `:revoke_failed` is
  non-terminal on purpose — the on-chain delegation is still live when
  a revoke attempt fails (send rejected, confirmation timeout, sentinel
  reverted), so the operator must be able to retry and the smart
  account must remain fail-closed. A new grant for the same smart
  account creates a new row only after the prior record reaches a
  terminal state.

  ## `delegation_id` field

  Free-form string column. Phoenix never parses it; it is the
  adapter's identifier for the on-chain authority record being
  managed. The on-the-wire encoding (4-byte ZeroDev `permissionId`,
  21-byte Kernel `validationId`, or a serialized plugin blob) is
  deferred until the ZeroDev SDK integration described in
  `docs/zerodev-permissions-integration.md` lands. An earlier
  version of this docstring claimed the value was a 66-char
  `bytes32 permissionId` derived from a single Permission
  Validator contract — that was a wrong-model assumption (see the
  integration doc). The column itself stays opaque, so no
  migration is needed.

  ## Permission artifact fields (#58)

  The cryptographic revoke path (`Kernel.uninstallValidation(bytes21,
  bytes, bytes)`) needs to reconstruct the same plugin object the
  grant flow installed. The adapter does that via
  `deserializePermissionAccount(...)` from `@zerodev/permissions`,
  which round-trips the base64 blob produced by
  `serializePermissionAccount(...)` at grant-time. Phoenix
  persists that blob plus a small denormalized header so:

    * `permission_blob` — the `serializePermissionAccount(...)` blob
      bytes. Opaque from Phoenix's side; Phoenix never opens it.
    * `permission_id` — 4-byte ZeroDev `permissionId`, denormalized
      for audit lookups.
    * `validation_id` — 21-byte Kernel `validationId`
      (`0x02 ‖ rightPad(permissionId, 20)`). The adapter feeds this
      directly to `uninstallValidation` as `vId`.
    * `kernel_version` — kernel implementation version the blob was
      produced under (e.g. `"0.3.1"`).
    * `permission_package_version` — `@zerodev/permissions` package
      version pinned at grant-time. Adapter refuses to deserialize
      a blob whose package version no longer matches its
      `KERNEL_PERMISSION_PIN`.
    * `installed_at_block` / `install_tx_hash` — install UserOp
      anchors for operator triage.
    * `session_signer_address` — 20-byte EOA bound to the
      permission's ECDSA signer module. Persisted because the
      `serializePermissionAccount(...)` blob is KEYLESS (no
      embedded `privateKey`); at revoke-time the adapter
      reconstructs a stub `ModularSigner` whose `account.address`
      equals this value, which is sufficient because
      `getEnableData(...)` does not sign — it just reads the
      address to recompute the kernel-stored deinitData. Storing
      the address keeps Phoenix free of any signing material.

  All eight columns are nullable. Legacy sentinel-era rows have
  them all NULL and stay on the sentinel revoke path. New rows
  populate them at grant-time; `cryptographically_revocable?/1`
  returns true iff the row has the complete wire-shape the adapter
  requires for the `permission` block.
  """

  use Bank.Schema

  @states [:pending, :active, :revoking, :revoke_failed, :revoked, :expired]
  @terminal_states [:revoked, :expired]

  @type t :: %__MODULE__{}

  schema "delegations" do
    field :smart_account_id, :string
    field :delegation_id, :string
    field :state, Ecto.Enum, values: @states, default: :pending
    field :chain, :string, default: "base"
    field :scope, :map, default: %{}
    field :granted_at, :utc_datetime_usec
    field :revoke_requested_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec
    field :last_reason, :string
    field :last_tx_hash, :string

    # ZeroDev permission-artifact fields (#58). Nullable — populated
    # only on grants that produced a real `PermissionPlugin` via
    # `toPermissionValidator(...)`. Sentinel-era rows keep them nil.
    field :permission_blob, :binary
    field :permission_id, :binary
    field :validation_id, :binary
    field :kernel_version, :string
    field :permission_package_version, :string
    field :installed_at_block, :integer
    field :install_tx_hash, :string
    # The session-signer EOA. Stored separately because the
    # serialized blob is keyless (no privateKey embedded) — see
    # the moduledoc above for why.
    field :session_signer_address, :string

    timestamps()
  end

  @permission_artifact_fields [
    :permission_blob,
    :permission_id,
    :validation_id,
    :kernel_version,
    :permission_package_version,
    :installed_at_block,
    :install_tx_hash,
    :session_signer_address
  ]

  def changeset(delegation, attrs) do
    delegation
    |> cast(
      attrs,
      [
        :smart_account_id,
        :delegation_id,
        :state,
        :chain,
        :scope,
        :granted_at,
        :revoke_requested_at,
        :revoked_at,
        :expires_at,
        :last_reason,
        :last_tx_hash
      ] ++ @permission_artifact_fields
    )
    |> validate_required([:smart_account_id, :delegation_id, :state, :chain])
    |> validate_byte_size(:permission_id, 4)
    |> validate_byte_size(:validation_id, 21)
    |> unique_constraint(:smart_account_id,
      name: :delegations_smart_account_active_idx,
      message: "a non-terminal delegation already exists for this smart account"
    )
  end

  @doc "Changeset for transitioning to :active."
  def grant_changeset(delegation, attrs \\ %{}) do
    delegation
    |> cast(attrs, [:granted_at, :scope, :last_reason])
    |> put_change(:state, :active)
    |> put_change(:granted_at, Map.get(attrs, :granted_at, DateTime.utc_now()))
  end

  @doc "Changeset for transitioning to :revoking."
  def revoke_requested_changeset(delegation, attrs \\ %{}) do
    delegation
    |> cast(attrs, [:last_reason, :revoke_requested_at])
    |> put_change(:state, :revoking)
    |> put_change(
      :revoke_requested_at,
      Map.get(attrs, :revoke_requested_at, DateTime.utc_now())
    )
  end

  @doc "Changeset for transitioning to :revoked."
  def revoked_changeset(delegation, attrs \\ %{}) do
    delegation
    |> cast(attrs, [:last_reason, :last_tx_hash, :revoked_at])
    |> put_change(:state, :revoked)
    |> put_change(:revoked_at, Map.get(attrs, :revoked_at, DateTime.utc_now()))
  end

  @doc """
  Changeset for transitioning to :revoke_failed.

  Used when the adapter's on-chain revoke attempt fails (send rejected,
  confirmation timeout, sentinel reverted). The delegation stays
  fail-closed (non-executable) but an operator can retry the revoke.
  """
  def revoke_failed_changeset(delegation, attrs \\ %{}) do
    delegation
    |> cast(attrs, [:last_reason, :last_tx_hash])
    |> put_change(:state, :revoke_failed)
  end

  @doc "Changeset for transitioning to :expired."
  def expired_changeset(delegation) do
    change(delegation, state: :expired)
  end

  @doc "Returns true if the state is terminal."
  def terminal?(%__MODULE__{state: state}), do: state in @terminal_states

  @doc "Returns the list of terminal states."
  def terminal_states, do: @terminal_states

  @doc """
  Returns true iff this delegation has the complete permission
  artifact set required for a cryptographic revoke dispatch (#58).

  The adapter schema requires a serialized plugin blob, 4-byte
  `permission_id`, 21-byte `validation_id`, `kernel_version`,
  `permission_package_version`, and `session_signer_address` (the
  20-byte EOA used to rebuild the keyless plugin's stub
  `ModularSigner` at revoke-time). Treating a partial row as
  cryptographically revocable would send malformed JSON and make the
  adapter reject the request after the worker has already selected the
  crypto path. We therefore require the complete wire-shape here.

  Rows where this returns `false` continue to revoke via the
  sentinel UserOp until their delegation is regranted under the new
  flow.
  """
  @spec cryptographically_revocable?(t()) :: boolean()
  def cryptographically_revocable?(%__MODULE__{
        permission_blob: blob,
        permission_id: pid,
        validation_id: vid,
        kernel_version: kernel_version,
        permission_package_version: package_version,
        session_signer_address: signer
      })
      when is_binary(blob) and byte_size(blob) > 0 and
             is_binary(pid) and byte_size(pid) == 4 and
             is_binary(vid) and byte_size(vid) == 21 and
             is_binary(kernel_version) and byte_size(kernel_version) > 0 and
             is_binary(package_version) and byte_size(package_version) > 0 and
             is_binary(signer) and byte_size(signer) == 42,
      do: true

  def cryptographically_revocable?(%__MODULE__{}), do: false

  # Validate fixed-size :binary fields. ZeroDev's `permissionId` is
  # exactly 4 bytes and `validationId` is exactly 21 bytes; a row
  # carrying anything else means upstream produced garbage and the
  # cryptographic revoke would build malformed calldata. We refuse
  # at the changeset boundary so the bad data never reaches the
  # adapter.
  defp validate_byte_size(changeset, field, expected) do
    Ecto.Changeset.validate_change(changeset, field, fn ^field, value ->
      cond do
        is_nil(value) -> []
        is_binary(value) and byte_size(value) == expected -> []
        true -> [{field, "must be exactly #{expected} bytes"}]
      end
    end)
  end
end
