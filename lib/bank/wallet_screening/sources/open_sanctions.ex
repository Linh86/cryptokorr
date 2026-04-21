defmodule Bank.WalletScreening.Sources.OpenSanctions do
  @moduledoc """
  Parser and normalizer for OpenSanctions `CryptoWallet`-related
  sanctions data.

  OpenSanctions publishes entity data in the FollowTheMoney (FtM)
  format. This module parses entries of schema type `CryptoWallet`
  and normalizes each into the `ScreeningRecord` shape with
  `control_tier: :hard_block`.

  ## Feed format

  OpenSanctions FtM entities for crypto wallets are shaped like:

      {
        "id": "os-entity-id",
        "schema": "CryptoWallet",
        "properties": {
          "publicKey": ["1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa"],
          "currency": ["BTC"],
          "holder": ["os-holder-entity-id"],
          "topics": ["sanction"],
          "sourceUrl": ["https://..."],
          ...
        }
      }

  ## Chain mapping

  OpenSanctions uses ISO-style currency codes. This module maps them
  to canonical chain identifiers:

      BTC  → bitcoin
      ETH  → ethereum
      USDT → ethereum
      USDC → ethereum
      XMR  → monero
      LTC  → litecoin
      XRP  → xrp

  Entries with unrecognised currencies are collected in `:skipped`.
  """

  @source_name "opensanctions"
  @evidence_base "https://opensanctions.org/entities/"

  @chain_map %{
    "BTC" => "bitcoin",
    "ETH" => "ethereum",
    "USDT" => "ethereum",
    "USDC" => "ethereum",
    "XMR" => "monero",
    "LTC" => "litecoin",
    "XRP" => "xrp"
  }

  @type parse_result :: %{
          records: [map()],
          skipped: [map()]
        }

  @doc """
  Parse OpenSanctions FtM entities into screening record attribute maps.

  Accepts a list of entities (already decoded from JSON). Returns
  `%{records: [...], skipped: [...]}`. Only processes entities with
  `schema: "CryptoWallet"` and `topics` containing `"sanction"`.
  """
  @spec parse(list()) :: parse_result()
  def parse(entities) when is_list(entities) do
    {records, skipped} =
      entities
      |> filter_sanctioned_wallets()
      |> Enum.reduce({[], []}, fn entity, {recs, skips} ->
        case normalise_entity(entity) do
          {:ok, record_list, skipped} -> {record_list ++ recs, skipped ++ skips}
        end
      end)

    %{records: Enum.reverse(records), skipped: Enum.reverse(skipped)}
  end

  @doc """
  Filter a list of FtM entities to only sanctioned CryptoWallet entries.
  """
  @spec filter_sanctioned_wallets(list()) :: list()
  def filter_sanctioned_wallets(entities) when is_list(entities) do
    Enum.filter(entities, fn entity ->
      Map.get(entity, "schema") == "CryptoWallet" and
        "sanction" in prop_list(entity, "topics")
    end)
  end

  defp normalise_entity(entity) do
    addresses = prop_list(entity, "publicKey")
    currencies = prop_list(entity, "currency")
    source_urls = prop_list(entity, "sourceUrl")
    holders = prop_list(entity, "holder")

    cond do
      addresses == [] ->
        {:ok, [], [skipped(entity, "no publicKey property")]}

      currencies == [] ->
        {:ok, [], [skipped(entity, "no currency property")]}

      true ->
        {records, skipped} =
          Enum.reduce(currencies, {[], []}, fn currency, {records, skipped} ->
            currency = String.upcase(currency)

            case Map.get(@chain_map, currency) do
              nil ->
                {records, [skipped(entity, "unsupported currency: #{currency}") | skipped]}

              chain ->
                records_for_currency(entity, addresses, currency, chain, holders, source_urls)
                |> merge_records(records, skipped)
            end
          end)

        {:ok, Enum.reverse(records), Enum.reverse(skipped)}
    end
  end

  defp records_for_currency(entity, addresses, currency, chain, holders, source_urls) do
    entity_id = Map.get(entity, "id")

    Enum.reduce(addresses, {[], []}, fn address, {records, skipped} ->
      address = String.trim(address)

      if address == "" do
        {records, [skipped(entity, "empty publicKey value") | skipped]}
      else
        record = %{
          chain: chain,
          address: address,
          control_tier: :hard_block,
          source: @source_name,
          source_record_id: "#{entity_id}-#{currency}-#{short_hash(address)}",
          category: "sanctions",
          reason: build_reason(entity_id, holders, currency),
          evidence_uri: build_evidence_uri(entity_id, source_urls),
          metadata: %{
            "entity_id" => entity_id,
            "currency" => currency,
            "holders" => holders,
            "source_urls" => source_urls
          },
          first_seen_at: DateTime.utc_now(),
          last_seen_at: DateTime.utc_now()
        }

        {[record | records], skipped}
      end
    end)
  end

  defp merge_records({new_records, new_skipped}, records, skipped) do
    {new_records ++ records, new_skipped ++ skipped}
  end

  defp skipped(entity, reason), do: %{entity: entity, reason: reason}

  defp prop_list(entity, key) do
    entity
    |> Map.get("properties", %{})
    |> Map.get(key, [])
  end

  defp build_reason(entity_id, holders, currency) do
    holder_str = if holders != [], do: " (holder: #{Enum.join(holders, ", ")})", else: ""
    "OpenSanctions sanctioned #{currency} wallet#{holder_str} [#{entity_id}]"
  end

  defp build_evidence_uri(entity_id, source_urls) do
    case source_urls do
      [url | _] -> url
      _ -> "#{@evidence_base}#{entity_id}/"
    end
  end

  defp short_hash(address) do
    :crypto.hash(:sha256, address)
    |> binary_part(0, 4)
    |> Base.encode16(case: :lower)
  end
end
