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

  def permission_card(assigns) do
    ~H"""
    <div id="permission-card" phx-hook="SessionPermissionInstall">
      <.card>
        <.card_header eyebrow="02 — Permission" title="Agent permission">
          <:right>
            <.status_pill kind={pill_kind(@permission)} />
          </:right>
        </.card_header>
        <div class="card__body">
          <.banner :if={@ambiguous?} kind="danger">
            Permission state is ambiguous. Contact ops via Advanced.
          </.banner>
          <.banner :if={@permission == :expired} kind="warn">
            The previous permission expired. Reinstall to bring the agent back online.
          </.banner>
          <.banner :if={@permission == :failed and @install_failure_reason != nil} kind="danger">
            Last install failed: {failure_reason_label(@install_failure_reason)}. No permission is in place.
          </.banner>
          <.banner :if={@permission == :failed and @install_failure_reason == nil} kind="danger">
            Last install failed. No permission is in place.
          </.banner>
          <.banner :if={@wrong_chain_id != nil} kind="warn">
            Wallet is on chain {@wrong_chain_id}. Switch to Base Sepolia (84532) and retry.
          </.banner>
          <.banner :if={@permission == :revoked} kind="info">
            You revoked the permission. The agent cannot move funds. Reinstall when ready.
          </.banner>
          <.scope_list />
          <div :if={show_install?(@permission, @ambiguous?)} class="card__actions">
            <button
              type="button"
              id="session-permission-browser-install-btn"
              data-binding-id={binding_id(@binding)}
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
          <div :if={@permission == :installing} class="card__actions">
            <div class="installing-row">
              <div class="spinner"></div>
              <span>Waiting for signature in your wallet…</span>
            </div>
          </div>
          <div :if={@permission == :active and is_struct(@delegation, Delegation)} class="card__body--rows" style="margin-top: 6px;">
            <.data_row label="Installed">{installed_at_label(@delegation)}</.data_row>
            <.data_row label="Smart account">
              <span class="mono">{short_smart_account(@delegation)}</span>
              <span class="hint">ZeroDev / Kernel v3</span>
            </.data_row>
            <.data_row :if={session_limit_label(@delegation) != nil} label="Session limit">
              <span class="mono tnum">{session_limit_label(@delegation)}</span>
            </.data_row>
            <div class="card__actions" style="padding-top: 12px;">
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

  defp show_install?(_p, true), do: false
  defp show_install?(p, _ambiguous?) when p in [:not_installed, :revoked, :expired, :failed], do: true
  defp show_install?(_p, _), do: false

  defp pill_kind(:not_installed), do: "not-installed"
  defp pill_kind(other), do: Atom.to_string(other) |> String.replace("_", "-")

  defp install_disabled?(wallet, binding) do
    wallet != :connected or not is_struct(binding, WalletBinding)
  end

  defp install_button_title(:connected, %WalletBinding{}), do: "Install permission"
  defp install_button_title(:connected, _), do: "Verify wallet binding first"
  defp install_button_title(_, _), do: "Connect wallet first"

  defp binding_id(%WalletBinding{id: id}) when is_binary(id), do: id
  defp binding_id(_), do: nil

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

  defp failure_reason_label(:user_rejected), do: "user rejected signature"
  defp failure_reason_label(:bundler_rejected), do: "bundler rejected the userop"
  defp failure_reason_label(:bundler_unavailable), do: "bundler unavailable"
  defp failure_reason_label(:chain_id_mismatch), do: "wallet on wrong chain"
  defp failure_reason_label(:insufficient_funds), do: "insufficient funds for gas"
  defp failure_reason_label(:userop_reverted), do: "userop reverted on-chain"
  defp failure_reason_label(:attestation_timeout), do: "attestation timed out"
  defp failure_reason_label(:unknown), do: "unknown error"
  defp failure_reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason_label(reason) when is_binary(reason), do: reason
  defp failure_reason_label(_), do: "unknown error"
end
