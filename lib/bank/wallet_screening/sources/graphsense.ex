defmodule Bank.WalletScreening.Sources.GraphSense do
  @moduledoc """
  Parser and normalizer for GraphSense tagpack attribution data.

  GraphSense publishes public tagpacks — collections of address tags
  that associate wallet addresses with known entities (exchanges,
  services, mining pools, etc.). This module parses tagpack entries
  and normalizes each into the `ScreeningRecord` shape with
  `control_tier: :context`.

  ## Feed format

  GraphSense tagpacks follow the TagPack schema. A tagpack is a JSON
  object containing a `tags` array:

      {
        "title": "DeFi Protocol Tags",
        "creator": "graphsense",
        "tags": [
          {
            "address": "0x1234...",
            "currency": "ETH",
            "label": "Uniswap V3 Router",
            "source": "https://etherscan.io/address/0x1234...",
            "category": "defi",
            "lastmod": "2025-06-01"
          },
          ...
        ]
      }

  Some tagpacks are distributed as NDJSON (one tag per line) or as a
  bare JSON array of tags. This parser handles all three shapes.

  ## Chain mapping

  GraphSense uses ISO-style currency codes. This module maps them
  to canonical chain identifiers:

      BTC  → bitcoin
      ETH  → ethereum
      LTC  → litecoin
      ZEC  → zcash
      BCH  → bitcoincash

  Tags with unrecognised currencies are skipped explicitly.

  ## Context-only semantics

  Attribution labels are enrichment data — they help operators
  understand what an address is associated with, but they must never
  block or challenge a transaction on their own. Every record
  produced by this module uses `control_tier: :context`.
  """

  @source_name "graphsense"
  @evidence_base "https://graphsense.info/address/"

  @chain_map %{
    "BTC" => "bitcoin",
    "ETH" => "ethereum",
    "LTC" => "litecoin",
    "ZEC" => "zcash",
    "BCH" => "bitcoincash"
  }

  @type parse_result :: %{
          records: [map()],
          skipped: [map()]
        }

  @doc """
  Parse GraphSense tagpack tags into screening record attribute maps.

  Accepts a list of tag entries (already decoded from JSON). Returns
  `%{records: [...], skipped: [...]}`.
  """
  @spec parse(list()) :: parse_result()
  def parse(tags) when is_list(tags) do
    {records, skipped} =
      Enum.reduce(tags, {[], []}, fn tag, {recs, skips} ->
        case normalise_tag(tag) do
          {:ok, record} -> {[record | recs], skips}
          {:skip, reason} -> {recs, [%{entry: tag, reason: reason} | skips]}
        end
      end)

    %{records: Enum.reverse(records), skipped: Enum.reverse(skipped)}
  end

  @doc """
  Extract the tags array from a tagpack envelope.

  Handles three shapes:
  - Tagpack object with `"tags"` key → extracts the array
  - Bare JSON array → returns as-is
  - NDJSON lines (pre-split into a list) → returns as-is
  """
  @spec extract_tags(map() | list()) :: list()
  def extract_tags(%{"tags" => tags}) when is_list(tags), do: tags
  def extract_tags(tags) when is_list(tags), do: tags
  def extract_tags(_), do: []

  defp normalise_tag(tag) do
    address = get_string(tag, "address")
    currency = get_string(tag, "currency")
    label = get_string(tag, "label")

    cond do
      is_nil(address) or address == "" ->
        {:skip, "missing or empty address"}

      is_nil(currency) or currency == "" ->
        {:skip, "missing currency for address #{address}"}

      true ->
        case resolve_chain(currency) do
          {:ok, chain} ->
            {:ok, build_record(tag, chain, address, currency, label)}

          {:skip, _} = skip ->
            skip
        end
    end
  end

  defp resolve_chain(currency) do
    case Map.get(@chain_map, String.upcase(currency)) do
      nil -> {:skip, "unsupported currency: #{currency}"}
      chain -> {:ok, chain}
    end
  end

  defp build_record(tag, chain, address, currency, label) do
    source_uri = get_string(tag, "source")
    category = get_string(tag, "category")
    lastmod = get_string(tag, "lastmod")
    creator = get_string(tag, "creator")
    confidence = get_string(tag, "confidence")

    %{
      chain: chain,
      address: address,
      control_tier: :context,
      source: @source_name,
      source_record_id: build_source_record_id(chain, address, label),
      category: category || "attribution",
      reason: build_reason(label, category, currency),
      evidence_uri: source_uri || "#{@evidence_base}#{currency}/#{address}",
      metadata: %{
        "label" => label,
        "currency" => currency,
        "category" => category,
        "source_uri" => source_uri,
        "lastmod" => lastmod,
        "creator" => creator,
        "confidence" => confidence
      },
      first_seen_at: parse_date(lastmod),
      last_seen_at: parse_date(lastmod)
    }
  end

  defp build_source_record_id(chain, address, label) do
    hash =
      :crypto.hash(:sha256, "#{chain}:#{address}:#{label}")
      |> binary_part(0, 6)
      |> Base.encode16(case: :lower)

    "gs-#{hash}"
  end

  defp build_reason(nil, nil, currency),
    do: "GraphSense: #{currency} address attribution"

  defp build_reason(label, nil, currency),
    do: "GraphSense: #{label} (#{currency})"

  defp build_reason(nil, category, currency),
    do: "GraphSense: #{category} #{currency} address"

  defp build_reason(label, category, currency),
    do: "GraphSense: #{label} — #{category} (#{currency})"

  defp parse_date(nil), do: nil

  defp parse_date(str) when is_binary(str) do
    case DateTime.from_iso8601(str <> "T00:00:00Z") do
      {:ok, dt, _} -> dt
      _ -> case DateTime.from_iso8601(str) do
        {:ok, dt, _} -> dt
        _ -> nil
      end
    end
  end

  defp get_string(map, key) do
    case Map.get(map, key) do
      s when is_binary(s) -> String.trim(s) |> non_empty()
      n when is_number(n) -> to_string(n)
      _ -> nil
    end
  end

  defp non_empty(""), do: nil
  defp non_empty(s), do: s
end
