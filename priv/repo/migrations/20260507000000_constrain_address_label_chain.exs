defmodule Bank.Repo.Migrations.ConstrainAddressLabelChain do
  @moduledoc """
  Audit M3: enforce the chain allowlist at the DB level.

  The Elixir layer (`Bank.Counterparties.AddressLabel.changeset/2`)
  already validates `:chain` against `@allowed_chains`. Adding a
  matching CHECK constraint closes the loop so a direct INSERT or
  bypass of the changeset cannot store an unsupported chain
  identifier.

  Allowlist matches `@allowed_chains` in the schema (`base`,
  `base-sepolia`, `ethereum`) — v0.1 intents only execute on `base`,
  but counterparty address labels can also be tracked on
  `base-sepolia` and `ethereum` for cross-chain screening flows.
  """

  use Ecto.Migration

  def up do
    create constraint(:address_labels, :address_labels_chain_in_allowlist,
             check: "chain IN ('base','base-sepolia','ethereum')"
           )
  end

  def down do
    drop constraint(:address_labels, :address_labels_chain_in_allowlist)
  end
end
