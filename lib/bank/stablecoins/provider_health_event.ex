defmodule Bank.Stablecoins.ProviderHealthEvent do
  @moduledoc """
  Durable, workspace-scoped log of stablecoin provider health
  transitions (#422). Append-only counterpart to the volatile ETS
  read store in `Bank.Stablecoins.ProviderHealth`.

  Rows are inserted by `Bank.Stablecoins.ProviderHealth` whenever
  a `record_success/2` or `record_failure/3` call observes a
  `from_state != to_state` transition AND the call carries a
  `workspace_id` opt. The table is the durable provenance for
  workspace-scoped notifications — the inbox row carries a
  pointer back to the event id via `subject_id`.

  Free-text fields (provider-supplied failure reasons,
  Authorization-marker shapes) are NEVER persisted into
  `evidence`. Only counter snapshots reach the row.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @states ~w(unknown healthy degraded failing)a

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "provider_health_events" do
    field :workspace_id, :binary_id
    field :provider, :string
    field :from_state, Ecto.Enum, values: @states
    field :to_state, Ecto.Enum, values: @states
    field :route_session_id, :binary_id
    field :evidence, :map, default: %{}
    field :observed_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(workspace_id provider from_state to_state route_session_id observed_at)a
  @optional ~w(evidence)a

  @doc """
  Build the insert changeset. Casts the controlled enum values
  for `from_state` / `to_state`, requires the workspace +
  provider + session triple, and accepts an optional `evidence`
  map (which is bounded by the migration's JSONB column — the
  caller is responsible for not threading free-text into it).
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = event, attrs) when is_map(attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:provider, max: 64)
  end
end
