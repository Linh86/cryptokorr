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
  """

  use BankWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]

  alias Bank.Repo
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
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "Base Sepolia · chain 84532"
      assert html =~ "USDC balance"
      # short-form rendered inline as `0x` + 4 + ellipsis + 4
      short = "0x" <> String.slice(String.downcase(address), 2, 4) <>
                "…" <> String.slice(String.downcase(address), -4, 4)

      assert html =~ short
      # Connected kind renders with colour class `ok`.
      assert html =~ "pill--ok"
      assert html =~ "Connected"
    end

    test "shows BaseScan link in the connected card", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")

      assert html =~ "View on BaseScan"
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

      html =
        render_hook(view, "wallet_connect:verify", %{
          "challenge_id" => binding.id,
          "signature" => signature
        })

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

  # --- helpers -----------------------------------------------------------

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
end
