defmodule BankWeb.PolicyBuilderLive do
  @moduledoc """
  Admin policy-builder UI on top of the `Bank.Policies.Versions`
  draft/publish foundation (#223) — closes #224.

  Mounted at `/policies/builder` on the operator+ live session so
  any workspace member with `:viewer | :operator | :admin | :owner`
  can view the builder, but every mutating event explicitly checks
  for `:admin` via `BankWeb.LiveAuth.authorize_action/2`. This
  matches the AGENTS pattern: read-everywhere, write-on-admin,
  with a clear flash message for operators who try to edit.

  ## Surface

  Two sections:

    * **Currently published** — read-only banner showing the
      workspace's `Bank.Policies.Versions.current_published/1`,
      its version number, and the resolved rule list.
    * **Draft** — the workspace's currently-open
      `Bank.Policies.Versions` draft. If none, an admin can open a
      new one (cloned from the current published). When a draft
      exists, the admin can:
        - add a new rule (type-switched form),
        - revise (edit) an existing rule via `Policies.revise_rule/3`,
        - remove a rule from the draft (drops the id; the rule row
          itself stays available for forensic / replay reads),
        - publish the draft via
          `Bank.Policies.Versions.publish_draft/2`.

  All mutations route through the existing `Bank.Policies` and
  `Bank.Policies.Versions` contexts — no new context surface, no
  new schema, no new migration.

  ## Rule families covered (MVP)

  Mirrors the existing `Bank.Policies.PolicyRule.@rule_types`:
  `:amount_limit`, `:rolling_spend_cap`, `:allowed_asset`,
  `:allowed_chain`, `:autonomy_tier`. The remaining types
  (`:slippage_ceiling`, `:allowed_router`, `:time_window`) and
  the issue body's "approval threshold" / "block unknown
  counterparty" / explicit mainnet-disabled rule are out of scope
  for the MVP and tracked as follow-up.

  ## Out of scope (#224 explicit non-goals)

  * No HTTP/API endpoint, no OpenAPI change.
  * No rule_type enum extension; we only build forms for existing
    types.
  * No rollback UI (#223 ships `rollback_to_version/2`; surfacing
    it is a separate UX concern).
  """

  use BankWeb, :live_view

  alias Bank.Policies
  alias Bank.Policies.{PolicyRule, PolicyVersion, Versions}
  alias BankWeb.LiveAuth

  @rule_types ~w(amount_limit rolling_spend_cap allowed_asset allowed_chain autonomy_tier)a

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_page, :policies)
     |> assign(:editing_rule_id, nil)
     |> assign(:rule_form, blank_rule_form())
     |> load_versions_and_rules()}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_page={@active_page}>
      <div class="space-y-6 p-6" id="policy-builder">
        <header>
          <h1 class="text-2xl font-bold">Policy builder</h1>
          <p class="text-sm text-base-content/70">
            Manage the workspace's draft and published policy
            versions. Editing requires the admin role.
          </p>
        </header>

        <.published_section
          published={@published_version}
          rules={@published_rules}
        />

        <.draft_section
          draft={@draft_version}
          rules={@draft_rules}
          rule_form={@rule_form}
          editing_rule_id={@editing_rule_id}
          can_edit?={admin?(@current_scope)}
        />
      </div>
    </Layouts.app>
    """
  end

  # --- published banner -------------------------------------------------

  attr :published, :any, required: true
  attr :rules, :list, required: true

  defp published_section(assigns) do
    ~H"""
    <section
      id="policy-builder-published"
      class="card bg-base-100 shadow-sm border border-base-300"
    >
      <div class="card-body">
        <h2 class="card-title">Currently published</h2>

        <%= if @published do %>
          <p id="policy-builder-published-meta" class="text-sm">
            Version <span class="font-mono">v{@published.version_number}</span>
            published by <span class="font-mono">{@published.published_by}</span>
            at <time>{format_time(@published.published_at)}</time>
          </p>

          <div id="policy-builder-published-rules" class="mt-3 space-y-2">
            <%= if @rules == [] do %>
              <p
                id="policy-builder-published-empty-rules"
                class="text-sm italic text-base-content/60"
              >
                The published version resolved to no active local rules.
              </p>
            <% else %>
              <ul class="text-sm space-y-1">
                <%= for rule <- @rules do %>
                  <li id={"policy-builder-published-rule-#{rule.id}"}>
                    <span class="font-mono text-xs">v{rule.version}</span>
                    {rule_summary(rule)}
                  </li>
                <% end %>
              </ul>
            <% end %>
          </div>
        <% else %>
          <p
            id="policy-builder-published-empty"
            class="text-sm italic text-base-content/60"
          >
            No policy version has been published in this workspace yet.
          </p>
        <% end %>
      </div>
    </section>
    """
  end

  # --- draft section ----------------------------------------------------

  attr :draft, :any, required: true
  attr :rules, :list, required: true
  attr :rule_form, :any, required: true
  attr :editing_rule_id, :any, required: true
  attr :can_edit?, :boolean, required: true

  defp draft_section(assigns) do
    ~H"""
    <section
      id="policy-builder-draft"
      class="card bg-base-100 shadow-sm border border-base-300"
    >
      <div class="card-body space-y-3">
        <div class="flex items-center justify-between">
          <h2 class="card-title">Draft</h2>

          <%= if @draft do %>
            <span
              id="policy-builder-draft-state"
              class="badge badge-warning"
            >
              Draft v{@draft.version_number}
            </span>
          <% else %>
            <span
              id="policy-builder-draft-state"
              class="badge badge-ghost"
            >
              No draft open
            </span>
          <% end %>
        </div>

        <%= if @draft do %>
          <.draft_rules
            rules={@rules}
            editing_rule_id={@editing_rule_id}
            can_edit?={@can_edit?}
            rule_form={@rule_form}
          />

          <%= if @can_edit? do %>
            <button
              id="policy-builder-publish-btn"
              type="button"
              phx-click="publish_draft"
              data-confirm="Publish this draft? It supersedes the current published version."
              class="btn btn-primary btn-sm mt-3"
            >
              Publish draft
            </button>
          <% end %>
        <% else %>
          <%= if @can_edit? do %>
            <button
              id="policy-builder-open-draft-btn"
              type="button"
              phx-click="open_draft"
              class="btn btn-primary btn-sm self-start"
            >
              Open new draft
            </button>
          <% else %>
            <p
              id="policy-builder-draft-readonly"
              class="text-sm italic text-base-content/60"
            >
              No draft is open. Admin role required to open a new draft.
            </p>
          <% end %>
        <% end %>
      </div>
    </section>
    """
  end

  # --- draft rules + add/edit form -------------------------------------

  attr :rules, :list, required: true
  attr :editing_rule_id, :any, required: true
  attr :can_edit?, :boolean, required: true
  attr :rule_form, :any, required: true

  defp draft_rules(assigns) do
    ~H"""
    <div id="policy-builder-draft-rules" class="space-y-2">
      <%= if @rules == [] do %>
        <p
          id="policy-builder-draft-empty-rules"
          class="text-sm italic text-base-content/60"
        >
          No rules in this draft yet.
        </p>
      <% else %>
        <ul class="text-sm space-y-1">
          <%= for rule <- @rules do %>
            <li
              id={"policy-builder-draft-rule-#{rule.id}"}
              class="flex items-center justify-between gap-2"
            >
              <span>
                <span class="font-mono text-xs">v{rule.version}</span>
                {rule_summary(rule)}
              </span>

              <%= if @can_edit? do %>
                <span class="flex gap-1">
                  <button
                    id={"policy-builder-edit-#{rule.id}"}
                    type="button"
                    phx-click="start_edit"
                    phx-value-rule-id={rule.id}
                    class="btn btn-ghost btn-xs"
                  >
                    Edit
                  </button>

                  <button
                    id={"policy-builder-remove-#{rule.id}"}
                    type="button"
                    phx-click="remove_rule"
                    phx-value-rule-id={rule.id}
                    data-confirm="Remove this rule from the draft? The rule row stays in the catalog."
                    class="btn btn-ghost btn-xs text-error"
                  >
                    Remove
                  </button>
                </span>
              <% end %>
            </li>
          <% end %>
        </ul>
      <% end %>

      <%= if @can_edit? do %>
        <.rule_form
          form={@rule_form}
          editing_rule_id={@editing_rule_id}
        />
      <% end %>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :editing_rule_id, :any, required: true

  defp rule_form(assigns) do
    ~H"""
    <.form
      :let={f}
      for={@form}
      id="policy-builder-rule-form"
      phx-change="validate_rule"
      phx-submit="save_rule"
      class="mt-3 space-y-2 border-t border-base-300 pt-3"
    >
      <h3 class="text-sm font-semibold">
        <%= if @editing_rule_id do %>
          Edit rule
        <% else %>
          Add rule to draft
        <% end %>
      </h3>

      <.input
        field={f[:rule_type]}
        type="select"
        label="Rule type"
        prompt="Choose a rule type"
        options={rule_type_options()}
      />

      <.input
        field={f[:priority]}
        type="number"
        label="Priority"
        value={Phoenix.HTML.Form.input_value(f, :priority) || 0}
      />

      <.params_subform form={f} />

      <div class="flex gap-2">
        <button
          id="policy-builder-save-rule-btn"
          type="submit"
          class="btn btn-primary btn-sm"
        >
          <%= if @editing_rule_id do %>
            Save changes
          <% else %>
            Add rule
          <% end %>
        </button>

        <%= if @editing_rule_id do %>
          <button
            id="policy-builder-cancel-edit-btn"
            type="button"
            phx-click="cancel_edit"
            class="btn btn-ghost btn-sm"
          >
            Cancel
          </button>
        <% end %>
      </div>
    </.form>
    """
  end

  attr :form, :any, required: true

  # Render every type-specific param input every time. The
  # `data-rule-type-group` attribute lets the styling layer hide
  # irrelevant groups; the param-extractor on the server side
  # (`params_for_type/1`) ignores fields that don't apply to the
  # selected `rule_type`. Always rendering the inputs keeps the
  # LiveView form deterministic for the test client (which
  # constructs form payloads from the rendered HTML).
  defp params_subform(assigns) do
    ~H"""
    <fieldset id="policy-builder-rule-params">
      <div data-rule-type-group="amount_limit">
        <.input
          field={@form[:max_per_tx]}
          type="text"
          label="Max amount per intent"
          placeholder="100.00"
        />
      </div>

      <div data-rule-type-group="rolling_spend_cap">
        <.input
          field={@form[:max_total]}
          type="text"
          label="Max total amount"
          placeholder="1000.00"
        />
        <.input
          field={@form[:window_hours]}
          type="number"
          label="Rolling window (hours)"
          placeholder="24"
        />
      </div>

      <div data-rule-type-group="allowed_asset_chain">
        <.input
          field={@form[:assets_csv]}
          type="text"
          label="Assets (comma-separated)"
          placeholder="USDC,USDT"
        />

        <.input
          field={@form[:chains_csv]}
          type="text"
          label="Chains (comma-separated)"
          placeholder="base,base-sepolia"
        />

        <.input
          field={@form[:mode]}
          type="select"
          label="Allowlist/Denylist mode (assets/chains)"
          options={[{"Allowlist", "allowlist"}, {"Denylist", "denylist"}]}
        />
      </div>

      <div data-rule-type-group="autonomy_tier">
        <.input
          field={@form[:tier]}
          type="select"
          label="Autonomy tier"
          options={[
            {"Auto-execute", "auto"},
            {"Manual approval", "manual"},
            {"Block", "block"}
          ]}
        />
      </div>
    </fieldset>
    """
  end

  # --- handle_event: read-only navigation -------------------------------

  @impl true
  def handle_event("validate_rule", %{"rule" => params}, socket) do
    {:noreply,
     assign(
       socket,
       :rule_form,
       build_rule_form(params, socket.assigns.editing_rule_id, :validate)
     )}
  end

  # --- handle_event: admin-only mutations -------------------------------

  def handle_event("open_draft", _params, socket) do
    with_admin(socket, fn socket ->
      ws_id = socket.assigns.current_scope.workspace.id
      actor_id = socket.assigns.current_scope.user.id

      case Versions.create_draft(ws_id, created_by: :user, actor_id: actor_id) do
        {:ok, _draft} ->
          {:noreply,
           socket
           |> put_flash(:info, "Draft opened.")
           |> load_versions_and_rules()}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply,
           put_flash(socket, :error, "Could not open draft: #{summarize_changeset(cs)}.")}
      end
    end)
  end

  def handle_event("save_rule", %{"rule" => params}, socket) do
    with_admin(socket, fn socket ->
      cond do
        is_nil(socket.assigns.draft_version) ->
          {:noreply, put_flash(socket, :error, "Open a draft before adding rules.")}

        socket.assigns.editing_rule_id ->
          do_revise_rule(socket, params)

        true ->
          do_add_rule(socket, params)
      end
    end)
  end

  def handle_event("start_edit", %{"rule-id" => rule_id}, socket) do
    with_admin(socket, fn socket ->
      case Enum.find(socket.assigns.draft_rules, &(&1.id == rule_id)) do
        nil ->
          {:noreply, put_flash(socket, :error, "Rule not found in draft.")}

        %PolicyRule{} = rule ->
          form = build_rule_form(rule_to_form_params(rule), rule.id, nil)
          {:noreply, socket |> assign(:editing_rule_id, rule.id) |> assign(:rule_form, form)}
      end
    end)
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_rule_id, nil)
     |> assign(:rule_form, blank_rule_form())}
  end

  def handle_event("remove_rule", %{"rule-id" => rule_id}, socket) do
    with_admin(socket, fn socket ->
      case socket.assigns.draft_version do
        nil ->
          {:noreply, put_flash(socket, :error, "No draft open.")}

        draft ->
          new_ids =
            draft
            |> PolicyVersion.rule_ids_list()
            |> List.delete(rule_id)

          case Versions.update_draft_rule_ids(draft, %{"items" => new_ids}) do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, "Rule removed from draft.")
               |> load_versions_and_rules()}

            {:error, :not_a_draft} ->
              {:noreply, put_flash(socket, :error, "The draft is no longer editable.")}

            {:error, %Ecto.Changeset{} = cs} ->
              {:noreply,
               put_flash(socket, :error, "Could not remove rule: #{summarize_changeset(cs)}.")}
          end
      end
    end)
  end

  def handle_event("publish_draft", _params, socket) do
    with_admin(socket, fn socket ->
      case socket.assigns.draft_version do
        nil ->
          {:noreply, put_flash(socket, :error, "No draft open.")}

        draft ->
          actor_id = socket.assigns.current_scope.user.id

          case Versions.publish_draft(draft, published_by: :user, actor_id: actor_id) do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, "Draft published.")
               |> load_versions_and_rules()}

            {:error, :not_a_draft} ->
              {:noreply, put_flash(socket, :error, "Draft is no longer publishable.")}

            {:error, %Ecto.Changeset{} = cs} ->
              {:noreply,
               put_flash(socket, :error, "Could not publish draft: #{summarize_changeset(cs)}.")}
          end
      end
    end)
  end

  # --- internals: load + build ------------------------------------------

  defp load_versions_and_rules(socket) do
    ws_id = socket.assigns.current_scope.workspace.id

    published = Versions.current_published(ws_id)

    draft =
      ws_id
      |> Versions.list_versions(status: :draft, limit: 1)
      |> List.first()

    %{rules: published_rules} =
      Versions.snapshot_for_workspace(ws_id) || %{rules: []}

    draft_rules =
      case draft do
        nil ->
          []

        %_{} = d ->
          d
          |> PolicyVersion.rule_ids_list()
          |> resolve_rules_in_workspace(ws_id)
      end

    socket
    |> assign(:published_version, published)
    |> assign(:published_rules, published_rules)
    |> assign(:draft_version, draft)
    |> assign(:draft_rules, draft_rules)
    |> assign(:editing_rule_id, nil)
    |> assign(:rule_form, blank_rule_form())
  end

  # Workspace-scoped fetch — defends in depth on top of the #226 P2
  # fix that scopes snapshot resolution to workspace_id.
  defp resolve_rules_in_workspace([], _ws_id), do: []

  defp resolve_rules_in_workspace(ids, ws_id) when is_list(ids) do
    import Ecto.Query

    Bank.Policies.PolicyRule
    |> where(
      [r],
      r.id in ^ids and r.state == ^:active and r.workspace_id == ^ws_id
    )
    |> Bank.Repo.all()
  end

  # --- form helpers -----------------------------------------------------

  defp blank_rule_form, do: build_rule_form(%{}, nil, nil)

  defp build_rule_form(params, _editing_id, action) do
    data = %{
      "rule_type" => params["rule_type"] || params[:rule_type] || "",
      "priority" => params["priority"] || params[:priority] || "0",
      "max_per_tx" => params["max_per_tx"] || params[:max_per_tx] || "",
      "max_total" => params["max_total"] || params[:max_total] || "",
      "window_hours" => params["window_hours"] || params[:window_hours] || "",
      "assets_csv" => params["assets_csv"] || params[:assets_csv] || "",
      "chains_csv" => params["chains_csv"] || params[:chains_csv] || "",
      "mode" => params["mode"] || params[:mode] || "allowlist",
      "tier" => params["tier"] || params[:tier] || "auto"
    }

    types_str = Enum.map(@rule_types, &Atom.to_string/1)
    cs = build_form_changeset(data, types_str, action)
    to_form(cs, as: :rule)
  end

  defp build_form_changeset(params, types_str, action) do
    types = %{
      rule_type: :string,
      priority: :integer,
      max_per_tx: :string,
      max_total: :string,
      window_hours: :integer,
      assets_csv: :string,
      chains_csv: :string,
      mode: :string,
      tier: :string
    }

    cs =
      {%{}, types}
      |> Ecto.Changeset.cast(params, Map.keys(types))
      |> Ecto.Changeset.validate_inclusion(:rule_type, types_str,
        message: "must be one of: #{Enum.join(types_str, ", ")}"
      )

    cs =
      case Ecto.Changeset.get_change(cs, :rule_type) do
        "amount_limit" ->
          Ecto.Changeset.validate_required(cs, [:max_per_tx], message: "is required")

        "rolling_spend_cap" ->
          cs
          |> Ecto.Changeset.validate_required([:max_total, :window_hours], message: "is required")
          |> Ecto.Changeset.validate_number(:window_hours, greater_than: 0)

        "allowed_asset" ->
          Ecto.Changeset.validate_required(cs, [:assets_csv], message: "list at least one asset")

        "allowed_chain" ->
          Ecto.Changeset.validate_required(cs, [:chains_csv], message: "list at least one chain")

        "autonomy_tier" ->
          Ecto.Changeset.validate_required(cs, [:tier], message: "choose a tier")

        _ ->
          cs
      end

    if action, do: Map.put(cs, :action, action), else: cs
  end

  defp do_add_rule(socket, params) do
    ws_id = socket.assigns.current_scope.workspace.id
    draft = socket.assigns.draft_version

    case create_rule_from_params(params, ws_id) do
      {:ok, rule} ->
        new_ids = PolicyVersion.rule_ids_list(draft) ++ [rule.id]

        case Versions.update_draft_rule_ids(draft, %{"items" => new_ids}) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Rule added to draft.")
             |> load_versions_and_rules()}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Rule was created but not added to draft.")}
        end

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         socket
         |> assign(:rule_form, build_rule_form(params, nil, :insert))
         |> put_flash(:error, "Fix the errors and try again: #{summarize_changeset(cs)}")}

      {:error, :invalid_form, form_cs} ->
        {:noreply,
         assign(
           socket,
           :rule_form,
           to_form(Map.put(form_cs, :action, :insert), as: :rule)
         )}
    end
  end

  defp do_revise_rule(socket, params) do
    ws_id = socket.assigns.current_scope.workspace.id
    rule_id = socket.assigns.editing_rule_id
    draft = socket.assigns.draft_version

    case Enum.find(socket.assigns.draft_rules, &(&1.id == rule_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Rule not found in draft.")}

      %PolicyRule{} = prior ->
        with {:ok, attrs} <- attrs_from_form_params(params, ws_id),
             {:ok, successor} <- Policies.revise_rule(prior, attrs, actor: :user) do
          new_ids =
            draft
            |> PolicyVersion.rule_ids_list()
            |> Enum.map(fn id -> if id == prior.id, do: successor.id, else: id end)

          case Versions.update_draft_rule_ids(draft, %{"items" => new_ids}) do
            {:ok, _} ->
              {:noreply,
               socket
               |> put_flash(:info, "Rule updated in draft.")
               |> load_versions_and_rules()}

            {:error, _} ->
              {:noreply,
               put_flash(socket, :error, "Successor created but draft pointer not updated.")}
          end
        else
          {:error, %Ecto.Changeset{} = cs} ->
            {:noreply,
             socket
             |> assign(:rule_form, build_rule_form(params, rule_id, :update))
             |> put_flash(:error, "Fix the errors and try again: #{summarize_changeset(cs)}")}

          {:error, :invalid_form, form_cs} ->
            {:noreply,
             assign(
               socket,
               :rule_form,
               to_form(Map.put(form_cs, :action, :update), as: :rule)
             )}

          {:error, :not_active} ->
            {:noreply, put_flash(socket, :error, "Underlying rule is not active any more.")}
        end
    end
  end

  defp create_rule_from_params(params, ws_id) do
    case attrs_from_form_params(params, ws_id) do
      {:ok, attrs} ->
        Policies.create_rule(attrs, actor: :user, workspace_id: ws_id)

      {:error, :invalid_form, _} = err ->
        err
    end
  end

  defp attrs_from_form_params(params, ws_id) do
    types_str = Enum.map(@rule_types, &Atom.to_string/1)
    cs = build_form_changeset(params, types_str, :insert)

    if cs.valid? do
      attrs = %{
        "rule_type" => params["rule_type"],
        "priority" => params["priority"] || "0",
        "scope" => %{},
        "params" => params_for_type(params),
        "state" => "active",
        "created_by" => "user",
        "workspace_id" => ws_id
      }

      {:ok, attrs}
    else
      {:error, :invalid_form, cs}
    end
  end

  defp params_for_type(%{"rule_type" => "amount_limit"} = p),
    do: %{"max_per_tx" => p["max_per_tx"]}

  defp params_for_type(%{"rule_type" => "rolling_spend_cap"} = p),
    do: %{"max_total" => p["max_total"], "window_hours" => p["window_hours"]}

  defp params_for_type(%{"rule_type" => "allowed_asset"} = p),
    do: %{
      "assets" => split_csv(p["assets_csv"]),
      "mode" => p["mode"] || "allowlist"
    }

  defp params_for_type(%{"rule_type" => "allowed_chain"} = p),
    do: %{
      "chains" => split_csv(p["chains_csv"]),
      "mode" => p["mode"] || "allowlist"
    }

  defp params_for_type(%{"rule_type" => "autonomy_tier"} = p),
    do: %{"tier" => p["tier"]}

  defp params_for_type(_), do: %{}

  defp split_csv(nil), do: []
  defp split_csv(""), do: []

  defp split_csv(s),
    do: s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp rule_to_form_params(%PolicyRule{} = rule) do
    base = %{
      "rule_type" => Atom.to_string(rule.rule_type),
      "priority" => to_string(rule.priority || 0)
    }

    type_specific =
      case rule.rule_type do
        :amount_limit ->
          %{"max_per_tx" => Map.get(rule.params || %{}, "max_per_tx", "")}

        :rolling_spend_cap ->
          %{
            "max_total" => Map.get(rule.params || %{}, "max_total", ""),
            "window_hours" => Map.get(rule.params || %{}, "window_hours", "")
          }

        :allowed_asset ->
          %{
            "assets_csv" => Enum.join(Map.get(rule.params || %{}, "assets", []), ","),
            "mode" => Map.get(rule.params || %{}, "mode", "allowlist")
          }

        :allowed_chain ->
          %{
            "chains_csv" => Enum.join(Map.get(rule.params || %{}, "chains", []), ","),
            "mode" => Map.get(rule.params || %{}, "mode", "allowlist")
          }

        :autonomy_tier ->
          %{"tier" => Map.get(rule.params || %{}, "tier", "auto")}

        _ ->
          %{}
      end

    Map.merge(base, type_specific)
  end

  # --- summaries / formatting ------------------------------------------

  @doc false
  def rule_summary(%PolicyRule{rule_type: :amount_limit, params: p}),
    do: "Max amount per intent: #{Map.get(p || %{}, "max_per_tx", "(unset)")}"

  def rule_summary(%PolicyRule{rule_type: :rolling_spend_cap, params: p}),
    do:
      "Rolling spend cap: #{Map.get(p || %{}, "max_total", "(unset)")} per #{Map.get(p || %{}, "window_hours", "?")}h"

  def rule_summary(%PolicyRule{rule_type: :allowed_asset, params: p}) do
    list = (Map.get(p || %{}, "assets") || []) |> Enum.join(", ")
    mode = Map.get(p || %{}, "mode", "allowlist")
    "Allowed assets (#{mode}): #{list}"
  end

  def rule_summary(%PolicyRule{rule_type: :allowed_chain, params: p}) do
    list = (Map.get(p || %{}, "chains") || []) |> Enum.join(", ")
    mode = Map.get(p || %{}, "mode", "allowlist")
    "Allowed chains (#{mode}): #{list}"
  end

  def rule_summary(%PolicyRule{rule_type: :autonomy_tier, params: p}),
    do: "Autonomy tier: #{Map.get(p || %{}, "tier", "(unset)")}"

  def rule_summary(%PolicyRule{rule_type: type}),
    do: "#{type} (no summary renderer)"

  defp format_time(nil), do: "(unknown)"
  defp format_time(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_time(other), do: to_string(other)

  defp rule_type_options do
    Enum.map(@rule_types, fn type -> {humanise(type), Atom.to_string(type)} end)
  end

  defp humanise(:amount_limit), do: "Max amount per intent"
  defp humanise(:rolling_spend_cap), do: "Rolling spend cap (daily, etc.)"
  defp humanise(:allowed_asset), do: "Allowed assets"
  defp humanise(:allowed_chain), do: "Allowed chains"
  defp humanise(:autonomy_tier), do: "Autonomy tier (auto / manual / block)"
  defp humanise(other), do: Atom.to_string(other)

  defp summarize_changeset(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field} #{msg}" end)
    |> Enum.join("; ")
  end

  defp admin?(%{role: role}) when role in [:admin, :owner], do: true
  defp admin?(_), do: false

  defp with_admin(socket, fun) do
    case LiveAuth.authorize_action(socket, :admin) do
      :ok ->
        fun.(socket)

      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to modify the policy builder.")}
    end
  end
end
