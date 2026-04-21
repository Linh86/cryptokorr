defmodule Bank.WalletScreening.Ingestion do
  @moduledoc """
  Orchestrates fetching, parsing, and upserting sanctions feed data
  into the screening store.

  Each `ingest_*` function:

    1. Fetches the feed over HTTP via `Req`.
    2. Parses + normalizes via the source-specific parser.
    3. Upserts all valid records via `Bank.WalletScreening.upsert_records/1`.
    4. Returns a summary of what was ingested, skipped, and any errors.

  Network fetching is separated from parsing so tests can exercise
  the parser directly with fixture data and stub the HTTP layer via
  `Req.Test`.

  ## Configuration

  Feed URLs and Req options are read from application config:

      config :bank, Bank.WalletScreening.Ingestion,
        ofac_url: "https://...",
        opensanctions_url: "https://...",
        req_options: []

  In the test environment, `req_options` should include
  `[plug: {Req.Test, Bank.WalletScreening.Ingestion}]` so HTTP
  calls are stubbed per-process.
  """

  require Logger

  alias Bank.WalletScreening
  alias Bank.WalletScreening.Sources.{BTCAbuse, EtherScamDB, OFAC, OpenSanctions, ScamSniffer}

  @type ingest_result :: %{
          source: String.t(),
          ingested: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: [term()]
        }

  @default_ofac_url "https://www.treasury.gov/ofac/downloads/sanctions/1.0/sdn_advanced.xml"
  @default_opensanctions_url "https://data.opensanctions.org/datasets/latest/sanctions/entities.ftm.json"
  @default_scamsniffer_url "https://raw.githubusercontent.com/scamsniffer/scam-database/main/blacklist/combined.json"
  @default_etherscamdb_url "https://raw.githubusercontent.com/MrLuit/EtherScamDB/master/data/scams.json"
  @default_btc_abuse_url "https://www.bitcoinabuse.com/api/reports/download"

  # --- Public API -------------------------------------------------------

  @doc """
  Ingest OFAC digital currency sanctions data.

  Fetches the OFAC advanced SDN feed, extracts digital currency
  address entries, normalizes them, and upserts into the screening
  store. The current public OFAC download is XML; JSON-shaped test
  fixtures remain supported for parser compatibility.
  """
  @spec ingest_ofac(keyword()) :: {:ok, ingest_result()} | {:error, term()}
  def ingest_ofac(opts \\ []) do
    url = Keyword.get(opts, :url, ofac_url())

    with {:ok, body} <- fetch_body(url),
         {:ok, entries} <- decode_ofac_payload(body) do
      %{records: records, skipped: skipped} = OFAC.parse(entries)
      do_upsert("ofac", records, skipped)
    end
  end

  @doc """
  Ingest OpenSanctions wallet-related sanctions data.

  Fetches the FtM entities feed (newline-delimited JSON), filters
  to sanctioned CryptoWallet entities, normalizes them, and upserts
  into the screening store.
  """
  @spec ingest_opensanctions(keyword()) :: {:ok, ingest_result()} | {:error, term()}
  def ingest_opensanctions(opts \\ []) do
    url = Keyword.get(opts, :url, opensanctions_url())

    with {:ok, body} <- fetch_body(url) do
      entities = decode_ndjson(body)
      %{records: records, skipped: skipped} = OpenSanctions.parse(entities)
      do_upsert("opensanctions", records, skipped)
    end
  end

  @doc """
  Ingest ScamSniffer phishing/scam address data.

  Fetches the ScamSniffer blocklist JSON feed, parses flagged
  addresses, and upserts into the screening store as `challenge`
  records.
  """
  @spec ingest_scamsniffer(keyword()) :: {:ok, ingest_result()} | {:error, term()}
  def ingest_scamsniffer(opts \\ []) do
    url = Keyword.get(opts, :url, scamsniffer_url())

    with {:ok, body} <- fetch_body(url),
         {:ok, entries} <- decode_json(body) do
      %{records: records, skipped: skipped} = ScamSniffer.parse(entries)
      do_upsert("scamsniffer", records, skipped)
    end
  end

  @doc """
  Ingest EtherScamDB scam address data.

  Fetches the EtherScamDB public JSON export, parses scam entries
  with Ethereum addresses, and upserts into the screening store as
  `challenge` records.
  """
  @spec ingest_etherscamdb(keyword()) :: {:ok, ingest_result()} | {:error, term()}
  def ingest_etherscamdb(opts \\ []) do
    url = Keyword.get(opts, :url, etherscamdb_url())

    with {:ok, body} <- fetch_body(url),
         {:ok, entries} <- decode_json_flexible(body) do
      %{records: records, skipped: skipped} = EtherScamDB.parse(entries)
      do_upsert("etherscamdb", records, skipped)
    end
  end

  @doc """
  Ingest Bitcoin abuse/scam feed data.

  Fetches the BTC abuse CSV export, parses and deduplicates by
  address, and upserts into the screening store as `challenge`
  records.
  """
  @spec ingest_btc_abuse(keyword()) :: {:ok, ingest_result()} | {:error, term()}
  def ingest_btc_abuse(opts \\ []) do
    url = Keyword.get(opts, :url, btc_abuse_url())

    with {:ok, body} <- fetch_body(url) do
      %{records: records, skipped: skipped} = BTCAbuse.parse_csv(body)
      do_upsert("btc_abuse", records, skipped)
    end
  end

  # --- Fetch helpers ----------------------------------------------------

  defp fetch_body(url) do
    case request(url) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("WalletScreening.Ingestion: feed returned HTTP #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("WalletScreening.Ingestion: fetch failed: #{inspect(reason)}")
        {:error, {:fetch_failed, reason}}
    end
  end

  defp request(url) do
    [
      url: url,
      method: :get,
      retry: false,
      decode_body: false
    ]
    |> Keyword.merge(req_options())
    |> Req.request()
  end

  # The current OFAC advanced SDN download is XML. Some tests and
  # historical mirrors expose equivalent JSON, so support both a
  # top-level list and a map with a nested list.
  defp decode_ofac_payload(body) when is_binary(body) do
    if body |> String.trim_leading() |> String.starts_with?("<") do
      {:ok, OFAC.extract_digital_currency_entries_from_xml(body)}
    else
      with {:ok, decoded} <- Jason.decode(body) do
        {:ok, extract_ofac_entries(decoded)}
      end
    end
  end

  defp extract_ofac_entries(body) when is_list(body) do
    OFAC.extract_digital_currency_entries(body)
  end

  defp extract_ofac_entries(body) when is_map(body) do
    entries =
      Map.get(body, "results", Map.get(body, "entries", Map.get(body, "data", [])))

    OFAC.extract_digital_currency_entries(entries)
  end

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, _other} -> {:ok, []}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  # EtherScamDB wraps the array in a top-level object with a "result"
  # or "data" key in some exports, or returns a bare array in others.
  defp decode_json_flexible(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, list} when is_list(list) ->
        {:ok, list}

      {:ok, %{"result" => list}} when is_list(list) ->
        {:ok, list}

      {:ok, %{"data" => list}} when is_list(list) ->
        {:ok, list}

      {:ok, _} ->
        {:ok, []}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp decode_ndjson(body) when is_binary(body) do
    body
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      case Jason.decode(line) do
        {:ok, entity} -> [entity | acc]
        {:error, _} -> acc
      end
    end)
    |> Enum.reverse()
  end

  # --- Upsert plumbing --------------------------------------------------

  defp do_upsert(source, records, skipped) do
    if skipped != [] do
      Logger.info(
        "WalletScreening.Ingestion: #{source} skipped #{length(skipped)} entries " <>
          "(first reason: #{inspect(hd(skipped).reason)})"
      )
    end

    case records do
      [] ->
        {:ok,
         %{
           source: source,
           ingested: 0,
           skipped: length(skipped),
           errors: []
         }}

      _ ->
        case WalletScreening.upsert_records(records) do
          {:ok, count} ->
            Logger.info("WalletScreening.Ingestion: #{source} upserted #{count} records")

            {:ok,
             %{
               source: source,
               ingested: count,
               skipped: length(skipped),
               errors: []
             }}

          {:error, reason} ->
            Logger.error("WalletScreening.Ingestion: #{source} upsert failed: #{inspect(reason)}")

            {:error, reason}
        end
    end
  end

  # --- Config -----------------------------------------------------------

  defp config, do: Application.get_env(:bank, __MODULE__, [])

  defp ofac_url, do: Keyword.get(config(), :ofac_url, @default_ofac_url)

  defp opensanctions_url,
    do: Keyword.get(config(), :opensanctions_url, @default_opensanctions_url)

  defp scamsniffer_url,
    do: Keyword.get(config(), :scamsniffer_url, @default_scamsniffer_url)

  defp etherscamdb_url,
    do: Keyword.get(config(), :etherscamdb_url, @default_etherscamdb_url)

  defp btc_abuse_url,
    do: Keyword.get(config(), :btc_abuse_url, @default_btc_abuse_url)

  defp req_options, do: Keyword.get(config(), :req_options, [])
end
