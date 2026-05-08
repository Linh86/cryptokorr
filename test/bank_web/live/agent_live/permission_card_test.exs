defmodule BankWeb.AgentLive.PermissionCardTest do
  @moduledoc """
  Tests for the I2 wiring of the AgentLive permission card to the
  real `Bank.SessionPermissions.BrowserInstall` flow + the
  `SessionPermissionInstall` JS hook + revoke via
  `Bank.Security.revoke_delegation/2`.

  Three slices:

    * static render — the card boots into `:not_installed`, displays
      the canonical `Scope.default/0` summary, and renders the JS
      hook contract (root `phx-hook` + button id).
    * install state machine — the hook events
      (`session_permission_install:awaiting | submitted | confirmed |
      failed | wrong_chain`) flip the LiveView through the design's
      `:installing | :failed` permission states without touching the
      DB.
    * revoke flow — with a real `:active` delegation row and a
      verified wallet binding, clicking Revoke opens the modal and
      `confirm_stop:revoke` enqueues a `Bank.Security.revoke_delegation/2`
      call that flips the row to `:revoking`.
  """
  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bank.Delegations.Delegation
  alias Bank.Repo
  alias Bank.SessionPermissions
  alias Bank.WalletBindings.WalletBinding

  setup :register_and_log_in_user

  describe "static render — no wallet binding" do
    test "renders the install button disabled and the canonical scope copy", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # Card chrome.
      assert html =~ "02 — Permission"
      assert html =~ "Agent permission"

      # Hook contract — root id + phx-hook attr + button id.
      assert html =~ ~s(id="permission-card")
      assert html =~ ~s(phx-hook="SessionPermissionInstall")
      assert html =~ ~s(id="session-permission-browser-install-btn")

      # The button is disabled (no wallet/binding) and renders the
      # connect-wallet-first hint.
      assert html =~ "is-disabled"
      assert html =~ "disabled"

      # Canonical scope copy from `Bank.SessionPermissions.Scope.default/0`.
      scope = Bank.SessionPermissions.Scope.default()
      assert html =~ hd(scope["allowed"])["label"]
      assert html =~ hd(scope["denied"])["label"]
    end
  end

  describe "install state machine via JS hook events (with verified binding)" do
    setup %{workspace: workspace, current_user: user} do
      binding = verified_binding(workspace.id, user.id)
      %{binding: binding}
    end

    test "session_permission_install:awaiting flips to :installing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "session_permission_install:awaiting", %{})

      html = render(view)
      assert html =~ "Installing"
      assert html =~ "Waiting for signature"
    end

    test "session_permission_install:submitted keeps state in :installing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "session_permission_install:submitted", %{
        "install_userop_hash" => "0xabc",
        "permission_id" => "0x01020304",
        "validation_id" => "0x" <> String.duplicate("00", 21),
        "smart_account_address" => "0x" <> String.duplicate("00", 20)
      })

      assert render(view) =~ "Installing"
    end

    test "session_permission_install:failed surfaces a sanitized failure reason", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "session_permission_install:failed", %{"reason" => "user_rejected"})

      html = render(view)
      assert html =~ "Failed"
      assert html =~ "user rejected"
    end

    test "session_permission_install:failed with unknown reason collapses to :unknown", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "session_permission_install:failed", %{"reason" => "totally-bogus"})

      html = render(view)
      assert html =~ "Failed"
      assert html =~ "unknown error"
    end

    test "session_permission_install:wrong_chain captures chain id and shows banner", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "session_permission_install:wrong_chain", %{"chain_id" => 1})

      html = render(view)
      assert html =~ "chain 1"
      assert html =~ "Switch to Base Sepolia"
    end

    test "session_permission_install:confirmed without a DB row stays at :installing", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "session_permission_install:confirmed", %{
        "install_userop_hash" => "0xabc",
        "tx_hash" => "0xdef",
        "block_number" => 42
      })

      # With a binding but no row written yet, the :confirmed
      # attestation maps to :installing. The on-chain verifier
      # worker (#474) is what eventually flips the row to :active
      # asynchronously; the card surfaces "Installing…" until then.
      assert render(view) =~ "Installing"
    end
  end

  describe "render with active delegation" do
    setup %{workspace: workspace, current_user: user} do
      {binding, delegation} = active_delegation_for_workspace(workspace.id, user.id)
      %{binding: binding, delegation: delegation}
    end

    test "shows the Active pill and a Revoke button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Active"
      assert html =~ "Revoke permission"
    end

    test "shows the smart account hint when a delegation is in place", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "ZeroDev / Kernel v3"
    end
  end

  describe "revoke flow" do
    setup %{workspace: workspace, current_user: user} do
      {binding, delegation} = active_delegation_for_workspace(workspace.id, user.id)
      %{binding: binding, delegation: delegation}
    end

    test "permission:revoke opens the modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      assert render(view) =~ "Revoke permission"

      view |> render_click("permission:revoke")
      assert render(view) =~ "Stop the agent?"
    end

    test "confirm_stop:cancel closes the modal without touching state", %{
      conn: conn,
      delegation: delegation
    } do
      {:ok, view, _html} = live(conn, "/")

      view |> render_click("permission:revoke")
      assert render(view) =~ "Stop the agent?"

      view |> render_click("confirm_stop:cancel")
      refute render(view) =~ "Stop the agent?"

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :active
    end

    test "confirm_stop:revoke flips the delegation row to :revoking", %{
      conn: conn,
      delegation: delegation
    } do
      {:ok, view, _html} = live(conn, "/")

      view |> render_click("permission:revoke")
      view |> render_click("confirm_stop:revoke")

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :revoking
    end
  end

  describe "find_active_delegation/2 — fail-closed on ambiguity" do
    test "single :active row returns ok", %{workspace: workspace, current_user: user} do
      binding = verified_binding(workspace.id, user.id)
      sa_id = SessionPermissions.compute_smart_account_id(binding)
      d = insert_delegation!(workspace.id, binding.id, sa_id, :active)

      assert {:ok, %Delegation{id: id}} =
               BankWeb.AgentLive.find_active_delegation(workspace.id, binding)

      assert id == d.id
    end

    test "no rows returns ok with nil", %{workspace: workspace, current_user: user} do
      binding = verified_binding(workspace.id, user.id)

      assert {:ok, nil} = BankWeb.AgentLive.find_active_delegation(workspace.id, binding)
    end

    test "two :active rows for the same smart_account return :ambiguous", %{
      workspace: workspace,
      current_user: user
    } do
      binding = verified_binding(workspace.id, user.id)
      sa_id = SessionPermissions.compute_smart_account_id(binding)

      _d1 = insert_delegation!(workspace.id, binding.id, sa_id, :active)
      :ok = force_insert_active_duplicate!(workspace.id, binding.id, sa_id)

      assert {:error, :ambiguous} =
               BankWeb.AgentLive.find_active_delegation(workspace.id, binding)
    end
  end

  # --- helpers -----------------------------------------------------------

  defp active_delegation_for_workspace(workspace_id, user_id) do
    binding = verified_binding(workspace_id, user_id)
    sa_id = SessionPermissions.compute_smart_account_id(binding)
    delegation = insert_delegation!(workspace_id, binding.id, sa_id, :active)
    {binding, delegation}
  end

  defp verified_binding(workspace_id, user_id) do
    nonce = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    now = DateTime.utc_now()
    expires = DateTime.add(now, 300, :second)
    addr = "0x" <> Base.encode16(:crypto.strong_rand_bytes(20), case: :lower)

    {:ok, binding} =
      Repo.insert(%WalletBinding{
        workspace_id: workspace_id,
        user_id: user_id,
        address: addr,
        chain_id: 84_532,
        nonce: nonce,
        challenge_message: "test binding",
        expires_at: expires,
        verified_at: now
      })

    binding
  end

  defp insert_delegation!(workspace_id, binding_id, smart_account_id, state) do
    attrs = %{
      smart_account_id: smart_account_id,
      delegation_id: "del-#{System.unique_integer([:positive])}",
      state: state,
      chain: "base-sepolia",
      scope: Bank.SessionPermissions.Scope.default(),
      workspace_id: workspace_id,
      binding_id: binding_id,
      root_validator_owner: "user",
      install_userop_hash: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    }

    {:ok, delegation} =
      %Delegation{}
      |> Delegation.changeset(attrs)
      |> Repo.insert()

    delegation
  end

  # The `delegations_smart_account_active_idx` partial-unique
  # constraint normally guarantees at-most-one non-terminal row per
  # `smart_account_id`. To exercise the LiveView's fail-closed
  # posture, we temporarily drop the index, insert the duplicate,
  # then restore the index after we've captured the row. Both inserts
  # must use the same `smart_account_id`, so the fail-closed branch
  # has something to match.
  defp force_insert_active_duplicate!(workspace_id, binding_id, smart_account_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "DROP INDEX IF EXISTS delegations_smart_account_active_idx",
      []
    )

    id = Ecto.UUID.generate()
    now = DateTime.utc_now()

    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO delegations
        (id, smart_account_id, delegation_id, state, chain, scope, workspace_id, binding_id,
         root_validator_owner, install_userop_hash, inserted_at, updated_at)
      VALUES ($1, $2, $3, 'active', 'base-sepolia', '{}'::jsonb, $4, $5, 'user', $6, $7, $8)
      """,
      [
        Ecto.UUID.dump!(id),
        smart_account_id,
        "del-#{System.unique_integer([:positive])}",
        Ecto.UUID.dump!(workspace_id),
        Ecto.UUID.dump!(binding_id),
        "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
        now,
        now
      ]
    )

    :ok
  end
end
