defmodule BankWeb.SecurityLive do
  @moduledoc """
  Security console — runtime safety posture and emergency controls.

  This is the operator's "is the runtime safe right now?" page. It
  consolidates the three safety levers in one place:

    * **Runtime pause / resume** — halts new `executing` transitions.
    * **Workspace agent-key pause / resume** — refuses every `/v1`
      API request from the workspace's keys (#231-a).
    * **Delegation status + risk summary** — per-state counts and
      revoke action for every active delegation in the workspace.
    * **Recent safety events** — pause/resume/revoke + workspace
      agent-key pause audit slice (#231-e), with operator
      filter form for event type / actor / time range (#212).

  ## Design decisions

  **One page, all controls.** The `Connection` page exposes the same
  pause/revoke for the primary delegation as a side-panel. This page
  is the canonical surface — it shows every active delegation (not
  just the primary), every safety-relevant event in one panel, and is
  reachable from the sidebar without navigating into Connection first.

  **Failure-safe posture.** All confirmations are inline `data-confirm`
  prompts, not separate flows. The runtime never auto-unpauses. A
  revoke is treated as authoritative the moment the API call accepts
  it — the UI shows `:revoking` immediately so an operator can't
  double-tap and create two revoke jobs.

  **Real-time.** Subscribes to `security:events` and `audit:stream` so
  pause/resume/revoke changes from any source (this UI, the API,
  another operator) are reflected immediately.
  """

  use BankWeb, :live_view

  alias Bank.Accounts
  alias Bank.APIKeys
  alias Bank.Audit
  alias Bank.Delegations
  alias Bank.Security
  alias Bank.Workspaces
  alias Bank.Workspaces.Workspace

  # Audit event types that belong on the safety timeline.
  #
  # `agent_keys.paused` / `agent_keys.resumed` events (#231-a)
  # carry `subject_id = workspace.id`, so `visible_to_workspace?/3`
  # gates them on workspace identity rather than the
  # delegation-id allowlist used for `delegation.*`.
  @safety_event_types [
    "security.paused",
    "security.resumed",
    # DB-backed scoped pauses (#228 Phase 1: chain). These rows
    # stamp `workspace_id` on the audit envelope directly, so the
    # `visible_to_workspace?/3` clause matches on
    # `event.workspace_id` rather than the existing blanket
    # `"security." <> _` rule (which is correct for the
    # runtime-global `security.paused`/`security.resumed` events
    # but would leak workspace-scoped scope events).
    "security.scope_paused",
    "security.scope_resumed",
    "delegation.revoke_requested",
    "delegation.revoked",
    "delegation.state_changed",
    "agent_keys.paused",
    "agent_keys.resumed",
    # Periodic stuck-plan detector (#230-b). The audit row stamps
    # `workspace_id` on the row directly, so the workspace gate in
    # `visible_to_workspace?/3` for this event matches on
    # `event.workspace_id` rather than `subject_id` like
    # `agent_keys.*`.
    "ops.stuck_plan_detected"
  ]

  # Default safety-timeline filter (#212). `range: "7d"` matches the
  # operator's "what happened this week?" reflex; "all" is reachable
  # via the dropdown but stays capped at 15 rows so a long history
  # doesn't drown the card.
  @default_safety_filters %{event_type: "all", actor: "all", range: "7d"}

  @safety_actor_options [
    {"All actors", "all"},
    {"user", "user"},
    {"agent", "agent"},
    {"runtime", "runtime"},
    {"adapter", "adapter"}
  ]

  @safety_range_options [
    {"Last 24 hours", "24h"},
    {"Last 7 days", "7d"},
    {"Last 30 days", "30d"},
    {"All time", "all"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.security_events())
      Bank.Runtime.PubSub.subscribe(Bank.Runtime.PubSub.audit_stream())
    end

    socket =
      socket
      |> assign(page_title: "Security")
      |> assign(:safety_filters, @default_safety_filters)
      |> load_state()

    {:ok, socket}
  end

  # --- Events ---------------------------------------------------------------

  @impl true
  def handle_event("pause_runtime", _params, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      case Security.pause(:global, reason: :operator_requested, actor: :user) do
        {:ok, _} ->
          {:noreply, socket |> load_state() |> put_flash(:info, "Runtime paused")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Pause failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to pause the runtime.")}
    end
  end

  def handle_event("resume_runtime", _params, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      case Security.resume(:global, actor: :user) do
        {:ok, _} ->
          {:noreply, socket |> load_state() |> put_flash(:info, "Runtime resumed")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Resume failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to resume the runtime.")}
    end
  end

  def handle_event("revoke_delegation", %{"smart-account-id" => sa_id}, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      case Security.revoke_delegation(sa_id, reason: :operator_requested, actor: :user) do
        {:ok, _job} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(:info, "Delegation revoke submitted. Awaiting on-chain confirmation.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Revoke failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to revoke a delegation.")}
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> load_state() |> put_flash(:info, "Console refreshed")}
  end

  # --- Manual abort of a stuck :prepared plan (#229/#230 UI) ---------------

  def handle_event("abort_plan", %{"plan-id" => plan_id}, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      # Workspace from current_scope (NEVER from form params): a hostile
      # event payload cannot redirect the abort at a sibling tenant's
      # plan. The context function ALSO scopes by workspace inside the
      # locked SELECT, so this is belt-and-suspenders.
      scope = socket.assigns.current_scope
      actor_id = scope.user && scope.user.id

      case Bank.Decisions.abort_plan(plan_id, scope.workspace,
             reason: :operator_requested,
             actor: :user,
             actor_id: actor_id
           ) do
        {:ok, :aborted, _plan, _intent_transition} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(:info, "Execution plan aborted.")}

        {:ok, :already_terminal, _plan, _intent_transition} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(:info, "Plan was already terminal; no change.")}

        {:error, :not_found} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(:error, "Plan not found in this workspace.")}

        {:error, {:not_safe_to_abort, status}} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(
             :error,
             "Cannot abort plan in #{status} from this console — adapter cancel required."
           )}

        {:error, %Ecto.Changeset{} = changeset} ->
          message = changeset_message(changeset, "Abort failed")
          {:noreply, put_flash(socket, :error, message)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Abort failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to abort an execution plan.")}
    end
  end

  # --- Agent-key pause / resume (#231-c) -----------------------------------

  def handle_event("pause_agent_keys", params, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      reason = clean_reason(Map.get(params, "reason"))
      actor = socket.assigns.current_scope.user
      # Workspace from current_scope (NEVER from form params) so a
      # hostile request cannot pause a workspace the operator is
      # not a member of.
      workspace = socket.assigns.current_scope.workspace

      case APIKeys.pause_workspace(workspace, actor, reason: reason) do
        {:ok, :paused, _} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(
             :info,
             "Agent keys paused. All /v1 traffic for this workspace is refused."
           )}

        {:ok, :already_paused, _} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(:info, "Agent keys are already paused.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          message = changeset_message(changeset, "Pause failed")
          {:noreply, put_flash(socket, :error, message)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Pause failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to pause agent keys.")}
    end
  end

  def handle_event("resume_agent_keys", _params, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      actor = socket.assigns.current_scope.user
      workspace = socket.assigns.current_scope.workspace

      case APIKeys.resume_workspace(workspace, actor) do
        {:ok, :resumed, _} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(:info, "Agent keys resumed. /v1 traffic for this workspace is restored.")}

        {:ok, :already_unpaused, _} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(:info, "Agent keys were not paused.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Resume failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to resume agent keys.")}
    end
  end

  # --- Chain pause / resume (#228 Phase 1) ---------------------------------
  #
  # Always uses the Phase-1 chain value `"base"` server-side; client
  # params are NOT trusted to choose a chain. Workspace is sourced
  # from `current_scope.workspace.id`, never from form input.
  # Authorization re-checks `:admin` so a hostile event from a
  # non-admin connection is refused with a flash even if the form
  # was hidden in their UI.

  @phase1_chain "base"

  def handle_event("pause_chain", params, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      reason = clean_reason(Map.get(params, "reason"))
      actor = socket.assigns.current_scope.user
      workspace_id = socket.assigns.current_scope.workspace.id

      case Security.pause(workspace_id, {:chain, @phase1_chain},
             actor: actor,
             reason: reason
           ) do
        {:ok, :paused, _pause} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(:info, "Base chain paused for this workspace.")}

        {:ok, :already_paused, _pause} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(:info, "Base chain is already paused.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          message = changeset_message(changeset, "Pause failed")
          {:noreply, put_flash(socket, :error, message)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Pause failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to pause a chain.")}
    end
  end

  def handle_event("resume_chain", _params, socket) do
    with :ok <- BankWeb.LiveAuth.authorize_action(socket, :admin) do
      actor = socket.assigns.current_scope.user
      workspace_id = socket.assigns.current_scope.workspace.id

      case Security.resume(workspace_id, {:chain, @phase1_chain}, actor: actor) do
        {:ok, :resumed, _pause} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(:info, "Base chain resumed for this workspace.")}

        {:ok, :already_running} ->
          {:noreply,
           socket
           |> load_state()
           |> put_flash(:info, "Base chain was not paused.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Resume failed: #{inspect(reason)}")}
      end
    else
      {:error, {:insufficient_role, _}} ->
        {:noreply, put_flash(socket, :error, "Admin role required to resume a chain.")}
    end
  end

  # --- Safety timeline filters (#212) --------------------------------------

  def handle_event("filter_safety_events", %{"filter" => params}, socket) do
    filters = merge_safety_filters(socket.assigns.safety_filters, params)
    {:noreply, socket |> assign(:safety_filters, filters) |> load_state()}
  end

  def handle_event("clear_safety_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:safety_filters, @default_safety_filters)
     |> load_state()}
  end

  defp merge_safety_filters(current, params) do
    %{
      event_type: filter_value(params, "event_type", current.event_type),
      actor: filter_value(params, "actor", current.actor),
      range: filter_value(params, "range", current.range)
    }
  end

  defp filter_value(params, key, fallback) do
    case Map.get(params, key) do
      v when is_binary(v) and v != "" -> v
      _ -> fallback
    end
  end

  defp clean_reason(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp clean_reason(_), do: nil

  defp changeset_message(changeset, fallback) do
    case changeset.errors do
      [{:agent_keys_paused_reason, {msg, _}} | _] ->
        "#{fallback}: reason #{msg}"

      [{field, {msg, _}} | _] ->
        "#{fallback}: #{field} #{msg}"

      [] ->
        fallback
    end
  end

  # --- PubSub handlers ------------------------------------------------------

  @impl true
  def handle_info(%{topic: topic}, socket) when topic in [:security_events, :audit_stream] do
    {:noreply, load_state(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- State loading --------------------------------------------------------

  defp load_state(socket) do
    workspace_id = socket.assigns.current_scope.workspace.id

    # Re-fetch the workspace from DB so the agent-keys pause panel
    # always reflects the latest state. `current_scope.workspace` is
    # mount-frozen and won't reflect a fresh pause/resume.
    workspace = Workspaces.get_workspace(workspace_id) || socket.assigns.current_scope.workspace
    paused_by = paused_by_user(workspace)

    delegations = Delegations.list_active(workspace_id: workspace_id)

    paused? = Security.paused?(:global)
    pause_snapshot = Security.snapshot()

    executable_count =
      Enum.count(delegations, fn
        %{state: :active, smart_account_id: sa_id} -> Delegations.executable?(sa_id)
        _ -> false
      end)

    execution_ready? = not paused? and executable_count > 0

    risk_summary = Enum.frequencies_by(delegations, & &1.state)

    # Stuck-plan detector rows (#229/#230). The `:workspace_id`
    # option pushes the workspace filter down into the per-status
    # DB query BEFORE `order_by` / `limit`, so sibling-tenant rows
    # cannot starve the current workspace's slot in the limit
    # budget. Post-fetch filtering would have hidden a
    # current-workspace row whenever 10+ older sibling rows were
    # in flight (Finding A on #305 review).
    stuck_plans =
      Bank.Ops.Health.stuck_plan_details(limit: 10, workspace_id: workspace_id)

    # Full set of non-terminal execution plans for the current
    # workspace (#229 incident-center surface). Stuck plans are a
    # threshold-filtered subset of this list; the in-flight card
    # gives operators the rest of the active pipeline so they can
    # see what is actually executing right now (`:prepared`,
    # `:signing`, `:broadcasting`, `:pending_confirmation`).
    # `Bank.Decisions.list_active_executions/1` already pushes
    # `:workspace_id` into the DB query (no in-memory post-filter).
    in_flight_plans =
      Bank.Decisions.list_active_executions(workspace_id: workspace_id)

    # Pending approvals for the current workspace (#229 incident-
    # center surface). Read-only mirror of the
    # `/queue#pending-approvals-section` data — operators triaging
    # an incident on `/security` see approval pressure without
    # leaving the page. Mutating approve/reject still happens on
    # `/queue` so the safety console stays read-side.
    # `Bank.Decisions.list_pending_approvals/1` already pushes
    # `:workspace_id` into the DB query (no in-memory post-filter).
    pending_approvals =
      Bank.Decisions.list_pending_approvals(workspace_id: workspace_id)

    # Active DB-backed pauses for the current workspace
    # (#228 Phase 1 — chain scope only). Read-only mirror of
    # `Bank.Security.Pauses.list_active/1`, which already refuses
    # to surface sibling-workspace rows even when given `nil`.
    # Mutating pause/resume controls wait for #332 — this slice is
    # surface-only so an operator can see "what is currently
    # paused" alongside the rest of the safety posture.
    chain_pauses = Bank.Security.Pauses.list_active(workspace_id)

    # Phase 1 base-chain pause indicator. Derived from the
    # already-loaded `chain_pauses` list rather than calling
    # `Security.paused?(ws_id, {:chain, "base"})` so we don't add
    # a second DB hit and so the indicator never disagrees with
    # the row that's about to render in the card. Only counts a
    # row whose scope_value is exactly "base"; rows for future
    # chains are ignored by the Phase-1 pause/resume controls.
    base_paused? =
      Enum.any?(chain_pauses, fn p ->
        p.scope_type == :chain and p.scope_value == "base"
      end)

    filters = socket.assigns[:safety_filters] || @default_safety_filters
    safety_events = load_safety_events(delegations, workspace_id, filters)

    # Phoenix forms require string-keyed params; the filter map is
    # atom-keyed in our state for clarity. Convert at the boundary.
    safety_filter_form =
      filters
      |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
      |> to_form(as: :filter)

    socket
    |> assign(:paused, paused?)
    |> assign(:pause_snapshot, pause_snapshot)
    |> assign(:agent_keys_workspace, workspace)
    |> assign(:agent_keys_paused, Workspace.agent_keys_paused?(workspace))
    |> assign(:agent_keys_paused_by, paused_by)
    |> assign(:delegations, delegations)
    |> assign(:executable_count, executable_count)
    |> assign(:execution_ready, execution_ready?)
    |> assign(:risk_summary, risk_summary)
    |> assign(:stuck_plans, stuck_plans)
    |> assign(:in_flight_plans, in_flight_plans)
    |> assign(:in_flight_plan_count, length(in_flight_plans))
    |> assign(:pending_approvals, pending_approvals)
    |> assign(:pending_approval_count, length(pending_approvals))
    |> assign(:chain_pauses, chain_pauses)
    |> assign(:base_paused, base_paused?)
    |> assign(:safety_events, safety_events)
    |> assign(:safety_filters, filters)
    |> assign(:safety_filter_form, safety_filter_form)
  end

  defp paused_by_user(%Workspace{agent_keys_paused_by_user_id: nil}), do: nil

  defp paused_by_user(%Workspace{agent_keys_paused_by_user_id: id}) when is_binary(id),
    do: Accounts.get_user(id)

  # Pulls the most recent safety events. We pass each safety event_type
  # individually because `Bank.Audit.list_events/2` does exact match;
  # then we union and sort. Capped small — this is a "is the runtime
  # safe right now?" view, not a forensic timeline.
  #
  # ## Filter pushdown vs in-memory (#212 P2 fix)
  #
  # `actor` and `range` are pushed down into the DB query via
  # `Audit.list_events/2`'s native `:actor` and `:from` filters so a
  # user with thousands of recent events of one type cannot starve
  # the in-memory match for a less-common actor / older row. The
  # earlier implementation fetched the latest 10 unfiltered rows per
  # type and then in-memory filtered, which silently hid every
  # actor-or-range match that fell outside the head of the table.
  #
  # ## Workspace-scoping rule (#158c, refined by #158d-b)
  #
  #   * `security.paused` / `security.resumed` stay runtime-global
  #     (correlation_id is `nil` per `Bank.Audit` docs). Every
  #     workspace's operators need visibility into a global pause.
  #   * `delegation.*` events from #158d-b onward carry `workspace_id`
  #     via the audit envelope passthrough, but events written
  #     before #158d-b have `workspace_id IS NULL`. A query-layer
  #     `WHERE workspace_id = ?` would silently drop the legacy
  #     tail. We keep the post-query filter against the workspace's
  #     own delegation ids — it is robust to both stamped and
  #     legacy events. Once a backfill closes the legacy tail (a
  #     future PR), the query can switch to `WHERE workspace_id`
  #     directly.
  #   * `agent_keys.*` carry `subject_id = workspace.id` (#231-a) and
  #     are filtered by that subject post-query.
  #
  # Because the workspace boundary stays in-memory for legacy-NULL
  # safety, we cursor through pages until we have collected up to 15
  # workspace-visible rows per type or hit the safety cap.
  @timeline_target_per_type 15
  @timeline_max_pages 5
  @timeline_page_size 50

  defp load_safety_events(workspace_delegations, workspace_id, filters) do
    delegation_ids =
      workspace_delegations
      |> Enum.map(& &1.id)
      |> MapSet.new()

    types_to_fetch = restrict_event_types(filters.event_type)
    cutoff = range_cutoff(filters.range)
    actor_atom = parse_actor_filter(filters.actor)

    types_to_fetch
    |> Enum.flat_map(fn type ->
      fetch_visible_for_type(type, actor_atom, cutoff, delegation_ids, workspace_id)
    end)
    |> Enum.sort_by(& &1.ts, {:desc, DateTime})
    |> Enum.take(@timeline_target_per_type)
  end

  defp fetch_visible_for_type(type, actor, cutoff, delegation_ids, workspace_id) do
    base_filters = build_query_filters(type, actor, cutoff)

    collect_pages(
      base_filters,
      delegation_ids,
      workspace_id,
      @timeline_target_per_type,
      _cursor = nil,
      _pages = 0,
      _acc = []
    )
  end

  # Recursively pages through `Audit.list_events/2` until either:
  #   * `target` workspace-visible rows have been collected,
  #   * no `next_cursor` remains (full table scanned within filters),
  #   * `@timeline_max_pages` safety cap is hit.
  defp collect_pages(_filters, _ids, _ws_id, target, _cursor, pages, acc)
       when length(acc) >= target or pages >= @timeline_max_pages do
    Enum.take(acc, target)
  end

  defp collect_pages(filters, delegation_ids, workspace_id, target, cursor, pages, acc) do
    opts = [limit: @timeline_page_size, order: :desc] ++ cursor_opt(cursor)
    %{events: events, next_cursor: next} = Audit.list_events(filters, opts)

    visible =
      Enum.filter(events, &visible_to_workspace?(&1, delegation_ids, workspace_id))

    new_acc = acc ++ visible

    cond do
      length(new_acc) >= target ->
        Enum.take(new_acc, target)

      next == nil ->
        new_acc

      true ->
        collect_pages(filters, delegation_ids, workspace_id, target, next, pages + 1, new_acc)
    end
  end

  defp cursor_opt(nil), do: []
  defp cursor_opt(cursor), do: [cursor: cursor]

  # Build the filter map handed to `Audit.list_events/2`. Actor and
  # range collapse to the no-filter form when the operator chose
  # `"all"` so the query stays as broad as before.
  defp build_query_filters(type, actor, cutoff) do
    base = %{event_type: type}
    base = if actor == :any, do: base, else: Map.put(base, :actor, actor)
    base = if is_nil(cutoff), do: base, else: Map.put(base, :from, cutoff)
    base
  end

  # Restrict the set of event_types to fetch based on the filter.
  # `"all"` (or any unrecognised value) keeps the full safety set.
  defp restrict_event_types("all"), do: @safety_event_types

  defp restrict_event_types(type) when is_binary(type) do
    if type in @safety_event_types, do: [type], else: @safety_event_types
  end

  defp restrict_event_types(_), do: @safety_event_types

  # `actor` is stored as an enum atom on `AuditEvent`. Coerce to atom
  # via the documented allowlist; anything else collapses to `:any`.
  # `:any` causes `build_query_filters/3` to omit the filter so the
  # DB-level `actor` predicate is skipped.
  defp parse_actor_filter("user"), do: :user
  defp parse_actor_filter("agent"), do: :agent
  defp parse_actor_filter("runtime"), do: :runtime
  defp parse_actor_filter("adapter"), do: :adapter
  defp parse_actor_filter(_), do: :any

  # `range_cutoff` returns the lower-bound `DateTime` to push down
  # via `Audit.list_events`'s `:from` filter. `nil` is the no-bound
  # case ("all time") and `build_query_filters/3` skips the `:from`
  # entry when `cutoff` is `nil`.
  defp range_cutoff("24h"), do: DateTime.add(DateTime.utc_now(), -24 * 3600, :second)
  defp range_cutoff("7d"), do: DateTime.add(DateTime.utc_now(), -7 * 86_400, :second)
  defp range_cutoff("30d"), do: DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
  defp range_cutoff(_), do: nil

  # `security.*` rows are runtime-global and always visible.
  # `delegation.*` rows are visible only when the subject_id (the
  # delegation's UUID) belongs to the current workspace.
  # `agent_keys.*` rows carry `subject_id = workspace.id` (#231-a),
  # so they are visible iff that subject equals the current
  # workspace — keeps the timeline from leaking another workspace's
  # pause activity.
  #
  # `security.scope_paused` / `security.scope_resumed` (#228 Phase
  # 1) are workspace-scoped: they stamp `event.workspace_id` and
  # MUST be gated on it BEFORE the blanket `"security." <> _`
  # rule below. Elixir matches first-clause-wins, so the order of
  # these clauses is load-bearing — moving them after the catch-
  # all would silently make every workspace see every other
  # workspace's chain pauses.
  defp visible_to_workspace?(
         %{event_type: "security.scope_paused", workspace_id: row_ws},
         _ids,
         ws_id
       )
       when is_binary(row_ws) and is_binary(ws_id),
       do: row_ws == ws_id

  defp visible_to_workspace?(
         %{event_type: "security.scope_resumed", workspace_id: row_ws},
         _ids,
         ws_id
       )
       when is_binary(row_ws) and is_binary(ws_id),
       do: row_ws == ws_id

  defp visible_to_workspace?(%{event_type: "security." <> _}, _ids, _ws_id), do: true

  defp visible_to_workspace?(%{event_type: "delegation." <> _, subject_id: id}, ids, _ws_id)
       when is_binary(id),
       do: MapSet.member?(ids, id)

  defp visible_to_workspace?(%{event_type: "agent_keys." <> _, subject_id: id}, _ids, ws_id)
       when is_binary(id) and is_binary(ws_id),
       do: id == ws_id

  # `ops.stuck_plan_detected` (#230-b) stamps `workspace_id` on the
  # audit row directly via the envelope passthrough, so we gate by
  # `event.workspace_id` rather than `subject_id` (which is the
  # plan id, not workspace-keyed).
  defp visible_to_workspace?(
         %{event_type: "ops.stuck_plan_detected", workspace_id: row_ws},
         _ids,
         ws_id
       )
       when is_binary(row_ws) and is_binary(ws_id),
       do: row_ws == ws_id

  defp visible_to_workspace?(_event, _ids, _ws_id), do: false

  # --- Render ----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} active_page={:security}>
      <%!-- Page header --%>
      <div class="flex items-center justify-between mb-6">
        <div>
          <h1 id="page-title" class="text-2xl font-bold tracking-tight">Security console</h1>
          <p class="mt-1 text-sm text-base-content/60">
            Runtime safety posture and emergency controls
          </p>
        </div>
        <button phx-click="refresh" class="btn btn-ghost btn-sm gap-1.5">
          <.icon name="hero-arrow-path" class="size-3.5" /> Refresh
        </button>
      </div>

      <%!-- Posture banner --%>
      <.posture_banner
        paused={@paused}
        execution_ready={@execution_ready}
        delegation_count={length(@delegations)}
      />

      <%!-- Main grid --%>
      <div class="mt-6 grid grid-cols-1 lg:grid-cols-3 gap-6">
        <%!-- Left column: runtime + agent keys + delegations --%>
        <div class="lg:col-span-2 space-y-6">
          <.runtime_card paused={@paused} pause_snapshot={@pause_snapshot} />
          <.agent_keys_card
            workspace={@agent_keys_workspace}
            paused={@agent_keys_paused}
            paused_by={@agent_keys_paused_by}
            current_role={@current_scope.role}
          />
          <.risk_summary_card
            summary={@risk_summary}
            executable_count={@executable_count}
            total={length(@delegations)}
          />
          <.stuck_plans_card
            rows={@stuck_plans}
            current_role={@current_scope.role}
          />
          <.in_flight_plans_card plans={@in_flight_plans} />
          <.pending_approvals_card approvals={@pending_approvals} />
          <.delegations_card delegations={@delegations} />
        </div>

        <%!-- Right column: incident snapshot + safety events --%>
        <div class="space-y-6">
          <.incident_summary_card
            workspace={@current_scope.workspace}
            paused={@paused}
            agent_keys_paused={@agent_keys_paused}
            delegations={@delegations}
            executable_count={@executable_count}
            stuck_plans={@stuck_plans}
            in_flight_plans={@in_flight_plans}
            pending_approvals={@pending_approvals}
            safety_events={@safety_events}
          />
          <.chain_pauses_card
            pauses={@chain_pauses}
            base_paused={@base_paused}
            current_role={@current_scope.role}
          />
          <.safety_events_card
            events={@safety_events}
            filter_form={@safety_filter_form}
            filters={@safety_filters}
          />
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Component: posture banner -------------------------------------------

  attr :paused, :boolean, required: true
  attr :execution_ready, :boolean, required: true
  attr :delegation_count, :integer, required: true

  defp posture_banner(%{paused: true} = assigns) do
    ~H"""
    <div
      id="posture-banner"
      data-posture="paused"
      class="rounded-xl border border-warning/30 bg-warning/10 p-5 flex items-start gap-3"
    >
      <.icon name="hero-pause-circle-solid" class="size-6 text-warning shrink-0" />
      <div>
        <h2 class="text-sm font-semibold text-warning">Runtime is paused</h2>
        <p class="mt-1 text-xs text-base-content/70">
          New executions are halted. Decisions and intents may still be written;
          nothing enters <code>:executing</code> until the runtime is resumed.
        </p>
      </div>
    </div>
    """
  end

  defp posture_banner(%{delegation_count: 0} = assigns) do
    ~H"""
    <div
      id="posture-banner"
      data-posture="no-delegation"
      class="rounded-xl border border-base-300 bg-base-200/40 p-5 flex items-start gap-3"
    >
      <.icon name="hero-link-slash" class="size-6 text-base-content/40 shrink-0" />
      <div>
        <h2 class="text-sm font-semibold text-base-content/70">No active delegation</h2>
        <p class="mt-1 text-xs text-base-content/60">
          No smart account has an active delegation. Execution is impossible
          until a delegation is established through the adapter callback flow.
        </p>
      </div>
    </div>
    """
  end

  defp posture_banner(%{execution_ready: true} = assigns) do
    ~H"""
    <div
      id="posture-banner"
      data-posture="ready"
      class="rounded-xl border border-success/30 bg-success/10 p-5 flex items-start gap-3"
    >
      <.icon name="hero-shield-check" class="size-6 text-success shrink-0" />
      <div>
        <h2 class="text-sm font-semibold text-success">Runtime is safe and execution-ready</h2>
        <p class="mt-1 text-xs text-base-content/70">
          <%= if @delegation_count > 1 do %>
            {@delegation_count} delegation(s) attached, at least one executable, runtime running.
          <% else %>
            A delegation is active and the runtime is running.
          <% end %>
          Auto-execute decisions will proceed; held and approval-required ones still need operator review.
        </p>
      </div>
    </div>
    """
  end

  defp posture_banner(assigns) do
    ~H"""
    <div
      id="posture-banner"
      data-posture="blocked"
      class="rounded-xl border border-base-300 bg-base-200/40 p-5 flex items-start gap-3"
    >
      <.icon name="hero-shield-exclamation" class="size-6 text-base-content/60 shrink-0" />
      <div>
        <h2 class="text-sm font-semibold text-base-content/80">Execution blocked</h2>
        <p class="mt-1 text-xs text-base-content/60">
          {@delegation_count} delegation(s) attached, but none are currently executable.
          Check the delegation panel below for per-account state.
        </p>
      </div>
    </div>
    """
  end

  # --- Component: runtime card ---------------------------------------------

  attr :paused, :boolean, required: true
  attr :pause_snapshot, :map, required: true

  defp runtime_card(assigns) do
    ~H"""
    <section
      id="runtime-card"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-cog-6-tooth" class="size-4" /> Runtime
        </h2>
        <span :if={@paused} class="badge badge-warning badge-sm">Paused</span>
        <span :if={!@paused} class="badge badge-success badge-sm">Running</span>
      </header>
      <div class="px-6 py-5">
        <p :if={!@paused} class="text-sm text-base-content/70">
          The runtime is processing decisions and execution transitions normally.
          Pausing halts new <code>:executing</code> transitions but does not drop
          inbound intents or suppress decision writing.
        </p>
        <div :if={@paused} class="space-y-3">
          <p class="text-sm text-base-content/70">
            Pause is in effect. Existing decisions are still written; nothing
            enters <code>:executing</code> until resumed.
          </p>
          <dl :if={@pause_snapshot.global} class="grid grid-cols-2 gap-4 text-sm">
            <div>
              <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
                Paused at
              </dt>
              <dd class="font-mono text-base-content/80">
                {format_datetime(@pause_snapshot.global.paused_at)}
              </dd>
            </div>
            <div>
              <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
                Reason
              </dt>
              <dd class="font-mono text-base-content/80">
                {@pause_snapshot.global.reason}
              </dd>
            </div>
            <div>
              <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
                Actor
              </dt>
              <dd class="font-mono text-base-content/80">
                {@pause_snapshot.global.actor}
              </dd>
            </div>
            <div :if={@pause_snapshot.global.actor_id}>
              <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
                Actor id
              </dt>
              <dd class="font-mono text-base-content/80">
                {@pause_snapshot.global.actor_id}
              </dd>
            </div>
          </dl>
        </div>
      </div>
      <footer class="flex items-center gap-2 px-6 py-4 border-t border-base-300 bg-base-200/20">
        <.button
          :if={!@paused}
          id="pause-btn"
          phx-click="pause_runtime"
          data-confirm="Pause the runtime? New executions will be halted. The runtime never auto-unpauses."
          class="btn btn-warning btn-soft btn-sm gap-1.5"
        >
          <.icon name="hero-pause" class="size-3.5" /> Pause runtime
        </.button>
        <.button
          :if={@paused}
          id="resume-btn"
          phx-click="resume_runtime"
          data-confirm="Resume runtime? New executions may start again immediately."
          class="btn btn-success btn-soft btn-sm gap-1.5"
        >
          <.icon name="hero-play" class="size-3.5" /> Resume runtime
        </.button>
      </footer>
    </section>
    """
  end

  # --- Component: agent-keys pause card (#231-c) ---------------------------

  attr :workspace, :map, required: true
  attr :paused, :boolean, required: true
  attr :paused_by, :map, default: nil
  attr :current_role, :atom, required: true

  defp agent_keys_card(assigns) do
    ~H"""
    <section
      id="agent-keys-pause-panel"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-key" class="size-4" /> Agent keys (workspace)
        </h2>
        <span
          :if={@paused}
          id="agent-keys-paused-badge"
          class="badge badge-warning badge-sm"
        >
          Paused
        </span>
        <span :if={!@paused} class="badge badge-success badge-sm">Active</span>
      </header>

      <div class="px-6 py-5">
        <p :if={!@paused} class="text-sm text-base-content/70">
          API keys for <span class="font-mono">{@workspace.slug}</span>
          authenticate normally. Pausing rejects every <code>/v1</code>
          request from this workspace's keys with <code>401 invalid_credentials</code>.
          Existing browser sessions are unaffected.
        </p>

        <div :if={@paused} class="space-y-3">
          <p class="text-sm text-base-content/70">
            Every <code>/v1</code> request from this workspace's API keys is
            being refused. Browser session admins can resume from this
            console.
          </p>
          <dl class="grid grid-cols-2 gap-4 text-sm">
            <div>
              <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
                Paused at
              </dt>
              <dd id="agent-keys-paused-since" class="font-mono text-base-content/80">
                {format_datetime(@workspace.agent_keys_paused_at)}
              </dd>
            </div>
            <div :if={@workspace.agent_keys_paused_reason}>
              <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
                Reason
              </dt>
              <dd id="agent-keys-paused-reason" class="font-mono text-base-content/80 break-words">
                {@workspace.agent_keys_paused_reason}
              </dd>
            </div>
            <div :if={@paused_by}>
              <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
                Paused by
              </dt>
              <dd id="agent-keys-paused-by" class="font-mono text-base-content/80">
                {@paused_by.email}
              </dd>
            </div>
          </dl>
        </div>
      </div>

      <%!-- Footer: action gate is admin-only. The mount-level role
        gate is :require_role, :operator, so non-admins SEE the
        panel read-only. handle_event still re-checks `:admin` so a
        hostile event from a non-admin connection is refused with a
        flash. --%>
      <footer
        :if={@current_role in [:admin, :owner]}
        class="px-6 py-4 border-t border-base-300 bg-base-200/20"
      >
        <form
          :if={!@paused}
          id="agent-keys-pause-form"
          phx-submit="pause_agent_keys"
          class="flex flex-col gap-3 sm:flex-row sm:items-end"
        >
          <label class="form-control flex-1">
            <span class="label-text text-xs uppercase tracking-wider text-base-content/60">
              Reason (optional)
            </span>
            <input
              type="text"
              name="reason"
              maxlength="256"
              placeholder="e.g. credential leak under investigation"
              class="input input-bordered input-sm w-full"
            />
          </label>
          <.button
            id="agent-keys-pause-submit"
            type="submit"
            data-confirm="Pause all agent keys for this workspace? Every /v1 API request will fail until resumed."
            class="btn btn-warning btn-soft btn-sm gap-1.5"
          >
            <.icon name="hero-pause" class="size-3.5" /> Pause agent keys
          </.button>
        </form>

        <.button
          :if={@paused}
          id="agent-keys-resume"
          phx-click="resume_agent_keys"
          data-confirm="Resume agent keys for this workspace?"
          class="btn btn-success btn-soft btn-sm gap-1.5"
        >
          <.icon name="hero-play" class="size-3.5" /> Resume agent keys
        </.button>
      </footer>
    </section>
    """
  end

  # --- Component: risk summary card (#231-e) -------------------------------

  attr :summary, :map, required: true
  attr :executable_count, :integer, required: true
  attr :total, :integer, required: true

  # Compact at-a-glance roll-up of the workspace's active delegation
  # population. The headline numbers — total tracked + executable now
  # — are first-class because they answer the operator's primary
  # questions ("how many delegations am I responsible for?" and "how
  # many can move funds right now?"). Per-state counts are rendered
  # only when non-zero so the card collapses to a clean two-cell view
  # when nothing is in flight.
  defp risk_summary_card(assigns) do
    ~H"""
    <section
      id="risk-summary-card"
      data-total={@total}
      data-executable={@executable_count}
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-shield-check" class="size-4" /> Active delegation risk summary
        </h2>
        <span class="badge badge-sm badge-ghost">{@total}</span>
      </header>

      <dl class="grid grid-cols-2 gap-4 px-6 py-5 text-sm">
        <div>
          <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
            Total tracked
          </dt>
          <dd id="risk-total" class="font-mono text-base-content/80">{@total}</dd>
        </div>
        <div>
          <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
            Executable now
          </dt>
          <dd id="risk-executable" class="font-mono text-base-content/80">
            {@executable_count}
          </dd>
        </div>

        <%= for {state, label, dom_id} <- [
          {:active, "Active", "risk-state-active"},
          {:pending, "Pending grant", "risk-state-pending"},
          {:revoking, "Revoking", "risk-state-revoking"},
          {:revoke_failed, "Revoke failed", "risk-state-revoke-failed"}
        ], Map.get(@summary, state, 0) > 0 do %>
          <div>
            <dt class="text-[0.65rem] uppercase tracking-wider text-base-content/40 mb-0.5">
              {label}
            </dt>
            <dd id={dom_id} class="font-mono text-base-content/80">
              {Map.get(@summary, state, 0)}
            </dd>
          </div>
        <% end %>
      </dl>

      <div
        :if={@total == 0}
        class="px-6 pb-5 -mt-2 text-xs text-base-content/50"
      >
        No active delegations to monitor.
      </div>
    </section>
    """
  end

  # --- Component: stuck-plans card (#229/#230) -----------------------------

  attr :rows, :list, required: true
  attr :current_role, :atom, required: true

  # Per-status threshold + age cells; abort affordance is rendered ONLY
  # for `:prepared` rows because `Bank.Decisions.abort_plan/3`'s
  # safe-state guard rejects every other non-terminal status. Non-
  # `:prepared` rows render the message "adapter cancel required" so
  # the operator understands why the row appears without an action.
  defp stuck_plans_card(assigns) do
    ~H"""
    <section
      id="stuck-plans-card"
      data-count={length(@rows)}
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-clock" class="size-4" /> Stuck execution plans
        </h2>
        <span class="badge badge-sm badge-ghost">{length(@rows)}</span>
      </header>

      <div
        :if={@rows == []}
        id="stuck-plans-empty"
        class="px-6 py-8 text-center text-sm text-base-content/50"
      >
        No execution plans past their stuck threshold.
      </div>

      <ul :if={@rows != []} class="divide-y divide-base-300">
        <li :for={row <- @rows} id={"stuck-plan-#{row.id}"} class="px-6 py-4">
          <.stuck_plan_row row={row} current_role={@current_role} />
        </li>
      </ul>
    </section>
    """
  end

  attr :row, :map, required: true
  attr :current_role, :atom, required: true

  defp stuck_plan_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3">
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="text-sm font-mono">{short_id(@row.id)}</span>
          <span
            id={"stuck-plan-status-#{@row.id}"}
            class={["badge badge-sm font-mono", stuck_status_badge_class(@row.execution_status)]}
            data-status={@row.execution_status}
          >
            {@row.execution_status}
          </span>
        </div>
        <div class="mt-1 text-xs text-base-content/50 flex items-center gap-3 flex-wrap">
          <span>
            stuck for
            <span id={"stuck-plan-stuck-for-#{@row.id}"} class="font-mono">
              {format_duration(@row.stuck_for_seconds)}
            </span>
          </span>
          <span>
            threshold <span class="font-mono">{format_duration(@row.threshold_seconds)}</span>
          </span>
        </div>
      </div>

      <%!-- Abort button only for :prepared. Other non-terminal
            statuses (:signing, :broadcasting, :pending_confirmation)
            already touched the adapter; aborting locally would
            orphan a chain operation. --%>
      <.button
        :if={@row.execution_status == :prepared and @current_role in [:admin, :owner]}
        id={"abort-plan-btn-#{@row.id}"}
        phx-click="abort_plan"
        phx-value-plan-id={@row.id}
        data-confirm="Abort this :prepared execution plan? Operator-confirmed; emits an audit row."
        class="btn btn-error btn-soft btn-xs gap-1.5"
      >
        <.icon name="hero-x-circle" class="size-3" /> Abort
      </.button>

      <span
        :if={@row.execution_status != :prepared}
        id={"stuck-plan-not-safe-#{@row.id}"}
        class="text-xs text-base-content/50 max-w-[12rem] text-right"
      >
        Adapter cancel required — not safe to abort here.
      </span>
    </div>
    """
  end

  defp stuck_status_badge_class(:prepared), do: "badge-warning"
  defp stuck_status_badge_class(:signing), do: "badge-error"
  defp stuck_status_badge_class(:broadcasting), do: "badge-error"
  defp stuck_status_badge_class(:pending_confirmation), do: "badge-error"
  defp stuck_status_badge_class(_), do: "badge-ghost"

  # `stuck_for_seconds` and `threshold_seconds` are integers from
  # `Health.stuck_plan_details/1`. Render compactly so a long backlog
  # still fits in the card.
  defp format_duration(seconds) when is_integer(seconds) and seconds < 60, do: "#{seconds}s"

  defp format_duration(seconds) when is_integer(seconds) and seconds < 3600 do
    minutes = div(seconds, 60)
    "#{minutes}m"
  end

  defp format_duration(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    if minutes == 0, do: "#{hours}h", else: "#{hours}h #{minutes}m"
  end

  defp format_duration(_), do: "-"

  # --- Component: in-flight execution plans card --------------------------
  #
  # Read-only operator view of the full non-terminal execution plan
  # set for the current workspace (#229). This is the superset of
  # `#stuck-plans-card`: stuck plans are filtered by per-status age
  # threshold, while this card shows everything in
  # `Bank.Decisions.list_active_executions/1` — the actual active
  # pipeline. No actions are wired in this slice; abort affordance
  # already lives on the stuck-plans card and is bound to the same
  # `Decisions.abort_plan/3` safe-state guard.
  #
  # Field selection deliberately avoids signing material, adapter
  # payloads, and chain refs. Operators get the handle (short id),
  # routing context (chain / asset / smart account), the lifecycle
  # state, and an updated-at age — enough to triage without leaking
  # anything that doesn't already render elsewhere on /security.

  attr :plans, :list, required: true

  defp in_flight_plans_card(assigns) do
    ~H"""
    <section
      id="in-flight-plans-card"
      data-count={length(@plans)}
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-bolt" class="size-4" /> In-flight execution plans
        </h2>
        <span class="badge badge-sm badge-ghost">{length(@plans)}</span>
      </header>

      <div
        :if={@plans == []}
        id="in-flight-plans-empty"
        class="px-6 py-8 text-center text-sm text-base-content/50"
      >
        No in-flight execution plans for this workspace.
      </div>

      <ul :if={@plans != []} class="divide-y divide-base-300">
        <li :for={plan <- @plans} id={"in-flight-plan-#{plan.id}"} class="px-6 py-4">
          <.in_flight_plan_row plan={plan} />
        </li>
      </ul>
    </section>
    """
  end

  attr :plan, :map, required: true

  defp in_flight_plan_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3">
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="text-sm font-mono">{short_id(@plan.id)}</span>
          <span
            id={"in-flight-plan-status-#{@plan.id}"}
            class={[
              "badge badge-sm font-mono",
              in_flight_status_badge_class(@plan.execution_status)
            ]}
            data-status={@plan.execution_status}
          >
            {@plan.execution_status}
          </span>
        </div>
        <div class="mt-1 text-xs text-base-content/50 flex items-center gap-3 flex-wrap">
          <span :if={@plan.chain}>
            chain <span class="font-mono">{@plan.chain}</span>
          </span>
          <span :if={@plan.asset}>
            asset <span class="font-mono">{@plan.asset}</span>
          </span>
          <span :if={@plan.smart_account_id}>
            sa <span class="font-mono">{short_id(@plan.smart_account_id)}</span>
          </span>
          <span>
            updated
            <span id={"in-flight-plan-age-#{@plan.id}"} class="font-mono">
              {format_age(@plan.updated_at)}
            </span>
            ago
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp in_flight_status_badge_class(:prepared), do: "badge-info"
  defp in_flight_status_badge_class(:signing), do: "badge-warning"
  defp in_flight_status_badge_class(:broadcasting), do: "badge-warning"
  defp in_flight_status_badge_class(:pending_confirmation), do: "badge-warning"
  defp in_flight_status_badge_class(_), do: "badge-ghost"

  # Computes a coarse human-readable age from a `DateTime`. Mirrors
  # `format_duration/1` shape but takes a timestamp so the in-flight
  # row can be rendered without the per-status threshold context the
  # stuck-plans helper carries.
  defp format_age(%DateTime{} = ts) do
    DateTime.utc_now()
    |> DateTime.diff(ts, :second)
    |> max(0)
    |> format_duration()
  end

  defp format_age(_), do: "-"

  # --- Component: pending approvals card -----------------------------------
  #
  # Read-only operator view of decisions currently awaiting approval
  # for the current workspace (#229). Mirrors the data shown on
  # `/queue#pending-approvals-section` so an incident operator can
  # see approval pressure without leaving `/security`. Mutating
  # approve/reject still happens on `/queue` — keeping the safety
  # console read-side avoids duplicating the approve transaction
  # across two surfaces.
  #
  # Field selection deliberately excludes `reasons`,
  # `policy_snapshot`, and other free-form decision payload that
  # could leak sensitive context; operators get the handle, risk
  # tier, intent summary, and timing — enough to triage.

  attr :approvals, :list, required: true

  defp pending_approvals_card(assigns) do
    ~H"""
    <section
      id="pending-approvals-card"
      data-count={length(@approvals)}
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-clock" class="size-4" /> Pending approvals
        </h2>
        <div class="flex items-center gap-2">
          <span class="badge badge-sm badge-ghost">{length(@approvals)}</span>
          <.link
            id="pending-approvals-queue-link"
            navigate="/queue#pending-approvals-section"
            class="link link-primary text-xs"
          >
            Review in queue
          </.link>
        </div>
      </header>

      <div
        :if={@approvals == []}
        id="pending-approvals-empty"
        class="px-6 py-8 text-center text-sm text-base-content/50"
      >
        No decisions awaiting approval for this workspace.
      </div>

      <ul :if={@approvals != []} class="divide-y divide-base-300">
        <li
          :for={envelope <- @approvals}
          id={"pending-approval-#{envelope.id}"}
          class="px-6 py-4"
        >
          <.pending_approval_row envelope={envelope} />
        </li>
      </ul>
    </section>
    """
  end

  attr :envelope, :map, required: true

  defp pending_approval_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3">
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="text-sm font-mono">{short_id(@envelope.id)}</span>
          <span
            id={"pending-approval-risk-#{@envelope.id}"}
            class={[
              "badge badge-sm font-mono",
              pending_approval_risk_badge_class(@envelope.risk_tier)
            ]}
            data-risk-tier={@envelope.risk_tier}
          >
            {@envelope.risk_tier}
          </span>
        </div>
        <div class="mt-1 text-xs text-base-content/50 flex items-center gap-3 flex-wrap">
          <span :if={@envelope.intent}>
            intent <span class="font-mono">{pending_approval_intent_label(@envelope.intent)}</span>
          </span>
          <span :if={@envelope.decided_at}>
            decided
            <span id={"pending-approval-age-#{@envelope.id}"} class="font-mono">
              {format_age(@envelope.decided_at)}
            </span>
            ago
          </span>
        </div>
      </div>
    </div>
    """
  end

  defp pending_approval_risk_badge_class(:low), do: "badge-ghost"
  defp pending_approval_risk_badge_class(:moderate), do: "badge-info"
  defp pending_approval_risk_badge_class(:elevated), do: "badge-warning"
  defp pending_approval_risk_badge_class(:severe), do: "badge-error"
  defp pending_approval_risk_badge_class(_), do: "badge-ghost"

  # Compact intent description for the approval row. Mirrors the
  # shape used by QueueLive's `intent_summary/1` without importing
  # the queue module — kept inline so the safety console doesn't
  # depend on an unrelated LiveView's helpers.
  defp pending_approval_intent_label(%{kind: kind, asset: asset, amount: amount}),
    do: "#{kind} #{amount} #{asset}"

  defp pending_approval_intent_label(_), do: "-"

  # --- Component: incident summary card ------------------------------------
  #
  # Read-only "what's the current incident posture?" snapshot. All
  # values come from existing `load_state/1` assigns — the card is
  # pure projection. Renders human-readable counts plus a
  # copy/export-friendly plaintext block an operator can paste into
  # a handoff message or a post-mortem doc.
  #
  # Field selection deliberately keeps the snapshot to public
  # operational counts — no reasons, no payloads, no API keys, no
  # tx refs, no signing material. The destination cards on the same
  # page already render any human-readable detail.

  attr :workspace, :map, required: true
  attr :paused, :boolean, required: true
  attr :agent_keys_paused, :boolean, required: true
  attr :delegations, :list, required: true
  attr :executable_count, :integer, required: true
  attr :stuck_plans, :list, required: true
  attr :in_flight_plans, :list, required: true
  attr :pending_approvals, :list, required: true
  attr :safety_events, :list, required: true

  defp incident_summary_card(assigns) do
    counts = %{
      delegations: length(assigns.delegations),
      executable: assigns.executable_count,
      stuck: length(assigns.stuck_plans),
      in_flight: length(assigns.in_flight_plans),
      pending_approvals: length(assigns.pending_approvals),
      safety_events: length(assigns.safety_events)
    }

    assigns =
      assign(assigns,
        counts: counts,
        copy_block:
          incident_summary_copy_block(
            assigns.workspace,
            assigns.paused,
            assigns.agent_keys_paused,
            counts
          )
      )

    ~H"""
    <section
      id="incident-summary-card"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-clipboard-document-list" class="size-4" /> Incident snapshot
        </h2>
        <span class="text-xs text-base-content/40 font-mono">
          {short_id(@workspace.id)}
        </span>
      </header>

      <dl class="px-6 py-4 grid grid-cols-2 gap-x-4 gap-y-2 text-xs">
        <div id="incident-summary-runtime" class="flex items-center justify-between gap-2">
          <dt class="text-base-content/50">Runtime</dt>
          <dd class={[
            "font-mono",
            if(@paused, do: "text-warning", else: "text-success")
          ]}>
            {if @paused, do: "paused", else: "running"}
          </dd>
        </div>
        <div id="incident-summary-agent-keys" class="flex items-center justify-between gap-2">
          <dt class="text-base-content/50">Agent keys</dt>
          <dd class={[
            "font-mono",
            if(@agent_keys_paused, do: "text-warning", else: "text-success")
          ]}>
            {if @agent_keys_paused, do: "paused", else: "active"}
          </dd>
        </div>
        <div id="incident-summary-delegations" class="flex items-center justify-between gap-2">
          <dt class="text-base-content/50">Delegations</dt>
          <dd class="font-mono">
            {@counts.executable}/{@counts.delegations} executable
          </dd>
        </div>
        <div id="incident-summary-plans" class="flex items-center justify-between gap-2">
          <dt class="text-base-content/50">Plans</dt>
          <dd class="font-mono">
            {@counts.stuck} stuck, {@counts.in_flight} in-flight
          </dd>
        </div>
        <div id="incident-summary-approvals" class="flex items-center justify-between gap-2">
          <dt class="text-base-content/50">Approvals</dt>
          <dd class="font-mono">{@counts.pending_approvals} pending</dd>
        </div>
        <div id="incident-summary-events" class="flex items-center justify-between gap-2">
          <dt class="text-base-content/50">Safety events</dt>
          <dd class="font-mono">{@counts.safety_events} shown</dd>
        </div>
      </dl>

      <div class="px-6 pb-4">
        <p class="text-xs text-base-content/40 mb-1.5">
          Copy snapshot for handoff or post-mortem:
        </p>
        <pre
          id="incident-summary-copy-block"
          class="text-[11px] leading-snug font-mono whitespace-pre-wrap break-words rounded-lg bg-base-200/60 border border-base-300 px-3 py-2 max-h-64 overflow-auto"
        ><%= @copy_block %></pre>
      </div>
    </section>
    """
  end

  # Builds the plaintext snapshot rendered inside
  # `#incident-summary-copy-block`. Kept as a pure helper so the
  # component stays curly-brace-free in HEEx and so tests can
  # eyeball the format without rendering.
  defp incident_summary_copy_block(workspace, paused?, agent_keys_paused?, counts) do
    runtime = if paused?, do: "paused", else: "running"
    agent_keys = if agent_keys_paused?, do: "paused", else: "active"
    workspace_slug = workspace.slug || "-"
    workspace_short = short_id(workspace.id)
    generated = DateTime.utc_now() |> DateTime.to_iso8601()

    """
    Incident snapshot
    Workspace: #{workspace_slug} (#{workspace_short})
    Runtime: #{runtime}
    Agent keys: #{agent_keys}
    Delegations: #{counts.delegations} active, #{counts.executable} executable
    Plans: #{counts.stuck} stuck, #{counts.in_flight} in-flight
    Approvals: #{counts.pending_approvals} pending
    Safety events shown: #{counts.safety_events}
    Generated: #{generated}
    """
  end

  # --- Component: chain pauses card (#228 Phase 1) -------------------------
  #
  # Read-only "what is currently paused at scope?" surface for the
  # current workspace. Sourced from
  # `Bank.Security.Pauses.list_active/1`, which is workspace-scoped
  # at the context layer (refuses to surface sibling-workspace rows
  # even when given `nil`).
  #
  # Phase 1 only ships `:chain` rows; future phases extend the
  # `scope_type` enum. The card renders whatever scope rows the
  # context returns so adding a new scope_type later does not
  # require this component to change.
  #
  # No mutating controls in this slice — pause/resume buttons wait
  # for #332's HTTP/UI surface. Field selection is intentionally
  # minimal: scope type/value, optional reason (≤256 chars,
  # operator-supplied), and the paused-at age. `created_by_user_id`
  # is omitted to keep the safety console scoped to the existing
  # patterns; the audit row carries the actor identity durably.

  attr :pauses, :list, required: true
  attr :base_paused, :boolean, required: true
  attr :current_role, :atom, required: true

  defp chain_pauses_card(assigns) do
    ~H"""
    <section
      id="chain-pauses-card"
      data-count={length(@pauses)}
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-no-symbol" class="size-4" /> Active scope pauses
        </h2>
        <span class="badge badge-sm badge-ghost">{length(@pauses)}</span>
      </header>

      <%!-- Phase 1 base-chain pause/resume control. The card stays a
            single section so operators see "what is paused" and "pause
            this" together. Non-admins see the read-only state with no
            mutating buttons; the event handlers re-check `:admin` so a
            hostile event from a non-admin connection is refused with a
            flash even if the form was hidden in their UI. --%>
      <div
        id="chain-pause-base-control"
        data-base-paused={to_string(@base_paused)}
        class="px-6 py-4 border-b border-base-300 bg-base-200/20"
      >
        <div class="flex items-center justify-between gap-3 mb-2">
          <span class="text-xs uppercase tracking-wider text-base-content/60">
            Base chain
          </span>
          <span
            id="chain-pause-base-status"
            class={[
              "badge badge-sm font-mono",
              if(@base_paused, do: "badge-warning", else: "badge-success")
            ]}
            data-state={if @base_paused, do: "paused", else: "running"}
          >
            {if @base_paused, do: "paused", else: "running"}
          </span>
        </div>

        <%!-- Admin pause form (when running) --%>
        <form
          :if={!@base_paused and @current_role in [:admin, :owner]}
          id="chain-pause-base-form"
          phx-submit="pause_chain"
          class="flex flex-col gap-2 sm:flex-row sm:items-end"
        >
          <label class="form-control flex-1">
            <span class="label-text text-xs text-base-content/60">
              Reason (optional)
            </span>
            <input
              id="chain-pause-base-reason"
              type="text"
              name="reason"
              maxlength="256"
              placeholder="e.g. base RPC outage"
              class="input input-bordered input-sm w-full"
            />
          </label>
          <.button
            id="chain-pause-base-submit"
            type="submit"
            data-confirm="Pause Base chain for this workspace? Pending and new chain operations on Base will be refused until resumed."
            class="btn btn-warning btn-soft btn-sm gap-1.5"
          >
            <.icon name="hero-pause" class="size-3.5" /> Pause Base
          </.button>
        </form>

        <%!-- Admin resume button (when paused) --%>
        <.button
          :if={@base_paused and @current_role in [:admin, :owner]}
          id="chain-resume-base-submit"
          phx-click="resume_chain"
          data-confirm="Resume Base chain for this workspace? Chain operations on Base may proceed again."
          class="btn btn-success btn-soft btn-sm gap-1.5"
        >
          <.icon name="hero-play" class="size-3.5" /> Resume Base
        </.button>

        <%!-- Read-only hint for non-admins --%>
        <p
          :if={@current_role not in [:admin, :owner]}
          id="chain-pause-base-readonly"
          class="text-xs text-base-content/50"
        >
          Admin role required to pause or resume a chain.
        </p>
      </div>

      <div
        :if={@pauses == []}
        id="chain-pauses-empty"
        class="px-6 py-8 text-center text-sm text-base-content/50"
      >
        No active scope pauses for this workspace.
      </div>

      <ul :if={@pauses != []} class="divide-y divide-base-300">
        <li :for={pause <- @pauses} id={"chain-pause-#{pause.id}"} class="px-6 py-4">
          <.chain_pause_row pause={pause} />
        </li>
      </ul>
    </section>
    """
  end

  attr :pause, :map, required: true

  defp chain_pause_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3">
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2 flex-wrap">
          <span
            id={"chain-pause-scope-#{@pause.id}"}
            class="badge badge-sm badge-warning font-mono"
            data-scope-type={@pause.scope_type}
            data-scope-value={@pause.scope_value}
          >
            {@pause.scope_type} · {@pause.scope_value}
          </span>
        </div>
        <div class="mt-1 text-xs text-base-content/50 flex items-center gap-3 flex-wrap">
          <span :if={@pause.reason}>
            reason
            <span id={"chain-pause-reason-#{@pause.id}"} class="font-mono break-words">
              {@pause.reason}
            </span>
          </span>
          <span :if={@pause.paused_at}>
            paused
            <span id={"chain-pause-age-#{@pause.id}"} class="font-mono">
              {format_age(@pause.paused_at)}
            </span>
            ago
          </span>
        </div>
      </div>
    </div>
    """
  end

  # --- Component: delegations card -----------------------------------------

  attr :delegations, :list, required: true

  defp delegations_card(assigns) do
    ~H"""
    <section
      id="delegations-card"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-link" class="size-4" /> Delegations
        </h2>
        <span class="badge badge-sm badge-ghost">{length(@delegations)}</span>
      </header>
      <div :if={@delegations == []} class="px-6 py-8 text-center text-sm text-base-content/50">
        No active delegations. Establish one through the adapter callback flow.
      </div>
      <ul :if={@delegations != []} class="divide-y divide-base-300">
        <li :for={delegation <- @delegations} class="px-6 py-4">
          <.delegation_row delegation={delegation} />
        </li>
      </ul>
    </section>
    """
  end

  attr :delegation, :map, required: true

  defp delegation_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3">
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2 flex-wrap">
          <span class="text-sm font-mono">{short_id(@delegation.smart_account_id)}</span>
          <span class={["badge badge-sm", delegation_badge_class(@delegation.state)]}>
            {@delegation.state}
          </span>
        </div>
        <div class="mt-1 text-xs text-base-content/50 flex items-center gap-3 flex-wrap">
          <span>chain: {@delegation.chain || "—"}</span>
          <span>delegation: {short_id(@delegation.delegation_id)}</span>
          <span :if={@delegation.granted_at}>
            granted: {format_datetime(@delegation.granted_at)}
          </span>
          <span :if={@delegation.revoke_requested_at}>
            revoke requested: {format_datetime(@delegation.revoke_requested_at)}
          </span>
        </div>
      </div>
      <.button
        :if={@delegation.state in [:active, :pending]}
        id={"revoke-btn-#{@delegation.smart_account_id}"}
        phx-click="revoke_delegation"
        phx-value-smart-account-id={@delegation.smart_account_id}
        data-confirm="Revoke this delegation? Execution will stop immediately. This cannot be undone from the API."
        class="btn btn-error btn-soft btn-xs gap-1.5"
      >
        <.icon name="hero-shield-exclamation" class="size-3" /> Revoke
      </.button>
      <.button
        :if={@delegation.state == :revoke_failed}
        id={"revoke-retry-btn-#{@delegation.smart_account_id}"}
        phx-click="revoke_delegation"
        phx-value-smart-account-id={@delegation.smart_account_id}
        data-confirm="Retry the revoke? The previous attempt failed on-chain."
        class="btn btn-error btn-soft btn-xs gap-1.5"
      >
        <.icon name="hero-arrow-path" class="size-3" /> Retry
      </.button>
    </div>
    """
  end

  # --- Component: safety events card ---------------------------------------

  attr :events, :list, required: true
  attr :filter_form, :map, required: true
  attr :filters, :map, required: true

  defp safety_events_card(assigns) do
    ~H"""
    <section
      id="safety-events-card"
      class="rounded-xl border border-base-300 bg-base-100 shadow-sm overflow-hidden"
    >
      <header class="px-6 py-4 border-b border-base-300 flex items-center justify-between">
        <h2 class="text-sm font-semibold flex items-center gap-1.5">
          <.icon name="hero-bell-alert" class="size-4" /> Recent safety events
        </h2>
        <span class="badge badge-sm badge-ghost">{length(@events)}</span>
      </header>

      <.form
        for={@filter_form}
        id="safety-filters-form"
        phx-change="filter_safety_events"
        class="px-6 py-3 border-b border-base-300 bg-base-200/30 grid grid-cols-1 sm:grid-cols-3 gap-3"
      >
        <.input
          field={@filter_form[:event_type]}
          id="filter-event-type"
          type="select"
          label="Event type"
          options={event_type_filter_options()}
        />
        <.input
          field={@filter_form[:actor]}
          id="filter-actor"
          type="select"
          label="Actor"
          options={actor_filter_options()}
        />
        <.input
          field={@filter_form[:range]}
          id="filter-range"
          type="select"
          label="Time range"
          options={range_filter_options()}
        />
        <div class="sm:col-span-3 flex justify-end">
          <button
            id="filter-clear"
            type="button"
            phx-click="clear_safety_filters"
            class="btn btn-ghost btn-xs"
          >
            <.icon name="hero-x-mark" class="size-3" /> Clear filters
          </button>
        </div>
      </.form>

      <div
        :if={@events == []}
        id="safety-events-empty"
        class="px-6 py-8 text-center text-sm text-base-content/50"
      >
        No safety events recorded yet.
      </div>
      <ol :if={@events != []} class="divide-y divide-base-300">
        <li :for={event <- @events} class="px-6 py-3">
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <div class="flex items-center gap-2 flex-wrap">
                <span class={[
                  "badge badge-sm font-mono",
                  event_type_badge_class(event.event_type)
                ]}>
                  {event.event_type}
                </span>
                <span class="badge badge-sm badge-ghost gap-1">
                  <.icon name={actor_icon(event.actor)} class="size-3" />
                  {event.actor}
                </span>
              </div>
              <div class="mt-1 text-[0.7rem] text-base-content/50 font-mono">
                {event.subject_type} &middot; {short_id(event.subject_id)}
              </div>
            </div>
            <span class="text-[0.7rem] text-base-content/40 font-mono shrink-0">
              {format_datetime(event.ts)}
            </span>
          </div>
        </li>
      </ol>
    </section>
    """
  end

  # --- View helpers ---------------------------------------------------------

  # Filter dropdown options. `<.input type="select">` expects
  # `[{label, value}, ...]`; the placeholder "All ..." sentinel maps
  # to value `"all"` which `restrict_event_types/1` /
  # `parse_actor_filter/1` / `range_cutoff/1` collapse to a no-op.
  defp event_type_filter_options do
    [{"All event types", "all"} | Enum.map(@safety_event_types, fn t -> {t, t} end)]
  end

  defp actor_filter_options, do: @safety_actor_options

  defp range_filter_options, do: @safety_range_options

  defp delegation_badge_class(:active), do: "badge-success"
  defp delegation_badge_class(:pending), do: "badge-warning"
  defp delegation_badge_class(:revoking), do: "badge-error"
  defp delegation_badge_class(:revoke_failed), do: "badge-error"
  defp delegation_badge_class(:revoked), do: "badge-ghost"
  defp delegation_badge_class(:expired), do: "badge-ghost"
  defp delegation_badge_class(_), do: "badge-ghost"

  defp event_type_badge_class("security." <> _), do: "badge-error"
  defp event_type_badge_class("delegation." <> _), do: "badge-error"
  defp event_type_badge_class(_), do: "badge-ghost"

  defp actor_icon(:user), do: "hero-user"
  defp actor_icon(:agent), do: "hero-cpu-chip"
  defp actor_icon(:runtime), do: "hero-cog-6-tooth"
  defp actor_icon(:adapter), do: "hero-link"
  defp actor_icon(_), do: "hero-question-mark-circle"

  defp short_id(nil), do: "-"
  defp short_id(id) when byte_size(id) > 12, do: String.slice(id, 0, 8) <> "..."
  defp short_id(id), do: id

  defp format_datetime(nil), do: "-"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end
end
