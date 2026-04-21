defmodule Bank.WalletScreening.ScreeningOutcome do
  @moduledoc """
  Machine-readable screening outcome produced by `Bank.WalletScreening.screen/3`.

  Encapsulates the precedence logic: when multiple screening records
  match an address, the highest-priority control tier wins.

      hard_block > challenge > context > score_only

  ## Outcome vocabulary

    * `:block` — at least one `:hard_block` record matched. The
      runtime must not execute.
    * `:challenge` — at least one `:challenge` record matched (and no
      `:hard_block`). Route to manual review.
    * `:clean` — no blocking or challenging hits. Context and
      score-only records are still carried for enrichment.

  ## Explainability

  `winning_record` is the single record that determined the outcome
  (highest tier, most recent within that tier). `all_records` carries
  every matching record so the operator can see the full picture.
  `context_records` and `score_records` are convenience accessors for
  the enrichment-only data.
  """

  alias Bank.WalletScreening.ScreeningRecord

  @type outcome :: :block | :challenge | :clean

  @type t :: %__MODULE__{
          outcome: outcome(),
          winning_record: ScreeningRecord.t() | nil,
          all_records: [ScreeningRecord.t()],
          context_records: [ScreeningRecord.t()],
          score_records: [ScreeningRecord.t()]
        }

  @enforce_keys [:outcome]
  defstruct outcome: :clean,
            winning_record: nil,
            all_records: [],
            context_records: [],
            score_records: []

  @tier_priority %{
    hard_block: 0,
    challenge: 1,
    context: 2,
    score_only: 3
  }

  @doc """
  Derive the screening outcome from a list of matching records.

  Records are expected to be pre-sorted by `updated_at desc` from the
  query layer.
  """
  @spec from_records([ScreeningRecord.t()]) :: t()
  def from_records([]) do
    %__MODULE__{outcome: :clean}
  end

  def from_records(records) when is_list(records) do
    sorted = Enum.sort_by(records, &Map.get(@tier_priority, &1.control_tier, 99))

    winning = List.first(sorted)
    outcome = tier_to_outcome(winning.control_tier)

    %__MODULE__{
      outcome: outcome,
      winning_record: winning,
      all_records: records,
      context_records: Enum.filter(records, &(&1.control_tier == :context)),
      score_records: Enum.filter(records, &(&1.control_tier == :score_only))
    }
  end

  @doc """
  Returns `true` when the outcome requires the runtime to stop
  execution (`:block` or `:challenge`).
  """
  @spec actionable?(t()) :: boolean()
  def actionable?(%__MODULE__{outcome: :block}), do: true
  def actionable?(%__MODULE__{outcome: :challenge}), do: true
  def actionable?(%__MODULE__{outcome: :clean}), do: false

  @doc """
  Returns `true` when the outcome is a hard block.
  """
  @spec blocked?(t()) :: boolean()
  def blocked?(%__MODULE__{outcome: :block}), do: true
  def blocked?(_), do: false

  defp tier_to_outcome(:hard_block), do: :block
  defp tier_to_outcome(:challenge), do: :challenge
  defp tier_to_outcome(:context), do: :clean
  defp tier_to_outcome(:score_only), do: :clean
end
