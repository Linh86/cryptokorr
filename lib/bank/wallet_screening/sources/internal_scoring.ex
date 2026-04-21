defmodule Bank.WalletScreening.Sources.InternalScoring do
  @moduledoc """
  Parser and normalizer for internal suspicious-wallet scoring data.

  Consumes feature-engineered scoring outputs (e.g. Elliptic++-style
  models) and normalizes each into the `ScreeningRecord` shape with
  `control_tier: :score_only`.

  ## Contract

  Score-only records are explicitly the weakest signal in the control
  model. They **must never** produce a `:block` or `:challenge`
  screening outcome on their own. They widen review friction
  (increasing the risk tier or triggering operator advisory) but
  cannot autonomously deny execution.

  ## Input format

  Scoring results are expected as a list of maps:

      [
        %{
          "address" => "0x1234...",
          "chain" => "ethereum",
          "score" => 0.87,
          "model_version" => "elliptic-v2.1",
          "features" => ["high_fan_in", "mixer_exposure"],
          "category" => "suspicious",
          "scored_at" => "2025-06-01T12:00:00Z"
        },
        ...
      ]

  Required fields: `address`, `chain`, `score`, `model_version`.
  Optional: `features`, `category`, `scored_at`.

  ## Score semantics

  `score` is a normalized value in [0.0, 1.0] where higher values
  indicate greater suspicion. The scoring pipeline does not define
  thresholds — downstream consumers (autonomy router, operator UI)
  interpret the value. This separation keeps the scoring contract
  clean: the model produces a number, the product decides what to
  do with it.

  ## Provenance

  Every record preserves:
  - `score` and `score_version` (the model version that produced it)
  - `metadata.features` (the feature set or family used)
  - `metadata.scored_at` (when the score was computed)
  - `reason` (human-readable summary)
  - `source_record_id` (deterministic from chain + address + model version)
  """

  @source_name "internal_scoring"

  @type parse_result :: %{
          records: [map()],
          skipped: [map()]
        }

  @doc """
  Parse scoring results into screening record attribute maps.

  Accepts a list of scoring entries. Returns
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
    chain = get_string(entry, "chain")
    score = get_score(entry)
    model_version = get_string(entry, "model_version")

    cond do
      is_nil(address) or address == "" ->
        {:skip, "missing or empty address"}

      is_nil(chain) or chain == "" ->
        {:skip, "missing chain for address #{address}"}

      is_nil(score) ->
        {:skip, "missing or invalid score for address #{address}"}

      is_nil(model_version) or model_version == "" ->
        {:skip, "missing model_version for address #{address}"}

      true ->
        {:ok, build_record(entry, chain, address, score, model_version)}
    end
  end

  defp build_record(entry, chain, address, score, model_version) do
    features = Map.get(entry, "features", [])
    category = get_string(entry, "category") || "suspicious"
    scored_at = get_string(entry, "scored_at")

    %{
      chain: chain,
      address: address,
      control_tier: :score_only,
      source: @source_name,
      source_record_id: build_source_record_id(chain, address, model_version),
      category: category,
      reason: build_reason(score, model_version, category),
      evidence_uri: nil,
      score: to_decimal(score),
      score_version: model_version,
      metadata: %{
        "model_version" => model_version,
        "features" => features,
        "category" => category,
        "scored_at" => scored_at,
        "raw_score" => score
      },
      first_seen_at: parse_datetime(scored_at),
      last_seen_at: parse_datetime(scored_at)
    }
  end

  defp build_source_record_id(chain, address, model_version) do
    hash =
      :crypto.hash(:sha256, "#{chain}:#{address}:#{model_version}")
      |> binary_part(0, 6)
      |> Base.encode16(case: :lower)

    "score-#{hash}"
  end

  defp build_reason(score, model_version, category) do
    score_str = if is_float(score), do: Float.round(score, 4), else: score
    "Internal scoring: #{category} (score=#{score_str}, model=#{model_version})"
  end

  defp get_score(entry) do
    case Map.get(entry, "score") do
      s when is_float(s) and s >= 0.0 and s <= 1.0 -> s
      s when is_integer(s) and s >= 0 and s <= 1 -> s / 1
      %Decimal{} = d -> Decimal.to_float(d)
      s when is_binary(s) -> parse_float_score(s)
      _ -> nil
    end
  end

  defp parse_float_score(s) do
    case Float.parse(s) do
      {f, _} when f >= 0.0 and f <= 1.0 -> f
      _ -> nil
    end
  end

  defp to_decimal(score) when is_float(score), do: Decimal.from_float(score)
  defp to_decimal(score) when is_integer(score), do: Decimal.new(score)
  defp to_decimal(%Decimal{} = d), do: d

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
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
