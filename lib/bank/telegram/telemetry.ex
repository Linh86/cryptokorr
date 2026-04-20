defmodule Bank.Telegram.Telemetry do
  @moduledoc """
  Typed wrappers around `:telemetry.execute/3` for the Telegram
  operator-bot surface (issue #74, epic #54).

  Mirrors the style of `Bank.Runtime.Telemetry`: one helper per
  event family, tag shapes pinned by a spec, and emission is
  best-effort — telemetry is an observability signal, never a
  correctness path, so emitters rescue / catch any error and
  return `:ok`.

  ## Event families

    * `[:bank, :telegram, :transport]` — one event per outbound
      Telegram Bot API call from `Bank.Telegram.Transport`.
      Metadata: `method`, `result` (`:ok` or an atom like
      `:telegram_unavailable` / `:telegram_rejected` /
      `:invalid_response` / `:bot_disabled` /
      `:bot_not_configured` / `:invalid_config`), and
      `retriable` (`true | false | :unknown` — see
      `Bank.Telegram.Transport.retriable?/1`).

    * `[:bank, :telegram, :alert]` — one event per
      `Bank.Telegram.Alerts.dispatch/1` outcome. Metadata:
      `alert_type`, `result` (`:ok` or an atom from the Alerts
      dispatch error surface — `:bot_disabled`,
      `:bot_not_configured`, `:invalid_config`, `:no_operators`,
      `:all_failed`, `:render_error`), `targeted` (total operator
      count) and `failed` (per-operator failure count on
      `:ok`/`:all_failed`).

    * `[:bank, :telegram, :webhook_auth]` — one event per
      `BankWeb.Plugs.VerifyTelegramWebhook` outcome. Metadata:
      `result` (`:ok` | `:missing_secret_token` |
      `:invalid_secret_token` | `:bot_disabled` |
      `:server_misconfigured`). Ops dashboards can graph the
      reject-class split to spot misconfigured clients vs
      brute-force attempts.

  ## Why telemetry and not Logger only

  Logger lines carry free-form text that's operator-friendly but
  hard to aggregate. Telemetry events fan out to any handler the
  runtime attaches, so ops dashboards, alerting pipelines, and
  tests can all observe the same signals without parsing log
  strings. The existing Logger calls stay — both surfaces coexist.

  ## Metrics integration

  Event attachment lives with the rest of the Phoenix telemetry
  configuration; consumers (Prometheus, Datadog, logs) subscribe
  via `:telemetry.attach/5` or the `telemetry_metrics` poller.
  This module deliberately does not depend on any specific
  backend.
  """

  @type transport_result ::
          :ok
          | :telegram_unavailable
          | :telegram_rejected
          | :invalid_response
          | :bot_disabled
          | :bot_not_configured
          | :invalid_config

  @type alert_result ::
          :ok
          | :bot_disabled
          | :bot_not_configured
          | :invalid_config
          | :no_operators
          | :all_failed
          | :render_error

  @type webhook_auth_result ::
          :ok
          | :missing_secret_token
          | :invalid_secret_token
          | :bot_disabled
          | :server_misconfigured

  @doc """
  Record a Bot API transport call result.

    * `method` — the Telegram Bot API method, e.g. `"sendMessage"`.
    * `result` — one of `t:transport_result/0`.
    * `retriable` — `true | false | :unknown` from
      `Bank.Telegram.Transport.retriable?/1`; dashboards use
      this to split transient failures from hard rejections.
  """
  @spec transport(String.t(), transport_result(), boolean() | :unknown) :: :ok
  def transport(method, result, retriable)
      when is_binary(method) and is_atom(result) and
             (is_boolean(retriable) or retriable == :unknown) do
    safe_emit(
      [:bank, :telegram, :transport],
      %{count: 1},
      %{method: method, result: result, retriable: retriable}
    )
  end

  @doc """
  Record an alert-dispatch outcome.

    * `alert_type` — the alert atom from
      `Bank.Telegram.Alerts.alert_types/0`.
    * `result` — one of `t:alert_result/0`.
    * `targeted` — number of operators the dispatch fanned out to
      (0 for short-circuit paths like `:bot_disabled`).
    * `failed` — per-operator failures observed; equal to
      `targeted` on `:all_failed`, 0 on full success.
  """
  @spec alert(atom(), alert_result(), non_neg_integer(), non_neg_integer()) :: :ok
  def alert(alert_type, result, targeted, failed)
      when is_atom(alert_type) and is_atom(result) and
             is_integer(targeted) and targeted >= 0 and
             is_integer(failed) and failed >= 0 do
    safe_emit(
      [:bank, :telegram, :alert],
      %{count: 1, targeted: targeted, failed: failed},
      %{alert_type: alert_type, result: result}
    )
  end

  @doc """
  Record a webhook-auth outcome from
  `BankWeb.Plugs.VerifyTelegramWebhook`.
  """
  @spec webhook_auth(webhook_auth_result()) :: :ok
  def webhook_auth(result) when is_atom(result) do
    safe_emit(
      [:bank, :telegram, :webhook_auth],
      %{count: 1},
      %{result: result}
    )
  end

  @doc "Canonical event names, for `:telemetry.attach_many/4` wiring."
  @spec events() :: [[atom()]]
  def events do
    [
      [:bank, :telegram, :transport],
      [:bank, :telegram, :alert],
      [:bank, :telegram, :webhook_auth]
    ]
  end

  defp safe_emit(event, measurements, metadata) do
    try do
      :telemetry.execute(event, measurements, metadata)
      :ok
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end
end
