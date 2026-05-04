defmodule BankWeb.API.V1.DecisionReportController do
  @moduledoc """
  `/v1/intents/:id/report` — download a deterministic decision-report
  Markdown artifact for an intent (#250).

  Composes the deterministic Report model (#248) with the Markdown
  renderer (#249) and the export wrapper (`Bank.Decisions.ReportExport`)
  to return a workspace-scoped, audit-friendly attachment.

  ## Auth / scope

  Viewer-readable. Mounted on `:api_authenticated` (no role gate
  beyond verified API key + valid workspace). Mirrors the
  `/v1/intents/:id/replay` access policy: anything a viewer is
  allowed to replay, they are allowed to download as a report
  artifact, because the report is a strict projection of the
  replay bundle.

  Cross-workspace requests collapse to `404 not_found` rather than
  `403 forbidden` so the response cannot confirm a row exists in a
  sibling tenant (#159b).

  ## Read-only

  No row is mutated, no Oban job is enqueued, no chain adapter is
  called, no broadcast is fired. The report is built from a
  read-only `Bank.Audit.replay/1` bundle and the renderer + export
  modules are pure functions over their inputs.

  ## Format

  Always returns `text/markdown; charset=utf-8` with
  `Content-Disposition: attachment; filename="..."`. The artifact
  body and `body_sha256` digest are byte-stable for the same
  intent's replay bundle (proven by `Bank.Decisions.ReportTest`,
  `Bank.Decisions.ReportMarkdownTest`, and
  `Bank.Decisions.ReportExportTest`).

  ## Out of scope

  UI access (#251), file-export of formats other than Markdown,
  bulk export, scheduled / signed download URLs.
  """

  use BankWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Bank.Audit
  alias Bank.Decisions.{Report, ReportExport}
  alias Bank.Intents
  alias OpenApiSpex.{Parameter, Reference}

  @id_ref %Reference{"$ref": "#/components/schemas/Id"}
  @request_id_in_ref %Reference{"$ref": "#/components/parameters/RequestIdIn"}
  @unauthorized_ref %Reference{"$ref": "#/components/responses/Unauthorized"}
  @too_many_requests_ref %Reference{"$ref": "#/components/responses/TooManyRequests"}
  @not_found_ref %Reference{"$ref": "#/components/responses/NotFound"}

  @intent_id_param %Parameter{
    name: :id,
    in: :path,
    required: true,
    description: "Opaque runtime-assigned agent intent id (UUID).",
    schema: @id_ref
  }

  operation(:show,
    summary: "Download decision report Markdown artifact",
    description: """
    Returns a deterministic Markdown decision report for the given
    intent, wrapped with a metadata block (`schema_version`,
    `report_version`, `intent_id`, `workspace_id`, `generated_at`,
    `body_sha256`). The artifact is the canonical
    `Bank.Decisions.Report` (#248) rendered via
    `Bank.Decisions.ReportMarkdown` (#249) and wrapped via
    `Bank.Decisions.ReportExport` (#250).

    The response sets `Content-Disposition: attachment;
    filename="decision-report-<intent>-<hash>.md"` for browser /
    cURL download. The same intent's replay bundle always produces
    the same Markdown body and the same `body_sha256` digest, so
    the artifact is suitable for audit cross-checks.

    Workspace-scoped: cross-workspace intent ids collapse to 404.
    Viewer-readable.
    """,
    tags: ["Decisions"],
    parameters: [@intent_id_param, @request_id_in_ref],
    responses: %{
      200 =>
        {"Decision report Markdown artifact", "text/markdown",
         %OpenApiSpex.Schema{
           type: :string,
           description: "Markdown body with HTML-comment metadata block at the top"
         }},
      401 => @unauthorized_ref,
      429 => @too_many_requests_ref,
      404 => @not_found_ref
    }
  )

  def show(conn, %{"id" => id}) do
    workspace_id = conn.assigns.current_scope.workspace.id

    with {:ok, intent_id} <- cast_uuid(id),
         intent when not is_nil(intent) <- Intents.get_in_workspace(intent_id, workspace_id),
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
      :error -> render_not_found(conn, id)
      nil -> render_not_found(conn, id)
      {:error, :not_found} -> render_not_found(conn, id)
    end
  end

  defp cast_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> :error
    end
  end

  defp cast_uuid(_), do: :error

  defp render_not_found(conn, intent_id) do
    conn
    |> put_status(:not_found)
    |> json(%{
      error: %{
        code: "not_found",
        message: "no intent with id=#{intent_id}",
        hint: "check the intent id or confirm the intent still exists",
        retryable: false
      }
    })
  end

  # The filename is built from the intent UUID and a SHA-256 hex
  # slice — both restricted to `[a-f0-9-]`. Wrapping in double
  # quotes is defence in depth so a future change to the filename
  # builder cannot inject a header break.
  defp attachment_header(filename) do
    ~s|attachment; filename="#{filename}"|
  end
end
