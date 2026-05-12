defmodule BankWeb.AgentLive.PermissionCard do
  @moduledoc """
  Section 2 — Agent permission. Render-only function component.

  All state lives in `BankWeb.AgentLive`. Events fire on the parent.

  Phase 2: card root carries `phx-hook="SessionPermissionInstall"` so
  the install button click is intercepted by the JS hook (#473), which
  fetches the canonical envelope, drives the ZeroDev SDK, and reports
  attestations back to Phoenix. The parent translates the
  hook + delegation + binding state into the design's permission
  enum via `permission_state/3`.
  """
  use Phoenix.Component

  import BankWeb.AgentComponents

  alias Bank.Delegations.Delegation
  alias Bank.WalletBindings.WalletBinding

  attr :wallet, :atom, required: true

  attr :permission, :atom,
    required: true,
    doc: ":not_installed | :installing | :active | :revoked | :expired | :failed"

  attr :binding, :any, default: nil, doc: "%WalletBinding{} or nil"
  attr :delegation, :any, default: nil, doc: "%Delegation{} or nil or :ambiguous"
  attr :ambiguous?, :boolean, default: false
  attr :install_failure_reason, :any, default: nil
  attr :wrong_chain_id, :any, default: nil

  attr :permission_outdated?, :boolean,
    default: false,
    doc:
      "true iff a policy expansion publish has landed since this delegation's granted_at; surfaces the reinstall-required banner + pill"

  def permission_card(assigns) do
    ~H"""
    <div id="permission-card" phx-hook="SessionPermissionInstall">
      <.card>
        <.card_header eyebrow="02 — Permission" title="Agent permission">
          <:right>
            <.status_pill kind={pill_kind(@permission, @permission_outdated?)} />
          </:right>
        </.card_header>
        <div class="card__body">
          <.banner
            :if={@permission_outdated? and @permission == :active}
            kind="warn"
          >
            <span id="permission-card-outdated-banner">
              Policy was expanded after this permission was installed.
              Reinstall the permission before running the agent — runtime
              will block new intents until you do.
            </span>
          </.banner>
          <.banner :if={@ambiguous?} kind="danger">
            Permission state is ambiguous. Contact ops via Advanced.
          </.banner>
          <.banner :if={@permission == :expired} kind="warn">
            The previous permission expired. Reinstall to bring the agent back online.
          </.banner>
          <.banner :if={@permission == :failed and revoke_failed?(@delegation)} kind="danger">
            Revoke failed: {revoke_failure_reason(@delegation)}. The on-chain permission may still be live — retry revoke is available.
          </.banner>
          <.banner
            :if={
              @permission == :failed and not revoke_failed?(@delegation) and
                @install_failure_reason != nil
            }
            kind="danger"
          >
            Last install failed: {failure_reason_label(@install_failure_reason)}. No permission is in place.
          </.banner>
          <.banner
            :if={
              @permission == :failed and not revoke_failed?(@delegation) and
                @install_failure_reason == nil
            }
            kind="danger"
          >
            Last install failed. No permission is in place.
          </.banner>
          <.banner :if={@wrong_chain_id != nil} kind="warn">
            Wallet is on chain {@wrong_chain_id}. Switch to Base Sepolia (84532) and retry.
          </.banner>
          <.banner :if={@permission == :revoked} kind="info">
            You revoked the permission. The agent cannot move funds. Reinstall when ready.
          </.banner>
          <.scope_list />
          <%!-- Inline Retry revoke CTA (P5 follow-up). The :revoke_failed
          state means the on-chain permission may still be live, so the
          operator MUST be able to retry the revoke. We surface the same
          revoke flow here, in addition to the topbar Stop button, so the
          retry CTA is visible alongside the failure banner. The
          confirm-stop modal that the topbar Stop opens is the single
          source of truth for the revoke event itself; clicking this
          button just opens that modal via the existing
          `permission:revoke` event. --%>
          <div :if={revoke_failed?(@delegation)} class="card__actions">
            <button
              type="button"
              id="session-permission-retry-revoke-btn"
              class="btn btn--ghost-danger"
              phx-click="permission:revoke"
            >
              <.cb_icon name="stop" size={14} /> Retry revoke
            </button>
            <span class="hint">
              Re-submits the revoke userop. State will reflect the on-chain outcome.
            </span>
          </div>
          <div :if={show_install?(@permission, @ambiguous?, @delegation)} class="card__actions">
            <button
              type="button"
              id="session-permission-browser-install-btn"
              data-binding-id={binding_id(@binding)}
              data-bound-address={binding_address(@binding)}
              class={["btn btn--primary", install_disabled?(@wallet, @binding) && "is-disabled"]}
              disabled={install_disabled?(@wallet, @binding)}
              phx-click="permission:install"
              title={install_button_title(@wallet, @binding)}
            >
              <.cb_icon name="lock" size={14} /> Install permission
            </button>
            <span class="hint">
              You'll sign one EIP-712 message · permission is stored on-chain
            </span>
          </div>
          <%!-- The design enum collapses both `:pending` (install in
          flight, browser must sign a UserOp) and `:revoking` (sentinel
          revoke in flight, server-side, no wallet signature required)
          into the `:installing` chip colour. The CARD COPY has to
          distinguish: revoke is a server-driven operation
          (`Bank.Runtime.Workers.RevokeDelegation`), the wallet does
          NOT have to sign anything. Branch on the raw delegation
          state so the operator sees the right hint. --%>
          <div
            :if={@permission == :installing and revoking?(@delegation)}
            class="card__actions"
          >
            <div class="installing-row">
              <div class="spinner"></div>
              <span>Revoking agent permission on-chain… no wallet signature needed.</span>
            </div>
          </div>
          <div
            :if={@permission == :installing and not revoking?(@delegation)}
            class="card__actions"
          >
            <div class="installing-row">
              <div class="spinner"></div>
              <span>Waiting for signature in your wallet…</span>
            </div>
          </div>
          <div
            :if={@permission == :active and is_struct(@delegation, Delegation)}
            class="card__body--rows"
            style="margin-top: 6px;"
          >
            <.data_row label="Installed">{installed_at_label(@delegation)}</.data_row>
            <.data_row label="Smart account">
              <span class="mono">{short_smart_account(@delegation)}</span>
              <span class="hint">ZeroDev / Kernel v3</span>
            </.data_row>
            <.data_row :if={session_limit_label(@delegation) != nil} label="Session limit">
              <span class="mono tnum">{session_limit_label(@delegation)}</span>
            </.data_row>
            <%!-- The browser-signed scope_snapshot doesn't yet carry
            numeric caps; they live on policy rules and are enforced
            by the runtime decision pipeline at dispatch time. Surface
            that explicitly so the operator knows where the gates are. --%>
            <.data_row :if={session_limit_label(@delegation) == nil} label="Limits">
              <span class="hint">
                Enforced per policy
              </span>
            </.data_row>
            <div class="card__actions" style="padding-top: 12px;">
              <%!-- When permission is outdated, the canonical recovery
              action is "revoke + reinstall". We surface a Reinstall CTA
              that opens the same confirm-stop modal as Revoke; the
              hint copy tells the operator they'll need to re-grant
              after the revoke confirms. --%>
              <button
                :if={@permission_outdated?}
                id="permission-card-reinstall-btn"
                type="button"
                class="btn btn--warn"
                phx-click="permission:revoke"
                title="Revoke now; reinstall after the chain confirms"
              >
                <.cb_icon name="lock" size={14} /> Reinstall permission
              </button>
              <button type="button" class="btn btn--ghost-danger" phx-click="permission:revoke">
                <.cb_icon name="stop" size={14} /> Revoke permission
              </button>
            </div>
          </div>
        </div>
      </.card>
    </div>
    """
  end

  # `Install permission` is the primary CTA for terminal "no live
  # delegation" states. `:revoke_failed` is explicitly NOT one of
  # them — the on-chain permission may still be live, so installing
  # a fresh delegation on top of it would be misleading. Operator
  # must clear the existing one first via Retry revoke.
  defp show_install?(_p, true, _delegation), do: false
  defp show_install?(_p, _ambiguous?, %Delegation{state: :revoke_failed}), do: false

  defp show_install?(p, _ambiguous?, _delegation)
       when p in [:not_installed, :revoked, :expired, :failed],
       do: true

  defp show_install?(_p, _, _), do: false

  # The `:active` pill flips to "Reinstall required" when the
  # permission is outdated; without this, the chip would read
  # "Active" while the runtime is silently blocking dispatch.
  defp pill_kind(:active, true), do: "reinstall-required"
  defp pill_kind(state, _outdated?), do: pill_kind(state)

  defp pill_kind(:not_installed), do: "not-installed"
  defp pill_kind(other), do: Atom.to_string(other) |> String.replace("_", "-")

  defp install_disabled?(wallet, binding) do
    wallet != :connected or not is_struct(binding, WalletBinding)
  end

  defp install_button_title(:connected, %WalletBinding{}), do: "Install permission"
  defp install_button_title(:connected, _), do: "Verify wallet binding first"

  defp install_button_title(:browser_disconnected, _),
    do: "Reconnect your wallet — it stopped exposing the bound account for this site"

  defp install_button_title(:wrong_chain, _),
    do: "Switch your wallet to Base Sepolia (chain 84532)"

  defp install_button_title(:account_mismatch, _),
    do: "Wallet is exposing a different account than the bound one"

  defp install_button_title(:wrong_network, _),
    do: "Switch your wallet to Base Sepolia (chain 84532)"

  defp install_button_title(:connecting, _),
    do: "Waiting for wallet connection…"

  defp install_button_title(_, _), do: "Connect wallet first"

  defp binding_id(%WalletBinding{id: id}) when is_binary(id), do: id
  defp binding_id(_), do: nil

  # EOA address bound to this workspace, rendered onto the install
  # button so the JS hook's passive `eth_accounts` preflight can
  # confirm the browser is exposing the SAME account before any
  # envelope fetch / EIP-712 sign / bundler submit fires.
  defp binding_address(%WalletBinding{address: address}) when is_binary(address), do: address
  defp binding_address(_), do: nil

  defp installed_at_label(%Delegation{installed_at_block: block, inserted_at: %_{} = at})
       when is_integer(block) do
    "#{format_dt(at)} · block #{block}"
  end

  defp installed_at_label(%Delegation{inserted_at: %_{} = at}) do
    format_dt(at)
  end

  defp installed_at_label(_), do: "—"

  defp format_dt(%NaiveDateTime{} = dt) do
    dt |> NaiveDateTime.to_iso8601()
  end

  defp format_dt(%DateTime{} = dt) do
    dt |> DateTime.to_iso8601()
  end

  defp format_dt(_), do: "—"

  defp short_smart_account(%Delegation{smart_account_id: id}) when is_binary(id) do
    if String.length(id) > 16 do
      head = String.slice(id, 0, 8)
      tail = String.slice(id, -6, 6)
      head <> "…" <> tail
    else
      id
    end
  end

  defp short_smart_account(_), do: "—"

  # Pulls "session_limit" out of the persisted scope JSON if present.
  # The MVP scope summary doesn't yet carry numeric limits (those live
  # on policy rules, enforced by the runtime gate), so this is `nil`
  # for now. Kept as a single seam so the row is easy to populate when
  # the scope schema grows numeric caps.
  defp session_limit_label(%Delegation{scope: %{} = scope}) do
    case Map.get(scope, "session_limit") || Map.get(scope, :session_limit) do
      nil -> nil
      val when is_binary(val) -> val
      val when is_number(val) -> "#{val} USDC"
      _ -> nil
    end
  end

  defp session_limit_label(_), do: nil

  defp revoke_failed?(%Delegation{state: :revoke_failed}), do: true
  defp revoke_failed?(_), do: false

  # Raw-state check the card uses to pick the right copy under
  # `permission == :installing` (which the design enum reuses for the
  # `:revoking` transition). Without this branch the revoke flow would
  # show "Waiting for signature in your wallet…" — incorrect for the
  # sentinel revoke path, which is server-driven.
  defp revoking?(%Delegation{state: :revoking}), do: true
  defp revoking?(_), do: false

  defp revoke_failure_reason(%Delegation{last_reason: nil}), do: "unknown"
  defp revoke_failure_reason(%Delegation{last_reason: reason}) when is_binary(reason), do: reason
  defp revoke_failure_reason(_), do: "unknown"

  defp failure_reason_label(:user_rejected), do: "user rejected signature"
  defp failure_reason_label(:bundler_rejected), do: "bundler rejected the userop"

  # Phoenix issued an envelope with `bundler_rpc_url: nil`. The env
  # vars are missing on the server. This is the only case where
  # asking the operator to set env vars makes sense.
  defp failure_reason_label(:bundler_not_configured),
    do:
      "no bundler URL in install envelope — set BASE_SEPOLIA_BUNDLER_RPC, BUNDLER_URL, or BUNDLER_RPC_URL in the dev env"

  # Phoenix issued an envelope WITH a bundler URL, but the browser
  # couldn't reach it: CORS rejection (most common — ZeroDev's hosted
  # bundler blocks origins not in the project's allowlist), DNS,
  # network timeout, HTTP 5xx, or `Failed to fetch`. The env is fine;
  # the URL just isn't browser-reachable from this origin.
  defp failure_reason_label(:bundler_unavailable),
    do:
      "bundler rejected the browser request (CORS / network / 5xx). " <>
        "Check that the bundler URL accepts requests from this origin — " <>
        "add localhost:4000 to the ZeroDev project's allowed origins, or " <>
        "switch to a CORS-friendly bundler like Pimlico."

  defp failure_reason_label(:chain_id_mismatch), do: "wallet on wrong chain"
  defp failure_reason_label(:insufficient_funds), do: "insufficient funds for gas"
  defp failure_reason_label(:userop_reverted), do: "userop reverted on-chain"
  defp failure_reason_label(:attestation_timeout), do: "attestation timed out"

  defp failure_reason_label(:wallet_not_connected),
    do: "browser wallet not connected — reconnect and retry"

  defp failure_reason_label(:account_mismatch),
    do: "wallet exposed a different account than the bound one"

  # The connected user EOA equals `OPERATOR_ADDRESS` AND the
  # browser kernel index equals the operator's. The derived smart
  # account would be the already-deployed operator one, and the
  # install UserOp would revert with Kernel's `InvalidSignature()`
  # because the existing account state can't accept a fresh enable
  # signature. The structural fix is to raise
  # `BROWSER_KERNEL_ACCOUNT_INDEX` (default 1) above the operator
  # index, OR connect a different wallet.
  defp failure_reason_label(:kernel_account_collision),
    do:
      "this wallet would target the operator smart account. " <>
        "Use browser kernel index 1 (or higher) or choose another wallet."

  # Adapter is unreachable / 5xx — Phoenix could not get the
  # session-validator signature. Retryable. Distinct from
  # `bundler_unavailable` so the operator copy points at the
  # right service.
  defp failure_reason_label(:session_signer_unavailable),
    do:
      "the operator session signer is unreachable. " <>
        "Confirm chain_adapter is running on :4100 and retry."

  # Adapter explicitly refused (4xx) — usually a mismatched
  # session signer address between Phoenix envelope and adapter
  # `DELEGATION_SIGNER_KEY`. NOT retryable until the operator
  # fixes the misconfiguration.
  defp failure_reason_label(:session_signer_refused),
    do:
      "the operator session signer refused this install request " <>
        "(usually a SESSION_SIGNER_ADDRESS / DELEGATION_SIGNER_KEY mismatch)."

  defp failure_reason_label(:unknown), do: "unknown error"
  defp failure_reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason_label(reason) when is_binary(reason), do: reason
  defp failure_reason_label(_), do: "unknown error"
end
