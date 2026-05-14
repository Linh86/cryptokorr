defmodule BankWeb.AgentAdvancedLive.PolicySection do
  @moduledoc """
  Renders the Advanced screen's `policies` accordion body against
  real workspace policy state.

  This component is the read + draft-lifecycle surface for the
  Advanced screen. It deliberately does NOT host the per-rule
  type-switched form — that already lives in
  `BankWeb.PolicyBuilderLive` and is one click away via the
  "Open builder" link. The value this section adds on top of the
  builder is the **safety analysis** the builder doesn't:

    * every rule in the published version (or the workspace's
      active ruleset, when no version has ever been published)
      rendered with rule_type / label / human-readable behaviour
      summary / version badge;
    * the draft, when one exists, with a per-rule
      `tightening`/`expansion` badge derived from the
      `Bank.Policies.PolicyDiff` classifier;
    * a `requires fresh permission install` banner when the
      draft's diff is an expansion, so the operator cannot
      silently grant the agent broader on-chain authority than
      the currently-installed permission covers.

  All draft-lifecycle buttons (`Open draft`, `Discard draft`,
  `Publish draft`) push events to `AgentAdvancedLive`, which is
  responsible for the `Bank.Policies.Versions` calls and the
  admin-role gate.
  """
  use Phoenix.Component

  import BankWeb.AgentComponents

  alias Bank.Policies.PolicyRule

  attr :published_version, :any, required: true
  attr :published_rules, :list, required: true
  attr :version_source, :atom, required: true, values: [:none, :active_ruleset, :published]
  attr :draft_version, :any, required: true
  attr :draft_rules, :list, required: true
  attr :diff, :any, required: true
  attr :can_edit?, :boolean, required: true
  attr :permission_outdated?, :boolean, default: false

  def render(assigns) do
    ~H"""
    <div class="adv-policy" id="adv-policy">
      <.published_subsection
        version={@published_version}
        rules={@published_rules}
        source={@version_source}
      />

      <.draft_subsection
        draft={@draft_version}
        rules={@draft_rules}
        diff={@diff}
        can_edit?={@can_edit?}
      />

      <%= if @permission_outdated? do %>
        <div id="adv-policy-permission-outdated">
          <.banner kind="warn">
            The permission you installed predates the most recent
            policy publish. New rules may be tighter or broader than
            what the on-chain permission covers — reinstall the
            permission so the agent's on-chain authority matches
            the live policy.
          </.banner>
        </div>
      <% end %>

      <.draft_actions
        draft={@draft_version}
        diff={@diff}
        can_edit?={@can_edit?}
      />
    </div>
    """
  end

  # --- published / active ruleset (read-only) -------------------------

  attr :version, :any, required: true
  attr :rules, :list, required: true
  attr :source, :atom, required: true

  defp published_subsection(assigns) do
    ~H"""
    <section class="adv-policy__section" id="adv-policy-published">
      <div class="adv-policy__head">
        <h3 class="adv-policy__h3 serif">Active policy</h3>
        <span class="adv-policy__meta">
          <%= case @source do %>
            <% :published -> %>
              <span class="tag tag--ok" id="adv-policy-source-published">
                Published v{@version.version_number}
              </span>
              <span class="ink-2">
                published at {format_dt(@version.published_at)}
              </span>
            <% :active_ruleset -> %>
              <span class="tag tag--mute" id="adv-policy-source-active">
                Active ruleset (no version published yet)
              </span>
            <% :none -> %>
              <span class="tag tag--mute" id="adv-policy-source-none">
                Safe defaults
              </span>
          <% end %>
        </span>
      </div>

      <%= if @rules == [] do %>
        <p class="adv-empty" id="adv-policy-published-empty">
          No policy rules are active in this workspace.
        </p>
      <% else %>
        <table class="adv-table" id="adv-policy-published-table">
          <thead>
            <tr>
              <th>Rule</th>
              <th>Behaviour</th>
              <th>Status</th>
            </tr>
          </thead>
          <tbody>
            <%= for rule <- @rules do %>
              <tr id={"adv-policy-published-rule-#{rule.id}"}>
                <td>{rule_label(rule)}</td>
                <td class="ink-2">{rule_summary(rule)}</td>
                <td>
                  <span class={["tag", state_tag_class(rule.state)]}>
                    {state_label(rule.state)}
                  </span>
                  <span class="ink-3 mono"> v{rule.version}</span>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      <% end %>
    </section>
    """
  end

  # --- draft ----------------------------------------------------------

  attr :draft, :any, required: true
  attr :rules, :list, required: true
  attr :diff, :any, required: true
  attr :can_edit?, :boolean, required: true

  defp draft_subsection(assigns) do
    ~H"""
    <section class="adv-policy__section" id="adv-policy-draft">
      <div class="adv-policy__head">
        <h3 class="adv-policy__h3 serif">Draft changes</h3>
        <%= if @draft do %>
          <span class="adv-policy__meta">
            <span class="tag tag--warn" id="adv-policy-draft-state">
              Draft v{@draft.version_number}
            </span>
            <span class="ink-2">
              {summarise_diff_counts(@diff)}
            </span>
          </span>
        <% else %>
          <span class="adv-policy__meta">
            <span class="tag tag--mute" id="adv-policy-draft-state">
              No draft open
            </span>
          </span>
        <% end %>
      </div>

      <%= cond do %>
        <% is_nil(@draft) -> %>
          <p class="adv-empty" id="adv-policy-draft-empty">
            <%= if @can_edit? do %>
              No unpublished changes. Open a draft to propose edits
              — runtime keeps using the currently-active policy
              until you publish.
            <% else %>
              No unpublished changes. Admin role required to open a
              new draft.
            <% end %>
          </p>
        <% @rules == [] -> %>
          <p class="adv-empty" id="adv-policy-draft-empty-rules">
            Draft v{@draft.version_number} has no rules — publishing it
            would deactivate the entire policy. Add rules in the
            policy builder before publishing.
          </p>
        <% true -> %>
          <table class="adv-table" id="adv-policy-draft-table">
            <thead>
              <tr>
                <th>Rule</th>
                <th>Behaviour</th>
                <th>Change</th>
              </tr>
            </thead>
            <tbody>
              <%= for rule <- @rules do %>
                <tr id={"adv-policy-draft-rule-#{rule.id}"}>
                  <td>{rule_label(rule)}</td>
                  <td class="ink-2">{rule_summary(rule)}</td>
                  <td>
                    {render_change_tag(@diff, rule.id)}
                  </td>
                </tr>
              <% end %>

              <%= for change <- removed_changes(@diff) do %>
                <tr
                  id={"adv-policy-draft-removed-#{change.rule_id}"}
                  class="adv-policy__row--removed"
                >
                  <td>{rule_label(change.prior)}</td>
                  <td class="ink-2">{rule_summary(change.prior)}</td>
                  <td>
                    <span class="tag tag--warn">Removed · expansion</span>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
      <% end %>

      <%= if @draft && @diff && @diff.requires_permission_reinstall? do %>
        <div id="adv-policy-draft-expansion-warn">
          <.banner kind="warn">
            Publishing this draft would <strong>expand</strong> the
            agent's authority compared to the currently published
            policy. A fresh permission install is required before
            the new policy can take effect.
          </.banner>
        </div>
      <% end %>

      <%= if @draft && @diff && !@diff.requires_permission_reinstall? && (@diff.tightening != [] || removed_changes_from_published?(@diff)) do %>
        <div id="adv-policy-draft-tightening-info">
          <.banner kind="info">
            This draft only tightens the agent's authority. It can be
            published without re-installing the permission.
          </.banner>
        </div>
      <% end %>
    </section>
    """
  end

  defp removed_changes_from_published?(%{expansion: expansion}) when is_list(expansion) do
    Enum.any?(expansion, &(&1.kind == :removed))
  end

  defp removed_changes_from_published?(_), do: false

  # --- action bar -----------------------------------------------------

  attr :draft, :any, required: true
  attr :diff, :any, required: true
  attr :can_edit?, :boolean, required: true

  defp draft_actions(assigns) do
    ~H"""
    <div class="adv-policy__actions" id="adv-policy-actions">
      <%= if @can_edit? do %>
        <%= if @draft do %>
          <button
            type="button"
            class="btn btn--secondary"
            phx-click="policy:discard_draft"
            id="adv-policy-discard-btn"
            data-confirm="Discard the open draft? The draft row will be deleted from the catalog."
          >
            Discard draft
          </button>
          <.link navigate="/policies/builder" class="btn btn--secondary" id="adv-policy-builder-link">
            Edit in policy builder
          </.link>
          <button
            type="button"
            class={["btn", publish_btn_class(@diff)]}
            phx-click="policy:publish_draft"
            id="adv-policy-publish-btn"
            data-confirm={publish_confirm(@diff)}
          >
            Publish draft
          </button>
        <% else %>
          <button
            type="button"
            class="btn btn--primary"
            phx-click="policy:open_draft"
            id="adv-policy-open-draft-btn"
          >
            Edit policy (open draft)
          </button>
          <.link navigate="/policies/builder" class="btn btn--secondary" id="adv-policy-builder-link">
            Open policy builder
          </.link>
        <% end %>
      <% else %>
        <p class="ink-3" id="adv-policy-readonly">
          Admin role required to open or publish a policy draft.
        </p>
      <% end %>
    </div>
    """
  end

  defp publish_btn_class(%{requires_permission_reinstall?: true}), do: "btn--warn"
  defp publish_btn_class(_), do: "btn--primary"

  defp publish_confirm(%{requires_permission_reinstall?: true}),
    do:
      "Publishing will require a fresh permission install — the agent will stay disabled until the operator reinstalls. Continue?"

  defp publish_confirm(_),
    do: "Publish this draft? It supersedes the currently published policy."

  # --- per-rule labels / summaries -----------------------------------

  @doc false
  def rule_label(%PolicyRule{rule_type: :amount_limit}), do: "Max amount per intent"
  def rule_label(%PolicyRule{rule_type: :rolling_spend_cap}), do: "Rolling spend cap"
  def rule_label(%PolicyRule{rule_type: :slippage_ceiling}), do: "Slippage ceiling"
  def rule_label(%PolicyRule{rule_type: :allowed_asset}), do: "Allowed assets"
  def rule_label(%PolicyRule{rule_type: :allowed_chain}), do: "Allowed chains"
  def rule_label(%PolicyRule{rule_type: :allowed_router}), do: "Allowed routers"
  def rule_label(%PolicyRule{rule_type: :autonomy_tier}), do: "Autonomy tier"
  def rule_label(%PolicyRule{rule_type: :time_window}), do: "Time window"

  def rule_label(%PolicyRule{rule_type: type}) when is_atom(type) do
    type |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  @doc false
  def rule_summary(%PolicyRule{rule_type: :amount_limit, params: p}) do
    max = Map.get(p || %{}, "max_per_tx", "(unset)")
    currency = Map.get(p || %{}, "currency")
    if currency, do: "≤ #{max} #{currency} per intent", else: "≤ #{max} per intent"
  end

  def rule_summary(%PolicyRule{rule_type: :rolling_spend_cap, params: p}) do
    cap = Map.get(p || %{}, "max_total", "(unset)")
    hrs = Map.get(p || %{}, "window_hours", "?")
    currency = Map.get(p || %{}, "currency")
    if currency, do: "≤ #{cap} #{currency} per #{hrs}h", else: "≤ #{cap} per #{hrs}h"
  end

  def rule_summary(%PolicyRule{rule_type: :slippage_ceiling, params: p}) do
    bps = Map.get(p || %{}, "max_bps", "(unset)")
    "≤ #{bps} bps slippage per swap"
  end

  def rule_summary(%PolicyRule{rule_type: :allowed_asset, params: p}),
    do: allowlist_summary(p, "assets")

  def rule_summary(%PolicyRule{rule_type: :allowed_chain, params: p}),
    do: allowlist_summary(p, "chains")

  def rule_summary(%PolicyRule{rule_type: :allowed_router, params: p}),
    do: allowlist_summary(p, "routers")

  def rule_summary(%PolicyRule{rule_type: :autonomy_tier, params: p}) do
    case Map.get(p || %{}, "tier") do
      "auto" -> "Auto-execute when policy passes"
      "manual" -> "Always require manual approval"
      "block" -> "Block automated execution"
      other -> "Tier: #{other || "(unset)"}"
    end
  end

  def rule_summary(%PolicyRule{rule_type: :time_window, params: p}) do
    start = Map.get(p || %{}, "start_hhmm", "00:00")
    stop = Map.get(p || %{}, "end_hhmm", "24:00")
    tz = Map.get(p || %{}, "timezone", "UTC")
    "Active #{start}–#{stop} #{tz}"
  end

  def rule_summary(%PolicyRule{params: p}), do: inspect(p)

  defp allowlist_summary(params, key) do
    mode = Map.get(params || %{}, "mode", "allowlist")
    items = (Map.get(params || %{}, key) || []) |> Enum.join(", ")
    "#{mode}: #{items}"
  end

  defp state_tag_class(:active), do: "tag--ok"
  defp state_tag_class(:draft), do: "tag--warn"
  defp state_tag_class(:archived), do: "tag--mute"
  defp state_tag_class(:superseded), do: "tag--mute"
  defp state_tag_class(_), do: "tag--mute"

  defp state_label(:active), do: "published"
  defp state_label(:draft), do: "draft"
  defp state_label(:archived), do: "archived"
  defp state_label(:superseded), do: "superseded"
  defp state_label(state), do: Atom.to_string(state || :unknown)

  # --- diff helpers ---------------------------------------------------

  defp summarise_diff_counts(nil), do: ""

  defp summarise_diff_counts(%{
         tightening: tightening,
         expansion: expansion
       }) do
    t = length(tightening)
    e = length(expansion)

    parts =
      [
        t > 0 && "#{t} tightening",
        e > 0 && "#{e} expansion"
      ]
      |> Enum.filter(& &1)

    case parts do
      [] -> "no changes vs published"
      list -> Enum.join(list, " · ")
    end
  end

  defp summarise_diff_counts(_), do: ""

  defp render_change_tag(nil, _id), do: nil

  defp render_change_tag(%{expansion: expansion, tightening: tightening}, rule_id) do
    cond do
      change = Enum.find(expansion, &(&1.rule_id == rule_id)) ->
        Phoenix.HTML.raw(
          ~s(<span class="tag tag--warn" title="#{change.reason}">expansion</span>)
        )

      change = Enum.find(tightening, &(&1.rule_id == rule_id)) ->
        Phoenix.HTML.raw(
          ~s(<span class="tag tag--ok" title="#{change.reason}">#{tightening_label(change)}</span>)
        )

      true ->
        Phoenix.HTML.raw(~s(<span class="tag tag--mute">unchanged</span>))
    end
  end

  defp render_change_tag(_, _), do: nil

  defp tightening_label(%{kind: :added}), do: "added · tightening"
  defp tightening_label(_), do: "tightening"

  defp removed_changes(nil), do: []

  defp removed_changes(%{expansion: expansion}),
    do: Enum.filter(expansion, &(&1.kind == :removed))

  defp removed_changes(_), do: []

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
  defp format_dt(other), do: to_string(other)
end
