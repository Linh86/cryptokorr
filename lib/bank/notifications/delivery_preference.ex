defmodule Bank.Notifications.DeliveryPreference do
  @moduledoc """
  Per-workspace preference for delivering inbox notifications
  to an external channel (#236).

  ## Targeting

  Exactly one of `user_id` or `role_target` must be set:

    * `user_id` — the preference applies to one specific user
      in this workspace.
    * `role_target` — the preference applies to every member
      whose membership role is `role_target`.

  Both null is rejected at the changeset layer; both set is
  rejected too. Partial unique indexes at the DB layer prevent
  duplicate `(workspace, user, channel)` and
  `(workspace, role, channel)` rows under concurrent writers.

  ## Channels

  External channels only — the `:in_app` channel is implicit
  in the inbox row itself, so there is no preference for it.
  Adding a new channel requires expanding the `@channels`
  vocabulary here AND the matching enum in
  `Bank.Notifications.Delivery`.

  ## Severity gating

  `min_severity` is the minimum
  `Bank.Notifications.Notification` severity that triggers
  delivery on this channel. The enum follows the inbox row's
  `info < warning < critical` ordering.

  ## Defaults

    * `min_severity: :warning` — operators / admins typically
      only want external notifications for warnings and
      above; info-level rows stay in-app only.
    * `enabled: true` — the row's existence implies the
      channel is opted in unless the operator explicitly
      flips it off.
  """

  use Bank.Schema

  alias Bank.Notifications.DeliveryPreference

  @channels ~w(email webhook telegram)a
  @role_targets ~w(viewer operator admin owner)a
  @severities ~w(info warning critical)a

  @type t :: %__MODULE__{}

  @doc "Closed channel vocabulary for external delivery."
  @spec channels() :: [atom()]
  def channels, do: @channels

  @doc "Closed severity vocabulary."
  @spec severities() :: [atom()]
  def severities, do: @severities

  schema "notification_delivery_preferences" do
    field :workspace_id, :binary_id
    field :user_id, :binary_id
    field :role_target, Ecto.Enum, values: @role_targets

    field :channel, Ecto.Enum, values: @channels
    field :min_severity, Ecto.Enum, values: @severities, default: :warning
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(workspace_id user_id role_target channel min_severity enabled)a
  @required_fields ~w(workspace_id channel)a

  @doc """
  Insert/update changeset. Enforces XOR on `user_id` /
  `role_target`. The unique constraints map to the partial
  indexes for both targeting modes.
  """
  @spec upsert_changeset(map()) :: Ecto.Changeset.t()
  def upsert_changeset(attrs) when is_map(attrs) do
    %DeliveryPreference{}
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:channel, @channels)
    |> validate_inclusion(:min_severity, @severities)
    |> validate_inclusion(:role_target, @role_targets)
    |> validate_target()
    |> unique_constraint(
      [:workspace_id, :user_id, :channel],
      name: :ndp_workspace_user_channel_uidx,
      message: "duplicate"
    )
    |> unique_constraint(
      [:workspace_id, :role_target, :channel],
      name: :ndp_workspace_role_channel_uidx,
      message: "duplicate"
    )
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc "Toggle changeset for the `enabled` flag."
  @spec set_enabled_changeset(t(), boolean()) :: Ecto.Changeset.t()
  def set_enabled_changeset(%DeliveryPreference{} = pref, enabled) when is_boolean(enabled) do
    change(pref, enabled: enabled)
  end

  @doc """
  Update changeset for an existing preference. Accepts only
  the mutable fields (`min_severity`, `enabled`); identity
  fields (`workspace_id`, `user_id`, `role_target`,
  `channel`) cannot be reassigned — operators must delete and
  re-insert if they want to retarget.
  """
  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%DeliveryPreference{} = pref, attrs) when is_map(attrs) do
    pref
    |> cast(attrs, [:min_severity, :enabled])
    |> validate_inclusion(:min_severity, @severities)
  end

  defp validate_target(changeset) do
    user_id = get_field(changeset, :user_id)
    role = get_field(changeset, :role_target)

    case {user_id, role} do
      {nil, nil} ->
        add_error(
          changeset,
          :user_id,
          "either user_id or role_target must be set"
        )

      {uid, role} when not is_nil(uid) and not is_nil(role) ->
        add_error(
          changeset,
          :role_target,
          "user_id and role_target are mutually exclusive"
        )

      _ ->
        changeset
    end
  end
end
