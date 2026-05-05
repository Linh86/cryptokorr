defmodule Bank.Activity.ExposureTest do
  @moduledoc """
  Tests for `Bank.Activity.Exposure` (#246) — opt-in workspace-
  scoped exposure aggregation backed by imported chain activity.

  Covers the #246 acceptance bullet:

    * "Exposure calculations can opt into confirmed imported
      activity"

  And the implicit constraint from the same issue body:

    * "use imported activity for context, reconciliation, and
      exposure WITHOUT treating it as authoritative when
      provenance is weak"

  Coverage:

    * default-deny: imported activity is NOT included unless the
      caller explicitly opts in
    * opt-in returns confirmed + high-confidence rows aggregated
      per asset (inbound, outbound, net, source_count)
    * weak provenance (`:medium`, `:low`) is excluded by default
      and included only when `:min_confidence` is widened
    * non-confirmed status (`:pending`, `:imported`, `:failed`)
      is NEVER included regardless of confidence
    * cross-workspace isolation
    * `:assets` filter restricts the aggregate
    * read-only: no row mutation, no Oban enqueue
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Activity
  alias Bank.Activity.{Exposure, ImportedActivity}
  alias Bank.Repo

  setup do
    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "exposure-#{System.unique_integer([:positive])}",
        name: "Exposure",
        mainnet_enabled: true
      })

    %{workspace: ws}
  end

  # --- default-deny -----------------------------------------------------

  describe "workspace_exposure_by_asset/2 — default-deny" do
    test "returns %{} when :include_imported_activity is not set", %{workspace: ws} do
      seed_confirmed_activity(ws.id, "USDC", :inbound, "100")

      assert Exposure.workspace_exposure_by_asset(ws.id) == %{}
    end

    test "returns %{} when :include_imported_activity is explicitly false", %{workspace: ws} do
      seed_confirmed_activity(ws.id, "USDC", :inbound, "100")

      assert Exposure.workspace_exposure_by_asset(ws.id, include_imported_activity: false) == %{}
    end

    test "returns %{} for nil / non-binary workspace_id (defensive)" do
      assert Exposure.workspace_exposure_by_asset(nil, include_imported_activity: true) == %{}
      assert Exposure.workspace_exposure_by_asset(123, include_imported_activity: true) == %{}
    end
  end

  # --- opt-in happy path ------------------------------------------------

  describe "workspace_exposure_by_asset/2 — opt-in confirmed + high-confidence" do
    test "aggregates confirmed + high-confidence rows per asset", %{workspace: ws} do
      seed_confirmed_activity(ws.id, "USDC", :inbound, "100.50")
      seed_confirmed_activity(ws.id, "USDC", :inbound, "50.00")
      seed_confirmed_activity(ws.id, "USDC", :outbound, "30.00")

      result =
        Exposure.workspace_exposure_by_asset(ws.id, include_imported_activity: true)

      assert Map.has_key?(result, "USDC")

      bucket = result["USDC"]
      assert Decimal.equal?(bucket.inbound, Decimal.new("150.50"))
      assert Decimal.equal?(bucket.outbound, Decimal.new("30.00"))
      assert Decimal.equal?(bucket.net, Decimal.new("120.50"))
      assert bucket.source_count == 3
    end

    test "groups by asset symbol independently", %{workspace: ws} do
      seed_confirmed_activity(ws.id, "USDC", :inbound, "100")
      seed_confirmed_activity(ws.id, "ETH", :inbound, "1.5")

      result = Exposure.workspace_exposure_by_asset(ws.id, include_imported_activity: true)

      assert Map.has_key?(result, "USDC")
      assert Map.has_key?(result, "ETH")
      assert Decimal.equal?(result["USDC"].inbound, Decimal.new("100"))
      assert Decimal.equal?(result["ETH"].inbound, Decimal.new("1.5"))
    end
  end

  # --- weak provenance excluded by default ------------------------------

  describe "workspace_exposure_by_asset/2 — confidence gate" do
    test "default :min_confidence excludes :medium and :low confidence rows",
         %{workspace: ws} do
      seed_activity(ws.id, status: :confirmed, confidence: :high, amount: "100", asset: "USDC")
      seed_activity(ws.id, status: :confirmed, confidence: :medium, amount: "10", asset: "USDC")
      seed_activity(ws.id, status: :confirmed, confidence: :low, amount: "1", asset: "USDC")

      result =
        Exposure.workspace_exposure_by_asset(ws.id, include_imported_activity: true)

      assert Decimal.equal?(result["USDC"].inbound, Decimal.new("100"))
      assert result["USDC"].source_count == 1
    end

    test "min_confidence: :medium widens the gate to include high+medium", %{workspace: ws} do
      seed_activity(ws.id, status: :confirmed, confidence: :high, amount: "100", asset: "USDC")
      seed_activity(ws.id, status: :confirmed, confidence: :medium, amount: "10", asset: "USDC")
      seed_activity(ws.id, status: :confirmed, confidence: :low, amount: "1", asset: "USDC")

      result =
        Exposure.workspace_exposure_by_asset(ws.id,
          include_imported_activity: true,
          min_confidence: :medium
        )

      assert Decimal.equal?(result["USDC"].inbound, Decimal.new("110"))
      assert result["USDC"].source_count == 2
    end

    test "min_confidence: :low includes everything", %{workspace: ws} do
      seed_activity(ws.id, status: :confirmed, confidence: :high, amount: "100", asset: "USDC")
      seed_activity(ws.id, status: :confirmed, confidence: :medium, amount: "10", asset: "USDC")
      seed_activity(ws.id, status: :confirmed, confidence: :low, amount: "1", asset: "USDC")

      result =
        Exposure.workspace_exposure_by_asset(ws.id,
          include_imported_activity: true,
          min_confidence: :low
        )

      assert Decimal.equal?(result["USDC"].inbound, Decimal.new("111"))
      assert result["USDC"].source_count == 3
    end
  end

  # --- non-confirmed status excluded -------------------------------------

  describe "workspace_exposure_by_asset/2 — status gate" do
    test "non-confirmed rows are NEVER counted, even at high confidence", %{workspace: ws} do
      for status <- [:pending, :imported, :failed] do
        seed_activity(ws.id,
          status: status,
          confidence: :high,
          amount: "999",
          asset: "USDC-#{status}"
        )
      end

      # Add one confirmed+high to prove the function does match
      # SOMETHING in this workspace.
      seed_activity(ws.id, status: :confirmed, confidence: :high, amount: "1", asset: "USDC-real")

      result =
        Exposure.workspace_exposure_by_asset(ws.id,
          include_imported_activity: true,
          min_confidence: :low
        )

      refute Map.has_key?(result, "USDC-pending")
      refute Map.has_key?(result, "USDC-imported")
      refute Map.has_key?(result, "USDC-failed")
      assert Map.has_key?(result, "USDC-real")
    end
  end

  # --- cross-workspace isolation ----------------------------------------

  describe "workspace_exposure_by_asset/2 — cross-workspace isolation" do
    test "sibling workspace's confirmed+high rows do not leak in", %{workspace: ws_a} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "exposure-other-#{System.unique_integer([:positive])}",
          name: "Exposure Other",
          mainnet_enabled: true
        })

      seed_confirmed_activity(ws_a.id, "USDC", :inbound, "10")
      seed_confirmed_activity(ws_b.id, "USDC", :inbound, "9999")

      result =
        Exposure.workspace_exposure_by_asset(ws_a.id, include_imported_activity: true)

      assert Decimal.equal?(result["USDC"].inbound, Decimal.new("10"))
      assert result["USDC"].source_count == 1
    end
  end

  # --- :assets filter ----------------------------------------------------

  describe "workspace_exposure_by_asset/2 — :assets filter" do
    test "restricts the aggregate to the listed asset symbols", %{workspace: ws} do
      seed_confirmed_activity(ws.id, "USDC", :inbound, "100")
      seed_confirmed_activity(ws.id, "ETH", :inbound, "1")

      result =
        Exposure.workspace_exposure_by_asset(ws.id,
          include_imported_activity: true,
          assets: ["USDC"]
        )

      assert Map.keys(result) == ["USDC"]
    end
  end

  # --- read-only ---------------------------------------------------------

  describe "read-only by construction" do
    test "enqueues no Oban job and does not mutate rows", %{workspace: ws} do
      activity = seed_confirmed_activity(ws.id, "USDC", :inbound, "10")

      jobs_before = Repo.all(Oban.Job)
      activity_before = Repo.get!(ImportedActivity, activity.id)

      _ = Exposure.workspace_exposure_by_asset(ws.id, include_imported_activity: true)

      assert Repo.all(Oban.Job) == jobs_before
      assert Repo.get!(ImportedActivity, activity.id) == activity_before
    end
  end

  # --- helpers -----------------------------------------------------------

  defp seed_confirmed_activity(workspace_id, asset, direction, amount_str) do
    seed_activity(workspace_id,
      status: :confirmed,
      confidence: :high,
      amount: amount_str,
      asset: asset,
      direction: direction
    )
  end

  defp seed_activity(workspace_id, opts) do
    {:ok, :inserted, row} =
      Activity.create_imported_activity(%{
        workspace_id: workspace_id,
        source_type: :wallet_chain,
        source_ref: "wallet:" <> Integer.to_string(System.unique_integer([:positive])),
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        asset: Keyword.fetch!(opts, :asset),
        chain: "base",
        amount: Decimal.new(Keyword.fetch!(opts, :amount)),
        direction: Keyword.get(opts, :direction, :inbound),
        status: Keyword.fetch!(opts, :status),
        confidence: Keyword.fetch!(opts, :confidence)
      })

    row
  end
end
