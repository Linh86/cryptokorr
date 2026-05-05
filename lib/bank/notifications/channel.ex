defmodule Bank.Notifications.Channel do
  @moduledoc """
  Behaviour for an external delivery channel (#236).

  Implementations are *thin* — they take a redacted payload
  and return one of a closed set of result atoms. The
  `Bank.Notifications.Deliveries` context is the surface that
  resolves the right channel module for a given delivery,
  builds the payload (already secret-redacted via the inbox
  row's existing #233 secret-marker gate), and records the
  outcome.

  ## Result vocabulary

      {:ok, info}                 — success; the channel may
                                    return a small map of
                                    transport metadata
                                    (provider id, message id);
                                    the caller never logs it.
      {:error, last_error_code}   — transient failure. `last_error_code`
                                    must be one of
                                    `Bank.Notifications.Delivery.last_error_codes/0`.
      {:permanent_error, code}    — terminal failure (auth wrong,
                                    schema rejected). The
                                    deliveries context skips
                                    retries and writes
                                    `:permanently_failed`.

  ## Why a behaviour with stubs

  This first slice ships the preferences + delivery state +
  retry math + payload redaction on top of #233. Real SMTP /
  webhook HTTP / Telegram clients are deferred to follow-up
  work — the issue body says "Add external notification
  delivery channels incrementally"; this is the foundation,
  not the wire-up to a real provider. Each follow-up channel
  implements this behaviour and registers itself in
  `Bank.Notifications.Channel.Registry` (see #205-style
  follow-ups).
  """

  alias Bank.Notifications.Delivery
  alias Bank.Notifications.Notification

  @type payload :: %{
          required(:title) => String.t(),
          required(:body) => String.t(),
          required(:severity) => atom(),
          required(:event_type) => String.t(),
          required(:action_link) => String.t() | nil,
          required(:correlation_id) => Ecto.UUID.t() | nil,
          required(:dedupe_key) => String.t()
        }

  @type result ::
          {:ok, map()}
          | {:error, atom()}
          | {:permanent_error, atom()}

  @doc "Deliver one rendered payload via this channel."
  @callback deliver(Notification.t(), payload(), keyword()) :: result()

  @doc """
  Render the redacted payload for a notification. The
  inbox row's `title` / `body` / `action_link` already
  passed the #233 secret-marker gate at insert time; this
  function projects them into the channel-bound shape and
  drops every other field that could carry surprise
  content.
  """
  @spec payload_for(Notification.t()) :: payload()
  def payload_for(%Notification{} = n) do
    %{
      title: n.title,
      body: n.body,
      severity: n.severity,
      event_type: n.event_type,
      action_link: n.action_link,
      correlation_id: n.correlation_id,
      dedupe_key: n.dedupe_key
    }
  end

  @doc """
  Returns the channel module that handles `delivery.channel`.
  """
  @spec module_for(Delivery.t()) :: module()
  def module_for(%Delivery{channel: :email}), do: Bank.Notifications.Channel.Stub
  def module_for(%Delivery{channel: :webhook}), do: Bank.Notifications.Channel.Stub
  def module_for(%Delivery{channel: :telegram}), do: Bank.Notifications.Channel.Stub
end
