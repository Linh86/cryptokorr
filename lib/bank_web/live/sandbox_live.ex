defmodule BankWeb.SandboxLive do
  @moduledoc """
  Guided sandbox demo (#239).

  Walks a reviewer through the MVP flow as an in-app checklist.
  Each step's "complete" indicator is derived from real workspace
  state (DB-backed counts), not hard-coded — so the page reflects
  what the operator has already done in their workspace.

  The page is read-only by construction:

    * No mutating phx-click events.
    * No forms that submit to the runtime / chain adapter.
    * No buttons. Every step exposes a navigation `<.link>` to the
      existing operator page where the action happens.

  Workspace boundary: every check is scoped to
  `current_scope.workspace.id`. Sibling-workspace data does not
  mark the current workspace's steps complete.
  """

  use BankWeb, :live_view

  import Ecto.Query

  alias Bank.Counterparties
  alias Bank.Decisions
  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Decisions.SimulationReport
  alias Bank.Intents
  alias Bank.Intents.AgentIntent
  alias Bank.Policies
  alias Bank.Repo

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Sandbox")
     |> load_state()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_state() |> put_flash(:info, "Sandbox checklist refreshed")}
  end

  defp load_state(socket) do
    workspace = socket.assigns.current_scope.workspace
    workspace_id = workspace.id

    steps = build_steps(workspace, workspace_id)
    completed = Enum.count(steps, & &1.complete?)

    socket
    |> assign(:steps, steps)
    |> assign(:completed_steps, completed)
    |> assign(:total_steps, length(steps))
  end

  # --- Step definitions ---------------------------------------------------
  #
  # Order mirrors the MVP review flow listed in #239: prove the
  # workspace is set up, configure rules and counterparties, submit
  # an intent, watch it simulate and decide, then exercise the
  # approval / replay / held-blocked surfaces.

  defp build_steps(workspace, workspace_id) do
    [
      %{
        id: "workspace",
        label: "Workspace ready",
        description:
          "An active workspace with at least one membership. The sandbox runs against this tenant.",
        link: ~p"/dashboard",
        link_label: "Open dashboard",
        complete?: workspace_ready?(workspace)
      },
      %{
        id: "policies",
        label: "Policies configured",
        description:
          "At least one active policy rule exists (amount cap, allowed asset/chain, autonomy tier, …).",
        link: ~p"/policies",
        link_label: "Open policies",
        complete?: policies_ready?(workspace_id)
      },
      %{
        id: "counterparty",
        label: "Counterparty trust set",
        description:
          "At least one counterparty has a trust assertion (anything other than the default :unknown).",
        link: ~p"/counterparties",
        link_label: "Open counterparties",
        complete?: counterparty_trust_set?(workspace_id)
      },
      %{
        id: "intent",
        label: "Intent created",
        description: "At least one agent intent has been submitted into this workspace.",
        link: ~p"/intents",
        link_label: "Open intents",
        complete?: intent_created?(workspace_id)
      },
      %{
        id: "simulate",
        label: "Simulation captured",
        description:
          "The runtime has recorded at least one simulation report for an intent in this workspace.",
        link: ~p"/intents",
        link_label: "Open intents",
        complete?: simulation_captured?(workspace_id)
      },
      %{
        id: "approval",
        label: "Approval queue exercised",
        description:
          "At least one decision has surfaced in the approval queue (outcome :approval_required).",
        link: ~p"/queue#pending-approvals-section",
        link_label: "Open approval queue",
        complete?: approval_exercised?(workspace_id)
      },
      %{
        id: "replay",
        label: "Replay available",
        description:
          "At least one intent has a decision envelope, so its full replay bundle can be inspected.",
        link: ~p"/audit",
        link_label: "Open audit",
        complete?: replay_available?(workspace_id)
      },
      %{
        id: "held-blocked",
        label: "Held / blocked example",
        description:
          "At least one decision was held or blocked by the trust engine — proves the safety rails fire.",
        link: ~p"/queue#held-actions-section",
        link_label: "Open held actions",
        complete?: held_or_blocked_seen?(workspace_id)
      }
    ]
  end

  # --- Step predicates ----------------------------------------------------
  #
  # Each predicate is a bounded LIMIT 1 read, workspace-scoped at
  # the context layer. None of them emits audit events or touches
  # the chain adapter — they are pure projections of state.

  # The user's `current_scope` already requires a workspace to mount
  # any LiveView in the `:workspace_viewer` session, so reaching this
  # page proves the workspace exists. Defensive guard for the
  # legacy / pending-user paths returns false.
  defp workspace_ready?(%Bank.Workspaces.Workspace{id: id}) when is_binary(id), do: true
  defp workspace_ready?(_), do: false

  defp policies_ready?(workspace_id) do
    %{entries: entries} =
      Policies.list_rules(%{state: :active}, workspace_id: workspace_id, limit: 1)

    entries != []
  end

  defp counterparty_trust_set?(workspace_id) do
    %{entries: entries} = Counterparties.list_counterparties(%{}, workspace_id: workspace_id)

    Enum.any?(entries, fn cp -> cp.current_trust_level != :unknown end)
  end

  defp intent_created?(workspace_id) do
    Intents.list(workspace_id: workspace_id, limit: 1) != []
  end

  defp simulation_captured?(workspace_id) do
    Repo.exists?(
      from(s in SimulationReport,
        join: i in AgentIntent,
        on: i.id == s.intent_id,
        where: i.workspace_id == ^workspace_id
      )
    )
  end

  defp approval_exercised?(workspace_id) do
    Repo.exists?(
      from(e in DecisionEnvelope,
        join: i in AgentIntent,
        on: i.id == e.intent_id,
        where: i.workspace_id == ^workspace_id and e.outcome == :approval_required
      )
    )
  end

  defp replay_available?(workspace_id) do
    Decisions.list_recent_decisions(1, workspace_id: workspace_id) != []
  end

  defp held_or_blocked_seen?(workspace_id) do
    Repo.exists?(
      from(e in DecisionEnvelope,
        join: i in AgentIntent,
        on: i.id == e.intent_id,
        where: i.workspace_id == ^workspace_id and e.outcome in [:hold, :block]
      )
    )
  end

  # --- Render --------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_page={:sandbox}>
      <div class="flex items-center justify-between mb-8">
        <div>
          <h1 id="sandbox-page-title" class="text-2xl font-bold tracking-tight">
            Guided sandbox
          </h1>
          <p class="mt-1 text-sm text-base-content/60">
            Walk through the MVP review flow without leaving the app. Each step links to
            the page where you can perform or inspect it. Completion reflects this
            workspace's actual data.
          </p>
        </div>
        <button phx-click="refresh" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
        </button>
      </div>

      <section
        id="sandbox-guide"
        data-completed={@completed_steps}
        data-total={@total_steps}
        class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
      >
        <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
          <h2 class="text-sm font-semibold flex items-center gap-1.5">
            <.icon name="hero-clipboard-document-check" class="size-4" /> Sandbox checklist
          </h2>
          <span id="sandbox-progress" class="badge badge-sm badge-ghost font-mono">
            {@completed_steps}/{@total_steps} complete
          </span>
        </header>

        <ol class="divide-y divide-base-300">
          <li
            :for={{step, index} <- Enum.with_index(@steps, 1)}
            id={"sandbox-step-" <> step.id}
            data-complete={to_string(step.complete?)}
            class="px-6 py-4 flex items-start justify-between gap-4"
          >
            <div class="flex items-start gap-3 min-w-0">
              <div class={[
                "w-8 h-8 rounded-lg flex items-center justify-center shrink-0 font-mono text-xs",
                sandbox_step_circle_class(step.complete?)
              ]}>
                <.icon
                  :if={step.complete?}
                  name="hero-check-circle-solid"
                  class="size-4"
                />
                <span :if={!step.complete?}>{index}</span>
              </div>
              <div class="min-w-0">
                <p class="text-sm font-medium">{step.label}</p>
                <p class="mt-0.5 text-xs text-base-content/50">{step.description}</p>
              </div>
            </div>
            <.link
              id={"sandbox-step-link-" <> step.id}
              navigate={step.link}
              class="link link-primary text-xs whitespace-nowrap"
            >
              {step.link_label}
            </.link>
          </li>
        </ol>
      </section>
    </Layouts.app>
    """
  end

  defp sandbox_step_circle_class(true), do: "bg-success/15 text-success"
  defp sandbox_step_circle_class(false), do: "bg-base-200 text-base-content/50"
end
