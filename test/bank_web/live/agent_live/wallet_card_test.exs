defmodule BankWeb.AgentLive.WalletCardTest do
  @moduledoc """
  Smoke tests for the redesigned AgentLive wallet card after phase 2
  wiring. Verifies:

    * disconnected render with the `wallet-connect-btn` the JS hook
      attaches to
    * connected render driven by an existing verified binding row
    * wrong-chain render via the JS hook event
    * the live `wallet_connect:connected` → push challenge →
      `wallet_connect:verify` round trip lands the card in connected

  Hardening (P3) coverage:

    * wrong-chain `wallet_connect:connected` does NOT persist a row
    * `wallet_connect:verify` with a malformed signature leaves the
      pending row's `verified_at` NULL (no fake verification)
    * a verified binding survives a fresh mount (load_wallet_binding
      reads from DB)
    * disconnect fail-closes the permission UI even when an active
      delegation row exists in the DB (DB row is preserved)
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]

  alias Bank.Delegations.Delegation
  alias Bank.Repo
  alias Bank.SessionPermissions
  alias Bank.WalletBindings
  alias Bank.WalletBindings.Signature
  alias Bank.WalletBindings.WalletBinding

  setup :register_and_log_in_user

  # secp256k1 generator point — convenient deterministic test key.
  @privkey <<1::256>>

  setup do
    {:ok, pubkey} = ExSecp256k1.create_public_key(@privkey)
    {:ok, address} = Signature.address_from_pubkey(pubkey)

    %{wallet_address: address}
  end

  describe "initial render — no binding" do
    test "renders the disconnected card with Connect button", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "01 — Wallet"
      assert html =~ "Connect a browser wallet to begin"
      assert html =~ "Connect wallet"
      assert html =~ ~s(id="wallet-card")
      assert html =~ ~s(phx-hook="WalletConnect")
      assert html =~ ~s(id="wallet-connect-btn")
    end

    test "renders the disconnected status pill", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      # `pill--ink` is the colour class the disconnected kind maps to.
      assert html =~ "pill--ink"
      assert html =~ "Not connected"
    end
  end

  describe "initial render — with active verified binding" do
    setup %{workspace: workspace, current_user: user, wallet_address: address} do
      {:ok, binding} =
        WalletBindings.issue_challenge(workspace.id, user.id, %{
          address: address,
          chain_id: 84_532
        })

      signature = sign_challenge(binding.challenge_message, @privkey)
      {:ok, verified} = WalletBindings.verify_and_bind(binding.id, signature)

      %{binding: verified}
    end

    test "renders the connected datarows driven by the binding", %{
      conn: conn,
      wallet_address: address
    } do
      {:ok, view, _html} = live(conn, "/")

      # Mount alone now produces `:browser_disconnected` — the new
      # composite derive requires the WalletConnect JS hook to push
      # `wallet_connect:browser_status` confirming the live provider
      # exposes the bound account. Simulate that push to land on
      # `:connected`, matching what the hook does on mount in
      # production.
      html = push_browser_connected(view, address)

      assert html =~ "Base Sepolia · chain 84532"
      assert html =~ "USDC balance"
      # short-form rendered inline as `0x` + 4 + ellipsis + 4
      short =
        "0x" <>
          String.slice(String.downcase(address), 2, 4) <>
          "…" <> String.slice(String.downcase(address), -4, 4)

      assert html =~ short
      # Connected kind renders with colour class `ok`.
      assert html =~ "pill--ok"
      assert html =~ "Connected"
    end

    test "shows BaseScan link in the connected card", %{
      conn: conn,
      wallet_address: address
    } do
      {:ok, view, _html} = live(conn, "/")

      html = push_browser_connected(view, address)
      assert html =~ "View on BaseScan"
    end

    test "without a browser_status push, the card renders :browser_disconnected", %{
      conn: conn,
      wallet_address: address
    } do
      {:ok, _view, html} = live(conn, "/")

      # The DB binding is verified, on Base Sepolia, non-revoked.
      # But the JS hook hasn't pushed any `browser_status` yet, so
      # the live provider's account exposure is unknown. The
      # composite derive lands on `:browser_disconnected` rather
      # than `:connected` — the pill must NOT say Connected and
      # the Reconnect/Disconnect CTAs must appear.
      refute html =~ "pill--ok"
      refute html =~ ">Connected<"
      assert html =~ "pill--warn"
      assert html =~ "Wallet disconnected"
      assert html =~ "Reconnect wallet"
      assert html =~ "Disconnect"

      # The bound address should still be visible (audit-friendly)
      # but the card body explains it's no longer exposed.
      short =
        "0x" <>
          String.slice(String.downcase(address), 2, 4) <>
          "…" <> String.slice(String.downcase(address), -4, 4)

      assert html =~ short
    end
  end

  # ── P0 wallet-state-divergence — composite states ──────────────────
  describe "composite browser-state derivation" do
    setup %{workspace: workspace, current_user: user, wallet_address: address} do
      {:ok, binding} =
        WalletBindings.issue_challenge(workspace.id, user.id, %{
          address: address,
          chain_id: 84_532
        })

      signature = sign_challenge(binding.challenge_message, @privkey)
      {:ok, verified} = WalletBindings.verify_and_bind(binding.id, signature)

      %{binding: verified}
    end

    test "exposed_account on Base Sepolia lands on :connected", %{
      conn: conn,
      wallet_address: address
    } do
      {:ok, view, _html} = live(conn, "/")

      html = push_browser_connected(view, address)

      assert html =~ "pill--ok"
      assert html =~ "Connected"
      assert html =~ "View on BaseScan"
    end

    test "exposed_account on the wrong chain renders :wrong_chain", %{
      conn: conn,
      wallet_address: address
    } do
      {:ok, view, _html} = live(conn, "/")

      html =
        render_hook(view, "wallet_connect:browser_status", %{
          "status" => "exposed_account",
          "accounts" => [address],
          # Ethereum mainnet — not Base Sepolia.
          "chain_id" => 1,
          "permissions_count" => 1
        })

      refute html =~ "pill--ok"
      assert html =~ "pill--warn"
      assert html =~ "Switch to Base Sepolia"
      assert html =~ "chain 84532"
    end

    test "exposed_account different from the bound address renders :account_mismatch", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      other = "0x" <> String.duplicate("ab", 20)

      html =
        render_hook(view, "wallet_connect:browser_status", %{
          "status" => "exposed_account",
          "accounts" => [other],
          "chain_id" => 84_532,
          "permissions_count" => 1
        })

      refute html =~ "pill--ok"
      assert html =~ "pill--warn"
      assert html =~ "Account mismatch"
      assert html =~ "exposing a different account"
    end

    test "no_account (revoked site permission) renders :browser_disconnected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        render_hook(view, "wallet_connect:browser_status", %{
          "status" => "no_account",
          "accounts" => [],
          "chain_id" => 84_532,
          "permissions_count" => 0
        })

      refute html =~ "pill--ok"
      assert html =~ "Wallet disconnected"
      assert html =~ "Reconnect wallet"
    end

    test "no_provider renders :browser_disconnected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        render_hook(view, "wallet_connect:browser_status", %{
          "status" => "no_provider",
          "accounts" => [],
          "chain_id" => nil,
          "permissions_count" => 0
        })

      refute html =~ "pill--ok"
      assert html =~ "Wallet disconnected"
    end

    test ":connected re-reverts to :browser_disconnected on a follow-up :no_account push", %{
      conn: conn,
      wallet_address: address
    } do
      {:ok, view, _html} = live(conn, "/")

      _ = push_browser_connected(view, address)

      assert render(view) =~ "pill--ok"

      # Operator clicks "Disconnect this site" in MetaMask → the
      # provider fires accountsChanged: [] → the hook re-pushes
      # browser_status. The UI must drop "Connected" immediately.
      html =
        render_hook(view, "wallet_connect:browser_status", %{
          "status" => "no_account",
          "accounts" => [],
          "chain_id" => 84_532,
          "permissions_count" => 0
        })

      refute html =~ "pill--ok"
      assert html =~ "Wallet disconnected"
    end
  end

  # `:connecting` is the explicit "wallet popup is queued" UI state.
  # The JS hook fires `wallet_connect:connecting` synchronously before
  # awaiting `eth_requestAccounts`, so the LiveView must flip to a
  # spinner + "Open your wallet to approve…" affordance immediately.
  # Without it the click looks like a no-op while MetaMask's popup is
  # queued behind another window.
  # EIP-6963 wallet picker. When the JS hook reports >1 announced
  # wallet, the card MUST render a per-wallet button instead of the
  # single "Connect wallet" CTA — Trust + MetaMask installed together
  # used to silently hijack `window.ethereum` based on injection
  # order. The picker breaks the tie by asking the user.
  describe "EIP-6963 wallet picker" do
    test "single announced provider renders single Connect button labeled with the wallet name",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        render_hook(view, "wallet_connect:providers_discovered", %{
          "providers" => [
            %{
              "uuid" => "uuid-1",
              "name" => "MetaMask",
              "rdns" => "io.metamask",
              "icon" => "data:image/svg+xml,..."
            }
          ]
        })

      assert html =~ ~s(id="wallet-connect-btn")
      assert html =~ "Connect MetaMask"
      refute html =~ "cb-wallet-picker"
    end

    test "multiple announced providers render the wallet picker, no single button", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      html =
        render_hook(view, "wallet_connect:providers_discovered", %{
          "providers" => [
            %{
              "uuid" => "uuid-mm",
              "name" => "MetaMask",
              "rdns" => "io.metamask",
              "icon" => nil
            },
            %{
              "uuid" => "uuid-tw",
              "name" => "Trust Wallet",
              "rdns" => "com.trustwallet.app",
              "icon" => nil
            }
          ]
        })

      assert html =~ "cb-wallet-picker"
      assert html =~ "MetaMask"
      assert html =~ "Trust Wallet"
      # `phx-click="wallet_connect:select_provider"` + the uuid for
      # each wallet — server's select_provider handler needs the uuid
      # to dispatch back to the hook.
      assert html =~ ~s(phx-value-uuid="uuid-mm")
      assert html =~ ~s(phx-value-uuid="uuid-tw")
      # Single-button path is suppressed when picker shows.
      refute html =~ ~s(id="wallet-connect-btn")
    end

    test "select_provider event pushes wallet_connect:use_provider back to the hook", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/")

      _ =
        render_hook(view, "wallet_connect:providers_discovered", %{
          "providers" => [
            %{"uuid" => "uuid-mm", "name" => "MetaMask", "rdns" => "io.metamask", "icon" => nil},
            %{
              "uuid" => "uuid-tw",
              "name" => "Trust Wallet",
              "rdns" => "com.trustwallet.app",
              "icon" => nil
            }
          ]
        })

      # `render_click` walks the picker button in the rendered HTML and
      # fires its phx-click event with the embedded phx-value-uuid.
      view |> element(~s([phx-value-uuid="uuid-mm"])) |> render_click()

      # Phoenix.LiveViewTest stores server-pushed events in the
      # rendered output; assert the hook will receive the
      # use_provider directive with the chosen uuid.
      assert_push_event(view, "wallet_connect:use_provider", %{uuid: "uuid-mm"})
    end

    test "non-string fields in providers payload are coerced to nil and dropped", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html =
        render_hook(view, "wallet_connect:providers_discovered", %{
          "providers" => [
            # Valid entry passes through.
            %{"uuid" => "ok", "name" => "Real", "rdns" => "io.real", "icon" => nil},
            # Missing uuid → dropped.
            %{"uuid" => nil, "name" => "NoUUID", "rdns" => "x", "icon" => nil},
            # Missing name → dropped.
            %{"uuid" => "u", "name" => nil, "rdns" => "x", "icon" => nil},
            # Non-binary uuid → coerced to nil → dropped.
            %{"uuid" => 42, "name" => "BadUUID", "rdns" => "x", "icon" => nil}
          ]
        })

      assert html =~ "Real"
      refute html =~ "NoUUID"
      refute html =~ "BadUUID"
    end
  end

  describe "wallet_connect:connecting event flow" do
    test "flips the wallet card into the :connecting variant", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      html = render_hook(view, "wallet_connect:connecting", %{})

      # Pending pill maps to `pill--warn` per AgentComponents.pill_config/1
      # (see "Pending" mapping). The status text is "Pending".
      assert html =~ "pill--warn"
      assert html =~ "Pending"
      # The spinner + the explicit "Open your wallet to approve" copy
      # must render so the user knows where to look.
      assert html =~ ~s(class="spinner")
      assert html =~ "Open your wallet to approve"
      assert html =~ "Waiting for wallet approval"
    end

    test ":connecting clears back to :disconnected on cancel", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/")

      _ = render_hook(view, "wallet_connect:connecting", %{})
      html = render_hook(view, "wallet_connect:cancelled", %{})

      assert html =~ "Connect a browser wallet to begin"
      refute html =~ "Waiting for wallet approval"
      refute html =~ ~s(class="spinner")
    end
  end

  describe "wallet_connect:connected event flow" do
    test "issues a challenge, pushes it back, and renders pending state", %{
      conn: conn,
      wallet_address: address
    } do
      {:ok, view, _html} = live(conn, "/")

      _ =
        render_hook(view, "wallet_connect:connected", %{
          "account" => address,
          "chain_id" => 84_532
        })

      # A pending binding row was created for this workspace + address.
      assert [%WalletBinding{verified_at: nil}] = list_pending_bindings(address)

      # The card is still on disconnected (verified_at not stamped yet),
      # but the underlying binding assign carries the challenge id.
      html = render(view)
      assert html =~ "01 — Wallet"
    end

    test "wallet_connect:connected on Base mainnet renders wrong_network", %{
      conn: conn,
      wallet_address: address
    } do
      {:ok, view, _html} = live(conn, "/")

      html =
        render_hook(view, "wallet_connect:connected", %{
          "account" => address,
          "chain_id" => 8453
        })

      # Wrong-network kind renders with colour class `warn`.
      assert html =~ "pill--warn"
      assert html =~ "Wrong network"
      assert html =~ "Switch your wallet to Base Sepolia"
    end

    test "wrong_chain hook event renders wrong_network without persisting", %{
      conn: conn,
      wallet_address: address
    } do
      {:ok, view, _html} = live(conn, "/")

      html =
        render_hook(view, "wallet_connect:wrong_chain", %{
          "account" => address,
          "chain_id" => 1
        })

      assert html =~ "pill--warn"
      assert html =~ "Wrong network"
      assert html =~ "Switch your wallet to Base Sepolia"
      # No row should land in the DB for an unsupported chain.
      assert [] = list_pending_bindings(address)
    end

    test "verify with a valid signature renders the connected datarows", %{
      conn: conn,
      wallet_address: address
    } do
      {:ok, view, _html} = live(conn, "/")

      _ =
        render_hook(view, "wallet_connect:connected", %{
          "account" => address,
          "chain_id" => 84_532
        })

      [binding] = list_pending_bindings(address)
      signature = sign_challenge(binding.challenge_message, @privkey)

      _ =
        render_hook(view, "wallet_connect:verify", %{
          "challenge_id" => binding.id,
          "signature" => signature
        })

      # The composite derive now requires a live browser_status push
      # exposing the bound account before flipping to `:connected` —
      # in production, MetaMask emits `accountsChanged` immediately
      # after `eth_requestAccounts` resolves, which triggers the
      # WalletConnect hook's `pushBrowserStatus`. Simulate that here.
      html = push_browser_connected(view, address)

      assert html =~ "pill--ok"
      assert html =~ "Connected"
      assert html =~ "Base Sepolia · chain 84532"
    end

    test "verify_error resets the card to disconnected", %{
      conn: conn,
      wallet_address: address
    } do
      {:ok, view, _html} = live(conn, "/")

      _ =
        render_hook(view, "wallet_connect:connected", %{
          "account" => address,
          "chain_id" => 84_532
        })

      [binding] = list_pending_bindings(address)

      html =
        render_hook(view, "wallet_connect:verify_error", %{
          "challenge_id" => binding.id,
          "reason" => "user_rejected"
        })

      assert html =~ "pill--ink"
      assert html =~ "Not connected"
      assert html =~ "Connect wallet"
    end

    test "disconnect revokes the active binding and resets the card", %{
      conn: conn,
      wallet_address: address
    } do
      {:ok, view, _html} = live(conn, "/")

      _ =
        render_hook(view, "wallet_connect:connected", %{
          "account" => address,
          "chain_id" => 84_532
        })

      [binding] = list_pending_bindings(address)
      signature = sign_challenge(binding.challenge_message, @privkey)

      _ =
        render_hook(view, "wallet_connect:verify", %{
          "challenge_id" => binding.id,
          "signature" => signature
        })

      html = render_hook(view, "wallet_connect:disconnect", %{})

      assert html =~ "pill--ink"
      assert html =~ "Not connected"
      assert html =~ "Connect wallet"

      # Underlying binding row is now revoked.
      revoked = Repo.get!(WalletBinding, binding.id)
      assert %DateTime{} = revoked.revoked_at
    end
  end

  describe "P3 hardening — fail-closed wallet binding" do
    test "wrong-chain wallet_connect:connected does NOT persist a row", %{
      conn: conn,
      wallet_address: address
    } do
      {:ok, view, _html} = live(conn, "/")

      before_count = Repo.aggregate(WalletBinding, :count)

      html =
        render_hook(view, "wallet_connect:connected", %{
          "account" => address,
          "chain_id" => 1
        })

      after_count = Repo.aggregate(WalletBinding, :count)

      # No row was created — the chain guard short-circuits before
      # `Repo.insert/1`.
      assert before_count == after_count

      # UI flips to wrong-network and shows the switch-network copy.
      assert html =~ "pill--warn"
      assert html =~ "Wrong network"
      assert html =~ "Switch your wallet to Base Sepolia"
    end

    test "verify with a malformed signature leaves verified_at nil and resets the card", %{
      conn: conn,
      wallet_address: address
    } do
      {:ok, view, _html} = live(conn, "/")

      _ =
        render_hook(view, "wallet_connect:connected", %{
          "account" => address,
          "chain_id" => 84_532
        })

      [binding] = list_pending_bindings(address)

      # 0xdeadbeef is hex but only 4 bytes — not a valid 65-byte
      # secp256k1 sig, so `verify_eip191/3` rejects it as malformed.
      html =
        render_hook(view, "wallet_connect:verify", %{
          "challenge_id" => binding.id,
          "signature" => "0xdeadbeef"
        })

      reloaded = Repo.get!(WalletBinding, binding.id)
      assert is_nil(reloaded.verified_at)

      # No verified row exists for this workspace.
      assert WalletBindings.get_active_binding(binding.workspace_id) == nil

      # Card flips back to disconnected.
      assert html =~ "pill--ink"
      assert html =~ "Not connected"
    end

    test "verified binding survives a fresh mount (reload from DB) and lands :connected once browser confirms",
         %{
           conn: conn,
           workspace: workspace,
           current_user: user,
           wallet_address: address
         } do
      # Real challenge + verify flow so the row carries a valid
      # challenge_message that the EIP-191 verifier accepts.
      {:ok, binding} =
        WalletBindings.issue_challenge(workspace.id, user.id, %{
          address: address,
          chain_id: 84_532
        })

      signature = sign_challenge(binding.challenge_message, @privkey)
      {:ok, _verified} = WalletBindings.verify_and_bind(binding.id, signature)

      # Fresh mount — `load_wallet_binding/1` reads the verified row
      # from the DB. With the P0 wallet-state-divergence fix the
      # mount alone is NOT enough — the UI lands on
      # `:browser_disconnected` until the JS hook confirms the live
      # provider still exposes the bound account. The hook does this
      # on every mount via the subscribe → pushBrowserStatus path;
      # we simulate it here.
      {:ok, view, mount_html} = live(conn, "/")

      refute mount_html =~ "pill--ok"
      assert mount_html =~ "Wallet disconnected"

      html = push_browser_connected(view, address)

      assert html =~ "pill--ok"
      assert html =~ "Connected"
      assert html =~ "Base Sepolia · chain 84532"

      short =
        "0x" <>
          String.slice(String.downcase(address), 2, 4) <>
          "…" <> String.slice(String.downcase(address), -4, 4)

      assert html =~ short
    end

    test "disconnect fail-closes the permission UI even with an active delegation row", %{
      conn: conn,
      workspace: workspace,
      current_user: user,
      wallet_address: address
    } do
      # 1. Real verified binding via the public flow.
      {:ok, binding} =
        WalletBindings.issue_challenge(workspace.id, user.id, %{
          address: address,
          chain_id: 84_532
        })

      signature = sign_challenge(binding.challenge_message, @privkey)
      {:ok, verified} = WalletBindings.verify_and_bind(binding.id, signature)

      # 2. Active delegation row tied to this binding's smart account.
      sa_id = SessionPermissions.compute_smart_account_id(verified)
      delegation = insert_active_delegation!(workspace.id, verified.id, sa_id)

      # 3. Mount — UI should show :active permission with the
      #    smart-account hint and the in-card Revoke button.
      {:ok, view, html} = live(conn, "/")

      # `:active` permission → "Active" pill text + the smart-account
      # hint + "Smart account" data row are only emitted in the
      # card's active branch.
      assert html =~ "ZeroDev / Kernel v3"
      assert html =~ "Smart account"

      # The :permission assign reflects the DB truth.
      assert :sys.get_state(view.pid).socket.assigns.permission == :active

      # 4. Disconnect.
      html_after = render_hook(view, "wallet_connect:disconnect", %{})

      # 5. Permission UI must fail-closed — the active datarows
      #    (Smart account / ZeroDev hint) are gone. The card now
      #    renders the install-cta branch, so "Install permission"
      #    appears (disabled, because the wallet is gone).
      refute html_after =~ "ZeroDev / Kernel v3"
      refute html_after =~ "Smart account"
      assert html_after =~ "Install permission"

      # The :permission assign is forced to :not_installed even
      # though the DB row stays :active.
      assert :sys.get_state(view.pid).socket.assigns.permission == :not_installed

      # 6. The DB delegation row is preserved with state :active —
      #    only Bank.Security.revoke_delegation/2 may flip it.
      reloaded_delegation = Repo.get!(Delegation, delegation.id)
      assert reloaded_delegation.state == :active
    end
  end

  # --- helpers -----------------------------------------------------------

  # Simulate the WalletConnect JS hook reporting that the live
  # browser provider exposes the bound account on Base Sepolia.
  # Production-equivalent push from `pushBrowserStatus` after a
  # successful EIP-6963 selection + accounts read. Returns the
  # updated rendered HTML.
  defp push_browser_connected(view, address) do
    render_hook(view, "wallet_connect:browser_status", %{
      "status" => "exposed_account",
      "accounts" => [address],
      "chain_id" => 84_532,
      "permissions_count" => 1
    })
  end

  defp list_pending_bindings(address) do
    workspace_id = Process.get(:bank_test_workspace_id)
    address_lower = String.downcase(address)

    Repo.all(
      from(b in WalletBinding,
        where:
          b.workspace_id == ^workspace_id and b.address == ^address_lower and
            is_nil(b.verified_at) and is_nil(b.revoked_at)
      )
    )
  end

  defp sign_challenge(message, privkey) do
    digest = Signature.eip191_hash(message)
    {:ok, {r, s, v}} = ExSecp256k1.sign(digest, privkey)
    "0x" <> Base.encode16(r <> s <> <<v + 27>>, case: :lower)
  end

  defp insert_active_delegation!(workspace_id, binding_id, smart_account_id) do
    attrs = %{
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

    {:ok, delegation} =
      %Delegation{}
      |> Delegation.changeset(attrs)
      |> Repo.insert()

    delegation
  end
end
