defmodule Bank.WalletBindings.WalletBinding do
  @moduledoc """
  Durable record of a verified browser-wallet identity binding.

  A binding ties a connected EOA address to a workspace + user pair.
  Each row carries the short-lived challenge that the wallet signed
  to prove ownership; once `verified_at` is set the EOA is considered
  bound for the workspace.

  ## Lifecycle

      pending ──verify──▶ verified ──revoke──▶ revoked
         │
         └──expire──▶ (left pending; not selectable as active)

  - `pending`   — `verified_at IS NULL` and `expires_at > now()`
  - `verified`  — `verified_at IS NOT NULL` and `revoked_at IS NULL`
  - `revoked`   — `revoked_at IS NOT NULL`
  - `expired`   — `verified_at IS NULL` and `expires_at <= now()`

  The state machine is implicit (no enum column) so a row never has to
  be migrated between states out-of-band. The active binding for a
  workspace is the most recent verified, non-revoked row.

  ## Privacy

  No private keys, signatures, or session tokens land on this row.
  `challenge_message` is the human-readable EIP-191 message the wallet
  signed (nonce, address, chain id, workspace id, issued/expires
  timestamps); the signature itself is verified, never persisted, and
  never logged.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "wallet_bindings" do
    field :workspace_id, :binary_id
    field :user_id, :binary_id
    field :address, :string
    field :chain_id, :integer
    field :nonce, :string
    field :challenge_message, :string
    field :expires_at, :utc_datetime_usec
    field :verified_at, :utc_datetime_usec
    field :revoked_at, :utc_datetime_usec
    field :revoked_reason, :string

    timestamps(type: :utc_datetime_usec)
  end

  @create_fields [
    :workspace_id,
    :user_id,
    :address,
    :chain_id,
    :nonce,
    :challenge_message,
    :expires_at
  ]

  @doc """
  Build a changeset for issuing a new pending challenge row.

  Normalizes the address to lowercase 0x-prefixed 42-char hex.
  """
  def challenge_changeset(attrs) do
    attrs = normalize_address(attrs)

    %__MODULE__{}
    |> cast(attrs, @create_fields)
    |> validate_required([
      :workspace_id,
      :address,
      :chain_id,
      :nonce,
      :challenge_message,
      :expires_at
    ])
    |> validate_format(:address, ~r/^0x[0-9a-f]{40}$/,
      message: "must be a normalized 0x-prefixed 42-char hex address"
    )
    |> validate_inclusion(:chain_id, [84_532],
      message: "MVP wallet binding only accepts Base Sepolia (84532)"
    )
    |> validate_length(:nonce, min: 16)
    |> unique_constraint(:nonce, name: :wallet_bindings_nonce_uidx)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  Build a changeset that marks a pending challenge as verified.
  """
  def verify_changeset(%__MODULE__{} = binding, verified_at) do
    binding
    |> change(verified_at: verified_at)
    |> validate_required([:verified_at])
  end

  @doc """
  Build a changeset that marks a verified binding as revoked.
  """
  def revoke_changeset(%__MODULE__{} = binding, revoked_at, reason) do
    binding
    |> change(revoked_at: revoked_at, revoked_reason: reason)
    |> validate_required([:revoked_at])
    |> validate_length(:revoked_reason, max: 200)
  end

  defp normalize_address(%{"address" => address} = attrs) when is_binary(address) do
    Map.put(attrs, "address", String.downcase(address))
  end

  defp normalize_address(%{address: address} = attrs) when is_binary(address) do
    Map.put(attrs, :address, String.downcase(address))
  end

  defp normalize_address(attrs), do: attrs
end
