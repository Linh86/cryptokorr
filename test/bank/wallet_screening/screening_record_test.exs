defmodule Bank.WalletScreening.ScreeningRecordTest do
  use Bank.DataCase, async: true

  alias Bank.WalletScreening.ScreeningRecord

  @valid_attrs %{
    chain: "base",
    address: "0xAbC123",
    normalised_address: "0xabc123",
    control_tier: :hard_block,
    source: "ofac",
    source_record_id: "sdn-12345",
    category: "sanctions",
    reason: "OFAC SDN list",
    evidence_uri: "https://ofac.treasury.gov/sdn/12345"
  }

  describe "changeset/2" do
    test "valid attrs produce a valid changeset" do
      changeset = ScreeningRecord.changeset(%ScreeningRecord{}, @valid_attrs)
      assert changeset.valid?
    end

    test "requires chain, address, normalised_address, control_tier, source, source_record_id" do
      changeset = ScreeningRecord.changeset(%ScreeningRecord{}, %{})
      refute changeset.valid?

      errors = errors_on(changeset)
      assert errors[:chain] != nil
      assert errors[:address] != nil
      assert errors[:normalised_address] != nil
      assert errors[:control_tier] != nil
      assert errors[:source] != nil
      assert errors[:source_record_id] != nil
    end

    test "rejects invalid control_tier" do
      attrs = Map.put(@valid_attrs, :control_tier, :invalid_tier)
      changeset = ScreeningRecord.changeset(%ScreeningRecord{}, attrs)
      refute changeset.valid?
    end

    test "accepts all valid control tiers" do
      for tier <- [:hard_block, :challenge, :context, :score_only] do
        attrs =
          @valid_attrs
          |> Map.put(:control_tier, tier)
          |> then(fn a ->
            if tier == :score_only do
              Map.merge(a, %{score: Decimal.new("0.85"), score_version: "v1"})
            else
              Map.drop(a, [:score, :score_version])
            end
          end)

        changeset = ScreeningRecord.changeset(%ScreeningRecord{}, attrs)

        assert changeset.valid?,
               "expected #{tier} to be valid, got: #{inspect(errors_on(changeset))}"
      end
    end

    test "score_only requires score field" do
      attrs =
        @valid_attrs
        |> Map.put(:control_tier, :score_only)
        |> Map.delete(:score)

      changeset = ScreeningRecord.changeset(%ScreeningRecord{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:score] != nil
    end

    test "non-score_only rejects score field" do
      attrs = Map.merge(@valid_attrs, %{score: Decimal.new("0.5")})
      changeset = ScreeningRecord.changeset(%ScreeningRecord{}, attrs)
      refute changeset.valid?
      assert errors_on(changeset)[:score] != nil
    end
  end

  describe "persistence" do
    test "inserts and retrieves a screening record" do
      {:ok, record} =
        %ScreeningRecord{}
        |> ScreeningRecord.changeset(@valid_attrs)
        |> Repo.insert()

      assert record.id != nil
      assert record.chain == "base"
      assert record.control_tier == :hard_block
      assert record.source == "ofac"

      retrieved = Repo.get!(ScreeningRecord, record.id)
      assert retrieved.normalised_address == "0xabc123"
    end

    test "enforces unique constraint on (chain, normalised_address, source, source_record_id)" do
      {:ok, _} =
        %ScreeningRecord{}
        |> ScreeningRecord.changeset(@valid_attrs)
        |> Repo.insert()

      {:error, changeset} =
        %ScreeningRecord{}
        |> ScreeningRecord.changeset(@valid_attrs)
        |> Repo.insert()

      refute changeset.valid?
    end

    test "allows same address from different sources" do
      {:ok, _} =
        %ScreeningRecord{}
        |> ScreeningRecord.changeset(@valid_attrs)
        |> Repo.insert()

      different_source =
        @valid_attrs
        |> Map.put(:source, "opensanctions")
        |> Map.put(:source_record_id, "os-99999")

      {:ok, record2} =
        %ScreeningRecord{}
        |> ScreeningRecord.changeset(different_source)
        |> Repo.insert()

      assert record2.normalised_address == "0xabc123"
    end
  end
end
