defmodule Bank.WalletScreening.Sources.GraphSense do
  @moduledoc """
  Parser and normalizer for GraphSense tagpack attribution data.

  GraphSense publishes public tagpacks — collections of address tags
  that associate wallet addresses with known entities (exchanges,
  services, mining pools, etc.). This module parses tagpack entries
  and normalizes each into the `ScreeningRecord` shape with
  `control_tier: :context`.

  ## Feed format

  GraphSense tagpacks follow the TagPack schema. The public repository
  currently publishes YAML files where common attribution metadata lives
  at the tagpack root and `tags` often contain only addresses:

      title: GraphSense Binance
      creator: GraphSense Core Team
      category: exchange
      currency: BTC
      label: binance.com
      source: https://www.coindesk.com/...
      tags:
      - address: 1NDyJtNTjmwk5xPNhjgAMu4HDHigtobu1s

  JSON tagpack objects with the same `tags` envelope and bare JSON tag
  arrays are also supported for mirrors and tests.

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
  Decode the public GraphSense YAML tagpack shape.

  This is intentionally a small source-specific reader, not a general
  YAML parser. It supports the root scalar metadata and `tags` list
  used by the public `graphsense-tagpacks` repository.
  """
  @spec decode_yaml(String.t()) :: map()
  def decode_yaml(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.reduce({%{}, [], nil, :root}, &decode_yaml_line/2)
    |> then(fn {metadata, tags, current_tag, _mode} ->
      tags =
        tags
        |> maybe_prepend(current_tag)
        |> Enum.reverse()

      Map.put(metadata, "tags", tags)
    end)
  end

  @doc """
  Extract the tags array from a tagpack envelope.

  Handles three shapes:
  - Tagpack object with `"tags"` key -> extracts tags and applies root metadata defaults
  - Bare JSON array -> returns as-is
  - NDJSON lines (pre-split into a list) -> returns as-is
  """
  @spec extract_tags(map() | list()) :: list()
  def extract_tags(%{"tags" => tags} = tagpack) when is_list(tags) do
    defaults = Map.drop(tagpack, ["tags"])

    Enum.map(tags, fn
      tag when is_map(tag) -> Map.merge(defaults, tag)
      other -> other
    end)
  end

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
      {:ok, dt, _} ->
        dt

      _ ->
        case DateTime.from_iso8601(str) do
          {:ok, dt, _} -> dt
          _ -> nil
        end
    end
  end

  defp get_string(map, key) do
    case Map.get(map, key) do
      s when is_binary(s) -> String.trim(s) |> non_empty()
      n when is_number(n) -> to_string(n)
      true -> "true"
      false -> "false"
      _ -> nil
    end
  end

  defp non_empty(""), do: nil
  defp non_empty(s), do: s

  defp decode_yaml_line(line, {metadata, tags, current_tag, mode}) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        {metadata, tags, current_tag, mode}

      trimmed == "tags:" ->
        {metadata, tags, current_tag, :tags}

      mode == :tags and String.starts_with?(trimmed, "- ") ->
        tag = trimmed |> String.trim_leading("- ") |> decode_yaml_kv()
        {metadata, maybe_prepend(tags, current_tag), tag, :tags}

      mode == :tags and String.contains?(trimmed, ":") and is_map(current_tag) ->
        {key, value} = split_yaml_kv(trimmed)
        {metadata, tags, Map.put(current_tag, key, yaml_scalar(value)), :tags}

      mode == :root and String.contains?(trimmed, ":") ->
        {key, value} = split_yaml_kv(trimmed)
        {Map.put(metadata, key, yaml_scalar(value)), tags, current_tag, :root}

      true ->
        {metadata, tags, current_tag, mode}
    end
  end

  defp decode_yaml_kv(""), do: %{}

  defp decode_yaml_kv(fragment) do
    if String.contains?(fragment, ":") do
      {key, value} = split_yaml_kv(fragment)
      %{key => yaml_scalar(value)}
    else
      %{"address" => yaml_scalar(fragment)}
    end
  end

  defp split_yaml_kv(line) do
    [key, value] = String.split(line, ":", parts: 2)
    {String.trim(key), String.trim(value)}
  end

  defp yaml_scalar(value) do
    value
    |> String.trim()
    |> String.trim_leading("'")
    |> String.trim_trailing("'")
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end

  defp maybe_prepend(list, nil), do: list
  defp maybe_prepend(list, map) when map == %{}, do: list
  defp maybe_prepend(list, map), do: [map | list]
end
