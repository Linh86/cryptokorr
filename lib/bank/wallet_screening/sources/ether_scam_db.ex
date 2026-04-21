defmodule Bank.WalletScreening.Sources.EtherScamDB do
  @moduledoc """
  Parser and normalizer for EtherScamDB scam address data.

  EtherScamDB maintains a community-contributed database of Ethereum
  scam addresses. The canonical public export is the GitHub
  `_data/scams.yaml` file; this module parses that shape into entry
  maps and then normalizes address-bearing entries into screening
  records.

  ## Feed format

  EtherScamDB's public JSON export contains entries shaped like:

      {
        "id": 12345,
        "name": "Fake Uniswap",
        "url": "https://fake-uniswap.com",
        "coin": "ETH",
        "category": "Phishing",
        "subcategory": "ICO Scam",
        "description": "Fake token swap site",
        "addresses": [
          "0xDeAdBeEf00000000000000000000000000000001"
        ],
        "reporter": "community",
        "status": "Active"
      }

  Some entries carry a single `address` string instead of `addresses`
  array. This parser handles both shapes.

  All entries are normalised to chain "ethereum" — EtherScamDB is
  exclusively Ethereum-family. Entries with no usable address are
  skipped explicitly.
  """

  @source_name "etherscamdb"
  @evidence_base "https://etherscamdb.info/scam/"

  @type parse_result :: %{
          records: [map()],
          skipped: [map()]
        }

  @doc """
  Parse EtherScamDB entries into screening record attribute maps.

  Accepts a list of entries (already decoded from JSON). Returns
  `%{records: [...], skipped: [...]}`.
  """
  @spec parse(list()) :: parse_result()
  def parse(entries) when is_list(entries) do
    {records, skipped} =
      Enum.reduce(entries, {[], []}, fn entry, {recs, skips} ->
        case normalise_entry(entry) do
          {:ok, new_records, new_skipped} ->
            {new_records ++ recs, new_skipped ++ skips}
        end
      end)

    %{records: Enum.reverse(records), skipped: Enum.reverse(skipped)}
  end

  @doc """
  Decode the canonical EtherScamDB `_data/scams.yaml` file.

  This is intentionally a tiny, source-specific YAML reader rather
  than a general YAML parser: we only need top-level scam entries,
  scalar fields, and the `addresses` string array used by the public
  feed. Unknown or multiline fields are ignored rather than treated
  as successful address data.
  """
  @spec decode_yaml(String.t()) :: [map()]
  def decode_yaml(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.reduce({[], nil, nil}, &decode_yaml_line/2)
    |> then(fn {entries, current, _array_key} ->
      entries
      |> maybe_prepend(current)
      |> Enum.reverse()
    end)
  end

  defp normalise_entry(entry) do
    addresses = extract_addresses(entry)
    entry_id = Map.get(entry, "id")
    name = get_string(entry, "name")
    category = get_string(entry, "category") || "scam"
    subcategory = get_string(entry, "subcategory")
    scam_url = get_string(entry, "url")
    status = get_string(entry, "status")

    case addresses do
      [] ->
        {:ok, [], [%{entry: entry, reason: "no usable address in entry"}]}

      addrs ->
        {records, skipped} =
          Enum.reduce(addrs, {[], []}, fn address, {recs, skips} ->
            address = String.trim(address)

            if address == "" do
              {recs, [%{entry: entry, reason: "empty address value"} | skips]}
            else
              record = %{
                chain: "ethereum",
                address: address,
                control_tier: :challenge,
                source: @source_name,
                source_record_id: build_source_record_id(entry_id, address),
                category: String.downcase(category),
                reason: build_reason(category, subcategory, name),
                evidence_uri: build_evidence_uri(entry_id, scam_url),
                metadata: %{
                  "entry_id" => entry_id,
                  "name" => name,
                  "category" => category,
                  "subcategory" => subcategory,
                  "scam_url" => scam_url,
                  "status" => status
                },
                first_seen_at: DateTime.utc_now(),
                last_seen_at: DateTime.utc_now()
              }

              {[record | recs], skips}
            end
          end)

        {:ok, Enum.reverse(records), Enum.reverse(skipped)}
    end
  end

  defp extract_addresses(entry) do
    case Map.get(entry, "addresses") do
      list when is_list(list) ->
        Enum.filter(list, &is_binary/1)

      _ ->
        case get_string(entry, "address") do
          nil -> []
          addr -> [addr]
        end
    end
  end

  defp build_source_record_id(nil, address) do
    hash =
      :crypto.hash(:sha256, address)
      |> binary_part(0, 6)
      |> Base.encode16(case: :lower)

    "esdb-#{hash}"
  end

  defp build_source_record_id(entry_id, address) do
    hash =
      :crypto.hash(:sha256, "#{entry_id}:#{address}")
      |> binary_part(0, 4)
      |> Base.encode16(case: :lower)

    "esdb-#{entry_id}-#{hash}"
  end

  defp build_reason(category, nil, nil), do: "EtherScamDB: #{category}"
  defp build_reason(category, nil, name), do: "EtherScamDB: #{category} — #{name}"

  defp build_reason(category, subcategory, nil),
    do: "EtherScamDB: #{category}/#{subcategory}"

  defp build_reason(category, subcategory, name),
    do: "EtherScamDB: #{category}/#{subcategory} — #{name}"

  defp build_evidence_uri(nil, nil), do: @evidence_base
  defp build_evidence_uri(nil, scam_url), do: scam_url
  defp build_evidence_uri(entry_id, _), do: "#{@evidence_base}#{entry_id}"

  defp get_string(map, key) do
    case Map.get(map, key) do
      s when is_binary(s) -> String.trim(s) |> non_empty()
      _ -> nil
    end
  end

  defp non_empty(""), do: nil
  defp non_empty(s), do: s

  defp decode_yaml_line(line, {entries, current, array_key}) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        {entries, current, array_key}

      trimmed == "-" ->
        {maybe_prepend(entries, current), %{}, nil}

      String.starts_with?(trimmed, "- ") and is_binary(array_key) ->
        value = trimmed |> String.trim_leading("- ") |> yaml_scalar()
        {entries, Map.update(current || %{}, array_key, [value], &(&1 ++ [value])), array_key}

      String.contains?(trimmed, ":") ->
        [key, value] = String.split(trimmed, ":", parts: 2)
        key = String.trim(key)
        value = String.trim(value)

        cond do
          value == "" ->
            {entries, current || %{}, key}

          value in ["|-", "|", ">-", ">"] ->
            {entries, current || %{}, nil}

          true ->
            {entries, Map.put(current || %{}, key, yaml_scalar(value)), nil}
        end

      true ->
        {entries, current, array_key}
    end
  end

  defp maybe_prepend(entries, nil), do: entries
  defp maybe_prepend(entries, current) when current == %{}, do: entries
  defp maybe_prepend(entries, current), do: [current | entries]

  defp yaml_scalar(value) do
    value
    |> String.trim()
    |> String.trim("'")
    |> String.trim("\"")
  end
end
