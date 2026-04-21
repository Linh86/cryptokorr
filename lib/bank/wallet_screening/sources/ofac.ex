defmodule Bank.WalletScreening.Sources.OFAC do
  @moduledoc """
  Parser and normalizer for OFAC SDN (Specially Designated Nationals)
  digital currency address data.

  OFAC publishes sanctioned digital currency addresses in their SDN
  list. This module parses the consolidated JSON feed and normalizes
  each entry into the `ScreeningRecord` shape with
  `control_tier: :hard_block`.

  ## Feed format

  The OFAC consolidated sanctions feed includes entries shaped like:

      {
        "id": 12345,
        "programs": ["SDGT"],
        "id_type": "Digital Currency Address - XBT",
        "id_number": "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa",
        "name": "Entity Name",
        ...
      }

  The `id_type` field contains `"Digital Currency Address"` followed
  by the currency ticker. The `id_number` is the raw wallet address.

  ## Chain mapping

  OFAC uses non-standard currency tickers in `id_type`. This module
  maps them to the canonical chain identifiers used in the screening
  store:

      XBT  → bitcoin
      ETH  → ethereum
      USDT → ethereum  (ERC-20 default; may also appear on other chains)
      USDC → ethereum
      XMR  → monero
      LTC  → litecoin
      ZEC  → zcash
      DASH → dash
      BSV  → bsv
      BCH  → bitcoincash
      XRP  → xrp
      ARB  → arbitrum

  Entries with unrecognised tickers are collected in the `:skipped`
  return so the caller can log them without silently dropping data.
  """

  @source_name "ofac"
  @evidence_base "https://sanctionssearch.ofac.treas.gov"

  @chain_map %{
    "XBT" => "bitcoin",
    "ETH" => "ethereum",
    "USDT" => "ethereum",
    "USDC" => "ethereum",
    "XMR" => "monero",
    "LTC" => "litecoin",
    "ZEC" => "zcash",
    "DASH" => "dash",
    "BSV" => "bsv",
    "BCH" => "bitcoincash",
    "XRP" => "xrp",
    "ARB" => "arbitrum"
  }

  @distinct_party_re ~r/<DistinctParty\b(?<attrs>[^>]*)>(?<body>.*?)<\/DistinctParty>/s
  @feature_type_re ~r/<FeatureType\b(?<attrs>[^>]*)>(?<label>.*?)<\/FeatureType>/s
  @feature_re ~r/<Feature\b(?<attrs>[^>]*)>.*?<VersionDetail\b[^>]*>(?<value>.*?)<\/VersionDetail>/s

  @primary_alias_re ~r/<Alias\b[^>]*Primary="true"[^>]*>(?<body>.*?)<\/Alias>/s
  @name_part_re ~r/<NamePartValue\b[^>]*>(?<value>.*?)<\/NamePartValue>/s

  @type parse_result :: %{
          records: [map()],
          skipped: [map()]
        }

  @doc """
  Parse OFAC feed entries into screening record attribute maps.

  Accepts a list of raw entries (already decoded from JSON). Returns
  `%{records: [...], skipped: [...]}` where `records` are ready for
  `Bank.WalletScreening.upsert_record/1` and `skipped` contains
  entries that could not be normalised (unrecognised chain, missing
  address, etc.) with the reason attached.
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

  @doc """
  Extract digital currency address entries from the full OFAC
  consolidated JSON payload. Filters to entries where `id_type`
  contains `"Digital Currency Address"`.
  """
  @spec extract_digital_currency_entries(list()) :: list()
  def extract_digital_currency_entries(entries) when is_list(entries) do
    Enum.filter(entries, fn entry ->
      id_type = Map.get(entry, "id_type", "")
      String.contains?(id_type, "Digital Currency Address")
    end)
  end

  @doc """
  Extract digital currency address entries from OFAC's advanced SDN XML.

  OFAC's current public advanced SDN download is XML. This helper
  converts the relevant `DistinctParty`/`Feature` records into the
  same lightweight entry shape accepted by `parse/1`, keeping the
  source-specific XML parsing out of the ingestion orchestrator.
  """
  @spec extract_digital_currency_entries_from_xml(String.t()) :: list()
  def extract_digital_currency_entries_from_xml(xml) when is_binary(xml) do
    feature_types = digital_currency_feature_types(xml)

    Regex.scan(@distinct_party_re, xml, capture: :all_names)
    |> Enum.flat_map(fn [attrs, body] ->
      fixed_ref = fixed_ref(attrs)
      entity_name = primary_name(body)

      Regex.scan(@feature_re, body, capture: :all_names)
      |> Enum.flat_map(fn [feature_attrs, value] ->
        feature_id = attr(feature_attrs, "ID")
        type_id = attr(feature_attrs, "FeatureTypeID")

        case Map.fetch(feature_types, type_id) do
          {:ok, label} ->
            [
              %{
                "id" => fixed_ref || feature_id,
                "id_type" => label,
                "id_number" => xml_text(value),
                "name" => entity_name,
                "programs" => []
              }
            ]

          :error ->
            []
        end
      end)
    end)
  end

  defp normalise_entry(entry) do
    with {:ok, ticker} <- extract_ticker(entry),
         {:ok, chain} <- resolve_chain(ticker),
         {:ok, address} <- extract_address(entry) do
      sdn_id = Map.get(entry, "id")
      entity_name = Map.get(entry, "name")
      programs = Map.get(entry, "programs", [])

      {:ok,
       %{
         chain: chain,
         address: address,
         control_tier: :hard_block,
         source: @source_name,
         source_record_id: "sdn-#{sdn_id}",
         category: "sanctions",
         reason: build_reason(entity_name, programs),
         evidence_uri: build_evidence_uri(sdn_id),
         metadata: %{
           "sdn_id" => sdn_id,
           "entity_name" => entity_name,
           "programs" => programs,
           "ticker" => ticker
         },
         first_seen_at: DateTime.utc_now(),
         last_seen_at: DateTime.utc_now()
       }}
    end
  end

  defp extract_ticker(entry) do
    case Map.get(entry, "id_type", "") do
      "Digital Currency Address - " <> ticker ->
        {:ok, String.trim(ticker)}

      other ->
        {:skip, "unrecognised id_type: #{inspect(other)}"}
    end
  end

  defp resolve_chain(ticker) do
    case Map.get(@chain_map, String.upcase(ticker)) do
      nil -> {:skip, "unsupported ticker: #{ticker}"}
      chain -> {:ok, chain}
    end
  end

  defp extract_address(entry) do
    case Map.get(entry, "id_number") do
      nil -> {:skip, "missing id_number"}
      "" -> {:skip, "empty id_number"}
      address -> {:ok, String.trim(address)}
    end
  end

  defp build_reason(entity_name, programs) do
    program_str = Enum.join(programs, ", ")

    case {entity_name, program_str} do
      {nil, ""} -> "OFAC SDN sanctioned address"
      {nil, p} -> "OFAC SDN sanctioned address (#{p})"
      {name, ""} -> "OFAC SDN: #{name}"
      {name, p} -> "OFAC SDN: #{name} (#{p})"
    end
  end

  defp build_evidence_uri(nil), do: @evidence_base
  defp build_evidence_uri(sdn_id), do: "#{@evidence_base}/Details.aspx?id=#{sdn_id}"

  defp digital_currency_feature_types(xml) do
    @feature_type_re
    |> Regex.scan(xml, capture: :all_names)
    |> Enum.reduce(%{}, fn [attrs, label], acc ->
      id = attr(attrs, "ID")
      label = xml_text(label)

      if is_binary(id) and String.contains?(label, "Digital Currency Address") do
        Map.put(acc, id, label)
      else
        acc
      end
    end)
  end

  defp fixed_ref(attrs) do
    attr(attrs, "FixedRef")
  end

  defp attr(attrs, name) do
    case Regex.run(~r/\b#{Regex.escape(name)}="([^"]*)"/, attrs, capture: :all_but_first) do
      [value] -> value
      nil -> nil
    end
  end

  defp primary_name(body) do
    alias_body =
      case Regex.named_captures(@primary_alias_re, body) do
        %{"body" => alias_body} -> alias_body
        nil -> body
      end

    names =
      @name_part_re
      |> Regex.scan(alias_body, capture: :all_names)
      |> Enum.map(fn [value] -> xml_text(value) end)
      |> Enum.reject(&(&1 == ""))

    case names do
      [] -> nil
      _ -> Enum.join(names, " ")
    end
  end

  defp xml_text(text) do
    text
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&apos;", "'")
    |> String.trim()
  end
end
