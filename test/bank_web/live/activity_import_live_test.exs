defmodule BankWeb.ActivityImportLiveTest do
  @moduledoc """
  LiveView tests for the CSV activity import (#244).
  """

  use BankWeb.ConnCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Phoenix.LiveViewTest

  alias Bank.Activity
  alias Bank.Activity.ImportedActivity
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Repo

  setup :register_and_log_in_user

  @valid_csv """
  occurred_at,asset,chain,amount,direction,memo
  2026-04-01T12:00:00Z,USDC,base,100.50,inbound,payroll
  2026-04-02T12:00:00Z,USDC,base,25.00,outbound,vendor
  """

  @mixed_csv """
  occurred_at,asset,chain,amount,direction
  2026-04-01T12:00:00Z,USDC,base,100,inbound
  bad-datetime,USDC,base,5,inbound
  2026-04-02T12:00:00Z,USDC,base,-1,inbound
  """

  describe "initial render" do
    test "renders upload form with stable ids and no preview/result yet",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/activity/import")

      assert has_element?(view, "#activity-import-page-title")
      assert has_element?(view, "#activity-import-upload-card")
      assert has_element?(view, "#activity-import-form")
      # `live_file_input` renders its own auto-id; assert the
      # input's presence by `name="csv"` (the upload config key)
      # rather than a custom id we cannot override.
      assert has_element?(view, ~s|#activity-import-form input[type="file"][name="csv"]|)
      assert has_element?(view, "#activity-import-preview-submit")
      assert has_element?(view, "#activity-import-commit-submit[data-confirm]")

      refute has_element?(view, "#activity-import-preview")
      refute has_element?(view, "#activity-import-commit-result")
      refute has_element?(view, "#activity-import-parse-error")
    end
  end

  describe "preview" do
    test "valid CSV → preview card shows new=2 / duplicate=0 / invalid=0",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/activity/import")

      upload = upload_csv(view, @valid_csv)
      render_upload(upload, "input.csv")

      view |> form("#activity-import-form") |> render_submit()

      assert has_element?(view, ~s|#activity-import-preview[data-new="2"]|)
      assert has_element?(view, ~s|#activity-import-preview[data-duplicate="0"]|)
      assert has_element?(view, ~s|#activity-import-preview[data-invalid="0"]|)
      assert has_element?(view, "#activity-import-preview-no-invalid")
    end

    test "mixed CSV reports per-row error rows with stable ids",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/activity/import")

      upload = upload_csv(view, @mixed_csv)
      render_upload(upload, "input.csv")

      view |> form("#activity-import-form") |> render_submit()

      assert has_element?(view, ~s|#activity-import-preview[data-new="1"]|)
      assert has_element?(view, ~s|#activity-import-preview[data-invalid="2"]|)

      # Row 3 has the bad datetime; row 4 has the negative amount.
      assert has_element?(view, "#activity-import-invalid-row-3", "occurred_at")
      assert has_element?(view, "#activity-import-invalid-row-4", "non-negative")
    end

    test "preview is read-only: no rows persisted",
         %{conn: conn, workspace: ws} do
      {:ok, view, _html} = live(conn, "/activity/import")

      upload = upload_csv(view, @valid_csv)
      render_upload(upload, "input.csv")

      view |> form("#activity-import-form") |> render_submit()

      assert Activity.list_imported_activities(workspace_id: ws.id) == []
    end

    test "forbidden header (workspace_id) lands a parse-error card",
         %{conn: conn} do
      hostile = """
      occurred_at,asset,amount,direction,workspace_id
      2026-04-01T12:00:00Z,USDC,100,inbound,sibling-workspace-uuid
      """

      {:ok, view, _html} = live(conn, "/activity/import")

      upload = upload_csv(view, hostile)
      render_upload(upload, "input.csv")

      view |> form("#activity-import-form") |> render_submit()

      assert has_element?(view, "#activity-import-parse-error", "workspace_id")
      refute has_element?(view, "#activity-import-preview")
    end
  end

  describe "commit" do
    test "valid CSV → result card shows inserted=2 and rows persist",
         %{conn: conn, workspace: ws} do
      {:ok, view, _html} = live(conn, "/activity/import")

      upload = upload_csv(view, @valid_csv)
      render_upload(upload, "input.csv")

      view |> element("#activity-import-commit-submit") |> render_click()

      assert has_element?(view, ~s|#activity-import-commit-result[data-inserted="2"]|)
      assert has_element?(view, ~s|#activity-import-commit-result[data-duplicate="0"]|)
      assert has_element?(view, ~s|#activity-import-commit-result[data-invalid="0"]|)

      assert [_, _] = Activity.list_imported_activities(workspace_id: ws.id)
    end

    test "re-committing the same CSV is idempotent: 0 inserted, all duplicate",
         %{conn: conn, workspace: ws} do
      {:ok, view, _html} = live(conn, "/activity/import")

      # First commit.
      upload1 = upload_csv(view, @valid_csv)
      render_upload(upload1, "input.csv")
      view |> element("#activity-import-commit-submit") |> render_click()

      assert [_, _] = Activity.list_imported_activities(workspace_id: ws.id)

      # Second commit of the same body.
      upload2 = upload_csv(view, @valid_csv)
      render_upload(upload2, "input.csv")
      view |> element("#activity-import-commit-submit") |> render_click()

      assert has_element?(view, ~s|#activity-import-commit-result[data-inserted="0"]|)
      assert has_element?(view, ~s|#activity-import-commit-result[data-duplicate="2"]|)
      assert Repo.aggregate(ImportedActivity, :count, :id) == 2
    end

    test "mixed CSV → result card surfaces both inserted rows AND invalid rows",
         %{conn: conn, workspace: ws} do
      {:ok, view, _html} = live(conn, "/activity/import")

      upload = upload_csv(view, @mixed_csv)
      render_upload(upload, "input.csv")

      view |> element("#activity-import-commit-submit") |> render_click()

      assert has_element?(view, ~s|#activity-import-commit-result[data-inserted="1"]|)
      assert has_element?(view, ~s|#activity-import-commit-result[data-invalid="2"]|)
      assert has_element?(view, "#activity-import-result-invalid-row-3")
      assert has_element?(view, "#activity-import-result-invalid-row-4")

      # The one valid row is persisted; the invalid rows are not.
      assert [_] = Activity.list_imported_activities(workspace_id: ws.id)
    end

    test "import does NOT trigger execution: no ExecutionPlan / no Oban job",
         %{conn: conn} do
      before_plans = Repo.aggregate(ExecutionPlan, :count, :id)

      {:ok, view, _html} = live(conn, "/activity/import")

      upload = upload_csv(view, @valid_csv)
      render_upload(upload, "input.csv")

      view |> element("#activity-import-commit-submit") |> render_click()

      assert Repo.aggregate(ExecutionPlan, :count, :id) == before_plans
      assert all_enqueued() == []
    end
  end

  describe "cross-workspace isolation" do
    test "importing in workspace A does not appear in sibling workspace B",
         %{conn: conn, workspace: ws_a} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "csv-sib-#{System.unique_integer([:positive])}",
          name: "Sibling",
          mainnet_enabled: true
        })

      {:ok, view, _html} = live(conn, "/activity/import")

      upload = upload_csv(view, @valid_csv)
      render_upload(upload, "input.csv")
      view |> element("#activity-import-commit-submit") |> render_click()

      assert length(Activity.list_imported_activities(workspace_id: ws_a.id)) == 2
      assert Activity.list_imported_activities(workspace_id: ws_b.id) == []
    end
  end

  describe "secret hygiene" do
    test "CSV with secret-bearing unknown columns lands redacted metadata only",
         %{conn: conn, workspace: ws} do
      hostile_csv = """
      occurred_at,asset,amount,direction,Authorization,private_key,memo
      2026-04-01T12:00:00Z,USDC,100,inbound,Bearer LEAKED_PROBE,0xLEAKED_PROBE,ok
      """

      {:ok, view, _html} = live(conn, "/activity/import")

      upload = upload_csv(view, hostile_csv)
      render_upload(upload, "input.csv")
      view |> element("#activity-import-commit-submit") |> render_click()

      assert [row] = Activity.list_imported_activities(workspace_id: ws.id)
      assert row.metadata["authorization"] == "[REDACTED]"
      assert row.metadata["private_key"] == "[REDACTED]"
      refute inspect(row.metadata) =~ "LEAKED_PROBE"
    end
  end

  # --- preview → commit (#244 P2 regression) ---------------------------

  describe "preview → commit (#244 P2)" do
    test "after Preview, clicking Commit without re-uploading still imports",
         %{conn: conn, workspace: ws} do
      # Pre-fix: `consume_uploaded_entries/3` ran inside Preview
      # AND inside Commit. Preview drained the entry, so the
      # second (Commit) click hit `:empty` and the import never
      # ran. The cached `:csv_body` assign fixes the flow.
      {:ok, view, _html} = live(conn, "/activity/import")

      upload = upload_csv(view, @valid_csv)
      render_upload(upload, "input.csv")

      # Preview consumes the upload and stores the body in the
      # LiveView assigns. The preview card appears.
      view |> form("#activity-import-form") |> render_submit()
      assert has_element?(view, ~s|#activity-import-preview[data-new="2"]|)

      # Commit WITHOUT re-uploading. The cached body is reused.
      view |> element("#activity-import-commit-submit") |> render_click()

      assert has_element?(view, ~s|#activity-import-commit-result[data-inserted="2"]|)
      assert [_, _] = Activity.list_imported_activities(workspace_id: ws.id)

      # Side-effect contract preserved: still no execution.
      assert all_enqueued() == []
    end

    test "Clear after Preview lets a fresh upload preview again",
         %{conn: conn, workspace: ws} do
      {:ok, view, _html} = live(conn, "/activity/import")

      upload1 = upload_csv(view, @valid_csv)
      render_upload(upload1, "input.csv")
      view |> form("#activity-import-form") |> render_submit()
      assert has_element?(view, "#activity-import-preview")

      # Clear drops the cached CSV body and resets the preview /
      # commit / parse-error cards. A subsequent upload behaves
      # like a fresh session.
      view |> element("#activity-import-clear") |> render_click()
      refute has_element?(view, "#activity-import-preview")

      upload2 = upload_csv(view, @valid_csv)
      render_upload(upload2, "input.csv")
      view |> form("#activity-import-form") |> render_submit()
      assert has_element?(view, ~s|#activity-import-preview[data-new="2"]|)

      assert Activity.list_imported_activities(workspace_id: ws.id) == []
    end

    test "Commit clears the cached body so a re-click does not re-import",
         %{conn: conn, workspace: ws} do
      {:ok, view, _html} = live(conn, "/activity/import")

      upload = upload_csv(view, @valid_csv)
      render_upload(upload, "input.csv")

      view |> element("#activity-import-commit-submit") |> render_click()
      assert has_element?(view, ~s|#activity-import-commit-result[data-inserted="2"]|)
      assert [_, _] = Activity.list_imported_activities(workspace_id: ws.id)

      # Second click without a fresh upload: cached body is gone,
      # no upload entry remains, so the operator sees the
      # "Choose a CSV file first" flash. Critically, we do NOT
      # re-import the same body silently.
      _ = view |> element("#activity-import-commit-submit") |> render_click()
      assert Repo.aggregate(ImportedActivity, :count, :id) == 2
    end
  end

  # --- helpers ----------------------------------------------------------

  defp upload_csv(view, csv) do
    file_input(view, "#activity-import-form", :csv, [
      %{
        name: "input.csv",
        content: csv,
        type: "text/csv"
      }
    ])
  end
end
