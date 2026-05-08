defmodule BankWeb.AgentLive.TestIntentCard do
  @moduledoc """
  Section 4 — Test intent. Render-only function component.

  All state (intent, last_result, mode, permission, user_role) lives in
  `BankWeb.AgentLive`. Run / approve events fire on the parent.

  Wiring (phase 2, complete):
  - The parent `intent:run` handler calls `Bank.Intents.submit/2`
    (workspace-scoped) using a per-mode payload that always pins
    `chain: "base-sepolia"` for sandbox safety.
  - The parent subscribes to `Bank.Runtime.PubSub.intent(intent_id)`
    after submit, mapping `:auto_exec | :hold | :approval_required |
    :block` outcomes plus execution events to the design's four
    IntentResult variants (executed / blocked / needs-approval /
    failed).
  - `Approve once` routes through `Bank.Decisions.approve/2`. Operator+
    role is required (`BankWeb.LiveAuth.authorize_action/2`); for
    viewer-tier users the button renders as disabled with a tooltip.
  """
  use Phoenix.Component

  import BankWeb.AgentComponents

  alias Bank.Workspaces.Membership

  attr :mode, :string, required: true
  attr :intent, :atom, required: true, doc: ":idle | :executing | :executed | :blocked | :needs_approval | :failed"
  attr :last_result, :map, default: nil
  attr :permission, :atom, required: true
  attr :user_role, :atom, default: :viewer

  def test_intent_card(assigns) do
    ex = intent_example(assigns.mode)
    running? = assigns.intent == :executing
    locked? = assigns.permission != :active
    approve_allowed? = approve_allowed?(assigns.user_role)
    assigns = assign(assigns, ex: ex, running?: running?, locked?: locked?, approve_allowed?: approve_allowed?)

    ~H"""
    <.card>
      <.card_header eyebrow="04 — Test" title="Test intent">
        <:right>
          <span class="hint">Sandbox · stays on Base Sepolia</span>
        </:right>
      </.card_header>
      <div class="card__body">
        <div class="test__top">
          <div>
            <div class="test__title">{@ex.title}</div>
            <div class="test__sub">{@ex.body}</div>
          </div>
          <button
            type="button"
            class="btn btn--primary"
            disabled={@locked? or @running?}
            phx-click="intent:run"
          >
            <span :if={@running?} class="spinner spinner--sm"></span>
            <%= if @running? do %>
              Running…
            <% else %>
              <.cb_icon name="play" size={14} /> Run test intent
            <% end %>
          </button>
        </div>
        <.intent_result
          :if={@last_result}
          result={@last_result}
          approve_allowed?={@approve_allowed?}
        />
        <div :if={@locked? and is_nil(@last_result)} class="test__locked">
          <.cb_icon name="lock" size={14} /> Install agent permission to run a test intent.
        </div>
      </div>
    </.card>
    """
  end

  attr :result, :map, required: true
  attr :approve_allowed?, :boolean, default: false

  defp intent_result(assigns) do
    cfg = result_cfg(assigns.result)
    assigns = assign(assigns, :cfg, cfg)

    ~H"""
    <div class={["intent-result", "intent-result--#{@cfg.kind}"]}>
      <div class="intent-result__icon">
        <.cb_icon name={@cfg.icon} size={16} stroke={2.0} />
      </div>
      <div class="intent-result__main">
        <div class="intent-result__title">{@cfg.title}</div>
        <div class="intent-result__body">{@cfg.body}</div>
        <div class="intent-result__meta mono">
          <span :if={@result[:tx_hash]}>tx {@result.tx_hash}</span>
          <a class="link-mute" href="#">View details <.cb_icon name="chevron-right" size={11} /></a>
        </div>
      </div>
      <button
        :if={@result.state == "needs-approval"}
        type="button"
        class={["btn btn--secondary", not @approve_allowed? && "is-disabled"]}
        disabled={not @approve_allowed?}
        title={
          if @approve_allowed?,
            do: "Approve this intent once",
            else: "Operator role required to approve"
        }
        phx-click="intent:approve"
      >
        Approve once
      </button>
    </div>
    """
  end

  defp approve_allowed?(role), do: Membership.role_at_least?(role, :operator)

  defp result_cfg(%{state: "executed", action: action}) do
    %{
      kind: "ok",
      icon: "check",
      title: "Intent executed",
      body: "#{action} settled on Base Sepolia. Funds remained inside permission scope."
    }
  end

  defp result_cfg(%{state: "blocked", reason: reason}) do
    %{
      kind: "danger",
      icon: "x",
      title: "Intent blocked",
      body:
        reason ||
          "Slippage 1.4% exceeds your 0.5% limit. The agent did not submit the transaction."
    }
  end

  defp result_cfg(%{state: "needs-approval"} = result) do
    %{
      kind: "warn",
      icon: "info",
      title: "Needs your approval",
      body:
        result[:reason] ||
          "This intent is over the per-trade limit. Approve once, or raise the limit to let the agent proceed automatically next time."
    }
  end

  defp result_cfg(%{state: "failed"} = result) do
    %{
      kind: "danger",
      icon: "warning",
      title: "Intent failed",
      body:
        result[:reason] ||
          "The runtime returned an error. No funds moved. We logged the trace under Activity."
    }
  end
end
