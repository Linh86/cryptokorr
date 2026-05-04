defmodule Bank.Decisions.ReportExport do
  @moduledoc """
  Decision report export artifact builder (#250).

  Wraps a `%Bank.Decisions.Report{}` (#248) rendered through
  `Bank.Decisions.ReportMarkdown.render/1` (#249) into a downloadable
  Markdown artifact. Every artifact carries:

    * a stable, safe filename derived from the intent id and a
      truncated body hash (no operator-supplied text — never any
      free-text reason, target description, or other untrusted
      input goes into the filename);
    * an HTML-comment metadata block at the top of the body
      naming the schema version, intent / workspace ids, the
      report's own `version`, the `generated_at` timestamp, and
      the SHA-256 hex digest of the rendered Markdown body;
    * the `Bank.Decisions.ReportMarkdown.render/1` output
      verbatim below the metadata block.

  ## PDF support — explicitly deferred

  The #250 issue body permits Markdown if "rendering PDF falls
  back to Markdown if chosen". v0.1 ships Markdown only:

    * adding a PDF dependency (`Pdf`, `wkhtmltopdf`, or a headless
      browser) widens the binary attack surface and the
      operational footprint without unlocking any acceptance
      criterion the issue actually requires;
    * Markdown is plain text — no font, image, or layout engine
      to leak data through;
    * Markdown is the contract `Bank.Decisions.ReportMarkdown`
      already commits to (deterministic, secret-redacted,
      replay-derived).

  When a future issue actually needs a PDF (e.g. compliance attest
  packet), the renderer can be added under
  `Bank.Decisions.ReportPdf` and `build/2` can grow a `:format`
  option — without changing the metadata-block contract this
  module establishes.

  ## Determinism

  The rendered Markdown body is byte-stable for the same input
  (proven by `Bank.Decisions.ReportMarkdownTest`). The metadata
  block is byte-stable for the same `(report, generated_at)`
  pair: pass `:generated_at` explicitly to lock determinism for
  audit-replay tests, or omit it to use `DateTime.utc_now/0`.
  Either way the `body_sha256` digest covers ONLY the rendered
  Markdown, not the metadata header — so two artifacts produced
  at different `generated_at` instants for the same report carry
  identical `body_sha256` values, which is what an auditor
  cross-checking the artifact wants.

  ## Secret hygiene

  This module never reads any field the
  `%Bank.Decisions.Report{}` struct does not expose. The
  metadata block contains only:

    * the schema version (constant);
    * the report version (constant per Report module);
    * `intent_id` and `workspace_id` from `report.generated_from`
      (UUIDs — opaque, non-PII);
    * the `generated_at` timestamp (request-time, not data-derived);
    * the `body_sha256` digest of the rendered body.

  No filename component, header field, or response header carries
  a value that could come from operator free-text input.
  """

  alias Bank.Decisions.{Report, ReportMarkdown}

  @schema_version "1"
  @media_type "text/markdown; charset=utf-8"

  @typedoc """
  An export artifact ready to send over HTTP or write to disk.
  """
  @type t :: %{
          filename: String.t(),
          body: String.t(),
          body_hash: String.t(),
          generated_at: String.t(),
          content_type: String.t(),
          schema_version: String.t()
        }

  @doc """
  Build a Markdown export artifact from a `%Report{}` struct.

  Options:

    * `:generated_at` — `DateTime.t()` or ISO8601 binary used in
      the metadata block. Defaults to `DateTime.utc_now/0`. Pass
      a fixed value in tests to make the artifact byte-stable.
  """
  @spec build(Report.t(), keyword()) :: t()
  def build(%Report{} = report, opts \\ []) do
    md_body = ReportMarkdown.render(report)
    body_hash = sha256_hex(md_body)
    generated_at = generated_at_iso(Keyword.get(opts, :generated_at))

    %{
      filename: build_filename(report, body_hash),
      body: wrap(report, md_body, body_hash, generated_at),
      body_hash: body_hash,
      generated_at: generated_at,
      content_type: @media_type,
      schema_version: @schema_version
    }
  end

  @doc """
  Returns the static media type used for every export artifact.
  Useful for callers that want to set Content-Type without
  building the full artifact (e.g. OpenAPI specs, documentation).
  """
  @spec media_type() :: String.t()
  def media_type, do: @media_type

  @doc """
  Returns the static schema version of the export envelope.
  Bumped when the metadata block format changes.
  """
  @spec schema_version() :: String.t()
  def schema_version, do: @schema_version

  # --- internals ----------------------------------------------------------

  defp wrap(report, md_body, body_hash, generated_at) do
    intent_id = Map.get(report.generated_from, :intent_id) || "(unknown)"
    workspace_id = Map.get(report.generated_from, :workspace_id) || "(unscoped)"

    """
    <!--
    decision-report-export
    schema_version: #{@schema_version}
    report_version: #{report.version}
    intent_id: #{intent_id}
    workspace_id: #{workspace_id}
    generated_at: #{generated_at}
    body_sha256: #{body_hash}
    -->

    """ <> md_body
  end

  defp build_filename(%Report{generated_from: gf}, body_hash) do
    intent_short = gf |> Map.get(:intent_id, "") |> safe_id_slice(8)
    hash_short = String.slice(body_hash, 0, 12)
    "decision-report-#{intent_short}-#{hash_short}.md"
  end

  # The intent id is a server-issued UUID, so this is belt-and-
  # braces: strip everything that isn't a hex character / dash so a
  # corrupted or non-UUID id can never inject a path separator,
  # quote, or shell metacharacter into the filename.
  defp safe_id_slice(nil, _take), do: "unknown"
  defp safe_id_slice("", _take), do: "unknown"

  defp safe_id_slice(value, take) when is_binary(value) do
    cleaned =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-f0-9-]/, "")

    case String.slice(cleaned, 0, take) do
      "" -> "unknown"
      slice -> slice
    end
  end

  defp safe_id_slice(_, _), do: "unknown"

  defp sha256_hex(s) when is_binary(s) do
    :crypto.hash(:sha256, s) |> Base.encode16(case: :lower)
  end

  defp generated_at_iso(nil), do: DateTime.utc_now() |> DateTime.to_iso8601()
  defp generated_at_iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp generated_at_iso(iso) when is_binary(iso), do: iso
end
