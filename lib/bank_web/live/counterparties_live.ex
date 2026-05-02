defmodule BankWeb.CounterpartiesLive do
  @moduledoc """
  Counterparties list and create — operator management of trusted recipients.

  Shows all counterparties with trust level badges, active/archived filter,
  and an inline create form. Each row navigates to the detail page for
  full management of addresses, evidence, and trust assertions.
  """

  use BankWeb, :live_view

  alias Bank.Counterparties
  alias Bank.Counterparties.Counterparty

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Counterparties")
      |> assign(:show_create, false)
      |> assign(:show_archived, false)
      |> assign_create_form(%{})
      |> load_counterparties()

    {:ok, socket}
  end

  # --- Events ---------------------------------------------------------------

  @impl true
  def handle_event("toggle_create", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create, !socket.assigns.show_create)
     |> assign_create_form(%{})}
  end

  def handle_event("toggle_archived", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_archived, !socket.assigns.show_archived)
     |> load_counterparties()}
  end

  def handle_event("validate_counterparty", %{"counterparty" => params}, socket) do
    {:noreply, assign_create_form(socket, params, :validate)}
  end

  def handle_event("save_counterparty", %{"counterparty" => params}, socket) do
    attrs =
      params
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Map.new()
      |> Map.put("created_by", "user")

    case Counterparties.create_counterparty(attrs,
           actor: :user,
           workspace_id: socket.assigns.current_scope.workspace.id
         ) do
      {:ok, _cp} ->
        {:noreply,
         socket
         |> put_flash(:info, "Counterparty created")
         |> assign(:show_create, false)
         |> assign_create_form(%{})
         |> load_counterparties()}

      {:error, changeset} ->
        {:noreply, assign(socket, :create_form, to_form(changeset, as: :counterparty))}
    end
  end

  # --- State loading --------------------------------------------------------

  defp load_counterparties(socket) do
    filters =
      if socket.assigns.show_archived,
        do: %{},
        else: %{active: true}

    %{entries: entries} =
      Counterparties.list_counterparties(filters,
        limit: 100,
        workspace_id: socket.assigns.current_scope.workspace.id
      )

    assign(socket, :counterparties, entries)
  end

  defp assign_create_form(socket, params, action \\ nil) do
    changeset =
      %Counterparty{}
      |> Counterparty.changeset(Map.merge(params, %{"created_by" => "user"}))

    changeset = if action, do: Map.put(changeset, :action, action), else: changeset
    assign(socket, :create_form, to_form(changeset, as: :counterparty))
  end

  # --- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_page={:counterparties}>
      <%!-- Header --%>
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 id="page-title" class="text-2xl font-bold tracking-tight">Counterparties</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Manage trusted recipients and their addresses
          </p>
        </div>
        <div class="flex items-center gap-2">
          <label class="label cursor-pointer gap-2 text-sm">
            <span class="text-base-content/60">Show archived</span>
            <input
              type="checkbox"
              class="toggle toggle-sm"
              checked={@show_archived}
              phx-click="toggle_archived"
            />
          </label>
          <button
            id="new-counterparty-btn"
            phx-click="toggle_create"
            class="btn btn-primary btn-sm gap-1.5"
          >
            <.icon name="hero-plus" class="size-3.5" /> New counterparty
          </button>
        </div>
      </div>

      <%!-- Create form --%>
      <div
        :if={@show_create}
        id="create-counterparty-form"
        class="mb-6 rounded-xl border border-base-300 bg-base-100 shadow-sm p-6"
      >
        <h3 class="text-sm font-semibold mb-4">New counterparty</h3>
        <.form for={@create_form} phx-change="validate_counterparty" phx-submit="save_counterparty">
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input
              field={@create_form[:name]}
              type="text"
              label="Name"
              placeholder="e.g. Acme Corp"
              required
            />
            <.input
              field={@create_form[:current_trust_level]}
              type="select"
              label="Initial trust level"
              options={trust_level_options()}
              prompt="Select trust level"
            />
            <.input
              field={@create_form[:ownership_context]}
              type="text"
              label="Ownership context"
              placeholder="e.g. treasury, payroll"
            />
            <div class="sm:col-span-2">
              <.input
                field={@create_form[:notes]}
                type="textarea"
                label="Notes"
                rows="2"
                placeholder="Optional notes about this counterparty"
              />
            </div>
          </div>
          <div class="flex items-center gap-2 mt-4">
            <.button type="submit" variant="primary" class="btn btn-primary btn-sm">
              Create counterparty
            </.button>
            <.button type="button" phx-click="toggle_create" class="btn btn-ghost btn-sm">
              Cancel
            </.button>
          </div>
        </.form>
      </div>

      <%!-- Empty state --%>
      <div
        :if={@counterparties == []}
        id="empty-counterparties"
        class="rounded-xl border-2 border-dashed border-base-300 bg-base-200/20 p-12 text-center"
      >
        <div class="w-14 h-14 rounded-full bg-base-300/50 flex items-center justify-center mx-auto mb-4">
          <.icon name="hero-users" class="size-7 text-base-content/30" />
        </div>
        <h2 class="text-lg font-semibold text-base-content/70">No counterparties</h2>
        <p class="mt-2 text-sm text-base-content/50 max-w-md mx-auto">
          Create your first trusted recipient to start configuring who can be paid.
        </p>
      </div>

      <%!-- Counterparties list --%>
      <div :if={@counterparties != []} id="counterparties-list" class="space-y-2">
        <.link
          :for={cp <- @counterparties}
          navigate={~p"/counterparties/#{cp.id}"}
          id={"cp-#{cp.id}"}
          class={[
            "flex items-center justify-between rounded-xl border bg-base-100 shadow-sm px-5 py-4 transition-colors hover:bg-base-200/50",
            if(cp.active, do: "border-base-300", else: "border-base-300/50 opacity-60")
          ]}
        >
          <div class="flex items-center gap-4 min-w-0">
            <div class={[
              "w-10 h-10 rounded-lg flex items-center justify-center shrink-0",
              trust_icon_bg(cp.current_trust_level)
            ]}>
              <.icon name={trust_icon(cp.current_trust_level)} class="size-5" />
            </div>
            <div class="min-w-0">
              <p class="text-sm font-semibold truncate">{cp.name}</p>
              <p :if={cp.ownership_context} class="text-xs text-base-content/40 truncate">
                {cp.ownership_context}
              </p>
            </div>
          </div>
          <div class="flex items-center gap-2 shrink-0 ml-3">
            <span :if={!cp.active} class="badge badge-sm badge-ghost">Archived</span>
            <.trust_badge level={cp.current_trust_level} />
            <.icon name="hero-chevron-right" class="size-4 text-base-content/30" />
          </div>
        </.link>
      </div>
    </Layouts.app>
    """
  end

  # --- Components ------------------------------------------------------------

  attr :level, :atom, required: true

  defp trust_badge(assigns) do
    ~H"""
    <span :if={@level} class={["badge badge-sm font-medium", trust_badge_class(@level)]}>
      {trust_label(@level)}
    </span>
    <span :if={is_nil(@level)} class="badge badge-sm badge-ghost font-medium">
      No assertion
    </span>
    """
  end

  # --- View helpers -----------------------------------------------------------

  defp trust_level_options do
    [
      {"Trusted", "trusted"},
      {"Sensitive", "sensitive"},
      {"Unknown", "unknown"},
      {"Conflicted", "conflicted"}
    ]
  end

  defp trust_badge_class(:trusted), do: "badge-success"
  defp trust_badge_class(:sensitive), do: "badge-warning"
  defp trust_badge_class(:unknown), do: "badge-ghost"
  defp trust_badge_class(:conflicted), do: "badge-error"
  defp trust_badge_class(_), do: "badge-ghost"

  defp trust_label(:trusted), do: "Trusted"
  defp trust_label(:sensitive), do: "Sensitive"
  defp trust_label(:unknown), do: "Unknown"
  defp trust_label(:conflicted), do: "Conflicted"
  defp trust_label(_), do: "–"

  defp trust_icon(:trusted), do: "hero-shield-check-solid"
  defp trust_icon(:sensitive), do: "hero-exclamation-triangle-solid"
  defp trust_icon(:unknown), do: "hero-question-mark-circle-solid"
  defp trust_icon(:conflicted), do: "hero-x-circle-solid"
  defp trust_icon(_), do: "hero-question-mark-circle-solid"

  defp trust_icon_bg(:trusted), do: "bg-success/15 text-success"
  defp trust_icon_bg(:sensitive), do: "bg-warning/15 text-warning"
  defp trust_icon_bg(:unknown), do: "bg-base-300/50 text-base-content/40"
  defp trust_icon_bg(:conflicted), do: "bg-error/15 text-error"
  defp trust_icon_bg(_), do: "bg-base-300/50 text-base-content/40"
end
