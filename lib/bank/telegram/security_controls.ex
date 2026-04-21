defmodule Bank.Telegram.SecurityControls do
  @moduledoc """
  Telegram step-up controls for runtime pause / resume (issue #73).

  Pause and resume are high-risk controls. A text command never mutates
  runtime state directly; it renders a short confirmation prompt with a
  signed, actor-bound inline button. The actual mutation happens only
  when that button returns through the callback-query path.

  This module deliberately does not introduce Telegram-specific runtime
  state. The confirmation token binds the operator, chat, action,
  expiry, and the fixed global-runtime target id. Replay is handled by
  the existing idempotent `Bank.Security.pause/2` and `resume/2` paths:
  a second tap produces `already_paused` / `already_running` rather than
  another audit event.
  """

  require Logger

  alias Bank.Security
  alias Bank.Telegram.CallbackToken
  alias Bank.Telegram.Config
  alias Bank.Telegram.Operator

  @runtime_control_target_id "00000000-0000-0000-0000-000000000073"
  @confirmation_max_age_s 60

  @type action :: :pause | :resume
  @type parse_result :: {:ok, action()} | :not_security_command | :not_a_command
  @type callback_reason ::
          :malformed
          | :invalid
          | :expired
          | :actor_mismatch
          | :forbidden
          | :unsupported_action
          | :wrong_target
          | :already_paused
          | :already_running
          | :backend_error

  @doc "The fixed UUID bound into global pause/resume confirmation tokens."
  @spec runtime_control_target_id() :: String.t()
  def runtime_control_target_id, do: @runtime_control_target_id

  @doc """
  Parse a raw Telegram text message for #73 security commands only.

  `/pause@SomeBot` and `/resume@SomeBot` are treated as
  `:not_a_command` for the same reason as #71 read commands: until the
  bot has an authoritative username, the safe choice in shared groups is
  to avoid answering commands explicitly addressed to a bot suffix.
  """
  @spec parse_command(term()) :: parse_result()
  def parse_command(text) when is_binary(text) do
    case String.trim(text) do
      "/" <> rest -> parse_slash(rest)
      _ -> :not_a_command
    end
  end

  def parse_command(_), do: :not_a_command

  @doc """
  Render a step-up confirmation prompt for `/pause` or `/resume`.

  The returned button is safe to pass directly to
  `Bank.Telegram.Transport.send_message/3` as `:inline_buttons`.
  """
  @spec confirmation(Operator.t(), action()) ::
          {:ok, String.t(), [[map()]]} | {:error, :forbidden, String.t(), []}
  def confirmation(%Operator{} = operator, action) when action in [:pause, :resume] do
    if Config.can?(operator, :pause_resume) do
      token =
        CallbackToken.sign(operator, action, @runtime_control_target_id,
          max_age: @confirmation_max_age_s
        )

      {:ok, confirmation_text(action), [[confirmation_button(action, token)]]}
    else
      {:error, :forbidden, "Not authorized for runtime pause/resume.", []}
    end
  end

  @doc """
  Apply a verified pause/resume callback payload.

  `Bank.Telegram.Callbacks` owns the shared callback-token verification
  boundary and delegates here only after token verification succeeds.
  """
  @spec apply_verified(Operator.t(), CallbackToken.payload()) ::
          {:ok, String.t()} | {:error, callback_reason(), String.t()}
  def apply_verified(%Operator{} = operator, %{action: action, target_id: target_id})
      when action in [:pause, :resume] do
    with :ok <- check_role(operator),
         :ok <- check_target(target_id) do
      run_security_action(operator, action)
    end
  end

  def apply_verified(_operator, _payload) do
    {:error, :unsupported_action, "Unsupported security action."}
  end

  @doc "Map callback-token verification errors onto operator-facing #73 text."
  @spec token_error(CallbackToken.verify_error()) ::
          {:error, callback_reason(), String.t()}
  def token_error(:malformed), do: {:error, :malformed, "Invalid confirmation."}
  def token_error(:invalid), do: {:error, :invalid, "Invalid confirmation."}

  def token_error(:expired),
    do: {:error, :expired, "This confirmation expired. Send /pause or /resume again."}

  def token_error(:actor_mismatch),
    do: {:error, :actor_mismatch, "This confirmation is not yours."}

  defp parse_slash(rest) do
    raw_name =
      rest
      |> String.split(" ", parts: 2)
      |> List.first()

    case String.split(raw_name, "@", parts: 2) do
      [_name, _bot] ->
        :not_a_command

      [name] ->
        case String.downcase(name) do
          "pause" -> {:ok, :pause}
          "resume" -> {:ok, :resume}
          _ -> :not_security_command
        end
    end
  end

  defp confirmation_text(:pause) do
    """
    Confirm runtime pause
    This blocks new executing transitions globally.
    Tap the button within 60 seconds to confirm.
    Security console: #{web_url("/security")}
    """
    |> String.trim_trailing()
  end

  defp confirmation_text(:resume) do
    """
    Confirm runtime resume
    This lifts the global pause. Queued intents do not auto-execute.
    Tap the button within 60 seconds to confirm.
    Security console: #{web_url("/security")}
    """
    |> String.trim_trailing()
  end

  defp confirmation_button(:pause, token), do: %{label: "Confirm pause", callback_data: token}
  defp confirmation_button(:resume, token), do: %{label: "Confirm resume", callback_data: token}

  defp check_role(operator) do
    if Config.can?(operator, :pause_resume) do
      :ok
    else
      {:error, :forbidden, "Not authorized."}
    end
  end

  defp check_target(@runtime_control_target_id), do: :ok
  defp check_target(_), do: {:error, :wrong_target, "Invalid confirmation."}

  defp run_security_action(operator, :pause) do
    opts = [
      reason: "telegram_operator_requested",
      actor: :user,
      actor_id: audit_actor_id(operator)
    ]

    case Security.pause(:global, opts) do
      {:ok, :paused} ->
        {:ok, "Runtime paused."}

      {:ok, :already_paused} ->
        {:error, :already_paused, "Runtime already paused."}

      {:error, reason} ->
        Logger.error("Bank.Telegram.SecurityControls: pause failed: #{inspect(reason)}")
        {:error, :backend_error, "Could not pause runtime."}
    end
  end

  defp run_security_action(operator, :resume) do
    opts = [
      reason: "telegram_operator_requested",
      actor: :user,
      actor_id: audit_actor_id(operator)
    ]

    case Security.resume(:global, opts) do
      {:ok, :resumed} ->
        {:ok, "Runtime resumed."}

      {:ok, :already_running} ->
        {:error, :already_running, "Runtime already running."}

      {:error, reason} ->
        Logger.error("Bank.Telegram.SecurityControls: resume failed: #{inspect(reason)}")
        {:error, :backend_error, "Could not resume runtime."}
    end
  end

  defp audit_actor_id(%Operator{audit_actor: audit_actor})
       when is_binary(audit_actor) and audit_actor != "" do
    "telegram:" <> audit_actor
  end

  defp web_url(path) do
    try do
      BankWeb.Endpoint.url() <> path
    rescue
      _ -> path
    end
  end
end
