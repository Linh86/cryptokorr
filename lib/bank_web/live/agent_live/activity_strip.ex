defmodule BankWeb.AgentLive.ActivityStrip do
  @moduledoc """
  Section 5 — Recent activity (top 5). Render-only function component.

  Activity rows are loaded + maintained by `BankWeb.AgentLive`.

  Phase 2 will:
  - Subscribe to `Bank.Runtime.PubSub.audit_stream/0` ("audit:stream")
    in AgentLive's mount
  - Initial load via `Bank.Audit.list_events(%{workspace_id: ws_id},
    limit: 5, order: :desc)`
  - Map audit row → activity entry (`%{id, t, kind, status, title,
    reason?, amount?, tx_hash?}`) per R4 spec
  - Re-fetch on `:appended` broadcasts
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: BankWeb.Endpoint,
    router: BankWeb.Router,
    statics: BankWeb.static_paths()

  import BankWeb.AgentComponents

  attr :activity, :list, required: true

  def activity_strip(assigns) do
    visible = Enum.take(assigns.activity, 5)
    assigns = assign(assigns, :visible, visible)

    ~H"""
    <.card>
      <.card_header eyebrow="05 — Activity" title="Recent activity">
        <:right>
          <.link navigate={~p"/activity"} class="link-btn">
            See all <.cb_icon name="chevron-right" size={12} />
          </.link>
        </:right>
      </.card_header>
      <ol class="timeline">
        <li :if={@visible == []} class="timeline__empty">
          No activity yet. Run a test intent to populate this.
        </li>
        <.activity_row :for={item <- @visible} item={item} />
      </ol>
    </.card>
    """
  end
end
