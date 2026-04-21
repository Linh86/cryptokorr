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
end
