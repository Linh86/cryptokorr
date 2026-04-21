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
  alias Bank.WalletScreening.Sources.{OFAC, OpenSanctions}

  @type ingest_result :: %{
          source: String.t(),
          ingested: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: [term()]
        }

  @default_ofac_url "https://sanctionslistservice.ofac.treas.gov/api/PublicationPreview/exports/ADVANCED_JSON"
  @default_opensanctions_url "https://data.opensanctions.org/datasets/latest/sanctions/entities.ftm.json"

  # --- Public API -------------------------------------------------------

  @doc """
  Ingest OFAC digital currency sanctions data.

  Fetches the consolidated OFAC JSON feed, extracts digital currency
  address entries, normalizes them, and upserts into the screening
  store.
  """
  @spec ingest_ofac(keyword()) :: {:ok, ingest_result()} | {:error, term()}
  def ingest_ofac(opts \\ []) do
    url = Keyword.get(opts, :url, ofac_url())

    with {:ok, body} <- fetch_json(url),
         entries <- extract_ofac_entries(body) do
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

    with {:ok, body} <- fetch_ndjson(url) do
      %{records: records, skipped: skipped} = OpenSanctions.parse(body)
      do_upsert("opensanctions", records, skipped)
    end
  end

  # --- Fetch helpers ----------------------------------------------------

  defp fetch_json(url) do
    case Req.get(url, req_options()) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("WalletScreening.Ingestion: OFAC feed returned HTTP #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("WalletScreening.Ingestion: OFAC fetch failed: #{inspect(reason)}")
        {:error, {:fetch_failed, reason}}
    end
  end

  defp fetch_ndjson(url) do
    case Req.get(url, Keyword.merge(req_options(), decode_body: false)) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        entities =
          body
          |> String.split("\n", trim: true)
          |> Enum.reduce([], fn line, acc ->
            case Jason.decode(line) do
              {:ok, entity} -> [entity | acc]
              {:error, _} -> acc
            end
          end)
          |> Enum.reverse()

        {:ok, entities}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("WalletScreening.Ingestion: OpenSanctions feed returned HTTP #{status}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("WalletScreening.Ingestion: OpenSanctions fetch failed: #{inspect(reason)}")
        {:error, {:fetch_failed, reason}}
    end
  end

  # The OFAC consolidated JSON payload structure varies. Support both
  # a top-level list and a map with a nested list.
  defp extract_ofac_entries(body) when is_list(body) do
    OFAC.extract_digital_currency_entries(body)
  end

  defp extract_ofac_entries(body) when is_map(body) do
    entries =
      Map.get(body, "results", Map.get(body, "entries", Map.get(body, "data", [])))

    OFAC.extract_digital_currency_entries(entries)
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
            Logger.error(
              "WalletScreening.Ingestion: #{source} upsert failed: #{inspect(reason)}"
            )

            {:error, reason}
        end
    end
  end

  # --- Config -----------------------------------------------------------

  defp config, do: Application.get_env(:bank, __MODULE__, [])

  defp ofac_url, do: Keyword.get(config(), :ofac_url, @default_ofac_url)
  defp opensanctions_url, do: Keyword.get(config(), :opensanctions_url, @default_opensanctions_url)
  defp req_options, do: Keyword.get(config(), :req_options, [])
end
