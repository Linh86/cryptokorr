defmodule Bank.Notifications.Delivery do
  @moduledoc """
  Per-channel delivery state row for an inbox notification (#236).

  Tracks one external-channel delivery attempt history for one
  `Bank.Notifications.Notification`. The inbox row itself is
  always preserved — failed external delivery never deletes,
  archives, or rewrites the inbox row (the issue's "in-app
  notification still exists even if external delivery fails"
  acceptance bullet).

  ## Status enum

      :queued             — waiting for the worker
      :delivering         — in-flight (worker has the row locked)
      :delivered          — terminal success
      :failed             — transient failure; will retry after
                            `next_attempt_at`
      :permanently_failed — terminal: hit `max_attempts` cap

  ## Last-error vocabulary

  `last_error` is intentionally a closed atom enum, not a free-
  text reason. Channel modules return one of:

      :transport_error      — network / DNS / TCP failure
      :provider_5xx         — server-side failure
      :provider_4xx         — client-side / config failure
      :provider_timeout     — request hit the receive timeout
      :malformed_payload    — local marshalling failure
      :rate_limited         — provider returned 429
      :unknown              — fallback when the channel cannot
                              classify the error

  This keeps a regression that accidentally captures a raw
  response body or a provider stacktrace at compile-time.
  """

  use Bank.Schema

  alias Bank.Notifications.Delivery
  alias Bank.Notifications.Notification

  @statuses ~w(queued delivering delivered failed permanently_failed)a
  @channels ~w(email webhook telegram)a

  @last_error_codes ~w(
    transport_error
    provider_5xx
    provider_4xx
    provider_timeout
    malformed_payload
    rate_limited
    unknown
  )a

  @type t :: %__MODULE__{}

  @doc "Closed status vocabulary for delivery rows."
  @spec statuses() :: [atom()]
  def statuses, do: @statuses

  @doc "Closed channel vocabulary."
  @spec channels() :: [atom()]
  def channels, do: @channels

  @doc "Closed last-error vocabulary."
  @spec last_error_codes() :: [atom()]
  def last_error_codes, do: @last_error_codes

  schema "notification_deliveries" do
    belongs_to :notification, Notification
    field :workspace_id, :binary_id

    field :channel, Ecto.Enum, values: @channels
    field :status, Ecto.Enum, values: @statuses, default: :queued

    field :attempts, :integer, default: 0
    field :max_attempts, :integer, default: 5

    field :last_error, Ecto.Enum, values: @last_error_codes
    field :next_attempt_at, :utc_datetime_usec
    field :delivered_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields ~w(notification_id workspace_id channel status attempts max_attempts last_error
                  next_attempt_at delivered_at)a
  @required_fields ~w(notification_id workspace_id channel)a

  @doc "Initial-insert changeset; `status` defaults to `:queued`."
  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) when is_map(attrs) do
    %Delivery{}
    |> cast(attrs, @cast_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:channel, @channels)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:last_error, @last_error_codes)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than: 0)
    |> unique_constraint(
      [:notification_id, :channel],
      name: :nd_notification_channel_uidx,
      message: "duplicate"
    )
    |> foreign_key_constraint(:notification_id)
    |> foreign_key_constraint(:workspace_id)
  end

  @doc "Transition to `:delivered` and stamp `delivered_at`."
  @spec mark_delivered_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def mark_delivered_changeset(%Delivery{} = d, %DateTime{} = at) do
    d
    |> change(status: :delivered, delivered_at: at, last_error: nil, next_attempt_at: nil)
    |> validate_inclusion(:status, @statuses)
  end

  @doc """
  Transition to `:failed` (transient), incrementing
  `attempts`, stamping `last_error`, and computing the next
  retry time. If `attempts + 1 >= max_attempts`, transition to
  `:permanently_failed` instead.
  """
  @spec mark_failed_changeset(t(), atom(), DateTime.t()) :: Ecto.Changeset.t()
  def mark_failed_changeset(%Delivery{} = d, error_code, %DateTime{} = now)
      when error_code in @last_error_codes do
    new_attempts = (d.attempts || 0) + 1

    if new_attempts >= (d.max_attempts || 5) do
      change(d,
        status: :permanently_failed,
        attempts: new_attempts,
        last_error: error_code,
        next_attempt_at: nil
      )
    else
      backoff_seconds = backoff_for(new_attempts)
      next_at = DateTime.add(now, backoff_seconds, :second)

      change(d,
        status: :failed,
        attempts: new_attempts,
        last_error: error_code,
        next_attempt_at: next_at
      )
    end
  end

  @doc """
  Exponential-with-cap backoff: 2^attempts * 30 seconds,
  capped at 1 hour. Deterministic for tests.
  """
  @spec backoff_for(pos_integer()) :: pos_integer()
  def backoff_for(attempts) when is_integer(attempts) and attempts > 0 do
    seconds = trunc(:math.pow(2, attempts) * 30)
    min(seconds, 3600)
  end
end
