defmodule BankWeb.DecisionReportDownloadController do
  @moduledoc """
  Browser-session-authenticated download of the deterministic
  decision report Markdown artifact (#251 P2).

  The `:api_authenticated` `/v1/intents/:id/report` endpoint
  (#250) requires an `Authorization: Bearer cb_...` header, so a
  logged-in LiveView viewer/operator clicking a browser anchor at
  `/v1/...` does not send credentials and gets `401`. This
  controller is the browser-session counterpart: same artifact,
  same workspace gate, but authenticated via the session cookie
  populated by `BankWeb.Plugs.FetchCurrentUser` on the `:browser`
  pipeline.

  The two routes deliberately live side-by-side so neither
  surface needs dual-auth complexity:

    * `/v1/intents/:id/report` — API-key viewer-readable download
      for SDK / cURL / CI clients (`#250`).
    * `/audit/replay/:intent_id/report` — browser-session
      viewer-readable download for the operator console (`#251`,
      this module).

  ## Auth + workspace scope

  Mounted on the `:browser` pipeline. The session is populated by
  `BankWeb.Plugs.FetchCurrentUser` (`conn.assigns.current_scope`
  carries `user`, `workspace`, `membership`, `role`).

    * Anonymous → redirect to `/login` (matches the rest of the
      browser console).
    * Authenticated but no resolved workspace → redirect to
      `/pending`.
    * Role below `:viewer` → redirect to `/unauthorized`.
    * Cross-workspace intent id → redirect to `/audit` with a
      `not found` flash, mirroring `BankWeb.IntentReplayLive`'s
      mount-time guard. This collapses cross-workspace ids to
      not-found so the response cannot confirm a sibling tenant
      row exists.

  ## Read-only

  No row is mutated, no Oban job is enqueued, no chain adapter is
  called, no broadcast is fired. The report body is built from a
  pure read-only `Bank.Audit.replay/1` bundle plus the
  deterministic `Bank.Decisions.Report` / `ReportExport` modules.

  ## Format

  Returns `text/markdown; charset=utf-8` with
  `Content-Disposition: attachment; filename="..."`. The artifact
  body and `body_sha256` digest are byte-stable for the same
  intent's replay bundle (proven by `Bank.Decisions.ReportTest`,
  `ReportMarkdownTest`, and `ReportExportTest`).
  """

  use BankWeb, :controller

  alias Bank.Audit
  alias Bank.Decisions.{Report, ReportExport}
  alias Bank.Intents
  alias Bank.Workspaces.Membership

  def show(conn, %{"intent_id" => intent_id}) do
    with :ok <- require_authenticated_viewer(conn),
         {:ok, uuid} <- cast_uuid(intent_id),
         workspace_id = conn.assigns.current_scope.workspace.id,
         %_{} = intent <- Intents.get_in_workspace(uuid, workspace_id),
         {:ok, bundle} <- Audit.replay(intent.id) do
      artifact = bundle |> Report.from_bundle() |> ReportExport.build()

      conn
      |> put_resp_header("content-type", artifact.content_type)
      |> put_resp_header("content-disposition", attachment_header(artifact.filename))
      |> put_resp_header("x-decision-report-hash", "sha256:" <> artifact.body_hash)
      |> put_resp_header("x-decision-report-generated-at", artifact.generated_at)
      |> put_resp_header("x-decision-report-schema-version", artifact.schema_version)
      |> send_resp(200, artifact.body)
    else
      {:redirect, path, flash} ->
        conn
        |> put_flash(:error, flash)
        |> redirect(to: path)

      {:redirect, path} ->
        redirect(conn, to: path)

      :error ->
        not_found_redirect(conn, intent_id)

      nil ->
        not_found_redirect(conn, intent_id)

      {:error, :not_found} ->
        not_found_redirect(conn, intent_id)
    end
  end

  defp require_authenticated_viewer(conn) do
    case conn.assigns[:current_scope] do
      nil ->
        {:redirect, "/login"}

      %{user: nil} ->
        {:redirect, "/login"}

      %{workspace: nil} ->
        {:redirect, "/pending"}

      %{role: role} ->
        if Membership.role_at_least?(role, :viewer) do
          :ok
        else
          {:redirect, "/unauthorized"}
        end
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp cast_uuid(_), do: :error

  # Cross-workspace and missing-id collapse to the same redirect so
  # the response cannot confirm a row exists in a sibling tenant.
  # Mirrors `BankWeb.IntentReplayLive`'s mount-time pattern.
  defp not_found_redirect(conn, intent_id) do
    short = intent_id |> to_string() |> String.slice(0, 8)

    conn
    |> put_flash(:error, "Intent #{short} not found")
    |> redirect(to: "/audit")
  end

  # The filename is built from the intent UUID and a SHA-256 hex
  # slice — both restricted to `[a-f0-9-]`. Wrapping in double
  # quotes is defence in depth so a future change to the filename
  # builder cannot inject a header break.
  defp attachment_header(filename) do
    ~s|attachment; filename="#{filename}"|
  end
end
