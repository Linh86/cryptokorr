defmodule BankWeb.AgentLive.PermissionCard do
  @moduledoc """
  Section 2 — Agent permission. Render-only function component.

  All state lives in `BankWeb.AgentLive`. Events fire on the parent.

  Phase 2 will:
  - Add `phx-hook="SessionPermissionInstall"` to the card root
  - Use `Bank.SessionPermissions.BrowserInstall.{build_envelope/2,
    record_attestation/3, status/2}` in the parent's handle_event
  - Read scope from `Bank.SessionPermissions.Scope.default/0`
  - Source datarows from the latest delegation row + binding
  - Wire revoke through `Bank.Security.revoke_delegation/2`
  """
  use Phoenix.Component

  import BankWeb.AgentComponents

  attr :wallet, :atom, required: true
  attr :permission, :atom,
    required: true,
    doc: ":not_installed | :installing | :active | :revoked | :expired | :failed"

  def permission_card(assigns) do
    ~H"""
    <.card>
      <.card_header eyebrow="02 — Permission" title="Agent permission">
        <:right>
          <.status_pill kind={pill_kind(@permission)} />
        </:right>
      </.card_header>
      <div class="card__body">
        <.banner :if={@permission == :expired} kind="warn">
          The previous permission expired. Reinstall to bring the agent back online.
        </.banner>
        <.banner :if={@permission == :failed} kind="danger">
          Last install failed: user rejected signature. No permission is in place.
        </.banner>
        <.banner :if={@permission == :revoked} kind="info">
          You revoked the permission. The agent cannot move funds. Reinstall when ready.
        </.banner>
        <.scope_list />
        <div :if={show_install?(@permission)} class="card__actions">
          <button
            type="button"
            class={["btn btn--primary", @wallet != :connected && "is-disabled"]}
            disabled={@wallet != :connected}
            phx-click="permission:install"
            title={
              if(@wallet == :connected, do: "Install permission", else: "Connect wallet first")
            }
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
        <div :if={@permission == :active} class="card__body--rows" style="margin-top: 6px;">
          <.data_row label="Installed">Today, 14:02 · expires in 7 days</.data_row>
          <.data_row label="Smart account">
            <span class="mono">0xKern…91ae</span>
            <span class="hint">ZeroDev / Kernel v3</span>
          </.data_row>
          <.data_row label="Session limit">
            <span class="mono tnum">100.00 USDC</span>
            · daily <span class="mono tnum">500.00 USDC</span>
          </.data_row>
          <div class="card__actions" style="padding-top: 12px;">
            <button type="button" class="btn btn--ghost-danger" phx-click="permission:revoke">
              <.cb_icon name="stop" size={14} /> Revoke permission
            </button>
          </div>
        </div>
      </div>
    </.card>
    """
  end

  defp show_install?(p) when p in [:not_installed, :revoked, :expired, :failed], do: true
  defp show_install?(_), do: false

  defp pill_kind(:not_installed), do: "not-installed"
  defp pill_kind(other), do: Atom.to_string(other) |> String.replace("_", "-")
end
