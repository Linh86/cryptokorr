defmodule Bank.Repo.Migrations.CreateWalletBindings do
  use Ecto.Migration

  def change do
    create table(:wallet_bindings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :restrict),
        null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all), null: true

      # Lowercase 0x-prefixed 42-char hex EOA address. Always normalized.
      add :address, :string, null: false

      # EIP-155 chain id. MVP enforces 84532 (Base Sepolia).
      add :chain_id, :integer, null: false

      # Random server-issued nonce. Unique across the table for replay
      # protection — a signature is only ever accepted once.
      add :nonce, :string, null: false

      # Full EIP-191 message that was signed. Stored so audit + replay
      # can re-derive what the wallet authorized; this contains the
      # nonce, address, chain, workspace id, and timestamps but no
      # secrets.
      add :challenge_message, :text, null: false

      # Challenge expiry. After this point a verify call is rejected
      # even if the signature is otherwise valid.
      add :expires_at, :utc_datetime_usec, null: false

      # Set when verify_and_bind/2 succeeds. Null = pending challenge.
      add :verified_at, :utc_datetime_usec, null: true

      # Set when an operator (or a re-bind) revokes the binding.
      add :revoked_at, :utc_datetime_usec, null: true
      add :revoked_reason, :string, null: true

      timestamps(type: :utc_datetime_usec)
    end

    # Replay protection: a signed nonce can only ever land once.
    create unique_index(:wallet_bindings, [:nonce], name: :wallet_bindings_nonce_uidx)

    # Lookup path for `get_active_binding/1` and the #170 status UI.
    create index(:wallet_bindings, [:workspace_id, :verified_at],
             name: :wallet_bindings_workspace_verified_at_idx
           )
  end
end
