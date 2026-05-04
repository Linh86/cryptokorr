defmodule BankWeb.ActivityImportLive do
  @moduledoc """
  CSV activity import LiveView (#244).

  Lets an operator upload a CSV file, preview the parsed rows
  classified as `:new` / `:duplicate` / `:invalid`, and commit
  the import. Workspace-scoped: every read/write goes through
  `current_scope.workspace.id`; the CSV body cannot supply a
  `workspace_id` (the parser's forbidden-columns guard rejects
  the upload outright).

  ## Read-only ledger contract

  The import path writes only to `imported_activities` via
  `Bank.Activity.create_imported_activity/1`. It does not mutate
  execution plans, enqueue Oban jobs, call the chain adapter,
  or create intents / decisions. Pinned by tests in
  `test/bank/activity/csv_import_test.exs` and the LiveView
  test in `test/bank_web/live/activity_import_live_test.exs`.

  ## Auth

  Mounts in the `:workspace_operator` `live_session` because
  importing writes new ledger rows. Viewer-tier users hit the
  existing redirect at the LiveView boundary.
  """

  use BankWeb, :live_view

  alias Bank.Activity.CsvImport

  @max_csv_bytes 5 * 1024 * 1024

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "CSV import")
     |> assign(:preview, nil)
     |> assign(:commit_result, nil)
     |> assign(:parse_error, nil)
     # Cache the consumed CSV binary so the preview→commit user
     # flow does not need a re-upload (#244 P2).
     # `consume_uploaded_entries/3` is one-shot — without this
     # cache the second `obtain_csv_body/1` call returns
     # `:empty` because the upload entries are already drained.
     # Cleared on successful commit and on the explicit Clear
     # button, so the operator can preview a fresh upload.
     |> assign(:csv_body, nil)
     |> allow_upload(:csv,
       accept: ~w(.csv),
       max_entries: 1,
       max_file_size: @max_csv_bytes
     )}
  end

  # --- Events -----------------------------------------------------------

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("preview", _params, socket) do
    case obtain_csv_body(socket) do
      {:ok, body, socket} ->
        workspace_id = socket.assigns.current_scope.workspace.id

        case CsvImport.preview(body, workspace_id) do
          {:ok, preview} ->
            {:noreply,
             socket
             |> assign(:preview, preview)
             |> assign(:commit_result, nil)
             |> assign(:parse_error, nil)
             |> put_flash(:info, "CSV parsed.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:preview, nil)
             |> assign(:commit_result, nil)
             |> assign(:parse_error, format_parse_error(reason))
             |> put_flash(:error, "CSV could not be parsed.")}
        end

      :empty ->
        {:noreply, put_flash(socket, :error, "Choose a CSV file first.")}
    end
  end

  def handle_event("commit", _params, socket) do
    case obtain_csv_body(socket) do
      {:ok, body, socket} ->
        workspace_id = socket.assigns.current_scope.workspace.id

        case CsvImport.commit(body, workspace_id) do
          {:ok, result} ->
            summary = result.summary

            {:noreply,
             socket
             |> assign(:preview, nil)
             |> assign(:commit_result, result)
             |> assign(:parse_error, nil)
             # Drop the cached body after a successful commit so a
             # subsequent unrelated upload starts fresh. Without
             # this, clicking Commit again would replay the same
             # file as duplicates.
             |> assign(:csv_body, nil)
             |> put_flash(
               :info,
               "Imported #{summary.inserted}, skipped #{summary.duplicate} duplicate(s), #{summary.invalid} invalid row(s)."
             )}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:preview, nil)
             |> assign(:commit_result, nil)
             |> assign(:parse_error, format_parse_error(reason))
             |> put_flash(:error, "CSV could not be imported.")}
        end

      :empty ->
        {:noreply, put_flash(socket, :error, "Choose a CSV file first.")}
    end
  end

  def handle_event("clear", _params, socket) do
    {:noreply,
     socket
     |> assign(:preview, nil)
     |> assign(:commit_result, nil)
     |> assign(:parse_error, nil)
     |> assign(:csv_body, nil)}
  end

  # --- Render -----------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_page={:activity_import}>
      <div class="flex items-center justify-between mb-8">
        <div>
          <h1 id="activity-import-page-title" class="text-2xl font-bold tracking-tight">
            CSV activity import
          </h1>
          <p class="mt-1 text-sm text-base-content/60">
            Upload a CSV of bank or wallet activity. Preview lands rows in
            <span class="font-mono">imported_activities</span>
            for this workspace only — no execution is triggered.
          </p>
        </div>
      </div>

      <section
        id="activity-import-upload-card"
        class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
      >
        <header class="px-6 py-4 border-b border-base-300">
          <h2 class="text-sm font-semibold flex items-center gap-1.5">
            <.icon name="hero-arrow-up-tray" class="size-4" /> Upload CSV
          </h2>
        </header>

        <form
          id="activity-import-form"
          phx-submit="preview"
          phx-change="validate"
          class="px-6 py-4 space-y-3"
        >
          <.live_file_input upload={@uploads.csv} />

          <div class="flex items-center gap-2">
            <.button
              id="activity-import-preview-submit"
              type="submit"
              class="btn btn-primary btn-sm gap-1.5"
            >
              <.icon name="hero-eye" class="size-3.5" /> Preview
            </.button>
            <.button
              id="activity-import-commit-submit"
              type="button"
              phx-click="commit"
              data-confirm="Import these CSV rows? Imported activity is read-only ledger data and cannot trigger execution."
              class="btn btn-success btn-soft btn-sm gap-1.5"
            >
              <.icon name="hero-check" class="size-3.5" /> Commit import
            </.button>
            <.button
              id="activity-import-clear"
              type="button"
              phx-click="clear"
              class="btn btn-ghost btn-sm gap-1.5"
            >
              <.icon name="hero-x-mark" class="size-3.5" /> Clear
            </.button>
          </div>

          <p class="text-xs text-base-content/40">
            Max 5 MB. Required headers:
            <span class="font-mono">occurred_at, asset, amount, direction</span>
            . Unknown columns are preserved (with secret-bearing keys redacted).
          </p>
        </form>
      </section>

      <%!-- Preview state --%>
      <section
        :if={@preview}
        id="activity-import-preview"
        data-new={@preview.summary.new}
        data-duplicate={@preview.summary.duplicate}
        data-invalid={@preview.summary.invalid}
        class="mt-6 rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
      >
        <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
          <h2 class="text-sm font-semibold flex items-center gap-1.5">
            <.icon name="hero-clipboard-document-list" class="size-4" /> Preview
          </h2>
          <div class="flex items-center gap-2 text-xs font-mono">
            <span id="activity-import-preview-new" class="badge badge-sm badge-info">
              {@preview.summary.new} new
            </span>
            <span id="activity-import-preview-duplicate" class="badge badge-sm badge-ghost">
              {@preview.summary.duplicate} duplicate
            </span>
            <span id="activity-import-preview-invalid" class="badge badge-sm badge-error">
              {@preview.summary.invalid} invalid
            </span>
          </div>
        </header>

        <ul
          :if={@preview.invalid != []}
          id="activity-import-preview-invalid-list"
          class="divide-y divide-base-300"
        >
          <li
            :for={row <- @preview.invalid}
            id={"activity-import-invalid-row-#{row.row}"}
            class="px-6 py-3 text-xs"
          >
            <span class="font-mono text-error">row {row.row}</span>:
            <span class="text-base-content/70">{Enum.join(row.errors, "; ")}</span>
          </li>
        </ul>

        <p
          :if={@preview.invalid == []}
          id="activity-import-preview-no-invalid"
          class="px-6 py-3 text-xs text-base-content/40"
        >
          No invalid rows.
        </p>
      </section>

      <%!-- Commit result --%>
      <section
        :if={@commit_result}
        id="activity-import-commit-result"
        data-inserted={@commit_result.summary.inserted}
        data-duplicate={@commit_result.summary.duplicate}
        data-invalid={@commit_result.summary.invalid}
        class="mt-6 rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
      >
        <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
          <h2 class="text-sm font-semibold flex items-center gap-1.5">
            <.icon name="hero-check-badge" class="size-4" /> Import result
          </h2>
          <div class="flex items-center gap-2 text-xs font-mono">
            <span id="activity-import-result-inserted" class="badge badge-sm badge-success">
              {@commit_result.summary.inserted} inserted
            </span>
            <span id="activity-import-result-duplicate" class="badge badge-sm badge-ghost">
              {@commit_result.summary.duplicate} duplicate
            </span>
            <span id="activity-import-result-invalid" class="badge badge-sm badge-error">
              {@commit_result.summary.invalid} invalid
            </span>
          </div>
        </header>

        <ul
          :if={@commit_result.invalid != []}
          id="activity-import-result-invalid-list"
          class="divide-y divide-base-300"
        >
          <li
            :for={row <- @commit_result.invalid}
            id={"activity-import-result-invalid-row-#{row.row}"}
            class="px-6 py-3 text-xs"
          >
            <span class="font-mono text-error">row {row.row}</span>:
            <span class="text-base-content/70">{Enum.join(row.errors, "; ")}</span>
          </li>
        </ul>
      </section>

      <%!-- Parse-time error (e.g. forbidden header / missing required column) --%>
      <section
        :if={@parse_error}
        id="activity-import-parse-error"
        class="mt-6 rounded-xl border border-error/40 bg-error/5 px-6 py-4 text-sm"
      >
        <p class="font-mono">{@parse_error}</p>
      </section>
    </Layouts.app>
    """
  end

  # --- Helpers ----------------------------------------------------------

  # Returns the CSV body to operate on, plus the (possibly
  # cache-updated) socket. Three cases, in order:
  #
  #   1. A previous Preview already consumed and cached the
  #      body in `:csv_body` — reuse it. This is the
  #      preview→commit flow that the #244 P2 ships:
  #      `consume_uploaded_entries/3` is one-shot, so without
  #      caching the second click would hit `:empty`.
  #   2. An upload entry is pending (direct Commit without
  #      Preview, or a fresh upload after Clear) — consume it
  #      once and cache the binary.
  #   3. Nothing to operate on — return `:empty`.
  defp obtain_csv_body(socket) do
    cond do
      is_binary(socket.assigns[:csv_body]) ->
        {:ok, socket.assigns.csv_body, socket}

      socket.assigns.uploads.csv.entries != [] ->
        case consume_uploaded_entries(socket, :csv, fn %{path: path}, _entry ->
               {:ok, File.read!(path)}
             end) do
          [body] when is_binary(body) ->
            {:ok, body, assign(socket, :csv_body, body)}

          _ ->
            :empty
        end

      true ->
        :empty
    end
  end

  defp format_parse_error(:empty), do: "CSV is empty."
  defp format_parse_error(:missing_header), do: "CSV is missing a header row."

  defp format_parse_error(:missing_required_column),
    do: "CSV header is missing one of: occurred_at, asset, amount, direction."

  defp format_parse_error({:forbidden_column, name}),
    do: "CSV header carries a forbidden column: \"#{name}\"."

  defp format_parse_error(other), do: "CSV could not be parsed: #{inspect(other)}"
end
