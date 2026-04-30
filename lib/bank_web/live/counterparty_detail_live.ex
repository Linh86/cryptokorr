defmodule BankWeb.CounterpartyDetailLive do
  @moduledoc """
  Counterparty detail page — full management of a single counterparty.

  Supports:
    * Viewing and editing counterparty fields (name, notes, ownership)
    * Archiving the counterparty
    * Managing address labels (add, retire)
    * Pinning evidence artifacts
    * Issuing trust assertions
    * Viewing current trust level and active assertions

  All mutations flow through `Bank.Counterparties` context functions,
  which emit audit events automatically.
  """

  use BankWeb, :live_view

  alias Bank.Counterparties
  alias Bank.Counterparties.{Counterparty, AddressLabel, EvidenceArtifact}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    workspace_id = socket.assigns.current_scope.workspace.id

    case Counterparties.get_counterparty_with_preloads(id, workspace_id: workspace_id) do
      {:ok, cp} ->
        socket =
          socket
          |> assign(page_title: cp.name)
          |> assign(:counterparty, cp)
          |> assign(:editing, false)
          |> assign(:adding_address, false)
          |> assign(:adding_evidence, false)
          |> assign(:asserting_trust, false)
          |> assign_edit_form(cp)
          |> assign_address_form(%{})
          |> assign_evidence_form(%{})
          |> assign_trust_form(%{})

        {:ok, socket}

      {:error, :not_found} ->
        # The id resolves to nothing the operator's workspace owns
        # — either it doesn't exist or it belongs to another
        # workspace. Same flash either way; the UI must not leak the
        # difference (#158c).
        {:ok,
         socket
         |> put_flash(:error, "Counterparty not found")
         |> redirect(to: ~p"/counterparties")}
    end
  end

  # --- Events: edit counterparty --------------------------------------------

  @impl true
  def handle_event("toggle_edit", _params, socket) do
    editing = !socket.assigns.editing

    socket =
      if editing,
        do: assign_edit_form(socket, socket.assigns.counterparty),
        else: socket

    {:noreply, assign(socket, :editing, editing)}
  end

  def handle_event("validate_edit", %{"counterparty" => params}, socket) do
    changeset =
      socket.assigns.counterparty
      |> Counterparty.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :edit_form, to_form(changeset, as: :counterparty))}
  end

  def handle_event("save_edit", %{"counterparty" => params}, socket) do
    params = params |> Enum.reject(fn {_k, v} -> v == "" end) |> Map.new()

    case Counterparties.update_counterparty(socket.assigns.counterparty, params, actor: :user) do
      {:ok, cp} ->
        cp = Counterparties.preload_counterparty(cp)

        {:noreply,
         socket
         |> assign(:counterparty, cp)
         |> assign(:editing, false)
         |> assign(page_title: cp.name)
         |> put_flash(:info, "Counterparty updated")}

      {:error, changeset} ->
        {:noreply, assign(socket, :edit_form, to_form(changeset, as: :counterparty))}
    end
  end

  def handle_event("archive", _params, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      case Counterparties.archive_counterparty(socket.assigns.counterparty, actor: :user) do
        {:ok, cp} ->
          cp = Counterparties.preload_counterparty(cp)

          {:noreply,
           socket
           |> assign(:counterparty, cp)
           |> put_flash(:info, "Counterparty archived")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to archive")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to archive a counterparty.")}
    end
  end

  # --- Events: address labels -----------------------------------------------

  def handle_event("toggle_add_address", _params, socket) do
    {:noreply,
     socket
     |> assign(:adding_address, !socket.assigns.adding_address)
     |> assign_address_form(%{})}
  end

  def handle_event("validate_address", %{"address_label" => params}, socket) do
    changeset =
      %AddressLabel{}
      |> AddressLabel.changeset(
        Map.put(params, "counterparty_id", socket.assigns.counterparty.id)
      )
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :address_form, to_form(changeset, as: :address_label))}
  end

  def handle_event("save_address", %{"address_label" => params}, socket) do
    case Counterparties.attach_address(socket.assigns.counterparty, params, actor: :user) do
      {:ok, _label} ->
        {:noreply,
         socket
         |> reload_counterparty()
         |> assign(:adding_address, false)
         |> assign_address_form(%{})
         |> put_flash(:info, "Address added")}

      {:error, :archived} ->
        {:noreply, put_flash(socket, :error, "Cannot add address to archived counterparty")}

      {:error, changeset} ->
        {:noreply, assign(socket, :address_form, to_form(changeset, as: :address_label))}
    end
  end

  def handle_event("retire_address", %{"label-id" => label_id}, socket) do
    label = Enum.find(socket.assigns.counterparty.address_labels, &(&1.id == label_id))

    if label do
      case Counterparties.retire_address_label(label, actor: :user) do
        {:ok, _label} ->
          {:noreply,
           socket
           |> reload_counterparty()
           |> put_flash(:info, "Address retired")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to retire address")}
      end
    else
      {:noreply, socket}
    end
  end

  # --- Events: evidence -----------------------------------------------------

  def handle_event("toggle_add_evidence", _params, socket) do
    {:noreply,
     socket
     |> assign(:adding_evidence, !socket.assigns.adding_evidence)
     |> assign_evidence_form(%{})}
  end

  def handle_event("validate_evidence", %{"evidence" => params}, socket) do
    changeset =
      %EvidenceArtifact{}
      |> EvidenceArtifact.changeset(
        Map.merge(params, %{
          "subject_type" => "counterparty",
          "subject_id" => socket.assigns.counterparty.id,
          "captured_by" => "user",
          "captured_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "payload_hash" => "placeholder"
        })
      )
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :evidence_form, to_form(changeset, as: :evidence))}
  end

  def handle_event("save_evidence", %{"evidence" => params}, socket) do
    case Counterparties.pin_evidence(socket.assigns.counterparty, params, actor: :user) do
      {:ok, _evidence} ->
        {:noreply,
         socket
         |> reload_counterparty()
         |> assign(:adding_evidence, false)
         |> assign_evidence_form(%{})
         |> put_flash(:info, "Evidence added")}

      {:error, :archived} ->
        {:noreply, put_flash(socket, :error, "Cannot add evidence to archived counterparty")}

      {:error, changeset} ->
        {:noreply, assign(socket, :evidence_form, to_form(changeset, as: :evidence))}
    end
  end

  # --- Events: trust assertions ---------------------------------------------

  def handle_event("toggle_assert_trust", _params, socket) do
    {:noreply,
     socket
     |> assign(:asserting_trust, !socket.assigns.asserting_trust)
     |> assign_trust_form(%{})}
  end

  def handle_event("validate_trust", %{"trust" => params}, socket) do
    {:noreply, assign_trust_form(socket, params, :validate)}
  end

  def handle_event("save_trust", %{"trust" => params}, socket) do
    cp = socket.assigns.counterparty

    attrs = %{
      "level" => params["level"],
      "rationale" => params["rationale"],
      "scope" => build_trust_scope(params),
      "issued_by" => "user",
      "issued_at" => DateTime.utc_now()
    }

    case Counterparties.issue_trust_assertion("counterparty", cp.id, attrs, actor: :user) do
      {:ok, _assertion} ->
        {:noreply,
         socket
         |> reload_counterparty()
         |> assign(:asserting_trust, false)
         |> assign_trust_form(%{})
         |> put_flash(:info, "Trust assertion issued")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Counterparty not found")}

      {:error, changeset} ->
        {:noreply, assign(socket, :trust_form, to_form(changeset, as: :trust))}
    end
  end

  # --- State loading --------------------------------------------------------

  defp reload_counterparty(socket) do
    workspace_id = socket.assigns.current_scope.workspace.id

    case Counterparties.get_counterparty_with_preloads(socket.assigns.counterparty.id,
           workspace_id: workspace_id
         ) do
      {:ok, cp} -> assign(socket, :counterparty, cp)
      {:error, _} -> socket
    end
  end

  defp assign_edit_form(socket, cp) do
    changeset = Counterparty.changeset(cp, %{})
    assign(socket, :edit_form, to_form(changeset, as: :counterparty))
  end

  defp assign_address_form(socket, params) do
    cp_id = if socket.assigns[:counterparty], do: socket.assigns.counterparty.id, else: ""

    changeset =
      %AddressLabel{}
      |> AddressLabel.changeset(Map.merge(params, %{"counterparty_id" => cp_id}))

    assign(socket, :address_form, to_form(changeset, as: :address_label))
  end

  defp assign_evidence_form(socket, params) do
    cp_id = if socket.assigns[:counterparty], do: socket.assigns.counterparty.id, else: ""

    changeset =
      %EvidenceArtifact{}
      |> EvidenceArtifact.changeset(
        Map.merge(params, %{
          "subject_type" => "counterparty",
          "subject_id" => cp_id,
          "captured_by" => "user",
          "captured_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "payload_hash" => "placeholder"
        })
      )

    assign(socket, :evidence_form, to_form(changeset, as: :evidence))
  end

  defp assign_trust_form(socket, params, action \\ nil) do
    types = %{
      level: :string,
      rationale: :string,
      scope_asset: :string,
      scope_chain: :string
    }

    changeset =
      {%{}, types}
      |> Ecto.Changeset.cast(params, Map.keys(types))
      |> Ecto.Changeset.validate_required([:level])

    changeset = if action, do: Map.put(changeset, :action, action), else: changeset
    assign(socket, :trust_form, to_form(changeset, as: :trust))
  end

  defp build_trust_scope(params) do
    scope = %{}

    scope =
      if params["scope_asset"] not in [nil, ""],
        do: Map.put(scope, "asset", params["scope_asset"]),
        else: scope

    scope =
      if params["scope_chain"] not in [nil, ""],
        do: Map.put(scope, "chain", params["scope_chain"]),
        else: scope

    scope
  end

  # --- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_page={:counterparties}>
      <%!-- Back link + header --%>
      <div class="mb-6">
        <.link
          navigate={~p"/counterparties"}
          class="text-sm text-base-content/50 hover:text-base-content flex items-center gap-1 mb-3"
        >
          <.icon name="hero-arrow-left" class="size-3.5" /> Back to counterparties
        </.link>

        <div class="flex items-center justify-between">
          <div class="flex items-center gap-3">
            <div class={[
              "w-12 h-12 rounded-xl flex items-center justify-center",
              trust_icon_bg(@counterparty.current_trust_level)
            ]}>
              <.icon name={trust_icon(@counterparty.current_trust_level)} class="size-6" />
            </div>
            <div>
              <h1 id="page-title" class="text-2xl font-bold tracking-tight">{@counterparty.name}</h1>
              <div class="flex items-center gap-2 mt-0.5">
                <.trust_badge level={@counterparty.current_trust_level} />
                <span :if={!@counterparty.active} class="badge badge-sm badge-error">Archived</span>
                <span :if={@counterparty.ownership_context} class="text-xs text-base-content/40">
                  {~c"·"} {@counterparty.ownership_context}
                </span>
              </div>
            </div>
          </div>
          <div class="flex items-center gap-2">
            <button phx-click="toggle_edit" class="btn btn-ghost btn-sm gap-1.5">
              <.icon name="hero-pencil" class="size-3.5" /> Edit
            </button>
            <button
              :if={@counterparty.active}
              id="archive-btn"
              phx-click="archive"
              data-confirm="Archive this counterparty? It will be excluded from active evaluation."
              class="btn btn-ghost btn-sm text-error gap-1.5"
            >
              <.icon name="hero-archive-box" class="size-3.5" /> Archive
            </button>
          </div>
        </div>
      </div>

      <%!-- Edit form --%>
      <div
        :if={@editing}
        id="edit-form"
        class="mb-6 rounded-xl border border-base-300 bg-base-100 shadow-sm p-6"
      >
        <h3 class="text-sm font-semibold mb-4">Edit counterparty</h3>
        <.form for={@edit_form} phx-change="validate_edit" phx-submit="save_edit">
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <.input field={@edit_form[:name]} type="text" label="Name" required />
            <.input field={@edit_form[:ownership_context]} type="text" label="Ownership context" />
            <div class="sm:col-span-2">
              <.input field={@edit_form[:notes]} type="textarea" label="Notes" rows="2" />
            </div>
          </div>
          <div class="flex items-center gap-2 mt-4">
            <.button type="submit" variant="primary" class="btn btn-primary btn-sm">Save</.button>
            <.button type="button" phx-click="toggle_edit" class="btn btn-ghost btn-sm">
              Cancel
            </.button>
          </div>
        </.form>
      </div>

      <%!-- Main grid --%>
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- Left column: addresses + evidence --%>
        <div class="lg:col-span-2 space-y-6">
          <.addresses_section
            labels={@counterparty.address_labels}
            adding={@adding_address}
            form={@address_form}
            active={@counterparty.active}
          />
          <.evidence_section
            artifacts={@counterparty.evidence_artifacts}
            adding={@adding_evidence}
            form={@evidence_form}
            active={@counterparty.active}
          />
        </div>

        <%!-- Right column: trust --%>
        <div class="space-y-6">
          <.trust_section
            assertions={@counterparty.trust_assertions}
            asserting={@asserting_trust}
            form={@trust_form}
            trust_level={@counterparty.current_trust_level}
          />
          <.details_card counterparty={@counterparty} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Component: addresses section ------------------------------------------

  attr :labels, :list, required: true
  attr :adding, :boolean, required: true
  attr :form, :map, required: true
  attr :active, :boolean, required: true

  defp addresses_section(assigns) do
    ~H"""
    <div id="addresses-section" class="rounded-xl border border-base-300 bg-base-100 shadow-sm">
      <div class="flex items-center justify-between px-6 py-4 border-b border-base-300">
        <h3 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-map-pin" class="size-4" /> Addresses
          <span class="badge badge-xs badge-ghost">{length(@labels)}</span>
        </h3>
        <button
          :if={@active}
          id="add-address-btn"
          phx-click="toggle_add_address"
          class="btn btn-ghost btn-xs gap-1"
        >
          <.icon name="hero-plus" class="size-3" /> Add
        </button>
      </div>

      <%!-- Add form --%>
      <div
        :if={@adding}
        id="add-address-form"
        class="px-6 py-4 border-b border-base-300 bg-base-200/30"
      >
        <.form for={@form} phx-change="validate_address" phx-submit="save_address">
          <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
            <.input field={@form[:chain]} type="text" label="Chain" placeholder="base" required />
            <.input field={@form[:address]} type="text" label="Address" placeholder="0x..." required />
            <.input field={@form[:alias]} type="text" label="Alias" placeholder="main wallet" />
            <.input
              field={@form[:role]}
              type="select"
              label="Role"
              options={[
                {"Payout", "payout"},
                {"Funding", "funding"},
                {"Contract", "contract"},
                {"Other", "other"}
              ]}
            />
          </div>
          <div class="flex items-center gap-2 mt-3">
            <.button type="submit" variant="primary" class="btn btn-primary btn-xs">
              Add address
            </.button>
            <.button type="button" phx-click="toggle_add_address" class="btn btn-ghost btn-xs">
              Cancel
            </.button>
          </div>
        </.form>
      </div>

      <%!-- Address list --%>
      <div :if={@labels == [] && !@adding} class="px-6 py-8 text-center">
        <p class="text-sm text-base-content/40">No addresses yet</p>
      </div>
      <div :if={@labels != []} class="divide-y divide-base-300">
        <div
          :for={label <- @labels}
          id={"addr-#{label.id}"}
          class="flex items-center justify-between px-6 py-3"
        >
          <div class="min-w-0">
            <p class="text-sm font-mono truncate">{label.address}</p>
            <div class="flex items-center gap-2 mt-0.5">
              <span class="badge badge-xs badge-ghost">{label.chain}</span>
              <span class={["badge badge-xs", role_badge_class(label.role)]}>{label.role}</span>
              <span :if={label.alias} class="text-xs text-base-content/40">{label.alias}</span>
              <span :if={label.verified} class="badge badge-xs badge-success">Verified</span>
            </div>
          </div>
          <button
            phx-click="retire_address"
            phx-value-label-id={label.id}
            data-confirm="Retire this address? It will remain in audit history."
            class="btn btn-ghost btn-xs text-error"
          >
            Retire
          </button>
        </div>
      </div>
    </div>
    """
  end

  # --- Component: evidence section -------------------------------------------

  attr :artifacts, :list, required: true
  attr :adding, :boolean, required: true
  attr :form, :map, required: true
  attr :active, :boolean, required: true

  defp evidence_section(assigns) do
    ~H"""
    <div id="evidence-section" class="rounded-xl border border-base-300 bg-base-100 shadow-sm">
      <div class="flex items-center justify-between px-6 py-4 border-b border-base-300">
        <h3 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-document-text" class="size-4" /> Evidence
          <span class="badge badge-xs badge-ghost">{length(@artifacts)}</span>
        </h3>
        <button
          :if={@active}
          id="add-evidence-btn"
          phx-click="toggle_add_evidence"
          class="btn btn-ghost btn-xs gap-1"
        >
          <.icon name="hero-plus" class="size-3" /> Add
        </button>
      </div>

      <%!-- Add form --%>
      <div
        :if={@adding}
        id="add-evidence-form"
        class="px-6 py-4 border-b border-base-300 bg-base-200/30"
      >
        <.form for={@form} phx-change="validate_evidence" phx-submit="save_evidence">
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <.input
              field={@form[:kind]}
              type="select"
              label="Kind"
              options={evidence_kind_options()}
              prompt="Select kind"
              required
            />
            <.input
              field={@form[:content_uri]}
              type="text"
              label="Content URI"
              placeholder="https://..."
              required
            />
            <.input
              field={@form[:weight]}
              type="select"
              label="Weight"
              options={[{"Low", "low"}, {"Medium", "medium"}, {"High", "high"}]}
              prompt="Select weight"
            />
            <.input
              field={@form[:source]}
              type="text"
              label="Source"
              placeholder="e.g. internal review"
            />
          </div>
          <div class="flex items-center gap-2 mt-3">
            <.button type="submit" variant="primary" class="btn btn-primary btn-xs">
              Add evidence
            </.button>
            <.button type="button" phx-click="toggle_add_evidence" class="btn btn-ghost btn-xs">
              Cancel
            </.button>
          </div>
        </.form>
      </div>

      <%!-- Evidence list --%>
      <div :if={@artifacts == [] && !@adding} class="px-6 py-8 text-center">
        <p class="text-sm text-base-content/40">No evidence yet</p>
      </div>
      <div :if={@artifacts != []} class="divide-y divide-base-300">
        <div :for={ev <- @artifacts} id={"ev-#{ev.id}"} class="px-6 py-3">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <span class={["badge badge-xs", evidence_kind_badge(ev.kind)]}>
                {evidence_kind_label(ev.kind)}
              </span>
              <span :if={ev.weight} class="badge badge-xs badge-ghost">{ev.weight}</span>
            </div>
            <span class="text-xs text-base-content/40">{format_datetime(ev.captured_at)}</span>
          </div>
          <p class="text-xs font-mono text-base-content/50 truncate mt-1">{ev.content_uri}</p>
          <p :if={ev.source} class="text-xs text-base-content/40 mt-0.5">Source: {ev.source}</p>
        </div>
      </div>
    </div>
    """
  end

  # --- Component: trust section ----------------------------------------------

  attr :assertions, :list, required: true
  attr :asserting, :boolean, required: true
  attr :form, :map, required: true
  attr :trust_level, :atom, required: true

  defp trust_section(assigns) do
    ~H"""
    <div id="trust-section" class="rounded-xl border border-base-300 bg-base-100 shadow-sm">
      <div class="flex items-center justify-between px-6 py-4 border-b border-base-300">
        <h3 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-shield-check" class="size-4" /> Trust
        </h3>
        <button
          id="assert-trust-btn"
          phx-click="toggle_assert_trust"
          class="btn btn-ghost btn-xs gap-1"
        >
          <.icon name="hero-plus" class="size-3" /> Assert
        </button>
      </div>

      <%!-- Current trust level --%>
      <div class="px-6 py-3 border-b border-base-300">
        <p class="text-xs text-base-content/50 mb-1">Current level</p>
        <.trust_badge level={@trust_level} />
      </div>

      <%!-- Assert form --%>
      <div
        :if={@asserting}
        id="assert-trust-form"
        class="px-6 py-4 border-b border-base-300 bg-base-200/30"
      >
        <.form for={@form} phx-change="validate_trust" phx-submit="save_trust">
          <div class="space-y-3">
            <.input
              field={@form[:level]}
              type="select"
              label="Trust level"
              options={trust_level_options()}
              prompt="Select level"
              required
            />
            <.input
              field={@form[:rationale]}
              type="textarea"
              label="Rationale"
              rows="2"
              placeholder="Why this trust level?"
            />
            <div class="grid grid-cols-2 gap-3">
              <div>
                <label class="label text-xs">Scope: Asset</label>
                <input
                  type="text"
                  name="trust[scope_asset]"
                  value={@form.params["scope_asset"] || ""}
                  placeholder="e.g. USDC (empty = broad)"
                  class="input input-sm input-bordered w-full"
                />
              </div>
              <div>
                <label class="label text-xs">Scope: Chain</label>
                <input
                  type="text"
                  name="trust[scope_chain]"
                  value={@form.params["scope_chain"] || ""}
                  placeholder="e.g. base (empty = broad)"
                  class="input input-sm input-bordered w-full"
                />
              </div>
            </div>
          </div>
          <div class="flex items-center gap-2 mt-3">
            <.button type="submit" variant="primary" class="btn btn-primary btn-xs">
              Issue assertion
            </.button>
            <.button type="button" phx-click="toggle_assert_trust" class="btn btn-ghost btn-xs">
              Cancel
            </.button>
          </div>
        </.form>
      </div>

      <%!-- Assertions list --%>
      <div :if={@assertions == [] && !@asserting} class="px-6 py-6 text-center">
        <p class="text-sm text-base-content/40">No trust assertions</p>
        <p class="text-xs text-base-content/30 mt-1">
          Issue an assertion to set this counterparty's trust level
        </p>
      </div>
      <div :if={@assertions != []} class="divide-y divide-base-300">
        <div :for={ta <- @assertions} id={"ta-#{ta.id}"} class="px-6 py-3">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <.trust_badge level={ta.level} />
              <span :if={ta.scope != %{}} class="badge badge-xs badge-outline font-mono">
                {scope_summary(ta.scope)}
              </span>
              <span :if={ta.scope == %{}} class="badge badge-xs badge-ghost">Broad</span>
            </div>
            <span class="text-xs text-base-content/40">{format_datetime(ta.issued_at)}</span>
          </div>
          <p :if={ta.rationale} class="text-xs text-base-content/50 mt-1">{ta.rationale}</p>
          <p class="text-[0.65rem] text-base-content/30 mt-0.5">by {ta.issued_by}</p>
        </div>
      </div>
    </div>
    """
  end

  # --- Component: details card -----------------------------------------------

  attr :counterparty, :map, required: true

  defp details_card(assigns) do
    ~H"""
    <div id="details-card" class="rounded-xl border border-base-300 bg-base-100 shadow-sm p-5">
      <h3 class="text-sm font-semibold mb-3 flex items-center gap-1.5">
        <.icon name="hero-information-circle" class="size-4" /> Details
      </h3>
      <dl class="space-y-2 text-sm">
        <div>
          <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40">Status</dt>
          <dd>{if @counterparty.active, do: "Active", else: "Archived"}</dd>
        </div>
        <div>
          <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40">Created by</dt>
          <dd>{@counterparty.created_by}</dd>
        </div>
        <div :if={@counterparty.notes}>
          <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40">Notes</dt>
          <dd class="text-base-content/60">{@counterparty.notes}</dd>
        </div>
        <div>
          <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40">ID</dt>
          <dd class="font-mono text-xs text-base-content/40">{@counterparty.id}</dd>
        </div>
      </dl>
    </div>
    """
  end

  # --- Component: trust badge ------------------------------------------------

  attr :level, :atom, required: true

  defp trust_badge(assigns) do
    ~H"""
    <span :if={@level} class={["badge badge-sm font-medium", trust_badge_class(@level)]}>
      {trust_label(@level)}
    </span>
    <span :if={is_nil(@level)} class="badge badge-sm badge-ghost font-medium">No assertion</span>
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

  defp evidence_kind_options do
    [
      {"User note", "user_note"},
      {"Signed message", "signed_message"},
      {"External lookup", "external_lookup"},
      {"Transaction history", "transaction_history"},
      {"Contract classification", "contract_classification"},
      {"Prior successful transfer", "prior_successful_transfer"}
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

  defp role_badge_class(:payout), do: "badge-info"
  defp role_badge_class(:funding), do: "badge-warning"
  defp role_badge_class(:contract), do: "badge-ghost"
  defp role_badge_class(_), do: "badge-ghost"

  defp evidence_kind_badge(:user_note), do: "badge-info"
  defp evidence_kind_badge(:signed_message), do: "badge-success"
  defp evidence_kind_badge(:external_lookup), do: "badge-ghost"
  defp evidence_kind_badge(:transaction_history), do: "badge-warning"
  defp evidence_kind_badge(:contract_classification), do: "badge-ghost"
  defp evidence_kind_badge(:prior_successful_transfer), do: "badge-success"
  defp evidence_kind_badge(_), do: "badge-ghost"

  defp evidence_kind_label(:user_note), do: "User note"
  defp evidence_kind_label(:signed_message), do: "Signed message"
  defp evidence_kind_label(:external_lookup), do: "External lookup"
  defp evidence_kind_label(:transaction_history), do: "Tx history"
  defp evidence_kind_label(:contract_classification), do: "Contract"
  defp evidence_kind_label(:prior_successful_transfer), do: "Prior transfer"
  defp evidence_kind_label(_), do: "–"

  defp scope_summary(scope) when map_size(scope) == 0, do: "broad"

  defp scope_summary(scope) do
    scope
    |> Enum.map(fn {k, v} -> "#{k}:#{v}" end)
    |> Enum.join(", ")
  end

  defp format_datetime(nil), do: "–"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end
end
