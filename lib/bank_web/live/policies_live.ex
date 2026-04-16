defmodule BankWeb.PoliciesLive do
  @moduledoc """
  Policy rules management — operator UI for the v1 rule catalog.

  Shows all policy rules with readable type labels, scope badges, and
  state indicators. Supports creating new rules (with rule-type-specific
  param forms), revising active rules, and archiving.

  Rule params are presented as structured form fields per rule type
  rather than raw JSON, so operators can understand what each rule does.
  """

  use BankWeb, :live_view

  alias Bank.Policies
  alias Bank.Policies.PolicyRule

  @rule_type_options [
    {"Amount limit", "amount_limit"},
    {"Rolling spend cap", "rolling_spend_cap"},
    {"Allowed asset", "allowed_asset"},
    {"Allowed chain", "allowed_chain"},
    {"Autonomy tier", "autonomy_tier"},
    {"Time window", "time_window"},
    {"Slippage ceiling (swaps)", "slippage_ceiling"},
    {"Allowed router (swaps)", "allowed_router"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(page_title: "Policies")
      |> assign(:show_create, false)
      |> assign(:filter_state, "active")
      |> assign(:revising_rule_id, nil)
      |> assign(:rule_type_options, @rule_type_options)
      |> assign_create_form(%{})
      |> assign_revise_form(%{})
      |> load_rules()

    {:ok, socket}
  end

  # --- Events ---------------------------------------------------------------

  @impl true
  def handle_event("toggle_create", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create, !socket.assigns.show_create)
     |> assign(:revising_rule_id, nil)
     |> assign_create_form(%{})}
  end

  def handle_event("filter_state", %{"state" => state}, socket) do
    {:noreply,
     socket
     |> assign(:filter_state, state)
     |> load_rules()}
  end

  def handle_event("validate_rule", %{"rule" => params}, socket) do
    {:noreply, assign_create_form(socket, params, :validate)}
  end

  def handle_event("save_rule", %{"rule" => params}, socket) do
    attrs = build_rule_attrs(params)

    case Policies.create_rule(attrs, actor: :user) do
      {:ok, _rule} ->
        {:noreply,
         socket
         |> put_flash(:info, "Policy rule created")
         |> assign(:show_create, false)
         |> assign_create_form(%{})
         |> load_rules()}

      {:error, changeset} ->
        {:noreply, assign(socket, :create_form, to_form(changeset, as: :rule))}
    end
  end

  def handle_event("start_revise", %{"rule-id" => rule_id}, socket) do
    rule = Enum.find(socket.assigns.rules, &(&1.id == rule_id))

    if rule do
      prefill = rule_to_form_params(rule)

      {:noreply,
       socket
       |> assign(:revising_rule_id, rule_id)
       |> assign(:show_create, false)
       |> assign_revise_form(prefill)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_revise", _params, socket) do
    {:noreply,
     socket
     |> assign(:revising_rule_id, nil)
     |> assign_revise_form(%{})}
  end

  def handle_event("validate_revise", %{"revise" => params}, socket) do
    {:noreply, assign_revise_form(socket, params, :validate)}
  end

  def handle_event("save_revise", %{"revise" => params}, socket) do
    rule_id = socket.assigns.revising_rule_id
    rule = Enum.find(socket.assigns.rules, &(&1.id == rule_id))

    if rule do
      attrs = build_rule_attrs(params)

      case Policies.revise_rule(rule, attrs, actor: :user) do
        {:ok, _new_rule} ->
          {:noreply,
           socket
           |> put_flash(:info, "Policy rule revised — new version created")
           |> assign(:revising_rule_id, nil)
           |> assign_revise_form(%{})
           |> load_rules()}

        {:error, :not_active} ->
          {:noreply, put_flash(socket, :error, "Only active rules can be revised")}

        {:error, changeset} ->
          {:noreply, assign(socket, :revise_form, to_form(changeset, as: :revise))}
      end
    else
      {:noreply, put_flash(socket, :error, "Rule not found")}
    end
  end

  def handle_event("archive_rule", %{"rule-id" => rule_id}, socket) do
    rule = Enum.find(socket.assigns.rules, &(&1.id == rule_id))

    if rule do
      case Policies.archive_rule(rule, actor: :user) do
        {:ok, _rule} ->
          {:noreply,
           socket
           |> put_flash(:info, "Policy rule archived")
           |> load_rules()}

        {:error, :not_active} ->
          {:noreply, put_flash(socket, :error, "Only active rules can be archived")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to archive rule")}
      end
    else
      {:noreply, put_flash(socket, :error, "Rule not found")}
    end
  end

  # --- State loading --------------------------------------------------------

  defp load_rules(socket) do
    filters =
      case socket.assigns.filter_state do
        "all" -> %{}
        state -> %{state: String.to_existing_atom(state)}
      end

    %{entries: entries} = Policies.list_rules(filters, limit: 100)
    assign(socket, :rules, entries)
  end

  defp assign_create_form(socket, params, action \\ nil) do
    changeset =
      %PolicyRule{}
      |> PolicyRule.changeset(Map.merge(params, %{"created_by" => "user", "state" => "active"}))

    changeset = if action, do: Map.put(changeset, :action, action), else: changeset
    assign(socket, :create_form, to_form(changeset, as: :rule))
  end

  defp assign_revise_form(socket, params, action \\ nil) do
    changeset =
      %PolicyRule{}
      |> PolicyRule.changeset(Map.merge(params, %{"created_by" => "user", "state" => "active"}))

    changeset = if action, do: Map.put(changeset, :action, action), else: changeset
    assign(socket, :revise_form, to_form(changeset, as: :revise))
  end

  defp build_rule_attrs(params) do
    rule_type = params["rule_type"]

    base = %{
      "rule_type" => rule_type,
      "priority" => params["priority"] || "0",
      "created_by" => "user",
      "state" => "active",
      "scope" => build_scope(params),
      "params" => build_params(rule_type, params)
    }

    base
  end

  defp build_scope(params) do
    scope = %{}

    scope =
      if params["scope_asset"] not in [nil, ""],
        do: Map.put(scope, "asset", params["scope_asset"]),
        else: scope

    scope =
      if params["scope_chain"] not in [nil, ""],
        do: Map.put(scope, "chain", params["scope_chain"]),
        else: scope

    scope =
      if params["scope_counterparty_id"] not in [nil, ""],
        do: Map.put(scope, "counterparty_id", params["scope_counterparty_id"]),
        else: scope

    scope
  end

  defp build_params("amount_limit", p),
    do: %{"max_per_tx" => p["param_max_per_tx"], "currency" => p["param_currency"]}

  defp build_params("rolling_spend_cap", p),
    do: %{"max_total" => p["param_max_total"], "window_hours" => p["param_window_hours"]}

  defp build_params("allowed_asset", p),
    do: %{"assets" => split_csv(p["param_assets"]), "mode" => p["param_mode"] || "allowlist"}

  defp build_params("allowed_chain", p),
    do: %{"chains" => split_csv(p["param_chains"]), "mode" => p["param_mode"] || "allowlist"}

  defp build_params("autonomy_tier", p),
    do: %{"tier" => p["param_tier"]}

  defp build_params("time_window", p),
    do: %{
      "timezone" => p["param_timezone"] || "UTC",
      "days_of_week" => parse_days(p["param_days_of_week"]),
      "start_hhmm" => p["param_start_hhmm"] || "00:00",
      "end_hhmm" => p["param_end_hhmm"] || "24:00"
    }

  defp build_params("slippage_ceiling", p),
    do: %{"max_bps" => p["param_max_bps"]}

  defp build_params("allowed_router", p),
    do: %{"routers" => split_csv(p["param_routers"]), "mode" => p["param_mode"] || "allowlist"}

  defp build_params(_, _), do: %{}

  defp split_csv(nil), do: []
  defp split_csv(""), do: []

  defp split_csv(s),
    do: s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

  defp parse_days(nil), do: [1, 2, 3, 4, 5, 6, 7]
  defp parse_days(""), do: [1, 2, 3, 4, 5, 6, 7]

  defp parse_days(s) do
    s
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(&String.to_integer/1)
    |> Enum.filter(&(&1 in 1..7))
  end

  defp rule_to_form_params(rule) do
    base = %{
      "rule_type" => to_string(rule.rule_type),
      "priority" => to_string(rule.priority),
      "scope_asset" => get_in(rule.scope, ["asset"]) || "",
      "scope_chain" => get_in(rule.scope, ["chain"]) || "",
      "scope_counterparty_id" => get_in(rule.scope, ["counterparty_id"]) || ""
    }

    params = rule.params || %{}

    param_fields =
      case rule.rule_type do
        :amount_limit ->
          %{
            "param_max_per_tx" => params["max_per_tx"] || "",
            "param_currency" => params["currency"] || ""
          }

        :rolling_spend_cap ->
          %{
            "param_max_total" => params["max_total"] || "",
            "param_window_hours" => params["window_hours"] || ""
          }

        :allowed_asset ->
          %{
            "param_assets" => Enum.join(params["assets"] || [], ", "),
            "param_mode" => params["mode"] || "allowlist"
          }

        :allowed_chain ->
          %{
            "param_chains" => Enum.join(params["chains"] || [], ", "),
            "param_mode" => params["mode"] || "allowlist"
          }

        :autonomy_tier ->
          %{"param_tier" => params["tier"] || ""}

        :time_window ->
          %{
            "param_timezone" => params["timezone"] || "UTC",
            "param_days_of_week" => Enum.join(params["days_of_week"] || [], ", "),
            "param_start_hhmm" => params["start_hhmm"] || "00:00",
            "param_end_hhmm" => params["end_hhmm"] || "24:00"
          }

        :slippage_ceiling ->
          %{"param_max_bps" => params["max_bps"] || ""}

        :allowed_router ->
          %{
            "param_routers" => Enum.join(params["routers"] || [], ", "),
            "param_mode" => params["mode"] || "allowlist"
          }

        _ ->
          %{}
      end

    Map.merge(base, param_fields)
  end

  # --- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active_page={:policies}>
      <%!-- Header --%>
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 id="page-title" class="text-2xl font-bold tracking-tight">Policies</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Manage policy rules that govern automation behavior
          </p>
        </div>
        <button id="new-rule-btn" phx-click="toggle_create" class="btn btn-primary btn-sm gap-1.5">
          <.icon name="hero-plus" class="size-3.5" /> New rule
        </button>
      </div>

      <%!-- Filter tabs --%>
      <div id="policy-filters" class="flex gap-1 mb-6">
        <button
          :for={
            {label, value} <- [
              {"Active", "active"},
              {"All", "all"},
              {"Archived", "archived"},
              {"Draft", "draft"}
            ]
          }
          phx-click="filter_state"
          phx-value-state={value}
          class={[
            "btn btn-xs",
            if(@filter_state == value, do: "btn-primary", else: "btn-ghost")
          ]}
        >
          {label}
        </button>
      </div>

      <%!-- Create form --%>
      <div
        :if={@show_create}
        id="create-rule-form"
        class="mb-6 rounded-xl border border-base-300 bg-base-100 shadow-sm p-6"
      >
        <h3 class="text-sm font-semibold mb-4">New policy rule</h3>
        <.rule_form
          form={@create_form}
          submit_event="save_rule"
          validate_event="validate_rule"
          rule_type_options={@rule_type_options}
        />
        <div class="flex items-center gap-2 mt-4">
          <button type="submit" form="create-rule-form-tag" class="btn btn-primary btn-sm">
            Create rule
          </button>
          <button type="button" phx-click="toggle_create" class="btn btn-ghost btn-sm">
            Cancel
          </button>
        </div>
      </div>

      <%!-- Empty state --%>
      <div
        :if={@rules == []}
        id="empty-rules"
        class="rounded-xl border-2 border-dashed border-base-300 bg-base-200/20 p-12 text-center"
      >
        <div class="w-14 h-14 rounded-full bg-base-300/50 flex items-center justify-center mx-auto mb-4">
          <.icon name="hero-scale" class="size-7 text-base-content/30" />
        </div>
        <h2 class="text-lg font-semibold text-base-content/70">No policy rules</h2>
        <p class="mt-2 text-sm text-base-content/50 max-w-md mx-auto">
          Create your first policy rule to define automation boundaries.
        </p>
      </div>

      <%!-- Rules list --%>
      <div :if={@rules != []} id="rules-list" class="space-y-3">
        <div :for={rule <- @rules} id={"rule-#{rule.id}"}>
          <.rule_card rule={rule} revising={@revising_rule_id == rule.id} />

          <%!-- Inline revise form --%>
          <div
            :if={@revising_rule_id == rule.id}
            id={"revise-form-#{rule.id}"}
            class="mt-1 rounded-b-xl border border-t-0 border-base-300 bg-base-200/30 p-6"
          >
            <h3 class="text-sm font-semibold mb-4">Revise rule — creates new version</h3>
            <.rule_form
              form={@revise_form}
              submit_event="save_revise"
              validate_event="validate_revise"
              rule_type_options={@rule_type_options}
              lock_type
            />
            <div class="flex items-center gap-2 mt-4">
              <button type="submit" form="revise-rule-form-tag" class="btn btn-primary btn-sm">
                Create revision
              </button>
              <button type="button" phx-click="cancel_revise" class="btn btn-ghost btn-sm">
                Cancel
              </button>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Component: rule form --------------------------------------------------

  attr :form, :map, required: true
  attr :submit_event, :string, required: true
  attr :validate_event, :string, required: true
  attr :rule_type_options, :list, required: true
  attr :lock_type, :boolean, default: false

  defp rule_form(assigns) do
    form_id =
      if assigns.submit_event == "save_rule",
        do: "create-rule-form-tag",
        else: "revise-rule-form-tag"

    assigns = assign(assigns, :form_id, form_id)

    ~H"""
    <.form for={@form} id={@form_id} phx-change={@validate_event} phx-submit={@submit_event}>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <.input
          field={@form[:rule_type]}
          type="select"
          label="Rule type"
          options={@rule_type_options}
          prompt="Select rule type"
          disabled={@lock_type}
          required
        />
        <.input
          field={@form[:priority]}
          type="number"
          label="Priority"
          value={@form[:priority].value || "0"}
        />
      </div>

      <%!-- Scope fields --%>
      <div class="mt-4">
        <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider mb-2">
          Scope (optional)
        </p>
        <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
          <div>
            <label class="label text-xs">Asset</label>
            <input
              type="text"
              name={@form.name <> "[scope_asset]"}
              value={@form.params["scope_asset"] || ""}
              placeholder="e.g. USDC"
              class="input input-sm input-bordered w-full"
            />
          </div>
          <div>
            <label class="label text-xs">Chain</label>
            <input
              type="text"
              name={@form.name <> "[scope_chain]"}
              value={@form.params["scope_chain"] || ""}
              placeholder="e.g. base"
              class="input input-sm input-bordered w-full"
            />
          </div>
          <div>
            <label class="label text-xs">Counterparty ID</label>
            <input
              type="text"
              name={@form.name <> "[scope_counterparty_id]"}
              value={@form.params["scope_counterparty_id"] || ""}
              placeholder="UUID (optional)"
              class="input input-sm input-bordered w-full font-mono text-xs"
            />
          </div>
        </div>
      </div>

      <%!-- Rule-type-specific params --%>
      <.rule_params form={@form} rule_type={to_string(@form[:rule_type].value || "")} />
    </.form>
    """
  end

  # --- Component: rule-type-specific params ----------------------------------

  attr :form, :map, required: true
  attr :rule_type, :string, required: true

  defp rule_params(%{rule_type: "amount_limit"} = assigns) do
    ~H"""
    <div class="mt-4">
      <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider mb-2">Parameters</p>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div>
          <label class="label text-xs">Max per transaction</label>
          <input
            type="text"
            name={@form.name <> "[param_max_per_tx]"}
            value={@form.params["param_max_per_tx"] || ""}
            placeholder="e.g. 1000"
            class="input input-sm input-bordered w-full"
          />
        </div>
        <div>
          <label class="label text-xs">Currency</label>
          <input
            type="text"
            name={@form.name <> "[param_currency]"}
            value={@form.params["param_currency"] || ""}
            placeholder="e.g. USDC"
            class="input input-sm input-bordered w-full"
          />
        </div>
      </div>
    </div>
    """
  end

  defp rule_params(%{rule_type: "rolling_spend_cap"} = assigns) do
    ~H"""
    <div class="mt-4">
      <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider mb-2">Parameters</p>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div>
          <label class="label text-xs">Max total spend</label>
          <input
            type="text"
            name={@form.name <> "[param_max_total]"}
            value={@form.params["param_max_total"] || ""}
            placeholder="e.g. 5000"
            class="input input-sm input-bordered w-full"
          />
        </div>
        <div>
          <label class="label text-xs">Window (hours)</label>
          <input
            type="number"
            name={@form.name <> "[param_window_hours]"}
            value={@form.params["param_window_hours"] || ""}
            placeholder="e.g. 24"
            class="input input-sm input-bordered w-full"
          />
        </div>
      </div>
    </div>
    """
  end

  defp rule_params(%{rule_type: "allowed_asset"} = assigns) do
    ~H"""
    <div class="mt-4">
      <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider mb-2">Parameters</p>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div>
          <label class="label text-xs">Assets (comma-separated)</label>
          <input
            type="text"
            name={@form.name <> "[param_assets]"}
            value={@form.params["param_assets"] || ""}
            placeholder="e.g. USDC, WETH"
            class="input input-sm input-bordered w-full"
          />
        </div>
        <div>
          <label class="label text-xs">Mode</label>
          <select name={@form.name <> "[param_mode]"} class="select select-sm select-bordered w-full">
            <option
              value="allowlist"
              selected={(@form.params["param_mode"] || "allowlist") == "allowlist"}
            >
              Allowlist
            </option>
            <option value="denylist" selected={@form.params["param_mode"] == "denylist"}>
              Denylist
            </option>
          </select>
        </div>
      </div>
    </div>
    """
  end

  defp rule_params(%{rule_type: "allowed_chain"} = assigns) do
    ~H"""
    <div class="mt-4">
      <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider mb-2">Parameters</p>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div>
          <label class="label text-xs">Chains (comma-separated)</label>
          <input
            type="text"
            name={@form.name <> "[param_chains]"}
            value={@form.params["param_chains"] || ""}
            placeholder="e.g. base, ethereum"
            class="input input-sm input-bordered w-full"
          />
        </div>
        <div>
          <label class="label text-xs">Mode</label>
          <select name={@form.name <> "[param_mode]"} class="select select-sm select-bordered w-full">
            <option
              value="allowlist"
              selected={(@form.params["param_mode"] || "allowlist") == "allowlist"}
            >
              Allowlist
            </option>
            <option value="denylist" selected={@form.params["param_mode"] == "denylist"}>
              Denylist
            </option>
          </select>
        </div>
      </div>
    </div>
    """
  end

  defp rule_params(%{rule_type: "autonomy_tier"} = assigns) do
    ~H"""
    <div class="mt-4">
      <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider mb-2">Parameters</p>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div>
          <label class="label text-xs">Tier</label>
          <select name={@form.name <> "[param_tier]"} class="select select-sm select-bordered w-full">
            <option value="">Select tier</option>
            <option value="auto" selected={@form.params["param_tier"] == "auto"}>
              Auto — fully autonomous
            </option>
            <option value="manual" selected={@form.params["param_tier"] == "manual"}>
              Manual — requires approval
            </option>
            <option value="block" selected={@form.params["param_tier"] == "block"}>
              Block — always rejected
            </option>
          </select>
        </div>
      </div>
    </div>
    """
  end

  defp rule_params(%{rule_type: "time_window"} = assigns) do
    ~H"""
    <div class="mt-4">
      <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider mb-2">Parameters</p>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div>
          <label class="label text-xs">Timezone</label>
          <input
            type="text"
            name={@form.name <> "[param_timezone]"}
            value={@form.params["param_timezone"] || "UTC"}
            placeholder="e.g. UTC"
            class="input input-sm input-bordered w-full"
          />
        </div>
        <div>
          <label class="label text-xs">Days of week (1=Mon, 7=Sun, comma-separated)</label>
          <input
            type="text"
            name={@form.name <> "[param_days_of_week]"}
            value={@form.params["param_days_of_week"] || "1,2,3,4,5,6,7"}
            placeholder="e.g. 1,2,3,4,5"
            class="input input-sm input-bordered w-full"
          />
        </div>
        <div>
          <label class="label text-xs">Start time (HH:MM)</label>
          <input
            type="text"
            name={@form.name <> "[param_start_hhmm]"}
            value={@form.params["param_start_hhmm"] || "00:00"}
            placeholder="e.g. 09:00"
            class="input input-sm input-bordered w-full"
          />
        </div>
        <div>
          <label class="label text-xs">End time (HH:MM)</label>
          <input
            type="text"
            name={@form.name <> "[param_end_hhmm]"}
            value={@form.params["param_end_hhmm"] || "24:00"}
            placeholder="e.g. 17:00"
            class="input input-sm input-bordered w-full"
          />
        </div>
      </div>
    </div>
    """
  end

  defp rule_params(%{rule_type: "slippage_ceiling"} = assigns) do
    ~H"""
    <div class="mt-4">
      <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider mb-2">Parameters</p>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div>
          <label class="label text-xs">Max slippage (basis points)</label>
          <input
            type="number"
            name={@form.name <> "[param_max_bps]"}
            value={@form.params["param_max_bps"] || ""}
            placeholder="e.g. 50"
            class="input input-sm input-bordered w-full"
          />
        </div>
      </div>
    </div>
    """
  end

  defp rule_params(%{rule_type: "allowed_router"} = assigns) do
    ~H"""
    <div class="mt-4">
      <p class="text-xs font-medium text-base-content/50 uppercase tracking-wider mb-2">Parameters</p>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div>
          <label class="label text-xs">Routers (comma-separated)</label>
          <input
            type="text"
            name={@form.name <> "[param_routers]"}
            value={@form.params["param_routers"] || ""}
            placeholder="e.g. uniswap_v3, 1inch"
            class="input input-sm input-bordered w-full"
          />
        </div>
        <div>
          <label class="label text-xs">Mode</label>
          <select name={@form.name <> "[param_mode]"} class="select select-sm select-bordered w-full">
            <option
              value="allowlist"
              selected={(@form.params["param_mode"] || "allowlist") == "allowlist"}
            >
              Allowlist
            </option>
            <option value="denylist" selected={@form.params["param_mode"] == "denylist"}>
              Denylist
            </option>
          </select>
        </div>
      </div>
    </div>
    """
  end

  defp rule_params(assigns) do
    ~H"""
    <div :if={@rule_type != ""} class="mt-4">
      <p class="text-xs text-base-content/40">Select a rule type to configure parameters.</p>
    </div>
    """
  end

  # --- Component: rule card --------------------------------------------------

  attr :rule, :map, required: true
  attr :revising, :boolean, default: false

  defp rule_card(assigns) do
    ~H"""
    <div class={[
      "rounded-xl border bg-base-100 shadow-sm px-6 py-4",
      if(@revising, do: "rounded-b-none border-b-0 border-primary/30", else: "border-base-300")
    ]}>
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3 min-w-0">
          <div class={[
            "w-9 h-9 rounded-lg flex items-center justify-center shrink-0",
            rule_type_bg(@rule.rule_type)
          ]}>
            <.icon name={rule_type_icon(@rule.rule_type)} class="size-4" />
          </div>
          <div class="min-w-0">
            <p class="text-sm font-semibold">
              {rule_type_label(@rule.rule_type)}
              <span class="text-base-content/40 font-normal text-xs ml-1">v{@rule.version}</span>
            </p>
            <p class="text-xs text-base-content/50 truncate">
              {params_summary(@rule)}
            </p>
          </div>
        </div>
        <div class="flex items-center gap-2 shrink-0 ml-3">
          <.scope_badges scope={@rule.scope} />
          <.state_badge state={@rule.state} />
          <div :if={@rule.state == :active} class="flex items-center gap-1">
            <button
              phx-click="start_revise"
              phx-value-rule-id={@rule.id}
              class="btn btn-ghost btn-xs gap-1"
            >
              <.icon name="hero-pencil" class="size-3" /> Revise
            </button>
            <button
              phx-click="archive_rule"
              phx-value-rule-id={@rule.id}
              data-confirm="Archive this rule? It will no longer participate in evaluation."
              class="btn btn-ghost btn-xs text-error gap-1"
            >
              <.icon name="hero-archive-box" class="size-3" /> Archive
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Component: scope badges -----------------------------------------------

  attr :scope, :map, required: true

  defp scope_badges(assigns) do
    ~H"""
    <span :if={@scope == %{}} class="badge badge-xs badge-ghost">Global</span>
    <span :for={{k, v} <- @scope} class="badge badge-xs badge-outline font-mono">
      {k}: {v}
    </span>
    """
  end

  # --- Component: state badge ------------------------------------------------

  attr :state, :atom, required: true

  defp state_badge(assigns) do
    ~H"""
    <span class={["badge badge-sm font-medium", state_badge_class(@state)]}>
      {state_label(@state)}
    </span>
    """
  end

  # --- View helpers -----------------------------------------------------------

  defp rule_type_label(:amount_limit), do: "Amount limit"
  defp rule_type_label(:rolling_spend_cap), do: "Rolling spend cap"
  defp rule_type_label(:allowed_asset), do: "Allowed asset"
  defp rule_type_label(:allowed_chain), do: "Allowed chain"
  defp rule_type_label(:autonomy_tier), do: "Autonomy tier"
  defp rule_type_label(:time_window), do: "Time window"
  defp rule_type_label(:slippage_ceiling), do: "Slippage ceiling"
  defp rule_type_label(:allowed_router), do: "Allowed router"
  defp rule_type_label(_), do: "Unknown"

  defp rule_type_icon(:amount_limit), do: "hero-banknotes"
  defp rule_type_icon(:rolling_spend_cap), do: "hero-chart-bar"
  defp rule_type_icon(:allowed_asset), do: "hero-currency-dollar"
  defp rule_type_icon(:allowed_chain), do: "hero-link"
  defp rule_type_icon(:autonomy_tier), do: "hero-adjustments-horizontal"
  defp rule_type_icon(:time_window), do: "hero-clock"
  defp rule_type_icon(:slippage_ceiling), do: "hero-arrow-trending-down"
  defp rule_type_icon(:allowed_router), do: "hero-arrows-right-left"
  defp rule_type_icon(_), do: "hero-question-mark-circle"

  defp rule_type_bg(:amount_limit), do: "bg-info/15 text-info"
  defp rule_type_bg(:rolling_spend_cap), do: "bg-warning/15 text-warning"
  defp rule_type_bg(:autonomy_tier), do: "bg-error/15 text-error"
  defp rule_type_bg(:time_window), do: "bg-primary/15 text-primary"
  defp rule_type_bg(_), do: "bg-base-300/50 text-base-content/40"

  defp state_badge_class(:active), do: "badge-success"
  defp state_badge_class(:draft), do: "badge-ghost"
  defp state_badge_class(:superseded), do: "badge-warning"
  defp state_badge_class(:archived), do: "badge-neutral"
  defp state_badge_class(_), do: "badge-ghost"

  defp state_label(:active), do: "Active"
  defp state_label(:draft), do: "Draft"
  defp state_label(:superseded), do: "Superseded"
  defp state_label(:archived), do: "Archived"
  defp state_label(_), do: "–"

  defp params_summary(%{rule_type: :amount_limit, params: p}),
    do: "Max #{p["max_per_tx"] || "–"} #{p["currency"] || ""} per transaction"

  defp params_summary(%{rule_type: :rolling_spend_cap, params: p}),
    do: "Max #{p["max_total"] || "–"} in #{p["window_hours"] || "–"}h window"

  defp params_summary(%{rule_type: :allowed_asset, params: p}),
    do: "#{String.capitalize(p["mode"] || "allowlist")}: #{Enum.join(p["assets"] || [], ", ")}"

  defp params_summary(%{rule_type: :allowed_chain, params: p}),
    do: "#{String.capitalize(p["mode"] || "allowlist")}: #{Enum.join(p["chains"] || [], ", ")}"

  defp params_summary(%{rule_type: :autonomy_tier, params: p}),
    do: "Tier: #{p["tier"] || "–"}"

  defp params_summary(%{rule_type: :time_window, params: p}),
    do: "#{p["start_hhmm"] || "00:00"}–#{p["end_hhmm"] || "24:00"} #{p["timezone"] || "UTC"}"

  defp params_summary(%{rule_type: :slippage_ceiling, params: p}),
    do: "Max #{p["max_bps"] || "–"} bps"

  defp params_summary(%{rule_type: :allowed_router, params: p}),
    do: "#{String.capitalize(p["mode"] || "allowlist")}: #{Enum.join(p["routers"] || [], ", ")}"

  defp params_summary(_), do: "–"
end
