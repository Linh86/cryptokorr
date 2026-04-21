defmodule Bank.WalletScreening.IntentScreening do
  @moduledoc """
  Resolves and runs wallet screening for an `%AgentIntent{}`.

  Used by `Bank.Autonomy` to get a machine-readable screening outcome
  before the autonomy truth table runs. Keeps the address resolution
  and screening call out of the autonomy module itself.

  ## Resolution

  The intent's target address is resolved in order:
  1. `target_raw_address` — used directly with `intent.chain`
  2. `target_address_label` / `target_address_label_id` — uses the
     label's own `(chain, address)` pair
  3. `target_counterparty_id` + `intent.chain` — resolves the single
     active label for that counterparty on the intent chain
  4. Neither present — returns `:not_applicable`

  ## Return shape

  Returns a screening result map:
  - `%{status: :block, outcome: %ScreeningOutcome{}, ...}` — sanctions hit
  - `%{status: :challenge, outcome: %ScreeningOutcome{}, ...}` — scam hit
  - `%{status: :clean, outcome: %ScreeningOutcome{}, ...}` — no actionable hit
  - `%{status: :unresolved, reason: atom(), ...}` — target references an
    address shape that exists but cannot be resolved safely
  - `%{status: :not_applicable, reason: atom()}` — no address-like target
  """

  alias Bank.Counterparties.AddressLabel
  alias Bank.Intents.AgentIntent
  alias Bank.Repo
  alias Bank.WalletScreening
  alias Bank.WalletScreening.ScreeningOutcome

  import Ecto.Query

  @type screening_result ::
          %{
            status: :block | :challenge | :clean,
            outcome: ScreeningOutcome.t(),
            chain: String.t(),
            address: String.t(),
            winning_source: String.t() | nil,
            winning_reason: String.t() | nil
          }
          | %{status: :unresolved, reason: atom(), chain: String.t() | nil}
          | %{status: :not_applicable, reason: atom()}

  @type resolved_target ::
          {:ok, String.t(), String.t()}
          | {:unresolved, atom(), String.t() | nil}
          | {:not_applicable, atom()}

  @doc """
  Screen an intent's target address. Returns a map the autonomy
  router can pattern-match on.
  """
  @spec screen(AgentIntent.t()) :: screening_result()
  def screen(%AgentIntent{} = intent) do
    case resolve_target(intent) do
      {:ok, chain, address} ->
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

      {:unresolved, reason, chain} ->
        %{status: :unresolved, reason: reason, chain: chain}

      {:not_applicable, reason} ->
        %{status: :not_applicable, reason: reason}
    end
  end

  @doc """
  Resolve an intent into the canonical `(chain, address)` pair used by
  wallet screening, without running the screening lookup.
  """
  @spec resolve_target(AgentIntent.t()) :: resolved_target()
  def resolve_target(%AgentIntent{target_raw_address: addr, chain: chain})
      when is_binary(addr) and addr != "" do
    {:ok, chain, addr}
  end

  def resolve_target(%AgentIntent{target_address_label: %AddressLabel{} = label}) do
    label_target(label)
  end

  def resolve_target(%AgentIntent{target_address_label_id: label_id})
      when is_binary(label_id) do
    case Repo.get(AddressLabel, label_id) do
      nil -> {:unresolved, :label_missing, nil}
      %AddressLabel{} = label -> label_target(label)
    end
  end

  def resolve_target(%AgentIntent{id: nil, target_counterparty_id: cp_id})
      when is_binary(cp_id) do
    {:not_applicable, :unpersisted_counterparty_target}
  end

  def resolve_target(%AgentIntent{target_counterparty_id: cp_id, chain: chain})
      when is_binary(cp_id) and is_binary(chain) do
    labels =
      Repo.all(
        from(l in AddressLabel,
          where:
            l.counterparty_id == ^cp_id and
              l.chain == ^chain and
              is_nil(l.retired_at),
          order_by: [asc: l.inserted_at]
        )
      )

    case labels do
      [label] -> label_target(label)
      [] -> {:unresolved, :no_active_label, chain}
      _ -> {:unresolved, :ambiguous_active_labels, chain}
    end
  end

  def resolve_target(_), do: {:not_applicable, :missing_target}

  defp label_target(%AddressLabel{retired_at: %DateTime{}, chain: chain}) do
    {:unresolved, :label_retired, chain}
  end

  defp label_target(%AddressLabel{chain: chain, address: address})
       when is_binary(chain) and is_binary(address) and address != "" do
    {:ok, chain, address}
  end

  defp label_target(%AddressLabel{chain: chain}) do
    {:unresolved, :label_missing_address, chain}
  end
end
