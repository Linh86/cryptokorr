defmodule Bank.Counterparties.AddressLabelTest do
  use Bank.DataCase, async: true

  alias Bank.Counterparties.AddressLabel
  alias Bank.Fixtures

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
          address: "0xabc"
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
          address: "0xabc",
          role: :cold_storage
        })

      refute changeset.valid?
    end
  end

  describe "partial unique index on active (chain, lower(address))" do
    test "allows two labels for the same (chain, address) when the first is retired" do
      cp = Fixtures.counterparty()
      retired = Fixtures.address_label(counterparty: cp, address: "0xabc")

      {:ok, _} =
        retired
        |> AddressLabel.retire(DateTime.utc_now())
        |> Repo.update()

      # Same (chain, address) now succeeds because the prior is retired.
      assert %AddressLabel{} =
               Fixtures.address_label(counterparty: cp, address: "0xabc")
    end

    test "rejects a second active label with the same (chain, lower(address))" do
      cp = Fixtures.counterparty()
      _first = Fixtures.address_label(counterparty: cp, address: "0xABC")

      {:error, changeset} =
        %AddressLabel{}
        |> AddressLabel.changeset(%{
          counterparty_id: cp.id,
          chain: "base",
          address: "0xabc",
          role: :payout
        })
        |> Repo.insert()

      refute changeset.valid?
      assert errors_on(changeset)[:chain] == ["is already in use for this chain"]
    end

    test "same address across different chains is fine" do
      cp = Fixtures.counterparty()
      base = Fixtures.address_label(counterparty: cp, chain: "base", address: "0xabc")
      opt = Fixtures.address_label(counterparty: cp, chain: "optimism", address: "0xabc")
      assert base.id != opt.id
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
