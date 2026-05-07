defmodule Bank.Counterparties.AddressLabelTest do
  use Bank.DataCase, async: true

  alias Bank.Counterparties.AddressLabel
  alias Bank.Fixtures

  # Canonical 40-hex addresses used by changeset tests. The format
  # validator (audit H7) requires `^0x[0-9a-fA-F]{40}$`.
  @valid_address "0x000000000000000000000000000000000000abcd"
  @valid_address_upper "0x000000000000000000000000000000000000ABCD"

  describe "changeset/2" do
    test "requires counterparty_id, chain, address, role" do
      changeset = AddressLabel.changeset(%AddressLabel{}, %{})
      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.counterparty_id
      assert "can't be blank" in errors.chain
      assert "can't be blank" in errors.address
    end

    test "defaults role to :other" do
      cp = Fixtures.counterparty()

      changeset =
        AddressLabel.changeset(%AddressLabel{}, %{
          counterparty_id: cp.id,
          chain: "base",
          address: @valid_address
        })

      assert get_field(changeset, :role) == :other
      assert changeset.valid?
    end

    test "rejects unknown roles" do
      cp = Fixtures.counterparty()

      changeset =
        AddressLabel.changeset(%AddressLabel{}, %{
          counterparty_id: cp.id,
          chain: "base",
          address: @valid_address,
          role: :cold_storage
        })

      refute changeset.valid?
    end

    # Audit H7: address format must be 0x-prefixed 20-byte hex.
    test "rejects malformed addresses" do
      cp = Fixtures.counterparty()

      for bad <- ["0x123", "not-an-address", "0x" <> String.duplicate("a", 41), ""] do
        changeset =
          AddressLabel.changeset(%AddressLabel{}, %{
            counterparty_id: cp.id,
            chain: "base",
            address: bad,
            role: :payout
          })

        refute changeset.valid?, "expected #{inspect(bad)} to be invalid"
        assert errors_on(changeset)[:address]
      end
    end

    test "accepts mixed-case 40-hex addresses" do
      cp = Fixtures.counterparty()

      changeset =
        AddressLabel.changeset(%AddressLabel{}, %{
          counterparty_id: cp.id,
          chain: "base",
          address: @valid_address_upper,
          role: :payout
        })

      assert changeset.valid?
    end

    # Audit M3: chain must be in @allowed_chains.
    test "rejects chains outside the allowlist" do
      cp = Fixtures.counterparty()

      for bad <- ["optimism", "arbitrum", "unknown-chain", "BASE", ""] do
        changeset =
          AddressLabel.changeset(%AddressLabel{}, %{
            counterparty_id: cp.id,
            chain: bad,
            address: @valid_address,
            role: :payout
          })

        refute changeset.valid?, "expected chain #{inspect(bad)} to be invalid"
        assert errors_on(changeset)[:chain]
      end
    end

    test "accepts every chain in the allowlist" do
      cp = Fixtures.counterparty()

      for chain <- ~w(base base-sepolia ethereum) do
        changeset =
          AddressLabel.changeset(%AddressLabel{}, %{
            counterparty_id: cp.id,
            chain: chain,
            address: @valid_address,
            role: :payout
          })

        assert changeset.valid?, "expected chain #{inspect(chain)} to be valid"
      end
    end
  end

  describe "partial unique index on active (chain, lower(address))" do
    test "allows two labels for the same (chain, address) when the first is retired" do
      cp = Fixtures.counterparty()
      retired = Fixtures.address_label(counterparty: cp, address: @valid_address)

      {:ok, _} =
        retired
        |> AddressLabel.retire(DateTime.utc_now())
        |> Repo.update()

      # Same (chain, address) now succeeds because the prior is retired.
      assert %AddressLabel{} =
               Fixtures.address_label(counterparty: cp, address: @valid_address)
    end

    test "rejects a second active label with the same (chain, lower(address))" do
      cp = Fixtures.counterparty()
      _first = Fixtures.address_label(counterparty: cp, address: @valid_address_upper)

      {:error, changeset} =
        %AddressLabel{}
        |> AddressLabel.changeset(%{
          counterparty_id: cp.id,
          chain: "base",
          address: @valid_address,
          role: :payout
        })
        |> Repo.insert()

      refute changeset.valid?
      assert errors_on(changeset)[:chain] == ["is already in use for this chain"]
    end

    test "same address across different chains is fine" do
      cp = Fixtures.counterparty()
      base = Fixtures.address_label(counterparty: cp, chain: "base", address: @valid_address)

      sepolia =
        Fixtures.address_label(counterparty: cp, chain: "base-sepolia", address: @valid_address)

      assert base.id != sepolia.id
    end
  end

  describe "retire/1" do
    test "sets retired_at without touching other fields" do
      label = Fixtures.address_label()

      {:ok, retired} =
        label
        |> AddressLabel.retire(DateTime.utc_now())
        |> Repo.update()

      assert retired.retired_at
      assert retired.chain == label.chain
      assert retired.address == label.address
    end
  end
end
