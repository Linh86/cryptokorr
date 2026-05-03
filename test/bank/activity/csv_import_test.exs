defmodule Bank.Activity.CsvImportTest do
  @moduledoc """
  Context tests for `Bank.Activity.CsvImport` (#244).
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Activity
  alias Bank.Activity.CsvImport
  alias Bank.Activity.ImportedActivity
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Repo

  setup do
    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "csv-#{System.unique_integer([:positive])}",
        name: "CSV"
      })

    %{workspace: ws}
  end

  # --- parse / preview happy paths --------------------------------------

  describe "parse/1" do
    test "parses MVP-shape CSV with required columns" do
      csv = """
      occurred_at,asset,chain,amount,direction,memo
      2026-04-01T12:00:00Z,USDC,base,100.50,inbound,payroll
      2026-04-02T12:00:00Z,USDC,base,25.00,outbound,vendor
      """

      assert {:ok, [r1, r2]} = CsvImport.parse(csv)
      assert r1.errors == []
      assert r2.errors == []
      assert r1.attrs.asset == "USDC"
      assert r1.attrs.amount == Decimal.new("100.50")
      assert r1.attrs.direction == :inbound
      assert r2.attrs.direction == :outbound
      # `memo` is unknown and lands in metadata.
      assert r1.attrs.metadata["memo"] == "payroll"
    end

    test "errors when header is missing a required column" do
      csv = """
      occurred_at,asset,amount
      2026-04-01T12:00:00Z,USDC,100
      """

      assert {:error, :missing_required_column} = CsvImport.parse(csv)
    end

    test "errors when header carries a forbidden column" do
      csv = """
      occurred_at,asset,amount,direction,workspace_id
      2026-04-01T12:00:00Z,USDC,100,inbound,sibling-workspace-uuid
      """

      assert {:error, {:forbidden_column, "workspace_id"}} = CsvImport.parse(csv)
    end

    test "errors with empty input" do
      assert {:error, :empty} = CsvImport.parse("")
      assert {:error, :empty} = CsvImport.parse("\n\n")
    end

    test "errors per-row do not abort parse/1; surfaced on the row" do
      csv = """
      occurred_at,asset,amount,direction
      bad-datetime,USDC,100,inbound
      2026-04-01T12:00:00Z,,100,inbound
      2026-04-01T12:00:00Z,USDC,not-a-decimal,inbound
      2026-04-01T12:00:00Z,USDC,-1,inbound
      2026-04-01T12:00:00Z,USDC,100,sideways
      """

      assert {:ok, rows} = CsvImport.parse(csv)
      assert length(rows) == 5
      assert Enum.all?(rows, &(&1.errors != []))
      assert hd(rows).row == 2
    end

    test "quoted fields with embedded commas survive the parser" do
      csv =
        ~S"""
        occurred_at,asset,amount,direction,notes
        2026-04-01T12:00:00Z,USDC,100,inbound,"a, b, c"
        """

      assert {:ok, [row]} = CsvImport.parse(csv)
      assert row.errors == []
      assert row.attrs.metadata["notes"] == "a, b, c"
    end
  end

  # --- preview -----------------------------------------------------------

  describe "preview/2" do
    test "splits parsed rows into new / duplicate / invalid",
         %{workspace: ws} do
      first_csv = """
      occurred_at,asset,amount,direction
      2026-04-01T12:00:00Z,USDC,100,inbound
      """

      assert {:ok, %{summary: %{inserted: 1}}} = CsvImport.commit(first_csv, ws.id)

      mixed_csv = """
      occurred_at,asset,amount,direction
      2026-04-01T12:00:00Z,USDC,100,inbound
      2026-04-02T12:00:00Z,USDC,50,inbound
      bad,USDC,5,inbound
      """

      assert {:ok, preview} = CsvImport.preview(mixed_csv, ws.id)

      assert preview.summary == %{new: 1, duplicate: 1, invalid: 1}
      assert length(preview.new) == 1
      assert length(preview.duplicate) == 1
      assert length(preview.invalid) == 1
      assert hd(preview.duplicate).existing
      assert hd(preview.invalid).errors != []
    end

    test "is pure: preview makes no inserts", %{workspace: ws} do
      csv = """
      occurred_at,asset,amount,direction
      2026-04-03T12:00:00Z,USDC,250,inbound
      """

      before = Repo.aggregate(ImportedActivity, :count, :id)
      assert {:ok, _} = CsvImport.preview(csv, ws.id)
      assert Repo.aggregate(ImportedActivity, :count, :id) == before
    end
  end

  # --- commit ------------------------------------------------------------

  describe "commit/2" do
    test "inserts new rows, classifies duplicates, surfaces invalid",
         %{workspace: ws} do
      csv = """
      occurred_at,asset,chain,amount,direction,memo
      2026-04-01T12:00:00Z,USDC,base,100,inbound,first
      2026-04-02T12:00:00Z,USDC,base,50,outbound,second
      bad,USDC,base,5,inbound,bad
      """

      assert {:ok, result} = CsvImport.commit(csv, ws.id)
      assert result.summary == %{inserted: 2, duplicate: 0, invalid: 1}
      assert [%ImportedActivity{}, %ImportedActivity{}] = result.inserted
      assert hd(result.invalid).errors != []
    end

    test "re-running commit on the same CSV is idempotent",
         %{workspace: ws} do
      csv = """
      occurred_at,asset,chain,amount,direction
      2026-04-01T12:00:00Z,USDC,base,100,inbound
      """

      assert {:ok, first} = CsvImport.commit(csv, ws.id)
      assert first.summary == %{inserted: 1, duplicate: 0, invalid: 0}

      assert {:ok, second} = CsvImport.commit(csv, ws.id)
      assert second.summary == %{inserted: 0, duplicate: 1, invalid: 0}

      assert Repo.aggregate(ImportedActivity, :count, :id) == 1
    end

    test "does not mutate ExecutionPlan or enqueue Oban jobs",
         %{workspace: ws} do
      csv = """
      occurred_at,asset,chain,amount,direction
      2026-04-01T12:00:00Z,USDC,base,100,inbound
      2026-04-02T12:00:00Z,USDC,base,50,outbound
      """

      before_plans = Repo.aggregate(ExecutionPlan, :count, :id)
      assert {:ok, _} = CsvImport.commit(csv, ws.id)
      assert Repo.aggregate(ExecutionPlan, :count, :id) == before_plans

      assert all_enqueued() == []
    end
  end

  # --- workspace boundary -----------------------------------------------

  describe "workspace boundary" do
    test "the same row in two workspaces inserts independently",
         %{workspace: ws_a} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "csv-sib-#{System.unique_integer([:positive])}",
          name: "Sibling"
        })

      csv = """
      occurred_at,asset,chain,amount,direction
      2026-04-01T12:00:00Z,USDC,base,100,inbound
      """

      assert {:ok, %{summary: %{inserted: 1}}} = CsvImport.commit(csv, ws_a.id)
      assert {:ok, %{summary: %{inserted: 1}}} = CsvImport.commit(csv, ws_b.id)

      assert Repo.aggregate(ImportedActivity, :count, :id) == 2
    end

    test "an existing duplicate in workspace B does not classify as duplicate in workspace A",
         %{workspace: ws_a} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "csv-sib2-#{System.unique_integer([:positive])}",
          name: "Sibling2"
        })

      csv = """
      occurred_at,asset,chain,amount,direction
      2026-04-01T12:00:00Z,USDC,base,100,inbound
      """

      # Pre-populate workspace B with the row.
      assert {:ok, %{summary: %{inserted: 1}}} = CsvImport.commit(csv, ws_b.id)

      # Workspace A still sees this as `:new`.
      assert {:ok, preview} = CsvImport.preview(csv, ws_a.id)
      assert preview.summary == %{new: 1, duplicate: 0, invalid: 0}
    end

    test "preview/2 with non-binary workspace_id is refused",
         %{workspace: _ws} do
      csv = """
      occurred_at,asset,amount,direction
      2026-04-01T12:00:00Z,USDC,100,inbound
      """

      assert {:error, :invalid_workspace} = CsvImport.preview(csv, nil)
      assert {:error, :invalid_workspace} = CsvImport.commit(csv, 12_345)
    end
  end

  # --- secret hygiene ----------------------------------------------------

  describe "secret hygiene" do
    test "secret-bearing unknown columns are redacted before persist",
         %{workspace: ws} do
      # Column names are normalised to lower-snake-case by the
      # parser, so `Authorization` becomes `authorization` in the
      # persisted metadata.
      csv =
        """
        occurred_at,asset,amount,direction,Authorization,private_key,memo
        2026-04-01T12:00:00Z,USDC,100,inbound,Bearer LEAKED_PROBE,0xLEAKED_PROBE,ok
        """

      assert {:ok, %{summary: %{inserted: 1}}} = CsvImport.commit(csv, ws.id)

      assert [row] = Activity.list_imported_activities(workspace_id: ws.id)
      assert row.metadata["authorization"] == "[REDACTED]"
      assert row.metadata["private_key"] == "[REDACTED]"
      assert row.metadata["memo"] == "ok"
      refute inspect(row.metadata) =~ "LEAKED_PROBE"
    end

    test "nested secret-keyed unknown columns (via JSON-shaped values) are also redacted",
         %{workspace: ws} do
      # CSV cells are flat strings, but the parser preserves the
      # column name. Nested redaction lives in the #243 P2 fix and
      # is exercised by the activity context tests; here we just
      # confirm the importer's path doesn't bypass it.
      csv =
        """
        occurred_at,asset,amount,direction,Authorization
        2026-04-01T12:00:00Z,USDC,100,inbound,Bearer LEAKED_PROBE
        """

      assert {:ok, %{inserted: [row]}} = CsvImport.commit(csv, ws.id)
      refute inspect(row.metadata) =~ "LEAKED_PROBE"
      refute inspect(row.metadata) =~ "Bearer "
    end
  end
end
