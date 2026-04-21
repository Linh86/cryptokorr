defmodule Bank.WalletScreening.Sources.BTCAbuse do
  @moduledoc """
  Parser and normalizer for Bitcoin abuse/scam feed data.

  BTCAbuse / Bitcoin Abuse-style datasets publish reported Bitcoin
  addresses with abuse categories and reporter metadata. The current
  public BTCAbuse site exposes browsable address evidence but does
  not expose a live unauthenticated bulk API, so ingestion expects an
  operator-configured CSV export with the historical Bitcoin Abuse
  field shape.

  ## Feed format

  The public CSV export has columns:

      id,address,abuse_type_id,abuse_type_other,abuser,description,
      from_country,from_country_code,created_at

  Common `abuse_type_id` values:
    * 1 — ransomware
    * 2 — darknet marketplace
    * 3 — bitcoin tumbler
    * 4 — blackmail scam
    * 5 — sextortion
    * 99 — other

  ## Deduplication

  The raw feed may contain many reports for the same address (each
  report is a separate row). This parser deduplicates by address,
  keeping the earliest `created_at` as `first_seen_at` and the
  latest as `last_seen_at`. The aggregate report count and dominant
  abuse type are preserved in metadata.

  All entries produce chain "bitcoin". Entries with missing or blank
  addresses are skipped.
  """

  @source_name "btc_abuse"
  @evidence_base "https://btcabuse.com/browse/"

  @abuse_types %{
    "1" => "ransomware",
    "2" => "darknet_marketplace",
    "3" => "bitcoin_tumbler",
    "4" => "blackmail_scam",
    "5" => "sextortion",
    "99" => "other"
  }

  @type parse_result :: %{
          records: [map()],
          skipped: [map()]
        }

  @doc """
  Parse BTC abuse CSV data into screening record attribute maps.

  Accepts raw CSV content as a binary string. Parses rows,
  deduplicates by address, and returns `%{records: [...], skipped: [...]}`.
  """
  @spec parse_csv(String.t()) :: parse_result()
  def parse_csv(csv_body) when is_binary(csv_body) do
    lines = String.split(csv_body, "\n", trim: true)

    case lines do
      [] ->
        %{records: [], skipped: []}

      [header | rows] ->
        columns = parse_header(header)
        parse_rows(rows, columns)
    end
  end

  @doc """
  Parse BTC abuse entries from a list of pre-decoded maps (JSON
  variant). Returns `%{records: [...], skipped: [...]}`.
  """
  @spec parse(list()) :: parse_result()
  def parse(entries) when is_list(entries) do
    {by_address, skipped} = group_reports(entries)
    records = build_records(by_address)
    %{records: records, skipped: skipped}
  end

  # --- CSV parsing -------------------------------------------------------

  defp parse_header(header) do
    header
    |> String.trim()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.downcase/1)
    |> Enum.with_index()
    |> Map.new()
  end

  defp parse_rows(rows, columns) do
    entries =
      rows
      |> Enum.map(fn row -> parse_csv_row(row, columns) end)
      |> Enum.reject(&is_nil/1)

    {by_address, skipped} = group_reports(entries)
    records = build_records(by_address)
    %{records: records, skipped: skipped}
  end

  defp parse_csv_row(row, columns) do
    fields =
      row
      |> String.trim()
      |> String.split(",", parts: map_size(columns))
      |> Enum.with_index()

    Enum.reduce(fields, %{}, fn {value, idx}, acc ->
      col_name =
        Enum.find(columns, fn {_name, i} -> i == idx end)

      case col_name do
        {name, _} -> Map.put(acc, name, String.trim(value))
        nil -> acc
      end
    end)
  end

  # --- Grouping and dedup ------------------------------------------------

  defp group_reports(entries) do
    Enum.reduce(entries, {%{}, []}, fn entry, {grouped, skipped} ->
      address = get_string(entry, "address")

      cond do
        is_nil(address) or address == "" ->
          {grouped, [%{entry: entry, reason: "missing or empty address"} | skipped]}

        true ->
          existing = Map.get(grouped, address, [])
          {Map.put(grouped, address, [entry | existing]), skipped}
      end
    end)
  end

  defp build_records(by_address) do
    Enum.map(by_address, fn {address, reports} ->
      report_count = length(reports)
      abuse_types = reports |> Enum.map(&get_abuse_type/1) |> Enum.frequencies()
      dominant_type = abuse_types |> Enum.max_by(fn {_type, count} -> count end) |> elem(0)

      created_dates =
        reports
        |> Enum.map(&get_string(&1, "created_at"))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()

      first_seen = List.first(created_dates)
      last_seen = List.last(created_dates)

      %{
        chain: "bitcoin",
        address: String.trim(address),
        control_tier: :challenge,
        source: @source_name,
        source_record_id: build_source_record_id(address),
        category: dominant_type,
        reason: build_reason(dominant_type, report_count),
        evidence_uri: "#{@evidence_base}#{address}",
        metadata: %{
          "report_count" => report_count,
          "abuse_types" => abuse_types,
          "first_report" => first_seen,
          "last_report" => last_seen
        },
        first_seen_at: parse_datetime(first_seen),
        last_seen_at: parse_datetime(last_seen)
      }
    end)
  end

  defp get_abuse_type(entry) do
    type_id = get_string(entry, "abuse_type_id")
    other = get_string(entry, "abuse_type_other")

    case Map.get(@abuse_types, type_id) do
      nil when not is_nil(other) -> other
      nil -> "unknown"
      name -> name
    end
  end

  defp build_source_record_id(address) do
    hash =
      :crypto.hash(:sha256, address)
      |> binary_part(0, 6)
      |> Base.encode16(case: :lower)

    "btcabuse-#{hash}"
  end

  defp build_reason(abuse_type, 1), do: "Bitcoin Abuse: #{abuse_type} (1 report)"
  defp build_reason(abuse_type, count), do: "Bitcoin Abuse: #{abuse_type} (#{count} reports)"

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp get_string(map, key) do
    case Map.get(map, key) do
      s when is_binary(s) -> String.trim(s) |> non_empty()
      n when is_integer(n) -> Integer.to_string(n)
      _ -> nil
    end
  end

  defp non_empty(""), do: nil
  defp non_empty(s), do: s
end
