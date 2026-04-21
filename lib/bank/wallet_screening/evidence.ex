defmodule Bank.WalletScreening.Evidence do
  @moduledoc """
  Operator-facing screening evidence for a given chain+address pair.

  Produces a serializable map that can be embedded in replay bundles,
  queue views, counterparty surfaces, and API responses. Calls
  `Bank.WalletScreening.screen/3` for the precedence outcome and
  `Bank.WalletScreening.FeedHealth` for freshness context.

  The output clearly distinguishes:
  - sanctions block (hard_block → "illegal to proceed")
  - scam/phishing challenge (challenge → "suspicious, manual review")
  - attribution context (context → "enrichment only, no block")
  - internal score advisory (score_only → "advisory only, no block")
  - clean (no records)

  ## Usage

      Bank.WalletScreening.Evidence.for_address("ethereum", "0x1234...")
      # => %{outcome: "block", tier: "hard_block", source: "ofac", ...}

      Bank.WalletScreening.Evidence.for_intent(intent)
      # => resolves target address from intent, screens it
  """

  alias Bank.WalletScreening
  alias Bank.WalletScreening.{FeedHealth, ScreeningOutcome, ScreeningRecord}
  alias Bank.Counterparties.AddressLabel
  alias Bank.Intents.AgentIntent
  alias Bank.Repo

  @type evidence :: %{
          outcome: String.t(),
          screened_address: String.t() | nil,
          screened_chain: String.t() | nil,
          winning_tier: String.t() | nil,
          winning_source: String.t() | nil,
          winning_reason: String.t() | nil,
          winning_evidence_uri: String.t() | nil,
          total_records: non_neg_integer(),
          records: [map()],
          feed_health: [map()]
        }

  @doc """
  Screen an address and return operator-facing evidence.
  """
  @spec for_address(String.t(), String.t(), keyword()) :: evidence()
  def for_address(chain, address, opts \\ []) when is_binary(chain) and is_binary(address) do
    screening = WalletScreening.screen(chain, address, opts)
    build_evidence(chain, address, screening)
  end

  @doc """
  Screen the target address of an intent and return evidence.

  Resolves the destination address from the intent's
  `target_raw_address` or `target_address_label_id`.
  """
  @spec for_intent(AgentIntent.t(), keyword()) :: evidence()
  def for_intent(%AgentIntent{} = intent, opts \\ []) do
    {chain, address} = resolve_target(intent)

    case {chain, address} do
      {nil, _} -> empty_evidence()
      {_, nil} -> empty_evidence()
      {c, a} -> for_address(c, a, opts)
    end
  end

  @doc """
  Build evidence from a pre-computed screening outcome.
  """
  @spec from_outcome(String.t(), String.t(), ScreeningOutcome.t()) :: evidence()
  def from_outcome(chain, address, %ScreeningOutcome{} = outcome) do
    build_evidence(chain, address, outcome)
  end

  # --- Builders -----------------------------------------------------------

  defp build_evidence(chain, address, %ScreeningOutcome{} = outcome) do
    winning = outcome.winning_record

    %{
      outcome: Atom.to_string(outcome.outcome),
      screened_address: address,
      screened_chain: chain,
      winning_tier: winning && Atom.to_string(winning.control_tier),
      winning_source: winning && winning.source,
      winning_reason: winning && winning.reason,
      winning_evidence_uri: winning && winning.evidence_uri,
      total_records: length(outcome.all_records),
      records: Enum.map(outcome.all_records, &render_record/1),
      feed_health: relevant_feed_health(outcome)
    }
  end

  defp empty_evidence do
    %{
      outcome: "clean",
      screened_address: nil,
      screened_chain: nil,
      winning_tier: nil,
      winning_source: nil,
      winning_reason: nil,
      winning_evidence_uri: nil,
      total_records: 0,
      records: [],
      feed_health: []
    }
  end

  defp render_record(%ScreeningRecord{} = r) do
    %{
      "id" => r.id,
      "control_tier" => Atom.to_string(r.control_tier),
      "source" => r.source,
      "source_record_id" => r.source_record_id,
      "category" => r.category,
      "reason" => r.reason,
      "evidence_uri" => r.evidence_uri,
      "score" => render_decimal(r.score),
      "score_version" => r.score_version,
      "metadata" => r.metadata
    }
  end

  defp render_decimal(nil), do: nil
  defp render_decimal(%Decimal{} = d), do: Decimal.to_string(d, :normal)
  defp render_decimal(other), do: other

  defp relevant_feed_health(%ScreeningOutcome{all_records: records}) do
    sources =
      records
      |> Enum.map(& &1.source)
      |> Enum.uniq()

    case sources do
      [] ->
        FeedHealth.stale_sources_by_severity(:high)
        |> Enum.map(&render_health/1)

      srcs ->
        Enum.map(srcs, fn source ->
          source |> FeedHealth.get() |> render_health()
        end)
    end
  end

  defp render_health(state) do
    %{
      "source" => state.source,
      "status" => Atom.to_string(state.status),
      "severity" => Atom.to_string(state.severity),
      "last_success_at" => state.last_success_at,
      "stale_after_hours" => state.stale_after_hours
    }
  end

  defp resolve_target(%AgentIntent{target_raw_address: addr, chain: chain})
       when is_binary(addr) and addr != "" do
    {chain, addr}
  end

  defp resolve_target(%AgentIntent{target_address_label_id: label_id, chain: chain})
       when is_binary(label_id) do
    case Repo.get(AddressLabel, label_id) do
      nil -> {chain, nil}
      %AddressLabel{address: addr} -> {chain, addr}
    end
  end

  defp resolve_target(_), do: {nil, nil}
end
