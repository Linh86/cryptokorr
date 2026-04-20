defmodule Bank.Telegram.Alerts do
  @moduledoc """
  Outbound Telegram alert delivery and message templates for the MVP
  operator events (issue #68, epic #54).

  This module is the first real consumer of the #69 Telegram
  transport / callback-token boundary. It builds on:

    * `Bank.Telegram.Config` — identity / allowlist / roles / secrets.
    * `Bank.Telegram.Transport` — outbound HTTP to the Telegram Bot API.
    * `Bank.Telegram.CallbackToken` — signed, short-lived, actor-bound
      inline-button payloads.

  Telegram is **not** the source of truth for any alert; every alert
  also has a record in the audit / web control tower. The bot is a
  convenience surface that shortens time-to-decision — operators can
  tap to act, or follow the deep link to the web console for richer
  context.

  ## Supported alert types

  Every alert is a tagged tuple `{:alert_type, context_map}`:

    * `:pending_approval`     — a decision entered the approval queue.
      The only alert with inline buttons today: per-recipient signed
      approve / reject callback tokens. The callback handler itself
      lands in #72; `#68` only emits the button payloads.
    * `:runtime_paused`       — `/v1/security/pause` took effect.
    * `:runtime_resumed`      — `/v1/security/resume` took effect.
    * `:revoke_incident`      — delegation revoke failed or the
      delegation state changed in a way operators should see.
    * `:execution_confirmed`  — execution plan landed on-chain.
    * `:execution_reverted`   — execution plan reverted on-chain.
    * `:execution_aborted`    — execution plan aborted before
      confirmation.
    * `:sanctions_hit`        — destination address matched a
      sanctions list; intent blocked.
    * `:scam_challenge`       — destination address flagged by a
      scam / phishing feed; intent routed to approval.

  ## Fan-out

  Every alert is delivered to every allowlisted operator in
  `Bank.Telegram.Config.load/0`. Deduplication by shared `chat_id`
  is intentionally **not** done here: for the `:pending_approval`
  case each recipient needs their own signed callback tokens, and
  uniform per-operator fan-out keeps the dispatch path simple.
  Operators sharing a group chat will see duplicate messages on
  MVP; a later issue (#74 observability / runbook) can add
  per-alert-class routing if that becomes a problem in practice.

  ## Truthfulness

  Inline buttons exist only for the `:pending_approval` case, and
  only because #72 will wire the callback handlers. Every other
  alert is pure text with deep links to the web console. The
  module does NOT imply that tapping a button on a non-approval
  alert would do something — because no such button is emitted.

  ## Error surface

    * `:ok` — at least one operator chat accepted the message.
    * `{:error, :bot_disabled}` — `Bank.Telegram.Config.enabled?/0`
      is `false`. No transport calls attempted.
    * `{:error, :bot_not_configured}` — enabled but no token.
    * `{:error, :invalid_config}` — config shape is broken.
    * `{:error, :no_operators}` — the allowlist is empty; a
      misconfiguration worth surfacing rather than silently
      no-op-ing.
    * `{:error, :unknown_alert}` — first-argument tuple didn't
      match a known alert type.
    * `{:error, {:missing_field, field, alert_type}}` — a required
      context field was absent.
    * `{:error, {:all_failed, [{chat_id, transport_error}, ...]}}`
      — every per-operator send failed. Callers can log the
      per-chat failures.
  """

  require Logger

  alias Bank.Telegram.CallbackToken
  alias Bank.Telegram.Config
  alias Bank.Telegram.Operator
  alias Bank.Telegram.Transport

  @alert_types ~w(
    pending_approval
    runtime_paused
    runtime_resumed
    revoke_incident
    execution_confirmed
    execution_reverted
    execution_aborted
    sanctions_hit
    scam_challenge
  )a

  @type alert_type ::
          :pending_approval
          | :runtime_paused
          | :runtime_resumed
          | :revoke_incident
          | :execution_confirmed
          | :execution_reverted
          | :execution_aborted
          | :sanctions_hit
          | :scam_challenge

  @type alert :: {alert_type(), map()}

  @type render_error ::
          :unknown_alert
          | {:missing_field, atom(), alert_type()}

  @type dispatch_error ::
          :bot_disabled
          | :bot_not_configured
          | :invalid_config
          | :no_operators
          | render_error()
          | {:all_failed, [{integer(), Transport.error()}]}

  @doc "All alert-type atoms this module supports."
  @spec alert_types() :: [alert_type()]
  def alert_types, do: @alert_types

  @doc """
  Render an alert's text. Pure and recipient-independent — per-
  recipient inline buttons are materialised at dispatch time in
  `buttons_for/2`.

  Returns `{:error, :unknown_alert}` for an unrecognised tag and
  `{:error, {:missing_field, field, alert_type}}` when a required
  context field is absent.
  """
  @spec render(alert()) :: {:ok, String.t()} | {:error, render_error()}
  def render({type, ctx}) when type in @alert_types and is_map(ctx) do
    render_type(type, ctx)
  end

  def render(_), do: {:error, :unknown_alert}

  @doc """
  Return the inline buttons this alert should carry **for this
  operator**. Empty list for every alert type except
  `:pending_approval`, which emits per-recipient signed approve /
  reject callback tokens — and then only when the operator's role
  has the `:approve_reject` capability per
  `Bank.Telegram.Config.can?/2`.

  ## Role boundary

  The #70 identity boundary pins `:viewer` as read-only (it may
  `:read` but not `:approve_reject`). Delivering mutating
  Approve / Reject buttons to a viewer would give them a UI path
  that their role is specifically forbidden from using; that
  leak is prevented here so the boundary is enforced at emit
  time, not only at callback verify time. Viewers still receive
  the informational alert text with its deep links — they just
  do not receive tappable mutating controls. Approvers,
  security-operators, and admins receive the buttons because
  their role grants `:approve_reject`.

  Kept as a separate step from `render/1` because callback tokens
  are actor-bound (signed with the recipient's user_id and
  chat_id), so they cannot be materialised before the recipient is
  known.
  """
  @spec buttons_for(alert(), Operator.t()) :: [Transport.inline_button()]
  def buttons_for({:pending_approval, %{decision_id: decision_id}}, %Operator{} = op)
      when is_binary(decision_id) do
    if Config.can?(op, :approve_reject) do
      [
        %{
          label: "Approve",
          callback_data: CallbackToken.sign(op, :approve, decision_id)
        },
        %{
          label: "Reject",
          callback_data: CallbackToken.sign(op, :reject, decision_id)
        }
      ]
    else
      []
    end
  end

  def buttons_for(_alert, _operator), do: []

  @doc """
  Dispatch an alert to every allowlisted operator. Fails closed on
  a disabled or misconfigured bot, on an empty allowlist, and on
  unknown or under-populated alerts — callers never accidentally
  silently drop a high-risk event.
  """
  @spec dispatch(alert()) :: :ok | {:error, dispatch_error()}
  def dispatch(alert) do
    with {:ok, cfg} <- Config.load() |> map_config_load(),
         :ok <- check_enabled(cfg),
         :ok <- check_bot_token(cfg),
         :ok <- check_operators(cfg),
         {:ok, text} <- render(alert) do
      fan_out(alert, text, cfg.operators)
    end
  end

  # --- rendering internals ---

  defp render_type(:pending_approval, ctx) do
    with :ok <- require_fields(:pending_approval, ctx, [:intent_id, :decision_id]) do
      lines = [
        "Pending approval",
        "Intent: #{ctx.intent_id}",
        amount_line(ctx),
        target_line(ctx),
        risk_tier_line(ctx),
        reasons_line(ctx),
        expires_line(ctx),
        queue_link(),
        replay_link(ctx.intent_id)
      ]

      {:ok, format_lines(lines)}
    end
  end

  defp render_type(:runtime_paused, ctx) do
    with :ok <- require_fields(:runtime_paused, ctx, [:scope]) do
      lines = [
        "Runtime paused",
        "Scope: #{ctx.scope}",
        reason_line(ctx),
        actor_line(ctx),
        security_link()
      ]

      {:ok, format_lines(lines)}
    end
  end

  defp render_type(:runtime_resumed, ctx) do
    with :ok <- require_fields(:runtime_resumed, ctx, [:scope]) do
      lines = [
        "Runtime resumed",
        "Scope: #{ctx.scope}",
        actor_line(ctx),
        security_link()
      ]

      {:ok, format_lines(lines)}
    end
  end

  defp render_type(:revoke_incident, ctx) do
    with :ok <- require_fields(:revoke_incident, ctx, [:smart_account_id, :state]) do
      lines = [
        "Delegation revoke incident",
        "Smart account: #{ctx.smart_account_id}",
        "State: #{ctx.state}",
        reason_line(ctx),
        security_link()
      ]

      {:ok, format_lines(lines)}
    end
  end

  defp render_type(:execution_confirmed, ctx), do: execution_alert(:execution_confirmed, ctx)
  defp render_type(:execution_reverted, ctx), do: execution_alert(:execution_reverted, ctx)
  defp render_type(:execution_aborted, ctx), do: execution_alert(:execution_aborted, ctx)

  defp render_type(:sanctions_hit, ctx) do
    with :ok <- require_fields(:sanctions_hit, ctx, [:intent_id, :address]) do
      lines = [
        "Sanctions hit — intent blocked",
        "Intent: #{ctx.intent_id}",
        "Address: #{ctx.address}",
        source_list_line(ctx),
        amount_line(ctx),
        replay_link(ctx.intent_id)
      ]

      {:ok, format_lines(lines)}
    end
  end

  defp render_type(:scam_challenge, ctx) do
    with :ok <- require_fields(:scam_challenge, ctx, [:intent_id, :address]) do
      lines = [
        "Scam / phishing challenge — approval required",
        "Intent: #{ctx.intent_id}",
        "Address: #{ctx.address}",
        source_list_line(ctx),
        amount_line(ctx),
        queue_link(),
        replay_link(ctx.intent_id)
      ]

      {:ok, format_lines(lines)}
    end
  end

  defp execution_alert(type, ctx) do
    with :ok <- require_fields(type, ctx, [:intent_id]) do
      header =
        case type do
          :execution_confirmed -> "Execution confirmed"
          :execution_reverted -> "Execution reverted"
          :execution_aborted -> "Execution aborted"
        end

      lines = [
        header,
        "Intent: #{ctx.intent_id}",
        amount_line(ctx),
        plan_line(ctx),
        final_reason_line(ctx),
        replay_link(ctx.intent_id)
      ]

      {:ok, format_lines(lines)}
    end
  end

  defp require_fields(type, ctx, fields) do
    case Enum.find(fields, fn f -> is_nil(Map.get(ctx, f)) end) do
      nil -> :ok
      missing -> {:error, {:missing_field, missing, type}}
    end
  end

  # --- line helpers (skip when context lacks the optional field) ---

  defp amount_line(%{amount: a, asset: asset, chain: chain}) when is_binary(a) or is_number(a),
    do: "Amount: #{a} #{asset} on #{chain}"

  defp amount_line(%{amount: a, asset: asset}) when is_binary(a) or is_number(a),
    do: "Amount: #{a} #{asset}"

  defp amount_line(_), do: nil

  defp target_line(%{target_label: label}) when is_binary(label) and label != "",
    do: "Target: #{label}"

  defp target_line(_), do: nil

  defp risk_tier_line(%{risk_tier: tier}) when not is_nil(tier), do: "Risk tier: #{tier}"
  defp risk_tier_line(_), do: nil

  defp reasons_line(%{reasons: reasons}) when is_list(reasons) and reasons != [] do
    "Reasons: " <> Enum.join(reasons, ", ")
  end

  defp reasons_line(_), do: nil

  defp expires_line(%{expires_at: ts}) when not is_nil(ts), do: "Expires: #{format_ts(ts)}"
  defp expires_line(_), do: nil

  defp reason_line(%{reason: reason}) when is_binary(reason) and reason != "",
    do: "Reason: #{reason}"

  defp reason_line(%{reason: reason}) when is_atom(reason) and not is_nil(reason),
    do: "Reason: #{reason}"

  defp reason_line(_), do: nil

  defp actor_line(%{actor_id: actor}) when is_binary(actor) and actor != "", do: "By: #{actor}"
  defp actor_line(_), do: nil

  defp plan_line(%{plan_id: id}) when is_binary(id), do: "Plan: #{id}"
  defp plan_line(_), do: nil

  defp final_reason_line(%{final_reason: r}) when is_binary(r) and r != "", do: "Reason: #{r}"

  defp final_reason_line(%{final_reason: r}) when is_atom(r) and not is_nil(r),
    do: "Reason: #{r}"

  defp final_reason_line(_), do: nil

  defp source_list_line(%{source_list: list}) when is_binary(list) and list != "",
    do: "List: #{list}"

  defp source_list_line(_), do: nil

  defp queue_link, do: "Review: #{web_url("/queue")}"
  defp security_link, do: "Security console: #{web_url("/security")}"
  defp replay_link(intent_id), do: "Replay: #{web_url("/audit/replay/#{intent_id}")}"

  defp web_url(path) do
    case fetch_endpoint_url() do
      {:ok, base} -> base <> path
      :error -> path
    end
  end

  defp fetch_endpoint_url do
    try do
      {:ok, BankWeb.Endpoint.url()}
    rescue
      _ -> :error
    end
  end

  defp format_ts(%DateTime{} = ts), do: DateTime.to_iso8601(ts)
  defp format_ts(ts) when is_binary(ts), do: ts
  defp format_ts(other), do: inspect(other)

  defp format_lines(lines) do
    lines
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  # --- dispatch internals ---

  defp map_config_load({:ok, cfg}), do: {:ok, cfg}
  defp map_config_load({:error, _}), do: {:error, :invalid_config}

  defp check_enabled(%{enabled: true}), do: :ok
  defp check_enabled(_), do: {:error, :bot_disabled}

  defp check_bot_token(%{bot_token: token}) when is_binary(token) and byte_size(token) > 0,
    do: :ok

  defp check_bot_token(_), do: {:error, :bot_not_configured}

  defp check_operators(%{operators: ops}) when is_list(ops) and ops != [], do: :ok
  defp check_operators(_), do: {:error, :no_operators}

  defp fan_out(alert, text, operators) do
    results =
      Enum.map(operators, fn %Operator{chat_id: chat_id} = op ->
        buttons = buttons_for(alert, op)

        opts = if buttons == [], do: [], else: [inline_buttons: buttons]

        case Transport.send_message(chat_id, text, opts) do
          {:ok, _} ->
            :ok

          {:error, reason} = err ->
            Logger.warning(
              "Bank.Telegram.Alerts: dispatch to chat_id=#{chat_id} failed: #{inspect(reason)}"
            )

            {chat_id, err}
        end
      end)

    failures = Enum.filter(results, &match?({_chat_id, _}, &1))

    cond do
      failures == [] -> :ok
      length(failures) == length(results) -> {:error, {:all_failed, failures}}
      true -> :ok
    end
  end
end
