defmodule Bank.WalletScreening.Sources.ScamSniffer do
  @moduledoc """
  Parser and normalizer for ScamSniffer scam/phishing address data.

  ScamSniffer publishes a JSON feed of flagged wallet addresses
  associated with phishing campaigns, drainer contracts, and other
  scam activity. This module parses those entries and normalizes
  each into the `ScreeningRecord` shape with
  `control_tier: :challenge`.

  ## Feed format

  ScamSniffer's blocklist API returns a JSON array of objects:

      [
        {
          "address": "0x1234...",
          "chain": "ethereum",
          "type": "phishing",
          "name": "Inferno Drainer",
          "url": "https://scamsniffer.io/address/0x1234..."
        },
        ...
      ]

  Some entries may omit `chain` (defaulting to "ethereum"), or carry
  additional metadata fields.

  ## Chain mapping

  ScamSniffer uses chain names directly. Entries without a `chain`
  field default to "ethereum" (the dominant chain for phishing
  campaigns). Unrecognised chains are preserved as-is — downstream
  address normalisation handles chain-specific casing.

  Entries with missing or blank addresses are skipped explicitly.
  """

  @source_name "scamsniffer"
  @evidence_base "https://scamsniffer.io/address/"

  @type parse_result :: %{
          records: [map()],
          skipped: [map()]
        }

  @doc """
  Parse ScamSniffer feed entries into screening record attribute maps.

  Accepts a list of entries (already decoded from JSON). Returns
  `%{records: [...], skipped: [...]}`.
  """
  @spec parse(list()) :: parse_result()
  def parse(entries) when is_list(entries) do
    {records, skipped} =
      Enum.reduce(entries, {[], []}, fn entry, {recs, skips} ->
        case normalise_entry(entry) do
          {:ok, record} -> {[record | recs], skips}
          {:skip, reason} -> {recs, [%{entry: entry, reason: reason} | skips]}
        end
      end)

    %{records: Enum.reverse(records), skipped: Enum.reverse(skipped)}
  end

  defp normalise_entry(entry) do
    address = get_string(entry, "address")

    cond do
      is_nil(address) or address == "" ->
        {:skip, "missing or empty address"}

      true ->
        chain = get_string(entry, "chain") || "ethereum"
        scam_type = get_string(entry, "type") || "scam"
        name = get_string(entry, "name")
        url = get_string(entry, "url")

        {:ok,
         %{
           chain: chain,
           address: address,
           control_tier: :challenge,
           source: @source_name,
           source_record_id: build_source_record_id(chain, address),
           category: scam_type,
           reason: build_reason(scam_type, name),
           evidence_uri: url || "#{@evidence_base}#{address}",
           metadata: build_metadata(entry),
           first_seen_at: DateTime.utc_now(),
           last_seen_at: DateTime.utc_now()
         }}
    end
  end

  defp build_source_record_id(chain, address) do
    hash =
      :crypto.hash(:sha256, "#{chain}:#{address}")
      |> binary_part(0, 6)
      |> Base.encode16(case: :lower)

    "ss-#{hash}"
  end

  defp build_reason(scam_type, nil), do: "ScamSniffer: #{scam_type} address"
  defp build_reason(scam_type, name), do: "ScamSniffer: #{scam_type} — #{name}"

  defp build_metadata(entry) do
    entry
    |> Map.take(["address", "chain", "type", "name", "url", "id", "tags", "created_at"])
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp get_string(map, key) do
    case Map.get(map, key) do
      s when is_binary(s) -> String.trim(s) |> non_empty()
      _ -> nil
    end
  end

  defp non_empty(""), do: nil
  defp non_empty(s), do: s
end
