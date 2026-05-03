defmodule Bank.Activity.ImportedActivity do
  @moduledoc """
  Normalized imported activity ledger row (#243).

  One row per source-side activity (CSV import, on-chain wallet sync,
  smart-account chain sync, manual operator entry). Workspace-scoped:
  the partial `(workspace_id, dedupe_key)` unique index makes
  re-imports idempotent within a workspace and incapable of
  bleeding across tenants.

  ## Read-only ledger contract

  This schema models accounting/ledger evidence. It is NOT part of
  the runtime execution path. Inserting an `ImportedActivity` does
  NOT:

    * write or mutate `Bank.Decisions.ExecutionPlan`,
    * enqueue an Oban job,
    * call `Bank.AdapterClient`, the chain adapter, or any
      broadcast/signing path,
    * create an `AgentIntent` or any decision envelope.

  Future surfaces (#244 CSV upload, #245 chain sync, reconciler) may
  read this table and link to it from intents/decisions, but the
  link goes one way: ledger → intent, never the other way.

  ## Dedupe key

  `dedupe_key` is computed by `Bank.Activity.compute_dedupe_key/1`
  and stored on the row. A re-import of the same source row collides
  on the partial unique index and the context returns
  `{:ok, :duplicate, existing}` without raising.

  ## Metadata

  `metadata` preserves unknown source-side fields verbatim so a
  future reconciler can re-derive a classification without re-pulling
  the source. The context's `redact_metadata/1` strips well-known
  secret keys (`Authorization`, `Bearer`, `private_key`, etc.)
  before write — the schema itself does not enforce that, the
  context does. See `Bank.Activity` for the full list.
  """

  use Bank.Schema

  alias Bank.Counterparties.Counterparty
  alias Bank.Workspaces.Workspace

  @source_types [:csv, :wallet_chain, :smart_account_chain, :manual]
  @directions [:inbound, :outbound]
  @statuses [:confirmed, :pending, :failed, :imported]
  @confidences [:high, :medium, :low]

  @type t :: %__MODULE__{}

  schema "imported_activities" do
    field :source_type, Ecto.Enum, values: @source_types
    field :source_ref, :string
    field :source_hash, :string

    field :occurred_at, :utc_datetime_usec

    field :asset, :string
    field :chain, :string
    field :amount, :decimal
    field :direction, Ecto.Enum, values: @directions

    field :from_address, :string
    field :to_address, :string

    field :tx_hash, :string
    field :bank_ref, :string

    field :status, Ecto.Enum, values: @statuses, default: :imported
    field :provenance, :string
    field :confidence, Ecto.Enum, values: @confidences, default: :medium

    field :metadata, :map, default: %{}
    field :dedupe_key, :string

    belongs_to :workspace, Workspace
    belongs_to :counterparty, Counterparty

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(
    workspace_id
    source_type
    source_ref
    source_hash
    occurred_at
    asset
    chain
    amount
    direction
    from_address
    to_address
    counterparty_id
    tx_hash
    bank_ref
    status
    provenance
    confidence
    metadata
    dedupe_key
  )a

  @required_fields ~w(
    workspace_id
    source_type
    occurred_at
    asset
    amount
    direction
    dedupe_key
  )a

  @doc """
  Insert changeset. Caller (the `Bank.Activity` context) MUST
  pre-compute `:dedupe_key` and pre-redact `:metadata` before
  passing attrs in — the schema validates structure but does not
  derive either field.
  """
  @spec create_changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def create_changeset(%__MODULE__{} = activity, attrs) do
    activity
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_at_least_one_source_handle()
    |> validate_amount_non_negative()
    |> assoc_constraint(:workspace)
    |> assoc_constraint(:counterparty)
    |> unique_constraint([:workspace_id, :dedupe_key],
      name: :imported_activities_workspace_dedupe_uniq
    )
  end

  @doc "Source-type enum, exported for callers / tests."
  @spec source_types() :: [atom()]
  def source_types, do: @source_types

  @doc "Direction enum, exported for callers / tests."
  @spec directions() :: [atom()]
  def directions, do: @directions

  @doc "Status enum, exported for callers / tests."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "Confidence enum, exported for callers / tests."
  @spec confidences() :: [atom()]
  def confidences, do: @confidences

  defp validate_at_least_one_source_handle(changeset) do
    ref = get_field(changeset, :source_ref)
    hash = get_field(changeset, :source_hash)

    if blank?(ref) and blank?(hash) do
      add_error(
        changeset,
        :source_ref,
        "either :source_ref or :source_hash must be present"
      )
    else
      changeset
    end
  end

  defp validate_amount_non_negative(changeset) do
    case get_field(changeset, :amount) do
      %Decimal{} = amount ->
        if Decimal.lt?(amount, 0) do
          add_error(changeset, :amount, "must be non-negative; sign is carried in :direction")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
