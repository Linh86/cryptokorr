defmodule BankWeb.API.V1.ApprovalController do
  @moduledoc """
  `/v1/approvals` — operator approval queue.

  Endpoints:

    * `GET  /v1/approvals`                         — pending queue
    * `POST /v1/approvals/:decision_id/approve`    — produces a
      successor envelope with outcome `auto_exec`
    * `POST /v1/approvals/:decision_id/reject`     — produces a
      successor envelope with outcome `block`

  Both mutating endpoints require an `actor_id` in the body — the
  operator id is captured on the successor envelope and every audit
  event so the approval trail is reconstructible.

  ## Dispatch field

  The success response carries a `dispatch` field describing what
  happened next:

    * `"recorded"` — approve path; the successor envelope was written
      but no `ExecutionPlan` was created and no execution was
      enqueued. The operator must follow up with
      `POST /v1/decisions/{id}/execute` (passing `smart_account_id`)
      to actually start execution. This is the v0.1 default; future
      tiered-autonomy modes may change it.
    * `"no_dispatch"` — reject path; nothing to execute.

  The `next_step` field on `"recorded"` responses is a hint
  pointing the operator at the execute endpoint.
  """

  use BankWeb, :controller

  alias Bank.Decisions
  alias Bank.Decisions.DecisionEnvelope

  def index(conn, _params) do
    decisions = Decisions.list_pending_approvals()
    json(conn, %{decisions: Enum.map(decisions, &summarize/1)})
  end

  def approve(conn, params), do: handle_action(conn, params, :approve)

  def reject(conn, params), do: handle_action(conn, params, :reject)

  defp handle_action(conn, %{"decision_id" => id} = params, action) do
    case extract_actor_id(params) do
      {:ok, actor_id} ->
        opts =
          [actor_id: actor_id]
          |> maybe_put(:reason, Map.get(params, "reason"))

        case apply_action(action, id, opts) do
          {:ok, successor, dispatch} ->
            conn
            |> put_status(:ok)
            |> json(success_body(successor, dispatch))

          {:error, reason} ->
            render_action_error(conn, reason)
        end

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: %{code: "invalid_request", message: "actor_id is required"}})
    end
  end

  defp apply_action(:approve, id, opts), do: Decisions.approve(id, opts)
  defp apply_action(:reject, id, opts), do: Decisions.reject(id, opts)

  defp extract_actor_id(%{"actor_id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp extract_actor_id(_), do: :error

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp render_action_error(conn, :not_found) do
    conn
    |> put_status(:not_found)
    |> json(%{error: %{code: "not_found", message: "decision not found"}})
  end

  defp render_action_error(conn, :already_superseded) do
    conn
    |> put_status(:conflict)
    |> json(%{error: %{code: "already_superseded", message: "decision is no longer current"}})
  end

  defp render_action_error(conn, {:wrong_outcome, outcome}) do
    conn
    |> put_status(:conflict)
    |> json(%{
      error: %{
        code: "wrong_outcome",
        message: "decision outcome is #{outcome}; approval only applies to approval_required"
      }
    })
  end

  defp render_action_error(conn, reason) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: %{code: "approval_failed", message: inspect(reason)}})
  end

  defp success_body(%DecisionEnvelope{} = successor, :recorded) do
    %{
      decision: summarize(successor),
      dispatch: "recorded",
      next_step: %{
        endpoint: "POST /v1/decisions/#{successor.id}/execute",
        message: "approval recorded; execute manually with smart_account_id when ready"
      }
    }
  end

  defp success_body(%DecisionEnvelope{} = successor, :no_dispatch) do
    %{
      decision: summarize(successor),
      dispatch: "no_dispatch"
    }
  end

  defp summarize(%DecisionEnvelope{} = e) do
    %{
      id: e.id,
      intent_id: e.intent_id,
      outcome: e.outcome,
      risk_tier: e.risk_tier,
      decided_at: e.decided_at,
      decided_by: e.decided_by,
      approval_expires_at: e.approval_expires_at,
      reasons: e.reasons
    }
  end
end
