defmodule Bank.WalletScreening.Sources.EtherScamDB do
  @moduledoc """
  Parser and normalizer for EtherScamDB scam address data.

  EtherScamDB maintains a community-contributed database of Ethereum
  scam addresses. The public export is a JSON array of scam entries
  with address, category, and reporter metadata.

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
        list |> Enum.filter(&is_binary/1) |> Enum.reject(&(String.trim(&1) == ""))

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
end
