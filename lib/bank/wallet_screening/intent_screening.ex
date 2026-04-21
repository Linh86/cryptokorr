defmodule Bank.WalletScreening.IntentScreening do
  @moduledoc """
  Resolves and runs wallet screening for an `%AgentIntent{}`.

  Used by `Bank.Autonomy` to get a machine-readable screening outcome
  before the autonomy truth table runs. Keeps the address resolution
  and screening call out of the autonomy module itself.

  ## Resolution

  The intent's target address is resolved in order:
  1. `target_raw_address` — used directly with `intent.chain`
  2. `target_address_label_id` — fetches the label's `address`
  3. Neither present — returns `{:ok, :not_applicable}`

  ## Return shape

  Returns `{:ok, screening_result}` where `screening_result` is one of:
  - `%{status: :block, outcome: %ScreeningOutcome{}, ...}` — sanctions hit
  - `%{status: :challenge, outcome: %ScreeningOutcome{}, ...}` — scam hit
  - `%{status: :clean, outcome: %ScreeningOutcome{}, ...}` — no actionable hit
  - `%{status: :not_applicable}` — no resolvable target address
  """

  alias Bank.Counterparties.AddressLabel
  alias Bank.Intents.AgentIntent
  alias Bank.Repo
  alias Bank.WalletScreening
  alias Bank.WalletScreening.ScreeningOutcome

  @type screening_result ::
          %{
            status: :block | :challenge | :clean,
            outcome: ScreeningOutcome.t(),
            chain: String.t(),
            address: String.t(),
            winning_source: String.t() | nil,
            winning_reason: String.t() | nil
          }
          | %{status: :not_applicable}

  @doc """
  Screen an intent's target address. Returns a map the autonomy
  router can pattern-match on.
  """
  @spec screen(AgentIntent.t()) :: screening_result()
  def screen(%AgentIntent{} = intent) do
    case resolve_target(intent) do
      {nil, _} ->
        %{status: :not_applicable}

      {_, nil} ->
        %{status: :not_applicable}

      {chain, address} ->
        outcome = WalletScreening.screen(chain, address)
        winning = outcome.winning_record

        %{
          status: outcome.outcome,
          outcome: outcome,
          chain: chain,
          address: address,
          winning_source: winning && winning.source,
          winning_reason: winning && winning.reason
        }
    end
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
