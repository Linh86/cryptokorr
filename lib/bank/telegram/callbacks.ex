defmodule Bank.Telegram.Callbacks do
  @moduledoc """
  Consume Telegram inline-button callbacks and apply them to the
  appropriate state machine (issues #72 + #73, epic #54).

  This is the only shared place that translates a Telegram button
  press into a real runtime mutation. The webhook controller
  authenticates the sender and then hands an authorized
  `Bank.Telegram.Operator` plus the normalized callback payload to
  `handle/3`. The function returns a short operator-facing string the
  controller surfaces via
  `Bank.Telegram.Transport.answer_callback_query/2`.

  ## Dependencies

    * `Bank.Telegram.CallbackToken.verify/4` — signed short-lived
      token check; actor-bound so a captured button cannot be replayed
      from a different chat / user.
    * `Bank.Telegram.Config.can?/2` — role-based capability checks.
      `Bank.Telegram.Alerts.buttons_for/2` already gates mutating
      buttons at emit time on `:approve_reject`; the re-check here is
      defense-in-depth against a bug that would let a viewer receive
      a button they should not have.
    * `Bank.Decisions.approve/2` / `reject/2` — the real state
      mutation. This module does not invent a parallel audit path;
      the decisions context already emits `Bank.Audit.Events`
      approval_granted / approval_rejected and broadcasts via
      `Bank.Runtime.Notifier`.
    * `Bank.Telegram.SecurityControls.apply_verified/2` — the #73
      step-up pause / resume path. It maps verified callback payloads
      onto `Bank.Security.pause/2` and `resume/2`.

  ## Supported actions

  `:approve`, `:reject`, `:pause`, and `:resume` are wired today.
  `:open_replay` is still refused with `:unsupported_action`.

  ## Audit attribution

  Decision and security mutations record
  `actor_id: "telegram:" <> audit_actor`. Both the action surface
  (Telegram) and the operator identity survive in the audit row. The
  `Bank.Audit.AuditEvent` schema does not have a separate `surface`
  field; encoding it into `actor_id` keeps the attribution a single
  string that is greppable and dashboard-friendly without broadening
  the schema. The actor type stays `:user`.

  ## Fail-closed

  Every error path returns `{:error, reason, text}` where `text` is
  short, truthful, and safe to show to an operator. No branch
  collapses a non-outcome into a fake success; the response either
  reports a real state transition or reports *why* the button did
  not do anything.

  The HTTP-side `answer_callback_query` call is the controller's
  responsibility — this module never touches the Telegram API
  directly.
  """

  require Logger

  alias Bank.Decisions
  alias Bank.Telegram.CallbackToken
  alias Bank.Telegram.Config
  alias Bank.Telegram.Operator
  alias Bank.Telegram.SecurityControls

  @type callback_query :: %{
          required(:user_id) => integer(),
          required(:chat_id) => integer(),
          required(:data) => String.t(),
          optional(:query_id) => String.t(),
          optional(:message_id) => integer() | nil,
          optional(:update_id) => integer()
        }

  @type reason ::
          :malformed
          | :invalid
          | :expired
          | :actor_mismatch
          | :forbidden
          | :unsupported_action
          | :wrong_target
          | :not_found
          | :already_resolved
          | :already_paused
          | :already_running
          | :wrong_state
          | :backend_error

  @type result :: {:ok, String.t()} | {:error, reason(), String.t()}

  @doc """
  Apply a callback from an already-authorized operator.

  `operator` must come from `Bank.Telegram.Config.authorize/2` — the
  controller is responsible for that. `callback` is the map produced
  by `Bank.Telegram.Update.from_telegram_json/1` for a
  `{:callback_query, ...}` variant.

  Options:

    * `:now` — override the clock used by `CallbackToken.verify/4`
      (seconds since epoch). Tests exercise the expiry branch without
      `Process.sleep/1`.
  """
  @spec handle(Operator.t(), callback_query(), keyword()) :: result()
  def handle(%Operator{} = operator, %{user_id: _, chat_id: _, data: _} = callback, opts \\ []) do
    with {:ok, payload} <- verify_token(callback, opts),
         :ok <- check_supported_action(payload.action) do
      apply_action(operator, payload)
    end
  end

  defp verify_token(callback, opts) do
    case CallbackToken.verify(callback.data, callback.user_id, callback.chat_id, opts) do
      {:ok, payload} ->
        {:ok, payload}

      {:error, reason} ->
        token_error(reason)
    end
  end

  defp token_error(:malformed), do: {:error, :malformed, "Invalid button."}
  defp token_error(:invalid), do: {:error, :invalid, "Invalid button."}

  defp token_error(:expired),
    do: {:error, :expired, "This button has expired. Request a fresh one."}

  defp token_error(:actor_mismatch), do: {:error, :actor_mismatch, "This button is not yours."}

  defp check_supported_action(action) when action in [:approve, :reject, :pause, :resume], do: :ok
  defp check_supported_action(_), do: {:error, :unsupported_action, "Unsupported button."}

  defp apply_action(operator, %{action: :approve, target_id: decision_id}) do
    with :ok <- check_approval_role(operator) do
      run_decision(operator, :approve, decision_id, "Approved via Telegram", "Approved.")
    end
  end

  defp apply_action(operator, %{action: :reject, target_id: decision_id}) do
    with :ok <- check_approval_role(operator) do
      run_decision(operator, :reject, decision_id, "Rejected via Telegram", "Rejected.")
    end
  end

  defp apply_action(operator, %{action: action} = payload) when action in [:pause, :resume] do
    SecurityControls.apply_verified(operator, payload)
  end

  defp check_approval_role(operator) do
    if Config.can?(operator, :approve_reject) do
      :ok
    else
      {:error, :forbidden, "Not authorized."}
    end
  end

  defp run_decision(operator, action, decision_id, reason, success_text) do
    opts = [actor_id: audit_actor_id(operator), reason: reason]

    result =
      case action do
        :approve -> Decisions.approve(decision_id, opts)
        :reject -> Decisions.reject(decision_id, opts)
      end

    case result do
      {:ok, _successor, _dispatch} ->
        {:ok, success_text}

      {:error, :not_found} ->
        {:error, :not_found, "Decision not found."}

      {:error, :already_superseded} ->
        {:error, :already_resolved, "Decision already resolved."}

      {:error, {:wrong_outcome, _}} ->
        {:error, :already_resolved, "Decision already resolved."}

      {:error, {:wrong_state, state}} ->
        Logger.error(
          "Bank.Telegram.Callbacks: #{action} on #{decision_id} hit wrong_state=#{inspect(state)} " <>
            "for operator=#{operator.audit_actor}"
        )

        {:error, :wrong_state, "Could not apply."}

      {:error, :intent_not_found} ->
        Logger.error("Bank.Telegram.Callbacks: #{action} on #{decision_id} hit intent_not_found")

        {:error, :backend_error, "Could not apply."}

      {:error, other} ->
        Logger.error(
          "Bank.Telegram.Callbacks: #{action} on #{decision_id} failed: #{inspect(other)}"
        )

        {:error, :backend_error, "Could not apply."}
    end
  end

  defp audit_actor_id(%Operator{audit_actor: audit_actor})
       when is_binary(audit_actor) and audit_actor != "" do
    "telegram:" <> audit_actor
  end
end
