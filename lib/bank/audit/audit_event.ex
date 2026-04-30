defmodule Bank.Audit.AuditEvent do
  @moduledoc """
  An append-only audit record. Every state transition, decision, and
  operator action writes exactly one `AuditEvent` row. Replay for an
  intent is the correlation-id slice ordered by `ts`.

  ## No updates

  The table has no `updated_at`. Correction is a *new* event whose
  `before_ref` / `after_ref` points at the prior event's stored refs —
  never an in-place edit. `timestamps(updated_at: false)` at the
  migration level enforces the insert-only posture.

  ## Polymorphic subject

  `subject_type` is a free string (`"agent_intent"`,
  `"decision_envelope"`, `"address_label"`, `"smart_account"`, ...)
  and `subject_id` is a free-form string. Most subjects today are
  uuid-keyed domain rows, but a smart-account id is a short opaque
  string and future on-chain subjects may use hex addresses — so the
  column is widened to text rather than uuid. Audit does not own
  foreign keys into every domain table; the correlation is by id
  alone. Consumers that need the full object join it separately.

  ## Integrity anchoring

  `payload_hash` captures the canonical hash of the event's payload at
  write time. Later issues add a chain anchor + signature pass on top
  of the payload hash. Writing that pipeline is out of scope for this
  migration / schema pair — that is issue #5.
  """

  use Bank.Schema

  alias Bank.Workspaces.Workspace

  # Insert-only: no `updated_at` column.
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  @actors [:user, :agent, :runtime, :adapter]

  @type t :: %__MODULE__{}

  schema "audit_events" do
    field :ts, :utc_datetime_usec
    field :actor, Ecto.Enum, values: @actors
    field :actor_id, :string
    field :event_type, :string
    field :subject_type, :string
    field :subject_id, :string
    field :correlation_id, Ecto.UUID
    field :before_ref, :map
    field :after_ref, :map
    field :payload_hash, :string
    field :schema_version, :string, default: "1"

    # Nullable workspace scope (#158a foundation; runtime filter in
    # #158b). Read hint only — `workspace_id` is intentionally NOT
    # part of `Bank.Audit.Envelope.@canonical_fields`, so existing
    # event hashes are unaffected and emitters that omit it write
    # nil.
    belongs_to :workspace, Workspace

    timestamps()
  end

  @doc """
  Changeset for writing a new audit event. There is intentionally no
  update changeset — correction goes through writing a new event
  whose `before_ref`/`after_ref` reference the prior row's payload.
  """
  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :ts,
      :actor,
      :actor_id,
      :event_type,
      :subject_type,
      :subject_id,
      :correlation_id,
      :before_ref,
      :after_ref,
      :payload_hash,
      :schema_version,
      :workspace_id
    ])
    |> validate_required([
      :actor,
      :event_type,
      :subject_type,
      :subject_id,
      :payload_hash
    ])
    |> foreign_key_constraint(:workspace_id)
    |> put_default_ts()
  end

  defp put_default_ts(changeset) do
    case get_field(changeset, :ts) do
      nil -> put_change(changeset, :ts, DateTime.utc_now())
      _ -> changeset
    end
  end
end
