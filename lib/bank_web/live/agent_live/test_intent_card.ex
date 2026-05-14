defmodule BankWeb.AgentLive.TestIntentCard do
  @moduledoc """
  Section 4 — Test intent. Render-only function component.

  All state (intent, last_result, mode, permission, user_role,
  details_open, preview_blocks_run, preview_route) lives in
  `BankWeb.AgentLive`. Run / approve / toggle-details events fire on
  the parent.

  Wiring:

    * The parent `intent:run` handler calls `Bank.Intents.submit/2`
      (workspace-scoped) using a per-mode payload that always pins
      `chain: "base-sepolia"` for sandbox safety.
    * The parent subscribes to `Bank.Runtime.PubSub.intent(intent_id)`
      after submit AND schedules periodic DB reconciliation so a
      PubSub broadcast that races the subscribe cannot leave the UI
      stuck on Running.
    * `Approve once` routes through `Bank.Decisions.approve/2`.
      Operator+ role is required; viewer-tier users see a disabled
      button with a tooltip.
    * `View details` toggles `:details_open` on the parent — the
      inline details panel shows the final decision state, reason
      code, and human-readable reason message. Replaces the prior
      dead `href="#"` anchor that navigated nowhere on a blocked
      outcome.

  ## Stable DOM ids (Playwright + manual ops)

    * `#test-intent-run`            — the Run button
    * `#test-intent-result`         — the IntentResult banner root
    * `#test-intent-result-state`   — final state label (Blocked / …)
    * `#test-intent-result-reason`  — human-readable reason message
    * `#test-intent-view-details`   — View-details toggle control
    * `#test-intent-details-panel`  — expanded details panel
    * `#test-intent-preview-only`   — preview-only Run guard banner
  """
  use Phoenix.Component

  import BankWeb.AgentComponents

  alias Bank.Workspaces.Membership

  attr :mode, :string, required: true

  attr :intent, :atom,
    required: true,
    doc: ":idle | :executing | :slow | :executed | :blocked | :needs_approval | :failed"

  attr :last_result, :map, default: nil
  attr :permission, :atom, required: true
  attr :user_role, :atom, default: :viewer
  attr :details_open, :boolean, default: false

  # Composite wallet state from `BankWeb.AgentLive.derive_wallet_state/2`.
  # Run is disabled whenever this is not `:connected` — even if the DB
  # delegation row is still :active, a stale tab whose browser wallet
  # has dropped this origin should NOT be able to submit intents the
  # operator believes can't reach the chain.
  attr :wallet, :atom, default: :disconnected

  # Preview-only Run gate. True iff the current preview carries an
  # explicit non-executable route flag (`route["executable?"] == false`)
  # — i.e. the provider is quote-only (Odos / 1inch). Preview loading,
  # preview missing, and preview error all leave Run enabled (advisory-
  # only contract preserved); the runtime fail-closes via
  # `Bank.Autonomy`/Decisions regardless.
  attr :preview_blocks_run, :boolean, default: false
  attr :preview_route, :string, default: nil

  # Permission-outdated gate (agent-advanced). True iff a policy
  # expansion publish has landed since the active delegation's
  # `granted_at`. We disable Run here so the operator gets immediate
  # feedback instead of a confusing block-from-runtime; the runtime
  # gate in `Bank.Decisions.evaluate_policy/3` still fires
  # independently, so a stale tab cannot bypass the check.
  attr :permission_outdated?, :boolean, default: false

  # Real 0x quote preview for swap mode. Read-only side-track wired
  # to `intent:preview_real_quote` — calls
  # `Bank.Decisions.SwapRouteResolver.resolve/2` with `chain: "base"`
  # WITHOUT going through `Bank.Intents.submit/2` or
  # `Decisions.approve/2`. Shape:
  #   * `nil` — no preview fetched yet
  #   * `%{state: :ok, route: route_map, fetched_at: dt}`
  #   * `%{state: :error, reason_code: code, fetched_at: dt}`
  attr :real_quote_preview, :map, default: nil

  def test_intent_card(assigns) do
    ex = intent_example(assigns.mode)
    running? = assigns.intent in [:executing, :slow]

    wallet_blocks? = assigns.wallet != :connected

    locked? =
      assigns.permission != :active or assigns.permission_outdated? or
        wallet_blocks?

    # Only swap mode depends on a swap route. Hold + Earn are not
    # gated on preview executability.
    swap_mode? = assigns.mode == "swap"
    preview_blocks? = swap_mode? and assigns.preview_blocks_run

    approve_allowed? = approve_allowed?(assigns.user_role)

    assigns =
      assign(assigns,
        ex: ex,
        running?: running?,
        locked?: locked?,
        preview_blocks?: preview_blocks?,
        approve_allowed?: approve_allowed?,
        wallet_blocks?: wallet_blocks?
      )

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
            id="test-intent-run"
            type="button"
            class="btn btn--primary"
            disabled={@locked? or @running? or @preview_blocks?}
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
        <div
          :if={@permission_outdated? and @permission == :active}
          id="test-intent-permission-outdated"
          class="test__locked"
        >
          <.cb_icon name="info" size={14} /> Policy was expanded after this permission was installed.
          Reinstall permission — the runtime will block this intent until you do.
        </div>
        <div
          :if={@preview_blocks?}
          id="test-intent-preview-only"
          class="test__locked"
        >
          <.cb_icon name="info" size={14} />
          This quote is preview-only ({@preview_route || "no route"}). No
          executable 0x route is available — Run is disabled. Change
          inputs or wait for the preview to refresh.
        </div>
        <.intent_result
          :if={@last_result}
          result={@last_result}
          details_open={@details_open}
          approve_allowed?={@approve_allowed?}
        />
        <%!--
          The wallet-stale banner takes precedence over the "Install
          permission" banner. If the operator has a stale DB
          delegation but the browser provider has dropped the
          origin (or switched account / chain), the operator first
          needs to fix the wallet — installing on top of a stale
          binding would just re-fail at `eth_requestAccounts`.
        --%>
        <div
          :if={@wallet_blocks? and is_nil(@last_result)}
          id="test-intent-wallet-locked"
          class="test__locked"
        >
          <.cb_icon name="lock" size={14} />
          {wallet_lock_copy(@wallet)}
        </div>
        <div
          :if={@permission != :active and not @wallet_blocks? and is_nil(@last_result)}
          class="test__locked"
        >
          <.cb_icon name="lock" size={14} /> Install agent permission to run a test intent.
        </div>
        <%!--
          Real 0x quote preview (Base mainnet, read-only). Rendered
          only in swap mode. Bypasses `Bank.Intents.submit/2` and
          `Decisions.approve/2` — no mainnet gate triggers, no tx
          ever broadcasts. The button stays clickable even when the
          Run flow is locked, so an operator can still see what the
          live quote looks like before installing permissions.
        --%>
        <div :if={@mode == "swap"} id="test-intent-real-quote" class="real-quote">
          <div class="real-quote__head">
            <div>
              <div class="real-quote__title">
                <.cb_icon name="swap" size={14} /> Real 0x quote · Base mainnet
              </div>
              <div class="real-quote__sub">
                Read-only — fetches a live quote from the 0x Swap API on Base mainnet.
                No transaction is broadcast. Execution still stays on Base Sepolia.
              </div>
            </div>
            <button
              id="test-intent-preview-real"
              type="button"
              class="btn btn--secondary"
              phx-click="intent:preview_real_quote"
            >
              <.cb_icon name="play" size={14} />
              {if @real_quote_preview, do: "Refresh quote", else: "Fetch real quote"}
            </button>
          </div>
          <.real_quote_panel :if={@real_quote_preview} preview={@real_quote_preview} />
        </div>
      </div>
    </.card>
    """
  end

  attr :preview, :map, required: true

  defp real_quote_panel(%{preview: %{state: :ok}} = assigns) do
    ~H"""
    <div
      id="test-intent-real-quote-panel"
      class="real-quote__panel real-quote__panel--ok"
      data-state="ok"
    >
      <dl class="real-quote__dl">
        <div>
          <dt>Pair</dt>
          <dd data-field="pair">
            {@preview.route.source_asset} → {@preview.route.destination_asset}
          </dd>
        </div>
        <div>
          <dt>Input</dt>
          <dd class="mono tnum" data-field="input">
            {format_amount(@preview.route.input_amount)} {@preview.route.source_asset}
          </dd>
        </div>
        <div>
          <dt>Expected output</dt>
          <dd class="mono tnum" data-field="expected-output">
            {format_amount(@preview.route.expected_output_amount)} {@preview.route.destination_asset}
          </dd>
        </div>
        <div>
          <dt>Minimum output</dt>
          <dd class="mono tnum" data-field="minimum-output">
            {format_amount(@preview.route.minimum_output_amount)} {@preview.route.destination_asset}
          </dd>
        </div>
        <div>
          <dt>Slippage cap</dt>
          <dd data-field="slippage">{format_slippage(@preview.route.slippage_bps)}</dd>
        </div>
        <div>
          <dt>Route provider</dt>
          <dd data-field="provider">{@preview.route.route_provider}</dd>
        </div>
        <div>
          <dt>Chain</dt>
          <dd data-field="chain">{@preview.route.chain} ({@preview.route.chain_id})</dd>
        </div>
        <div>
          <dt>Quote timestamp</dt>
          <dd class="mono" data-field="quote-timestamp">
            {format_dt(@preview.route.quote_timestamp)}
          </dd>
        </div>
        <div>
          <dt>Deadline</dt>
          <dd class="mono" data-field="deadline">{format_dt(@preview.route.deadline)}</dd>
        </div>
        <div>
          <dt>Calldata</dt>
          <dd class="mono" data-field="calldata">
            {calldata_size(@preview.route.calldata)} bytes
          </dd>
        </div>
      </dl>
      <div class="real-quote__footer mono">
        Fetched {format_dt(@preview.fetched_at)} · preview only
      </div>
    </div>
    """
  end

  defp real_quote_panel(%{preview: %{state: :error}} = assigns) do
    ~H"""
    <div
      id="test-intent-real-quote-panel"
      class="real-quote__panel real-quote__panel--error"
      data-state="error"
    >
      <div class="real-quote__error">
        <.cb_icon name="warning" size={14} />
        <span>{quote_error_body(@preview.reason_code)}</span>
      </div>
      <div class="real-quote__footer mono">
        <span data-field="reason-code">{@preview.reason_code}</span>
        · fetched {format_dt(@preview.fetched_at)}
      </div>
    </div>
    """
  end

  defp format_amount(%Decimal{} = d) do
    d |> Decimal.normalize() |> Decimal.to_string(:normal)
  end

  defp format_amount(n) when is_integer(n) or is_float(n), do: to_string(n)
  defp format_amount(other), do: inspect(other)

  defp format_slippage(bps) when is_integer(bps) do
    pct = bps / 100
    "#{:erlang.float_to_binary(pct, decimals: 2)}% (#{bps} bps)"
  end

  defp format_slippage(_), do: "—"

  defp format_dt(%DateTime{} = dt),
    do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp format_dt(_), do: "—"

  defp calldata_size("0x" <> hex) when is_binary(hex), do: div(byte_size(hex), 2)
  defp calldata_size(bin) when is_binary(bin), do: div(byte_size(bin), 2)
  defp calldata_size(_), do: 0

  defp quote_error_body("preview:no_wallet_binding"),
    do: "Connect your wallet first — the preview needs an address to use as the 0x taker."

  defp quote_error_body("preview:missing_api_key"),
    do:
      "Server has no 0x API key configured. Export ZEROX_API_KEY in the shell " <>
        "where mix phx.server runs, then restart the server. " <>
        "Get a free key at dashboard.0x.org."

  defp quote_error_body("swap_route_resolver:missing_taker_address"),
    do: "No taker address available. Connect a wallet and try again."

  defp quote_error_body("swap_route_resolver:route_unavailable:" <> rest),
    do: "0x returned no usable quote (#{rest})."

  defp quote_error_body("swap_route_resolver:quote_request_build:" <> rest),
    do: "Could not build quote request: #{rest}."

  defp quote_error_body("swap_route_resolver:" <> rest),
    do: "Quote unavailable: #{rest}."

  defp quote_error_body(code), do: code

  attr :result, :map, required: true
  attr :details_open, :boolean, default: false
  attr :approve_allowed?, :boolean, default: false

  defp intent_result(assigns) do
    cfg = result_cfg(assigns.result)
    assigns = assign(assigns, :cfg, cfg)

    ~H"""
    <div
      id="test-intent-result"
      class={["intent-result", "intent-result--#{@cfg.kind}"]}
      data-state={@result.state}
    >
      <div class="intent-result__icon">
        <.cb_icon name={@cfg.icon} size={16} stroke={2.0} />
      </div>
      <div class="intent-result__main">
        <div id="test-intent-result-state" class="intent-result__title">
          {@cfg.title}
        </div>
        <div id="test-intent-result-reason" class="intent-result__body">
          {@cfg.body}
        </div>
        <div class="intent-result__meta mono">
          <span :if={@result[:tx_hash]}>tx {@result.tx_hash}</span>
          <button
            id="test-intent-view-details"
            type="button"
            class="link-mute"
            phx-click="intent:toggle_details"
          >
            <%= if @details_open do %>
              Hide details
            <% else %>
              View details
            <% end %>
            <.cb_icon name="chevron-right" size={11} />
          </button>
        </div>
        <div
          :if={@details_open}
          id="test-intent-details-panel"
          class="intent-result__details"
        >
          <dl class="intent-result__dl">
            <div>
              <dt>Final state</dt>
              <dd data-field="state">{@result.state}</dd>
            </div>
            <div :if={@result[:reason_code]}>
              <dt>Reason code</dt>
              <dd class="mono" data-field="reason-code">{@result.reason_code}</dd>
            </div>
            <div :if={@result[:reason]}>
              <dt>Reason</dt>
              <dd data-field="reason-message">{@result.reason}</dd>
            </div>
            <div :if={@result[:decision_envelope_id]}>
              <dt>Decision envelope</dt>
              <dd class="mono" data-field="decision-envelope">
                {@result.decision_envelope_id}
              </dd>
            </div>
            <div :if={@result[:execution_plan_id]}>
              <dt>Execution plan</dt>
              <dd class="mono" data-field="execution-plan">
                {@result.execution_plan_id}
              </dd>
            </div>
            <div :if={@result[:tx_hash]}>
              <dt>Transaction</dt>
              <dd class="mono" data-field="tx-hash">{@result.tx_hash}</dd>
            </div>
          </dl>
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

  # Operator-facing copy for the wallet-stale Run-lock banner. The Run
  # button is gated whenever `:wallet` is not `:connected`; this maps
  # each non-connected state to a short, actionable message.
  defp wallet_lock_copy(:browser_disconnected),
    do:
      "Your browser wallet stopped exposing the bound account. Reconnect it before running an intent."

  defp wallet_lock_copy(:wrong_chain),
    do:
      "Your wallet is on the wrong chain. Switch to Base Sepolia (84532) before running an intent."

  defp wallet_lock_copy(:account_mismatch),
    do:
      "Your wallet is exposing a different account than the bound one. Switch back or reconnect to rebind."

  defp wallet_lock_copy(:wrong_network),
    do:
      "Your wallet is on the wrong chain. Switch to Base Sepolia (84532) before running an intent."

  defp wallet_lock_copy(:connecting), do: "Waiting for your wallet to finish connecting…"
  defp wallet_lock_copy(_), do: "Connect your wallet to run a test intent."

  defp result_cfg(%{state: "executed", action: action}) do
    %{
      kind: "ok",
      icon: "check",
      title: "Intent executed",
      body: "#{action} settled on Base Sepolia. Funds remained inside permission scope."
    }
  end

  defp result_cfg(%{state: "blocked"} = result) do
    %{
      kind: "danger",
      icon: "x",
      title: "Intent blocked",
      body: blocked_body(result)
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

  # Spinner-timeout variant: the LiveView's 30s watchdog fired AND
  # the DB reconciliation came back empty, so the intent is genuinely
  # still in flight. A real decision/execution event arriving later
  # overwrites this state.
  defp result_cfg(%{state: "slow"}) do
    %{
      kind: "warn",
      icon: "info",
      title: "Still processing",
      body:
        "The agent is still working on this intent. Check Activity for the final outcome — or come back in a moment."
    }
  end

  # Approved-but-held variant: operator approval succeeded but
  # `Bank.Decisions.approve/2` returned `{:held, reason}`. Render
  # amber so the UI never implies success.
  defp result_cfg(%{state: "held"} = result) do
    %{
      kind: "warn",
      icon: "info",
      title: "Approved · dispatch held",
      body:
        result[:reason] ||
          "Dispatch is held. Check the Advanced screen's policy queue or runtime status."
    }
  end

  # Approved-and-dispatched variant: `Bank.Decisions.approve/2`
  # returned `{:dispatched, plan}`. The ExecutionPlan is queued and
  # the worker will broadcast `:execution_updated` later; until then
  # the operator sees an unambiguous "approval accepted, dispatch
  # in flight" copy WITHOUT the stale `Approve once` button (the
  # button only renders for `state: "needs-approval"`).
  defp result_cfg(%{state: "dispatching"}) do
    %{
      kind: "warn",
      icon: "info",
      title: "Approved · dispatching",
      body: "Approval accepted. Execution plan queued on Base Sepolia."
    }
  end

  # Honest body for a blocked outcome. Prefer the decision envelope's
  # first `reasons.items` entry; fall back to the reason code; then a
  # generic. The prior hardcoded "Slippage 1.4% exceeds your 0.5%
  # limit" copy was visible for unrelated blocks (e.g.
  # `policy_malformed_params`, `chain_not_allowed`) and confused
  # operators.
  defp blocked_body(%{reason: reason}) when is_binary(reason) and reason != "", do: reason

  defp blocked_body(%{reason_code: code}) when is_binary(code) and code != "" do
    "Blocked by policy (#{code}). Open details for the full reason."
  end

  defp blocked_body(_) do
    "The agent did not submit the transaction. Open details for the policy reason."
  end
end
