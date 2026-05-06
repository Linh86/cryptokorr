defmodule Bank.DefiVenues.Morpho.WithdrawPreviewTest do
  @moduledoc """
  Pure unit tests for `Bank.DefiVenues.Morpho.WithdrawPreview`
  (#207). No DB; no I/O; just the snapshot-derived
  liquidity-ceiling math + block-or-partial signal computation.
  """

  use ExUnit.Case, async: true

  alias Bank.DefiVenues.Morpho.{PersistedVaultSnapshot, WithdrawPreview}

  defp snapshot(state, overrides \\ %{}) do
    base = %PersistedVaultSnapshot{
      id: "11111111-1111-4111-8111-111111111111",
      chain_id: 84_532,
      vault_address: "0xbeef000000000000000000000000000000000099",
      payload_hash: "demo-hash",
      fetched_at: ~U[2026-05-06 09:00:00.000000Z],
      state: state
    }

    Map.merge(base, overrides)
  end

  describe "preview/3 — happy paths" do
    test "smaller-than-ceiling request returns full preview, no block, no partial" do
      snap = snapshot(%{"total_assets" => "1000"})

      assert {:ok, preview} = WithdrawPreview.preview(snap, Decimal.new("100"))

      assert preview.chain == "base-sepolia"
      assert preview.chain_id == 84_532
      assert preview.vault_address == snap.vault_address
      assert Decimal.equal?(preview.requested_assets, Decimal.new("100"))
      assert Decimal.equal?(preview.max_withdrawable, Decimal.new("1000"))
      refute preview.would_block?
      refute preview.would_partial?
      assert preview.snapshot_id == snap.id
      assert preview.snapshot_payload_hash == "demo-hash"
      assert preview.snapshot_fetched_at == "2026-05-06T09:00:00.000000Z"
    end

    test "request equal to ceiling is a full withdraw, not a partial" do
      snap = snapshot(%{"total_assets" => "500"})

      assert {:ok, preview} = WithdrawPreview.preview(snap, Decimal.new("500"))
      refute preview.would_block?
      refute preview.would_partial?
    end

    test "would_partial? is true when request exceeds ceiling" do
      snap = snapshot(%{"total_assets" => "100"})

      assert {:ok, preview} = WithdrawPreview.preview(snap, Decimal.new("200"))
      refute preview.would_block?
      assert preview.would_partial?
    end

    test "would_block? is true when ceiling is zero" do
      snap = snapshot(%{"total_assets" => "0"})

      assert {:ok, preview} = WithdrawPreview.preview(snap, Decimal.new("100"))
      assert preview.would_block?
      refute preview.would_partial?
    end

    test "accepts atom-keyed state for forward compatibility" do
      snap = snapshot(%{total_assets: "750"})

      assert {:ok, preview} = WithdrawPreview.preview(snap, Decimal.new("100"))
      assert Decimal.equal?(preview.max_withdrawable, Decimal.new("750"))
    end

    test "accepts integer total_assets" do
      snap = snapshot(%{"total_assets" => 1234})

      assert {:ok, preview} = WithdrawPreview.preview(snap, Decimal.new("100"))
      assert Decimal.equal?(preview.max_withdrawable, Decimal.new("1234"))
    end
  end

  describe "preview/3 — invalid amount" do
    test "rejects nil request" do
      snap = snapshot(%{"total_assets" => "1000"})
      assert {:error, :morpho_withdraw_invalid_amount} = WithdrawPreview.preview(snap, nil)
    end

    test "rejects zero request" do
      snap = snapshot(%{"total_assets" => "1000"})

      assert {:error, :morpho_withdraw_invalid_amount} =
               WithdrawPreview.preview(snap, Decimal.new(0))
    end

    test "rejects negative request" do
      snap = snapshot(%{"total_assets" => "1000"})

      assert {:error, :morpho_withdraw_invalid_amount} =
               WithdrawPreview.preview(snap, Decimal.new("-1"))
    end

    test "rejects non-Decimal request" do
      snap = snapshot(%{"total_assets" => "1000"})
      assert {:error, :morpho_withdraw_invalid_amount} = WithdrawPreview.preview(snap, "100")
    end
  end

  describe "preview/3 — invalid snapshot" do
    test "rejects missing total_assets" do
      snap = snapshot(%{})

      assert {:error, :morpho_withdraw_snapshot_invalid} =
               WithdrawPreview.preview(snap, Decimal.new("100"))
    end

    test "rejects unparseable total_assets" do
      snap = snapshot(%{"total_assets" => "not-a-number"})

      assert {:error, :morpho_withdraw_snapshot_invalid} =
               WithdrawPreview.preview(snap, Decimal.new("100"))
    end

    test "rejects negative total_assets (defensive)" do
      snap = snapshot(%{"total_assets" => "-1"})

      assert {:error, :morpho_withdraw_snapshot_invalid} =
               WithdrawPreview.preview(snap, Decimal.new("100"))
    end
  end
end
