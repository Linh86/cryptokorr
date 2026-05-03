defmodule Bank.Activity.CsvImport do
  @moduledoc """
  CSV activity import for #244.

  Parses an MVP CSV format into rows ready for the read-only
  `Bank.Activity` ledger. Provides three pure entry points:

    * `parse/1` — turn a CSV binary into `{:ok, rows} |
      {:error, reason}`. Pure: no DB calls.
    * `preview/2` — parse + classify each row against an
      existing workspace ledger without inserting. Returns
      `%{new: [...], duplicate: [...], invalid: [...], summary:
      %{...}}`. Reads through `Bank.Activity.get_by_dedupe_key/2`
      to detect duplicates.
    * `commit/2` — preview, then insert each "new" row via
      `Bank.Activity.create_imported_activity/1`. Returns the
      same shape as `preview/2`, with rows replaced by the
      persisted `%ImportedActivity{}` structs and a per-row
      duplicate / invalid breakdown.

  All three are workspace-scoped at the API surface — callers
  pass `workspace_id` explicitly, never derived from the CSV
  body. The parser refuses any field named `workspace_id` /
  `dedupe_key` / `id` so a hostile CSV cannot retarget the
  insert at a sibling tenant or override the dedupe key.

  ## MVP schema

  The first non-blank line is the header row. Recognised columns
  (case-insensitive, snake-cased on read):

    * `occurred_at` — ISO-8601 datetime, REQUIRED.
    * `asset` — REQUIRED.
    * `chain` — optional.
    * `amount` — decimal, REQUIRED, non-negative (sign carried
      in `direction`).
    * `direction` — `inbound | outbound`, REQUIRED.
    * `from_address` — optional.
    * `to_address` — optional.
    * `tx_hash` — optional.
    * `bank_ref` — optional.
    * `status` — `confirmed | pending | failed | imported`,
      optional, default `imported`.
    * `provenance` — optional, free-form.
    * `confidence` — `high | medium | low`, optional, default
      `medium`.

  Any header outside this allowlist is preserved verbatim into
  the row's `metadata` map (with the value redacted by the
  ledger context's secret-key allowlist). The fixed column set
  keeps the surface tight for v1; mapping UI is deferred.

  ## Read-only ledger contract

  This module never mutates execution plans, enqueues Oban jobs,
  calls the chain adapter, or creates intents / decisions.
  `commit/2` writes only to `imported_activities` via
  `Bank.Activity.create_imported_activity/1`, which the #243
  tests already pin as side-effect-free.
  """

  alias Bank.Activity
  alias Bank.Activity.ImportedActivity

  @typedoc "Outcome of `commit/2` for a single CSV row."
  @type commit_outcome ::
          {:inserted, ImportedActivity.t()}
          | {:duplicate, ImportedActivity.t()}
          | {:invalid, %{row: pos_integer(), errors: [String.t()], raw: map()}}

  @recognised_columns ~w(
    occurred_at
    asset
    chain
    amount
    direction
    from_address
    to_address
    tx_hash
    bank_ref
    status
    provenance
    confidence
    counterparty_id
  )

  # Headers we forbid the CSV from supplying. They are owned by
  # the context (workspace boundary, dedupe identity) and a
  # CSV-supplied value would either be redundant (id collision)
  # or actively dangerous (cross-workspace retargeting).
  @forbidden_columns ~w(workspace_id dedupe_key id source_type)

  @directions ~w(inbound outbound)
  @statuses ~w(confirmed pending failed imported)
  @confidences ~w(high medium low)

  # --- Public API --------------------------------------------------------

  @doc """
  Parse a CSV binary into a list of normalised row maps. Returns
  `{:ok, rows}` where every row is a map of recognised fields
  plus an `unknown_fields` map, OR `{:error, reason}` when the
  CSV is structurally invalid (missing header, no required
  columns, forbidden column present).

  Per-row errors are surfaced inside each row map's `:errors`
  list — they do NOT cause `parse/1` to fail. Callers iterate
  and route invalid rows to the error report.
  """
  @spec parse(binary()) :: {:ok, [map()]} | {:error, atom() | {atom(), term()}}
  def parse(csv) when is_binary(csv) do
    with {:ok, lines} <- split_lines(csv),
         {:ok, header, body} <- split_header(lines),
         :ok <- validate_header(header) do
      rows =
        body
        |> Enum.with_index(2)
        |> Enum.map(fn {line, row_number} ->
          parse_row(line, header, row_number)
        end)

      {:ok, rows}
    end
  end

  def parse(_), do: {:error, :not_a_binary}

  @doc """
  Parse the CSV and classify each row against the workspace's
  existing ledger. Pure function: no DB writes.

  Returns:

      %{
        new: [row, ...],          # passed validation, no dup
        duplicate: [%{row: r, existing: %ImportedActivity{}}, ...],
        invalid: [%{row: ..., errors: [...], raw: %{}}, ...],
        summary: %{new: n, duplicate: n, invalid: n}
      }
  """
  @spec preview(binary(), String.t()) ::
          {:ok, map()} | {:error, atom() | {atom(), term()}}
  def preview(csv, workspace_id) when is_binary(workspace_id) do
    with {:ok, rows} <- parse(csv) do
      {invalid, candidates} =
        Enum.split_with(rows, fn row -> row.errors != [] end)

      {duplicate, new} =
        Enum.split_with(candidates, fn row ->
          Activity.get_by_dedupe_key(workspace_id, row.dedupe_key)
        end)

      duplicate =
        Enum.map(duplicate, fn row ->
          %{
            row: row.row,
            existing: Activity.get_by_dedupe_key(workspace_id, row.dedupe_key),
            attrs: row.attrs
          }
        end)

      invalid =
        Enum.map(invalid, fn row ->
          %{row: row.row, errors: row.errors, raw: row.raw}
        end)

      {:ok,
       %{
         new: new,
         duplicate: duplicate,
         invalid: invalid,
         summary: %{
           new: length(new),
           duplicate: length(duplicate),
           invalid: length(invalid)
         }
       }}
    end
  end

  def preview(_csv, _workspace_id), do: {:error, :invalid_workspace}

  @doc """
  Run a full import: parse → classify → insert each "new" row
  via `Bank.Activity.create_imported_activity/1`. Returns the
  same shape as `preview/2`, with `:new` replaced by `:inserted`
  carrying the persisted `%ImportedActivity{}` structs.

  No `Repo.transaction/1` wrapping the whole import: each row
  is its own insert, so a partial failure leaves the successful
  rows persisted (which matches the import-job semantics — the
  acceptance criterion is "Bad rows are reported, not silently
  dropped", not "all-or-nothing").
  """
  @spec commit(binary(), String.t()) ::
          {:ok, map()} | {:error, atom() | {atom(), term()}}
  def commit(csv, workspace_id) when is_binary(workspace_id) do
    with {:ok, preview} <- preview(csv, workspace_id) do
      {inserted, failed} =
        preview.new
        |> Enum.map(&insert_one(&1, workspace_id))
        |> Enum.split_with(fn
          {:inserted, _} -> true
          {:duplicate, _} -> true
          _ -> false
        end)

      {inserted_rows, dup_rows} =
        Enum.split_with(inserted, &match?({:inserted, _}, &1))

      inserted_records = Enum.map(inserted_rows, fn {:inserted, r} -> r end)

      dup_records =
        Enum.map(dup_rows, fn {:duplicate, r} -> %{existing: r, source: :race} end)

      invalid =
        preview.invalid ++
          Enum.map(failed, fn {:invalid, info} -> info end)

      summary = %{
        inserted: length(inserted_records),
        duplicate: length(preview.duplicate) + length(dup_records),
        invalid: length(invalid)
      }

      {:ok,
       %{
         inserted: inserted_records,
         duplicate: preview.duplicate ++ dup_records,
         invalid: invalid,
         summary: summary
       }}
    end
  end

  def commit(_csv, _workspace_id), do: {:error, :invalid_workspace}

  # --- Parsing internals -------------------------------------------------

  defp split_lines(csv) do
    lines =
      csv
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.reject(&(&1 == ""))

    if lines == [], do: {:error, :empty}, else: {:ok, lines}
  end

  defp split_header([header | rest]), do: {:ok, header, rest}
  defp split_header(_), do: {:error, :missing_header}

  defp validate_header(header) do
    columns = parse_csv_line(header) |> Enum.map(&normalise_column/1)

    forbidden = Enum.filter(columns, &(&1 in @forbidden_columns))

    cond do
      forbidden != [] ->
        {:error, {:forbidden_column, hd(forbidden)}}

      not Enum.all?(["occurred_at", "asset", "amount", "direction"], &(&1 in columns)) ->
        {:error, :missing_required_column}

      true ->
        :ok
    end
  end

  defp parse_row(line, header_line, row_number) do
    headers = parse_csv_line(header_line) |> Enum.map(&normalise_column/1)
    values = parse_csv_line(line)
    raw = headers |> Enum.zip(values) |> Map.new()

    {recognised, unknown} =
      Enum.split_with(raw, fn {k, _} -> k in @recognised_columns end)

    recognised = Map.new(recognised)
    unknown_metadata = Activity.redact_metadata(Map.new(unknown))

    case build_attrs(recognised, unknown_metadata, row_number) do
      {:ok, attrs} ->
        dedupe_key = compute_row_dedupe_key(attrs, row_number)
        attrs = Map.put(attrs, :dedupe_key, dedupe_key)

        %{
          row: row_number,
          raw: raw,
          attrs: attrs,
          dedupe_key: dedupe_key,
          errors: []
        }

      {:error, errors} ->
        %{
          row: row_number,
          raw: raw,
          attrs: nil,
          dedupe_key: nil,
          errors: errors
        }
    end
  end

  defp build_attrs(recognised, unknown_metadata, row_number) do
    with {:ok, occurred_at} <-
           parse_datetime(recognised["occurred_at"], "occurred_at"),
         {:ok, amount} <- parse_amount(recognised["amount"]),
         {:ok, direction} <- parse_enum(recognised["direction"], "direction", @directions),
         {:ok, status} <-
           parse_enum_optional(recognised["status"], "status", @statuses, "imported"),
         {:ok, confidence} <-
           parse_enum_optional(recognised["confidence"], "confidence", @confidences, "medium"),
         {:ok, asset} <- presence(recognised["asset"], "asset") do
      {:ok,
       %{
         source_type: :csv,
         source_hash: source_hash_for(recognised, unknown_metadata),
         source_ref: "csv:row:#{row_number}",
         occurred_at: occurred_at,
         asset: asset,
         chain: blank_to_nil(recognised["chain"]),
         amount: amount,
         direction: direction,
         from_address: blank_to_nil(recognised["from_address"]),
         to_address: blank_to_nil(recognised["to_address"]),
         tx_hash: blank_to_nil(recognised["tx_hash"]),
         bank_ref: blank_to_nil(recognised["bank_ref"]),
         status: status,
         provenance: blank_to_nil(recognised["provenance"]),
         confidence: confidence,
         counterparty_id: blank_to_nil(recognised["counterparty_id"]),
         metadata: unknown_metadata
       }}
    else
      {:error, msg} -> {:error, [msg]}
    end
  end

  defp insert_one(row, workspace_id) do
    attrs = Map.put(row.attrs, :workspace_id, workspace_id)

    case Activity.create_imported_activity(attrs) do
      {:ok, :inserted, record} ->
        {:inserted, record}

      {:ok, :duplicate, existing} ->
        {:duplicate, existing}

      {:error, %Ecto.Changeset{} = cs} ->
        {:invalid,
         %{
           row: row.row,
           errors: cs.errors |> Enum.map(fn {k, {m, _}} -> "#{k}: #{m}" end),
           raw: row.raw
         }}
    end
  end

  # --- Helpers ------------------------------------------------------------

  defp parse_csv_line(line) do
    # Minimal CSV parser: comma-separated, optional double-quote
    # wrapping with `""` as the quoted-quote escape. No multi-line
    # cells. Adequate for the MVP CSV format; mapping UI / mapping
    # rules ship in a follow-up.
    line
    |> String.to_charlist()
    |> parse_csv_chars([], [], false)
    |> Enum.reverse()
    |> Enum.map(&String.trim/1)
  end

  defp parse_csv_chars([], cur, acc, _in_quotes) do
    [List.to_string(Enum.reverse(cur)) | acc]
  end

  defp parse_csv_chars([?, | rest], cur, acc, false) do
    parse_csv_chars(rest, [], [List.to_string(Enum.reverse(cur)) | acc], false)
  end

  defp parse_csv_chars([?" | rest], cur, acc, false) when cur == [] do
    parse_csv_chars(rest, cur, acc, true)
  end

  defp parse_csv_chars([?", ?" | rest], cur, acc, true) do
    parse_csv_chars(rest, [?" | cur], acc, true)
  end

  defp parse_csv_chars([?" | rest], cur, acc, true) do
    parse_csv_chars(rest, cur, acc, false)
  end

  defp parse_csv_chars([c | rest], cur, acc, in_quotes) do
    parse_csv_chars(rest, [c | cur], acc, in_quotes)
  end

  defp normalise_column(column) when is_binary(column) do
    column
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, "_")
  end

  defp normalise_column(_), do: ""

  defp parse_datetime(nil, field), do: {:error, "#{field}: missing"}
  defp parse_datetime("", field), do: {:error, "#{field}: missing"}

  defp parse_datetime(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _reason} -> {:error, "#{field}: invalid ISO-8601 datetime"}
    end
  end

  defp parse_amount(nil), do: {:error, "amount: missing"}
  defp parse_amount(""), do: {:error, "amount: missing"}

  defp parse_amount(value) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = decimal, ""} ->
        if Decimal.lt?(decimal, 0) do
          {:error, "amount: must be non-negative; sign is carried in :direction"}
        else
          {:ok, decimal}
        end

      _ ->
        {:error, "amount: not a decimal"}
    end
  end

  defp parse_enum(nil, field, _allowed), do: {:error, "#{field}: missing"}
  defp parse_enum("", field, _allowed), do: {:error, "#{field}: missing"}

  defp parse_enum(value, field, allowed) when is_binary(value) do
    normalised = String.downcase(String.trim(value))

    if normalised in allowed do
      # Intentionally `String.to_existing_atom/1` (not
      # `String.to_atom/1`): the schema's `Ecto.Enum` already
      # interned every allowed value, so this lookup cannot blow
      # the atom table on hostile input.
      {:ok, String.to_existing_atom(normalised)}
    else
      {:error, "#{field}: must be one of #{Enum.join(allowed, ", ")}"}
    end
  end

  defp parse_enum_optional(value, field, allowed, _default)
       when is_binary(value) and value != "" do
    parse_enum(value, field, allowed)
  end

  defp parse_enum_optional(_, _field, _allowed, default) do
    {:ok, String.to_existing_atom(default)}
  end

  defp presence(value, _field) when is_binary(value) and value != "", do: {:ok, value}
  defp presence(_, field), do: {:error, "#{field}: missing"}

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s) when is_binary(s), do: s

  defp source_hash_for(recognised, unknown_metadata) do
    seed =
      [
        Map.get(recognised, "occurred_at", ""),
        Map.get(recognised, "asset", ""),
        Map.get(recognised, "chain", ""),
        Map.get(recognised, "amount", ""),
        Map.get(recognised, "direction", ""),
        Map.get(recognised, "from_address", ""),
        Map.get(recognised, "to_address", ""),
        Map.get(recognised, "tx_hash", ""),
        Map.get(recognised, "bank_ref", ""),
        :erlang.phash2(unknown_metadata) |> Integer.to_string()
      ]
      |> Enum.join("|")

    :crypto.hash(:sha256, seed) |> Base.encode16(case: :lower)
  end

  defp compute_row_dedupe_key(attrs, _row_number) do
    Activity.compute_dedupe_key(attrs)
  end
end
