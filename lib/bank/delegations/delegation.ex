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
  managed. After GitHub #58 ships against a Kernel v3 modular
  account, fresh `delegation_id` values are the lowercase
  0x-prefixed hex form of the Permission Validator's `bytes32
  permissionId` (66 chars total). The full mapping rationale lives
  in `docs/smart-account-and-revoke-design.md` (#56); the
  `delegation_id` ↔ `permissionId` round-trip helpers and the
  ERC-7579 outer-execute pin landed under #57. The validator's own
  disable ABI is pinned later, by #58, against a specific verified
  deployment — see the adapter's `permission_validator.ts` for why.
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

    timestamps()
  end

  def changeset(delegation, attrs) do
    delegation
    |> cast(attrs, [
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
    ])
    |> validate_required([:smart_account_id, :delegation_id, :state, :chain])
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
end
