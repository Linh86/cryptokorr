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

  describe "DB-truth gating — UI never advances past :installing without a :active delegation row" do
    setup %{workspace: workspace, current_user: user} do
      binding = verified_binding(workspace.id, user.id)
      %{binding: binding}
    end

    test ":confirmed event with a :pending delegation row keeps permission at :installing", %{
      conn: conn,
      workspace: workspace,
      binding: binding
    } do
      sa_id = SessionPermissions.compute_smart_account_id(binding)
      _pending = insert_delegation!(workspace.id, binding.id, sa_id, :pending)

      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "session_permission_install:confirmed", %{
        "install_userop_hash" => "0xabc",
        "tx_hash" => "0xdef",
        "block_number" => 42
      })

      html = render(view)
      assert html =~ "Installing"
      # The Active pill must NOT render — that's the lie we're guarding
      # against. Match the data-row label with class="hint" to avoid
      # collision with "Active" inside any narrative copy.
      refute html =~ ~s(class="status status--active)
    end

    test ":confirmed → DB flips to :active → poll picks it up and renders Active", %{
      conn: conn,
      workspace: workspace,
      binding: binding
    } do
      sa_id = SessionPermissions.compute_smart_account_id(binding)
      pending = insert_delegation!(workspace.id, binding.id, sa_id, :pending)

      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "session_permission_install:confirmed", %{
        "install_userop_hash" => "0xabc",
        "tx_hash" => "0xdef",
        "block_number" => 42
      })

      # Still :installing — the row is :pending in the DB.
      assert render(view) =~ "Installing"

      # The on-chain verifier worker would normally flip this row;
      # we simulate the flip by direct DB update, then send the next
      # poll message and expect the LiveView to re-read and render
      # the Active pill.
      {:ok, _updated} =
        pending
        |> Ecto.Changeset.change(state: :active)
        |> Repo.update()

      send(view.pid, {:poll_install_status, 0})

      html = render(view)
      assert html =~ "Active"
      assert html =~ "Revoke permission"
    end

    test ":confirmed schedules a poll only when permission != :active", %{
      conn: conn,
      workspace: workspace,
      binding: binding
    } do
      # Pre-create an :active row so `recompute_permission/1` lands
      # on :active immediately on the :confirmed event. The handler
      # should detect that and NOT schedule a poll.
      sa_id = SessionPermissions.compute_smart_account_id(binding)
      _active = insert_delegation!(workspace.id, binding.id, sa_id, :active)

      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "session_permission_install:confirmed", %{
        "install_userop_hash" => "0xabc",
        "tx_hash" => "0xdef",
        "block_number" => 42
      })

      assert render(view) =~ "Active"

      # No poll should be in the mailbox — the :active short-circuit
      # in `handle_event` skipped the `Process.send_after/3` call.
      refute_received {:poll_install_status, _}
      {:messages, msgs} = :erlang.process_info(view.pid, :messages)

      refute Enum.any?(msgs, fn
               {:poll_install_status, _} -> true
               _ -> false
             end),
             "expected no :poll_install_status messages in the LiveView mailbox after a :confirmed that lands on :active"
    end

    test ":poll_install_status with a non-:active delegation does not lift permission to :active",
         %{
           conn: conn,
           workspace: workspace,
           binding: binding
         } do
      # `:revoking` is non-terminal so it shows up in
      # `Delegations.list_active/1`, but it's not `:active`. The
      # poll handler must NOT misread a `:revoking` row as a
      # successful install.
      sa_id = SessionPermissions.compute_smart_account_id(binding)
      _revoking = insert_delegation!(workspace.id, binding.id, sa_id, :revoking)

      {:ok, view, _html} = live(conn, "/")

      send(view.pid, {:poll_install_status, 0})

      html = render(view)
      # The Active pill must not render.
      refute html =~ ~s(class="status status--active)
      # And the active-delegation card body must not render either.
      refute html =~ "ZeroDev / Kernel v3"
    end

    test ":poll_install_status at terminal attempt does not schedule another", %{
      conn: conn,
      workspace: workspace,
      binding: binding
    } do
      sa_id = SessionPermissions.compute_smart_account_id(binding)
      _pending = insert_delegation!(workspace.id, binding.id, sa_id, :pending)

      {:ok, view, _html} = live(conn, "/")

      # Fire the final attempt directly — the LiveView should NOT
      # schedule attempt 6.
      send(view.pid, {:poll_install_status, 5})
      # Force a render to ensure the message has been processed.
      _ = render(view)

      # No follow-up poll message should be queued.
      {:messages, msgs} = :erlang.process_info(view.pid, :messages)

      refute Enum.any?(msgs, fn
               {:poll_install_status, _} -> true
               _ -> false
             end),
             "expected no further :poll_install_status messages after the terminal attempt; got: #{inspect(msgs)}"
    end

    test "install_poll_delay_ms/1 returns exponential backoff capped at @install_poll_max_ms" do
      # 2_000 * 2^attempt, clamped at 32_000.
      assert BankWeb.AgentLive.install_poll_delay_ms(0) == 2_000
      assert BankWeb.AgentLive.install_poll_delay_ms(1) == 4_000
      assert BankWeb.AgentLive.install_poll_delay_ms(2) == 8_000
      assert BankWeb.AgentLive.install_poll_delay_ms(3) == 16_000
      assert BankWeb.AgentLive.install_poll_delay_ms(4) == 32_000
      assert BankWeb.AgentLive.install_poll_delay_ms(5) == 32_000
      assert BankWeb.AgentLive.install_poll_delay_ms(8) == 32_000
    end
  end

  describe "session_permission_install:failed — every BrowserInstall.failure_categories/0 atom" do
    setup %{workspace: workspace, current_user: user} do
      binding = verified_binding(workspace.id, user.id)
      %{binding: binding}
    end

    test "every published failure category atom flips :permission to :failed and renders the banner",
         %{conn: conn} do
      reasons = Bank.SessionPermissions.BrowserInstall.failure_categories()

      for reason <- reasons do
        {:ok, view, _html} = live(conn, "/")

        render_hook(view, "session_permission_install:failed", %{
          "reason" => Atom.to_string(reason)
        })

        html = render(view)

        assert html =~ "Failed",
               "expected the Failed pill for reason #{inspect(reason)}; got: #{html}"

        assert html =~ "No permission is in place",
               "expected the failure banner for reason #{inspect(reason)}"
      end
    end

    test ":bundler_not_configured renders the env-var copy", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "session_permission_install:failed", %{
        "reason" => "bundler_not_configured"
      })

      html = render(view)

      # The env-var copy is appropriate ONLY when the envelope arrived
      # without a bundler URL — i.e. Phoenix could not find one in any
      # of the recognised env vars. Telling the operator to set env
      # vars when the URL IS set but the browser couldn't reach it
      # (CORS) is what landed us in this fix.
      assert html =~ "no bundler URL in install envelope"
      assert html =~ "BASE_SEPOLIA_BUNDLER_RPC"
      assert html =~ "BUNDLER_URL"
      assert html =~ "BUNDLER_RPC_URL"
    end

    test ":bundler_unavailable renders the CORS / network copy, NOT the env-var copy",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "session_permission_install:failed", %{
        "reason" => "bundler_unavailable"
      })

      html = render(view)

      # Positive: the copy must point the operator at the actual root
      # cause — bundler-side rejection (CORS allowlist, network
      # failure, 5xx). It must mention CORS so they know to add the
      # origin to ZeroDev / Pimlico instead of fiddling with env vars.
      assert html =~ "CORS",
             "bundler_unavailable copy must mention CORS as the most common cause"

      assert html =~ "Pimlico" or html =~ "ZeroDev",
             "bundler_unavailable copy must suggest a concrete remediation"

      # Negative regression: this is the bug we just fixed. The
      # env-var copy belongs on `bundler_not_configured` ONLY. Asking
      # the operator to set env vars that ARE already set wastes time
      # and obscures the real CORS issue.
      refute html =~ "set BASE_SEPOLIA_BUNDLER_RPC",
             "bundler_unavailable must NOT tell the operator to set env vars — that copy belongs on :bundler_not_configured"
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

  # The agent_alpha live_session already gates mount on `:operator`+,
  # so a viewer can't reach the page through the router. But
  # `GlobalState.revoke/1` is also called inline by AgentActivityLive
  # and AgentAdvancedLive's `confirm_stop:revoke` handlers, and a
  # future routing change or a manually-pushed event must not
  # escalate a viewer-tier socket into a delegation revoke. The gate
  # inside `revoke/1` is defense-in-depth.
  describe "GlobalState.revoke/1 — operator gate (P5 fail-closed)" do
    test "viewer-role socket is refused with a flash and the delegation row is unchanged",
         %{workspace: workspace, current_user: user} do
      {_binding, delegation} = active_delegation_for_workspace(workspace.id, user.id)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          delegation: delegation,
          current_scope: %{user: user, workspace: workspace, role: :viewer},
          stop_open: true
        }
      }

      result = BankWeb.AgentLive.GlobalState.revoke(socket)

      # Flash carries the role-required copy.
      assert get_in(result.assigns, [:flash, "error"]) =~ "Operator role required"
      # Stop modal is force-closed.
      assert result.assigns.stop_open == false

      # The delegation row is not touched.
      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :active
    end

    test "operator-role socket proceeds and flips the delegation row to :revoking",
         %{workspace: workspace, current_user: user} do
      {_binding, delegation} = active_delegation_for_workspace(workspace.id, user.id)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          delegation: delegation,
          current_scope: %{user: user, workspace: workspace, role: :operator},
          stop_open: true,
          # GlobalState.refresh/1 is called on success; it expects
          # these assigns to be readable.
          wallet_binding: nil,
          wallet: :disconnected,
          address: nil,
          permission: :active
        }
      }

      _result = BankWeb.AgentLive.GlobalState.revoke(socket)

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :revoking
    end
  end

  # `:revoke_failed` is a special-case trust surface. The on-chain
  # delegation may still be live, so:
  #   * Banner must be explicit that the permission may still be live.
  #   * Stop / Retry revoke must STAY enabled so the operator can
  #     retry the revoke userop.
  #   * Install permission must NOT show as a primary CTA — installing
  #     fresh while the prior delegation is still live is misleading.
  #   * intent:run remains a no-op (covered in the dedicated suite
  #     below).
  describe "permission card :revoke_failed (retry trust surface)" do
    test "renders the danger banner with the persisted last_reason", %{
      conn: conn,
      workspace: workspace,
      current_user: user
    } do
      binding = verified_binding(workspace.id, user.id)
      sa_id = SessionPermissions.compute_smart_account_id(binding)

      _ =
        insert_delegation_with_attrs!(workspace.id, binding.id, sa_id, %{
          state: :revoke_failed,
          last_reason: "bundler unavailable"
        })

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Revoke failed: bundler unavailable"
      assert html =~ "on-chain permission may still be live"
      assert html =~ "retry revoke is available"
      # The install-failed banner must NOT also render — they're
      # mutually exclusive once the row is :revoke_failed.
      refute html =~ "Last install failed"
    end

    test "falls back to \"unknown\" when last_reason is nil", %{
      conn: conn,
      workspace: workspace,
      current_user: user
    } do
      binding = verified_binding(workspace.id, user.id)
      sa_id = SessionPermissions.compute_smart_account_id(binding)

      _ =
        insert_delegation_with_attrs!(workspace.id, binding.id, sa_id, %{
          state: :revoke_failed,
          last_reason: nil
        })

      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Revoke failed: unknown"
    end

    test "does NOT render the Install permission CTA — old delegation may still be live",
         %{
           conn: conn,
           workspace: workspace,
           current_user: user
         } do
      binding = verified_binding(workspace.id, user.id)
      sa_id = SessionPermissions.compute_smart_account_id(binding)

      _ =
        insert_delegation_with_attrs!(workspace.id, binding.id, sa_id, %{
          state: :revoke_failed,
          last_reason: "bundler unavailable"
        })

      {:ok, _view, html} = live(conn, "/")

      # The install-button id is the only deterministic anchor (every
      # other failure variant of the card DOES render this button).
      refute html =~ ~s(id="session-permission-browser-install-btn")
      refute html =~ "Install permission"
    end

    test "renders the inline Retry revoke CTA wired to the existing revoke event",
         %{
           conn: conn,
           workspace: workspace,
           current_user: user
         } do
      binding = verified_binding(workspace.id, user.id)
      sa_id = SessionPermissions.compute_smart_account_id(binding)

      _ =
        insert_delegation_with_attrs!(workspace.id, binding.id, sa_id, %{
          state: :revoke_failed,
          last_reason: "bundler unavailable"
        })

      {:ok, _view, html} = live(conn, "/")

      # Stable id so future tests / E2E selectors don't drift.
      assert html =~ ~s(id="session-permission-retry-revoke-btn")
      # Re-uses the same `permission:revoke` event AgentLive already
      # owns — the modal-confirm flow is the single source of truth
      # for the actual revoke call.
      assert html =~ "Retry revoke"

      assert Regex.match?(
               ~r/<button[^>]*id="session-permission-retry-revoke-btn"[^>]*phx-click="permission:revoke"/,
               html
             )
    end

    test "Retry revoke flips the delegation row from :revoke_failed to :revoking",
         %{
           conn: conn,
           workspace: workspace,
           current_user: user
         } do
      binding = verified_binding(workspace.id, user.id)
      sa_id = SessionPermissions.compute_smart_account_id(binding)

      delegation =
        insert_delegation_with_attrs!(workspace.id, binding.id, sa_id, %{
          state: :revoke_failed,
          last_reason: "bundler unavailable"
        })

      {:ok, view, _html} = live(conn, "/")

      # Click the inline Retry revoke CTA → opens the confirm-stop
      # modal (same code path as `permission:revoke` from an :active
      # delegation; we proved this in the "wired to the existing
      # revoke event" test above).
      view |> render_click("permission:revoke")
      assert render(view) =~ "Stop the agent?"

      # Confirming the revoke runs through `Bank.Security.revoke_delegation/2`
      # which calls `Delegations.record_revoke_requested/2` — that
      # transition accepts `:active | :pending | :revoke_failed` → `:revoking`.
      view |> render_click("confirm_stop:revoke")

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :revoking
    end
  end

  # The design enum maps `:revoking` → `:installing`, so naively
  # gating Stop on `permission in [:active, :installing]` would
  # re-enable the button while the revoke is already in flight. The
  # topbar must look at the raw delegation state and disable Stop
  # when the delegation is mid-revoke or in any failed/terminal state.
  describe "TopBar Stop button gating (P5 fail-closed)" do
    test "Stop is disabled when delegation is :revoking", %{
      conn: conn,
      workspace: workspace,
      current_user: user
    } do
      binding = verified_binding(workspace.id, user.id)
      sa_id = SessionPermissions.compute_smart_account_id(binding)
      _ = insert_delegation!(workspace.id, binding.id, sa_id, :revoking)

      {:ok, _view, html} = live(conn, "/")

      topbar_btn = topbar_stop_button!(html)
      assert topbar_btn =~ "is-disabled"
      assert topbar_btn =~ "disabled"
    end

    # Codex review found this test inverted the desired behavior. The
    # domain says `:revoke_failed` may still be a live on-chain
    # delegation — the operator MUST be able to retry revoke from the
    # Stop affordance. Both the topbar Stop and the StopCard Revoke
    # button stay enabled (and re-fire the same `permission:revoke`
    # → confirm-stop modal → `Bank.Security.revoke_delegation/2`
    # path that an `:active` delegation would).
    test "Stop is ENABLED when delegation is :revoke_failed (retry path)", %{
      conn: conn,
      workspace: workspace,
      current_user: user
    } do
      binding = verified_binding(workspace.id, user.id)
      sa_id = SessionPermissions.compute_smart_account_id(binding)
      _ = insert_delegation!(workspace.id, binding.id, sa_id, :revoke_failed)

      {:ok, _view, html} = live(conn, "/")

      topbar_btn = topbar_stop_button!(html)
      refute topbar_btn =~ "is-disabled"
      refute topbar_btn =~ ~s(disabled=)

      stop_btn = stop_card_revoke_button!(html)
      refute stop_btn =~ "is-disabled"
      refute stop_btn =~ ~s(disabled=)
    end

    test "StopCard's Revoke button is disabled when delegation is :revoking",
         %{
           conn: conn,
           workspace: workspace,
           current_user: user
         } do
      binding = verified_binding(workspace.id, user.id)
      sa_id = SessionPermissions.compute_smart_account_id(binding)
      _ = insert_delegation!(workspace.id, binding.id, sa_id, :revoking)

      {:ok, _view, html} = live(conn, "/")

      btn = stop_card_revoke_button!(html)
      assert btn =~ "is-disabled"
      assert btn =~ "disabled"
    end

    test "Stop is enabled when delegation is :active", %{
      conn: conn,
      workspace: workspace,
      current_user: user
    } do
      _ = active_delegation_for_workspace(workspace.id, user.id)

      {:ok, _view, html} = live(conn, "/")

      refute topbar_stop_button!(html) =~ "is-disabled"
    end
  end

  # P4 also enforces `delegation.state == :active` as a precondition;
  # this set of tests pins the same fail-closed posture so dropping
  # the design-enum `:permission == :active` check doesn't lose the
  # guard.
  describe "intent:run defense-in-depth (P5 fail-closed)" do
    setup %{workspace: workspace, current_user: user} do
      binding = verified_binding(workspace.id, user.id)
      %{binding: binding}
    end

    test "intent:run is a no-op when the delegation is :revoking", %{
      conn: conn,
      workspace: workspace,
      binding: binding
    } do
      sa_id = SessionPermissions.compute_smart_account_id(binding)
      _ = insert_delegation!(workspace.id, binding.id, sa_id, :revoking)

      {:ok, view, _html} = live(conn, "/")

      # Push the event directly — no Bank.Intents.submit/2 should run,
      # so the :intent assign stays at its mount default :idle.
      render_hook(view, "intent:run", %{})

      # The IntentResult card surfaces the latest run; absence of an
      # "executing" / "executed" / "blocked" / "failed" copy means
      # intent:run was a no-op.
      html = render(view)
      refute html =~ "Running"
      refute html =~ "Executed"
      refute html =~ "executed"
    end

    test "intent:run is a no-op when the delegation is :revoke_failed", %{
      conn: conn,
      workspace: workspace,
      binding: binding
    } do
      sa_id = SessionPermissions.compute_smart_account_id(binding)
      _ = insert_delegation!(workspace.id, binding.id, sa_id, :revoke_failed)

      {:ok, view, _html} = live(conn, "/")

      render_hook(view, "intent:run", %{})

      html = render(view)
      refute html =~ "Running"
      refute html =~ "Executed"
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

  # Pulls the topbar Stop button (which carries
  # `phx-click="topbar:stop_agent"`) out of a rendered HTML string.
  # Phoenix encodes the phx-click value as a JS-encoded JSON token,
  # so we match on the literal `topbar:stop_agent` substring.
  defp topbar_stop_button!(html) do
    matches = Regex.scan(~r/<button[^>]*topbar:stop_agent[^>]*>/, html)

    case matches do
      [[btn] | _] -> btn
      _ -> flunk("topbar Stop button not found in rendered HTML: #{inspect(matches)}")
    end
  end

  # Pulls the StopCard's Revoke button (the one that carries
  # `phx-click="permission:revoke"`).
  defp stop_card_revoke_button!(html) do
    matches = Regex.scan(~r/<button[^>]*permission:revoke[^>]*>/, html)

    case matches do
      [[btn] | _] -> btn
      _ -> flunk("StopCard Revoke button not found in rendered HTML: #{inspect(matches)}")
    end
  end

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
    insert_delegation_with_attrs!(workspace_id, binding_id, smart_account_id, %{state: state})
  end

  defp insert_delegation_with_attrs!(workspace_id, binding_id, smart_account_id, extra_attrs) do
    base = %{
      smart_account_id: smart_account_id,
      delegation_id: "del-#{System.unique_integer([:positive])}",
      state: :active,
      chain: "base-sepolia",
      scope: Bank.SessionPermissions.Scope.default(),
      workspace_id: workspace_id,
      binding_id: binding_id,
      root_validator_owner: "user",
      install_userop_hash: "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    }

    attrs = Map.merge(base, extra_attrs)

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
