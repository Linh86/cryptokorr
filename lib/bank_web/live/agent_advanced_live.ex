defmodule BankWeb.AgentAdvancedLive do
  @moduledoc """
  Advanced screen — accordion of ops surfaces.

  The `policies` section is fully wired to the workspace's real
  `Bank.Policies.Versions` aggregate: it reads the published
  version (or the active ruleset fallback when none has ever been
  published), exposes a safe draft lifecycle
  (open / discard / publish) for admins, and surfaces the
  `Bank.Policies.PolicyDiff` "tightening vs expansion" analysis
  so an admin cannot silently grant the agent broader on-chain
  authority than the currently-installed permission covers.

  The remaining accordion sections are still static stubs and
  remain on the parallel work plan; they are unchanged here.
  """
  use BankWeb, :live_view

  import BankWeb.AgentComponents

  alias Bank.Policies
  alias Bank.Policies.{PolicyVersion, Versions}
  alias BankWeb.AgentAdvancedLive.PolicySection
  alias BankWeb.AgentLayouts
  alias BankWeb.AgentLive.GlobalState
  alias BankWeb.LiveAuth

  @sections [
    %{
      id: "policies",
      icon: "shield",
      title: "Policy rules",
      sub:
        "Per-counterparty, per-token, per-mode rules. Edits open a draft; runtime keeps using the active policy until you publish."
    },
    %{
      id: "counterparties",
      icon: "agent",
      title: "Counterparties",
      sub:
        "Allowlisted destinations the agent can interact with. Adding new ones requires a fresh permission."
    },
    %{
      id: "queue",
      icon: "queue",
      title: "Action queue",
      sub: "Intents waiting for approval, simulation, or settlement."
    },
    %{
      id: "audit",
      icon: "history",
      title: "Audit replay",
      sub: "Step-through of policy decisions for any past intent."
    },
    %{
      id: "health",
      icon: "health",
      title: "Adapter health",
      sub: "0x · Morpho · Pimlico bundler · Coinbase RPC."
    },
    %{
      id: "plans",
      icon: "doc",
      title: "Raw execution plans",
      sub: "JSON plan + simulation diff. Useful when wiring a new adapter."
    },
    %{
      id: "events",
      icon: "activity",
      title: "Debug events",
      sub: "Stream of internal events from the policy engine and bundler."
    },
    %{
      id: "inbox",
      icon: "mail",
      title: "Inbox",
      sub: "Cross-org notifications and approvals from collaborators."
    }
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: GlobalState.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Advanced")
     |> assign(:open_id, "policies")
     |> GlobalState.init()
     |> load_policy_state()}
  end

  @impl true
  def handle_event("section:toggle", %{"id" => id}, socket) do
    new_open = if socket.assigns.open_id == id, do: nil, else: id
    {:noreply, assign(socket, :open_id, new_open)}
  end

  # Topbar Stop button + revoke modal — same flow as AgentLive.
  def handle_event("topbar:stop_agent", _, socket),
    do: {:noreply, assign(socket, :stop_open, true)}

  def handle_event("confirm_stop:cancel", _, socket),
    do: {:noreply, assign(socket, :stop_open, false)}

  def handle_event("confirm_stop:revoke", _, socket),
    do: {:noreply, GlobalState.revoke(socket)}

  def handle_event("topbar:" <> _, _, socket), do: {:noreply, socket}

  # --- policy draft lifecycle -----------------------------------------

  def handle_event("policy:open_draft", _, socket) do
    with_admin(socket, fn socket ->
      ws_id = workspace_id!(socket)
      actor_id = socket.assigns.current_scope.user.id

      case Versions.create_draft(ws_id, created_by: :user, actor_id: actor_id) do
        {:ok, _draft} ->
          {:noreply,
           socket
           |> put_flash(:info, "Draft opened. Edit rules in the policy builder.")
           |> load_policy_state()}

        {:error, %Ecto.Changeset{} = cs} ->
          {:noreply, put_flash(socket, :error, "Could not open draft: #{changeset_summary(cs)}.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not open draft: #{inspect(reason)}.")}
      end
    end)
  end

  def handle_event("policy:discard_draft", _, socket) do
    with_admin(socket, fn socket ->
      case socket.assigns.policy_draft_version do
        nil ->
          {:noreply, put_flash(socket, :error, "No draft is open.")}

        draft ->
          actor_id = socket.assigns.current_scope.user.id

          case Versions.discard_draft(draft, actor: :user, actor_id: actor_id) do
            {:ok, _deleted} ->
              {:noreply,
               socket
               |> put_flash(:info, "Draft discarded.")
               |> load_policy_state()}

            {:error, :not_a_draft} ->
              {:noreply,
               put_flash(socket, :error, "The draft is no longer editable; reload the page.")}

            {:error, reason} ->
              {:noreply,
               put_flash(socket, :error, "Could not discard draft: #{inspect(reason)}.")}
          end
      end
    end)
  end

  def handle_event("policy:publish_draft", _, socket) do
    with_admin(socket, fn socket ->
      case socket.assigns.policy_draft_version do
        nil ->
          {:noreply, put_flash(socket, :error, "No draft is open.")}

        draft ->
          actor_id = socket.assigns.current_scope.user.id

          case Versions.publish_draft(draft, published_by: :user, actor_id: actor_id) do
            {:ok, _published} ->
              flash =
                cond do
                  socket.assigns.policy_diff &&
                      socket.assigns.policy_diff.requires_permission_reinstall? ->
                    "Draft published. Permission install is now outdated — reinstall the permission so the agent's on-chain authority matches the new policy."

                  true ->
                    "Draft published."
                end

              {:noreply,
               socket
               |> put_flash(:info, flash)
               |> load_policy_state()}

            {:error, :not_a_draft} ->
              {:noreply,
               put_flash(socket, :error, "Draft is no longer publishable; reload the page.")}

            {:error, %Ecto.Changeset{} = cs} ->
              {:noreply,
               put_flash(socket, :error, "Could not publish draft: #{changeset_summary(cs)}.")}

            {:error, reason} ->
              {:noreply,
               put_flash(socket, :error, "Could not publish draft: #{inspect(reason)}.")}
          end
      end
    end)
  end

  @impl true
  def handle_info(%{topic: :security_events} = _msg, socket),
    do: {:noreply, socket |> GlobalState.refresh() |> load_policy_state()}

  def handle_info({event, %{smart_account_id: sa_id}}, socket)
      when event in [:revoke_requested, :revoked, :revoke_failed] do
    case socket.assigns[:delegation] do
      %{smart_account_id: ^sa_id} ->
        {:noreply, socket |> GlobalState.refresh() |> load_policy_state()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :sections, @sections)

    ~H"""
    <AgentLayouts.app
      flash={@flash}
      wallet={@wallet}
      permission={@permission}
      address={@address}
      active={:advanced}
      delegation={@delegation}
    >
      <header class="ac__hero">
        <div>
          <div class="ucase" style="color: var(--ink-3);">Advanced</div>
          <h1 class="ac__title serif">For when you need the cockpit</h1>
          <p class="ac__lede">
            Everything ops-heavy lives here so the main screen stays focused.
            Most users won't open this.
          </p>
        </div>
      </header>

      <.policy_top_banner
        permission_outdated?={@permission_outdated?}
        version_source={@policy_version_source}
      />

      <div class="adv-list">
        <article :for={s <- @sections} class={["adv", @open_id == s.id && "is-open"]}>
          <button type="button" class="adv__head" phx-click="section:toggle" phx-value-id={s.id}>
            <span class="adv__icon"><.cb_icon name={s.icon} size={16} /></span>
            <span class="adv__main">
              <span class="adv__title serif">{s.title}</span>
              <span class="adv__sub">{s.sub}</span>
            </span>
            <span class="adv__chev">
              <.cb_icon
                name={if(@open_id == s.id, do: "chevron-down", else: "chevron-right")}
                size={14}
              />
            </span>
          </button>
          <div :if={@open_id == s.id} class="adv__body">
            <.section_body
              id={s.id}
              published_version={@policy_published_version}
              published_rules={@policy_published_rules}
              version_source={@policy_version_source}
              draft_version={@policy_draft_version}
              draft_rules={@policy_draft_rules}
              diff={@policy_diff}
              can_edit?={@policy_can_edit?}
              permission_outdated?={@permission_outdated?}
            />
          </div>
        </article>
      </div>

      <AgentLayouts.confirm_stop_modal open={@stop_open} />
    </AgentLayouts.app>
    """
  end

  # The top-of-page banner: surfaces "safe defaults" when no policy
  # version has ever been published, OR the "permission is outdated"
  # banner when an expansion publish has landed since the agent's
  # delegation was granted. The two banners are mutually exclusive
  # (safe-defaults implies no published policy, which implies nothing
  # to be outdated against).
  attr :permission_outdated?, :boolean, required: true
  attr :version_source, :atom, required: true

  defp policy_top_banner(assigns) do
    ~H"""
    <%= cond do %>
      <% @permission_outdated? -> %>
        <div id="adv-top-permission-outdated">
          <.banner kind="warn">
            Policy was changed and now <strong>expands</strong>
            the agent's authority. The installed permission no longer
            covers the new scope — reinstall the permission before the
            agent dispatches new intents.
          </.banner>
        </div>
      <% @version_source in [:none, :active_ruleset] -> %>
        <.banner kind="info">
          You're in <strong>safe defaults</strong>.
          Publishing a draft below opens a draft against the
          workspace's policy; runtime keeps using the active ruleset
          until you publish.
        </.banner>
      <% true -> %>
        <.banner kind="info">
          The runtime is using the workspace's <strong>published policy version</strong>.
          Edits open a draft and never mutate the active rules directly.
        </.banner>
    <% end %>
    """
  end

  # ── Section bodies ────────────────────────────────────────────────

  attr :id, :string, required: true
  attr :published_version, :any, required: true
  attr :published_rules, :list, required: true
  attr :version_source, :atom, required: true
  attr :draft_version, :any, required: true
  attr :draft_rules, :list, required: true
  attr :diff, :any, required: true
  attr :can_edit?, :boolean, required: true
  attr :permission_outdated?, :boolean, required: true

  defp section_body(%{id: "policies"} = assigns) do
    ~H"""
    <PolicySection.render
      published_version={@published_version}
      published_rules={@published_rules}
      version_source={@version_source}
      draft_version={@draft_version}
      draft_rules={@draft_rules}
      diff={@diff}
      can_edit?={@can_edit?}
      permission_outdated?={@permission_outdated?}
    />
    """
  end

  defp section_body(%{id: "counterparties"} = assigns) do
    ~H"""
    <table class="adv-table">
      <thead>
        <tr>
          <th>Counterparty</th>
          <th>Role</th>
          <th>Status</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td class="mono">0x Aggregator</td>
          <td class="ink-2">Routing</td>
          <td><span class="tag tag--ok">allow</span></td>
        </tr>
        <tr>
          <td class="mono">Morpho · Re7 USDC</td>
          <td class="ink-2">Vault</td>
          <td><span class="tag tag--ok">allow</span></td>
        </tr>
        <tr>
          <td class="mono">Morpho · Gauntlet Prime</td>
          <td class="ink-2">Vault</td>
          <td><span class="tag tag--ok">allow</span></td>
        </tr>
        <tr>
          <td class="mono">Morpho · Moonwell Flagship</td>
          <td class="ink-2">Vault</td>
          <td><span class="tag tag--ok">allow</span></td>
        </tr>
        <tr>
          <td class="mono">Coinbase RPC</td>
          <td class="ink-2">Read</td>
          <td><span class="tag tag--ok">allow</span></td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp section_body(%{id: "queue"} = assigns) do
    ~H"""
    <table class="adv-table">
      <thead>
        <tr>
          <th>Intent</th>
          <th>State</th>
          <th>Age</th>
        </tr>
      </thead>
      <tbody>
        <tr>
          <td>Swap 60 USDC → USDbC</td>
          <td><.status_pill kind="needs-approval" size="sm" /></td>
          <td class="mono">2 min</td>
        </tr>
        <tr>
          <td colspan="3" class="adv-empty">— Queue is otherwise clear —</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp section_body(%{id: "audit"} = assigns) do
    ~H"""
    <div class="audit">
      <div class="audit__step">
        <span class="mono">01</span> intent received · swap 10 USDC → USDbC
      </div>
      <div class="audit__step"><span class="mono">02</span> policy: scope check · pass</div>
      <div class="audit__step">
        <span class="mono">03</span> simulation: 0x quote 0.4% slippage · pass
      </div>
      <div class="audit__step audit__step--ok">
        <span class="mono">04</span> bundler accepted · settled in 2.1s
      </div>
    </div>
    """
  end

  defp section_body(%{id: "health"} = assigns) do
    rows = [
      {"0x Aggregator", "executed", "ok", "142 ms"},
      {"Morpho", "executed", "ok", "210 ms"},
      {"Pimlico bundler", "executed", "ok", "88 ms"},
      {"Coinbase RPC", "needs-approval", "degraded", "640 ms"}
    ]

    assigns = assign(assigns, :rows, rows)

    ~H"""
    <ul class="adapters">
      <li :for={{name, kind, label, latency} <- @rows} class="adapters__row">
        <span>{name}</span>
        <.status_pill kind={kind} label={label} size="sm" />
        <span class="mono ink-2">{latency}</span>
      </li>
    </ul>
    """
  end

  defp section_body(%{id: "plans"} = assigns) do
    ~H"""
    <pre class="plan">{plan_json()}</pre>
    """
  end

  defp section_body(%{id: "events"} = assigns) do
    events = [
      "policy.scope.match · swap",
      "0x.quote.received · 9.961 USDbC",
      "bundler.userop.signed",
      "bundler.userop.included · block 11_209_482"
    ]

    assigns = assign(assigns, :events, events)

    ~H"""
    <ul class="eventlog">
      <li :for={e <- @events} class="mono">{e}</li>
    </ul>
    """
  end

  defp section_body(%{id: "inbox"} = assigns) do
    ~H"""
    <div class="adv-empty" style="padding: 24px 0;">
      No messages. Multi-user mode is off in private alpha.
    </div>
    """
  end

  defp section_body(assigns) do
    ~H"""
    <div class="adv-empty">—</div>
    """
  end

  defp plan_json do
    """
    {
      "intent": "swap",
      "from": "USDC",
      "to":   "USDbC",
      "amount": "10000000",
      "route": ["0x:v1.aggregator"],
      "slippageBps": 40,
      "gasEstimate": "0.000412 ETH"
    }
    """
  end

  # ── policy state loader ───────────────────────────────────────────

  # Resolves the workspace's currently-active rule set (published
  # version when one exists, workspace-scoped active ruleset
  # otherwise), the open draft + its rules, the diff against
  # published, the admin gate, and the permission-outdated flag.
  defp load_policy_state(socket) do
    ws_id = workspace_id(socket)
    can_edit? = admin?(socket.assigns[:current_scope])

    {published_version, published_rules, version_source} = load_published(ws_id)
    {draft_version, draft_rules} = load_draft(ws_id)
    diff = compute_diff(draft_version)

    outdated? = permission_outdated?(ws_id)

    socket
    |> assign(:policy_published_version, published_version)
    |> assign(:policy_published_rules, published_rules)
    |> assign(:policy_version_source, version_source)
    |> assign(:policy_draft_version, draft_version)
    |> assign(:policy_draft_rules, draft_rules)
    |> assign(:policy_diff, diff)
    |> assign(:policy_can_edit?, can_edit?)
    |> assign(:permission_outdated?, outdated?)
  end

  defp load_published(nil), do: {nil, [], :none}

  defp load_published(ws_id) when is_binary(ws_id) do
    case Versions.snapshot_for_workspace(ws_id) do
      %{rules: rules, version_id: _} = snap ->
        version = Versions.current_published(ws_id)
        source = if version, do: :published, else: :active_ruleset
        # `snap.rules` is already workspace-scoped + active-only.
        # We re-fetch the version row to pick up `published_at` etc.
        # for the UI banner.
        _ = snap
        {version, rules, source}

      nil ->
        # No published policy version. Fall back to the workspace's
        # active ruleset so the operator sees what the decision
        # pipeline would actually use (`Bank.Decisions.evaluate_policy`
        # falls back to `Policies.load_active_ruleset(workspace_id:)`
        # in this case).
        rules = Policies.load_active_ruleset(workspace_id: ws_id)
        source = if rules == [], do: :none, else: :active_ruleset
        {nil, rules, source}
    end
  end

  defp load_draft(nil), do: {nil, []}

  defp load_draft(ws_id) when is_binary(ws_id) do
    case Versions.list_versions(ws_id, status: :draft, limit: 1) do
      [] ->
        {nil, []}

      [%PolicyVersion{} = draft] ->
        rules =
          draft
          |> PolicyVersion.rule_ids_list()
          |> resolve_draft_rules(ws_id)

        {draft, rules}
    end
  end

  # Workspace-scoped fetch for the draft view: shows both `:active`
  # rules (cloned from the current published version when the draft
  # was opened) and `:draft` rules (added/revised inside this draft).
  # Mirrors `BankWeb.PolicyBuilderLive.resolve_rules_in_workspace/2`
  # but keeps this LiveView self-contained.
  defp resolve_draft_rules([] = _ids, _ws_id), do: []

  defp resolve_draft_rules(ids, ws_id) when is_list(ids) and is_binary(ws_id) do
    import Ecto.Query

    Bank.Policies.PolicyRule
    |> where(
      [r],
      r.id in ^ids and r.state in ^[:active, :draft] and r.workspace_id == ^ws_id
    )
    |> Bank.Repo.all()
  end

  defp compute_diff(nil), do: nil
  defp compute_diff(%PolicyVersion{} = draft), do: Versions.diff_against_published(draft)

  # Reads the same workspace-level resolver the runtime uses
  # (`Bank.Policies.workspace_permission_gate/1`). Covers both:
  #
  #   * `{:outdated, _}` — expansion publish landed after the
  #     active delegation's `granted_at`, and
  #   * `:legacy_nil_grant` — `:active` row with `granted_at = nil`
  #     in a workspace that has ever published a policy version
  #     (runtime fails closed; UI MUST mirror that).
  #
  # Without consulting the shared helper, the Advanced banner
  # could disagree with the runtime (e.g. legacy nil grant: old
  # code returned false here, but runtime returns
  # `:legacy_nil_grant` and produces a `:block` decision).
  defp permission_outdated?(ws_id) when is_binary(ws_id),
    do: Bank.Policies.permission_outdated?(ws_id)

  defp permission_outdated?(_), do: false

  # ── helpers ──────────────────────────────────────────────────────

  defp workspace_id(socket) do
    case socket.assigns[:current_scope] do
      %{workspace: %{id: id}} -> id
      _ -> nil
    end
  end

  defp workspace_id!(socket) do
    workspace_id(socket) || raise "AgentAdvancedLive event without a current_scope.workspace"
  end

  defp admin?(%{role: role}) when role in [:admin, :owner], do: true
  defp admin?(_), do: false

  defp with_admin(socket, fun) do
    case LiveAuth.authorize_action(socket, :admin) do
      :ok ->
        fun.(socket)

      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to change policy.")}
    end
  end

  defp changeset_summary(%Ecto.Changeset{errors: errors}) do
    errors
    |> Enum.map(fn {field, {msg, _}} -> "#{field} #{msg}" end)
    |> Enum.join("; ")
  end
end
