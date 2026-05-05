defmodule Bank.Notifications.Deliveries do
  @moduledoc """
  Notification delivery preferences + per-channel delivery
  state (#236).

  This module is the orchestrator that bridges the inbox row
  (`Bank.Notifications.Notification` from #233) to one or
  more external channels. It owns:

    * preference upserts (`set_preference/1`,
      `disable_preference/1`)
    * preference reads (`list_preferences/2`,
      `enabled_channels_for/1`)
    * per-channel delivery row creation
      (`enqueue_deliveries/1`)
    * delivery state transitions (`attempt_delivery/2`,
      `mark_delivered/2`, `mark_failed/3`)
    * payload rendering (deferred to
      `Bank.Notifications.Channel.payload_for/1` so this
      module never reads the raw inbox row's secret-bearing
      fields directly)

  ## Side-effect contract

    * No external HTTP — the channel modules return a closed
      enum. Real SMTP / webhook / Telegram clients land in
      follow-up issues.
    * No Oban / no PubSub broadcast.
    * No log line carries a raw error body — `last_error` is
      a closed atom enum (see
      `Bank.Notifications.Delivery.last_error_codes/0`).

  ## Workspace boundary

  Every preference and every delivery row carries
  `workspace_id`. Cross-workspace lookups are not supported.
  """

  import Ecto.Query

  alias Bank.Notifications.Channel
  alias Bank.Notifications.Delivery
  alias Bank.Notifications.DeliveryPreference
  alias Bank.Notifications.Notification
  alias Bank.Repo

  @severity_rank %{info: 0, warning: 1, critical: 2}

  @type preference_attrs :: %{
          required(:workspace_id) => Ecto.UUID.t(),
          required(:channel) => atom(),
          optional(:user_id) => Ecto.UUID.t() | nil,
          optional(:role_target) => atom() | nil,
          optional(:min_severity) => atom(),
          optional(:enabled) => boolean()
        }

  @type enqueue_result :: {:ok, [Delivery.t()]} | {:error, term()}

  # --- Preferences -----------------------------------------------------

  @doc """
  Upsert a preference. Idempotent: the same target + channel
  pair returns `{:ok, existing_or_updated}`. Subsequent calls
  with new `min_severity` / `enabled` update the row in place.
  """
  @spec set_preference(preference_attrs()) ::
          {:ok, DeliveryPreference.t()} | {:error, Ecto.Changeset.t()}
  def set_preference(attrs) when is_map(attrs) do
    case fetch_preference(attrs) do
      %DeliveryPreference{} = existing ->
        update_preference(existing, attrs)

      nil ->
        attrs
        |> DeliveryPreference.upsert_changeset()
        |> Repo.insert()
        |> case do
          {:ok, _} = ok ->
            ok

          {:error, %Ecto.Changeset{} = cs} ->
            if dedupe_violation?(cs) do
              # Race winner inserted between our fetch and
              # insert — re-read and update idempotently.
              case fetch_preference(attrs) do
                %DeliveryPreference{} = existing -> update_preference(existing, attrs)
                nil -> {:error, cs}
              end
            else
              {:error, cs}
            end
        end
    end
  end

  defp update_preference(%DeliveryPreference{} = existing, attrs) do
    existing
    |> DeliveryPreference.update_changeset(attrs)
    |> Repo.update()
  end

  defp dedupe_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_, {"duplicate", [{:constraint, :unique} | _]}} -> true
      _ -> false
    end)
  end

  defp fetch_preference(%{user_id: user_id} = attrs) when is_binary(user_id) do
    workspace_id = Map.fetch!(attrs, :workspace_id)
    channel = Map.fetch!(attrs, :channel)

    Repo.one(
      from(p in DeliveryPreference,
        where:
          p.workspace_id == ^workspace_id and p.user_id == ^user_id and
            p.channel == ^channel
      )
    )
  end

  defp fetch_preference(%{role_target: role} = attrs) when not is_nil(role) do
    workspace_id = Map.fetch!(attrs, :workspace_id)
    channel = Map.fetch!(attrs, :channel)

    Repo.one(
      from(p in DeliveryPreference,
        where:
          p.workspace_id == ^workspace_id and p.role_target == ^role and
            p.channel == ^channel
      )
    )
  end

  defp fetch_preference(_), do: nil

  @doc "Flip an existing preference's `enabled` flag."
  @spec disable_preference(DeliveryPreference.t()) ::
          {:ok, DeliveryPreference.t()} | {:error, Ecto.Changeset.t()}
  def disable_preference(%DeliveryPreference{} = pref) do
    pref
    |> DeliveryPreference.set_enabled_changeset(false)
    |> Repo.update()
  end

  @doc "List preferences in a workspace, optionally filtered by channel / target."
  @spec list_preferences(Ecto.UUID.t(), keyword()) :: [DeliveryPreference.t()]
  def list_preferences(workspace_id, opts \\ []) when is_binary(workspace_id) do
    DeliveryPreference
    |> where([p], p.workspace_id == ^workspace_id)
    |> filter_preferences(opts)
    |> order_by([p], asc: p.inserted_at)
    |> Repo.all()
  end

  defp filter_preferences(query, opts) do
    Enum.reduce(opts, query, fn
      {:channel, channel}, q -> where(q, [p], p.channel == ^channel)
      {:user_id, user_id}, q when is_binary(user_id) -> where(q, [p], p.user_id == ^user_id)
      {:role_target, role}, q when not is_nil(role) -> where(q, [p], p.role_target == ^role)
      {:enabled, e}, q when is_boolean(e) -> where(q, [p], p.enabled == ^e)
      _, q -> q
    end)
  end

  @doc """
  Compute the list of channels this notification should be
  delivered to, given the preferences in its workspace.

  Resolution rule:

    1. If the notification has a `user_id`, look up the
       `user_id`-targeted preferences first. A row found
       there determines the channel state (enabled +
       severity threshold met).
    2. Otherwise, look up the `role_target`-targeted
       preferences for the notification's `role_target`.
    3. No preference → channel is OFF (safe default — the
       inbox row is always written; external delivery is
       opt-in).

  Returns a list of channel atoms in
  `Bank.Notifications.Delivery.channels/0`.
  """
  @spec enabled_channels_for(Notification.t()) :: [atom()]
  def enabled_channels_for(%Notification{} = n) do
    workspace_id = n.workspace_id
    severity = n.severity

    rows = preferences_for_recipient(n)

    rows
    |> Enum.filter(fn p ->
      p.workspace_id == workspace_id and p.enabled and severity_meets?(severity, p.min_severity)
    end)
    |> Enum.map(& &1.channel)
    |> Enum.uniq()
  end

  defp preferences_for_recipient(%Notification{user_id: user_id}) when is_binary(user_id) do
    DeliveryPreference
    |> where([p], p.user_id == ^user_id)
    |> Repo.all()
  end

  defp preferences_for_recipient(%Notification{role_target: role}) when not is_nil(role) do
    DeliveryPreference
    |> where([p], p.role_target == ^role)
    |> Repo.all()
  end

  defp preferences_for_recipient(_), do: []

  defp severity_meets?(severity, min_severity) do
    Map.get(@severity_rank, severity, 0) >= Map.get(@severity_rank, min_severity, 0)
  end

  # --- Deliveries ------------------------------------------------------

  @doc """
  Create one `notification_deliveries` row per enabled
  channel for the given notification. Idempotent: a second
  call for the same notification returns the existing rows
  without inserting duplicates.
  """
  @spec enqueue_deliveries(Notification.t()) :: enqueue_result()
  def enqueue_deliveries(%Notification{} = n) do
    channels = enabled_channels_for(n)

    rows =
      Enum.map(channels, fn channel ->
        attrs = %{
          notification_id: n.id,
          workspace_id: n.workspace_id,
          channel: channel,
          status: :queued,
          attempts: 0
        }

        case attrs |> Delivery.create_changeset() |> Repo.insert() do
          {:ok, row} ->
            row

          {:error, %Ecto.Changeset{} = cs} ->
            if dedupe_violation?(cs) do
              Repo.one(
                from(d in Delivery,
                  where: d.notification_id == ^n.id and d.channel == ^channel
                )
              )
            else
              cs
            end
        end
      end)

    case Enum.find(rows, &match?(%Ecto.Changeset{}, &1)) do
      nil -> {:ok, rows}
      cs -> {:error, cs}
    end
  end

  @doc "List delivery rows for one notification."
  @spec list_deliveries_for(Notification.t() | Ecto.UUID.t()) :: [Delivery.t()]
  def list_deliveries_for(%Notification{id: id}), do: list_deliveries_for(id)

  def list_deliveries_for(notification_id) when is_binary(notification_id) do
    Repo.all(
      from(d in Delivery,
        where: d.notification_id == ^notification_id,
        order_by: [asc: d.inserted_at]
      )
    )
  end

  @doc """
  Run one delivery attempt. Looks up the channel module via
  `Bank.Notifications.Channel.module_for/1`, renders the
  redacted payload, calls `deliver/3`, and records the
  outcome (delivered / failed / permanently_failed).

  Returns the updated `%Delivery{}`.
  """
  @spec attempt_delivery(Delivery.t(), DateTime.t()) ::
          {:ok, Delivery.t()} | {:error, Ecto.Changeset.t() | term()}
  def attempt_delivery(%Delivery{} = d, %DateTime{} = now) do
    notification = Repo.get!(Notification, d.notification_id)
    payload = Channel.payload_for(notification)
    channel_mod = Channel.module_for(d)

    case channel_mod.deliver(notification, payload, []) do
      {:ok, _info} ->
        d
        |> Delivery.mark_delivered_changeset(now)
        |> Repo.update()

      {:error, code} when is_atom(code) ->
        d
        |> Delivery.mark_failed_changeset(code, now)
        |> Repo.update()

      {:permanent_error, code} when is_atom(code) ->
        # Permanent error — skip retry math and go straight
        # to the terminal state.
        d
        |> Delivery.mark_failed_changeset(code, now)
        # If the channel says permanent, force the status to
        # :permanently_failed regardless of attempt count.
        |> Ecto.Changeset.put_change(:status, :permanently_failed)
        |> Ecto.Changeset.put_change(:next_attempt_at, nil)
        |> Repo.update()

      other ->
        {:error, {:invalid_channel_result, other}}
    end
  end

  @doc """
  Convenience: run `enqueue_deliveries/1` for a notification.
  Used as a best-effort hook from
  `Bank.Notifications.create/1`. Returns `:ok` regardless of
  outcome (errors are intentionally swallowed so a
  preference-side failure cannot break the inbox-row write).
  """
  @spec dispatch_after_create(Notification.t()) :: :ok
  def dispatch_after_create(%Notification{} = n) do
    case enqueue_deliveries(n) do
      {:ok, _} -> :ok
      {:error, _} -> :ok
    end
  end
end
