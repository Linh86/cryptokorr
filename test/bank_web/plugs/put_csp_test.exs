defmodule BankWeb.Plugs.PutCSPTest do
  @moduledoc """
  Unit coverage for `BankWeb.Plugs.PutCSP`.

  The plug is wired into `:browser` and `:browser_session_json`. Its
  load-bearing job is to forbid every cross-origin connect by
  default — `connect-src 'self'` — while widening that allowlist to
  include the configured ERC-4337 bundler URL so the operator
  console's browser-driven install hook can actually reach it.

  Without that widening the install fails with viem's
  `Failed to fetch` (which the classifier then reports as
  `bundler_unavailable`) before any signing popup ever opens — the
  P0 wallet-state-divergence story documented this in the
  `permission_card_test.exs` regression for the failure-reason copy.
  This test pins the upstream cause: that the plug-issued CSP
  permits the configured bundler origin in the first place.
  """

  use ExUnit.Case, async: false

  alias BankWeb.Plugs.PutCSP

  setup do
    saved = Application.get_env(:bank, Bank.SessionPermissions.BrowserInstall, [])

    on_exit(fn ->
      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall, saved)
    end)

    :ok
  end

  describe "configured_bundler_origin/0" do
    test "extracts scheme://host (port omitted for default ports)" do
      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall,
        bundler_rpc_url: "https://api.pimlico.io/v2/84532/rpc?apikey=pim_redacted"
      )

      assert PutCSP.configured_bundler_origin() == "https://api.pimlico.io"
    end

    test "keeps non-default ports in the origin" do
      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall,
        bundler_rpc_url: "http://localhost:4337/rpc"
      )

      assert PutCSP.configured_bundler_origin() == "http://localhost:4337"
    end

    test "returns nil when bundler_rpc_url is missing" do
      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall, [])
      assert PutCSP.configured_bundler_origin() == nil
    end

    test "returns nil for a malformed URL (no scheme)" do
      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall,
        bundler_rpc_url: "not-a-url"
      )

      assert PutCSP.configured_bundler_origin() == nil
    end

    test "strips API-key query parameters from the origin" do
      # The whole point: even if the configured URL embeds an API
      # key, the CSP must NEVER carry the key — only the origin.
      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall,
        bundler_rpc_url: "https://api.pimlico.io/v2/84532/rpc?apikey=SECRET_KEY"
      )

      origin = PutCSP.configured_bundler_origin()
      assert origin == "https://api.pimlico.io"
      refute origin =~ "SECRET_KEY"
      refute origin =~ "apikey"
    end
  end

  describe "configured_chain_rpc_origin/0" do
    test "returns the origin of the chain RPC URL" do
      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall,
        chain_rpc_url: "https://sepolia.base.org"
      )

      assert PutCSP.configured_chain_rpc_origin() == "https://sepolia.base.org"
    end

    test "returns nil when chain_rpc_url is missing" do
      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall, [])
      assert PutCSP.configured_chain_rpc_origin() == nil
    end
  end

  describe "build_csp/0" do
    test "connect-src includes 'self' AND the configured bundler origin" do
      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall,
        bundler_rpc_url: "https://api.pimlico.io/v2/84532/rpc?apikey=pim_x"
      )

      csp = PutCSP.build_csp()

      assert csp =~ "connect-src 'self' https://api.pimlico.io"
      # API key MUST never appear in the CSP header.
      refute csp =~ "apikey"
      refute csp =~ "pim_x"
    end

    test "connect-src includes BOTH bundler AND chain RPC origins when both configured" do
      # This is the load-bearing fix for the
      # `createKernelAccount → getSenderAddress → Cannot read
      # properties of undefined (reading 'match')` crash. The hook
      # opens TWO transports: bundlerTransport (ERC-4337 methods) and
      # publicClient (generic `eth_call`). They must point at
      # different RPC URLs when the bundler is a bundler-only host
      # (Pimlico, Stackup, Candide). Both origins must be in
      # `connect-src` so the browser doesn't block either with
      # `Failed to fetch` (which the classifier misreports as
      # `bundler_unavailable`).
      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall,
        bundler_rpc_url: "https://api.pimlico.io/v2/84532/rpc?apikey=pim_x",
        chain_rpc_url: "https://sepolia.base.org"
      )

      csp = PutCSP.build_csp()

      assert csp =~ "https://api.pimlico.io"
      assert csp =~ "https://sepolia.base.org"
      refute csp =~ "apikey"
    end

    test "connect-src does NOT duplicate the same origin when bundler == chain RPC" do
      # ZeroDev's hosted bundler serves both bundler and chain
      # methods — same URL for both. The CSP must list the origin
      # exactly once to avoid `connect-src 'self' https://x https://x`
      # noise.
      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall,
        bundler_rpc_url: "https://rpc.zerodev.app/api/v3/proj/chain/84532",
        chain_rpc_url: "https://rpc.zerodev.app/api/v3/proj/chain/84532"
      )

      csp = PutCSP.build_csp()

      # Count occurrences of the origin in the directive — must be 1.
      origin_count =
        csp
        |> String.split("https://rpc.zerodev.app")
        |> length()
        |> Kernel.-(1)

      assert origin_count == 1,
             "connect-src should list duplicate origins only once; got CSP: #{csp}"
    end

    test "connect-src falls back to the known browser-friendly bundler hosts when config is missing" do
      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall, [])

      csp = PutCSP.build_csp()

      # Both fallbacks must appear so the install hook can reach the
      # operator-configured bundler even in a half-configured dev
      # env. Pimlico + ZeroDev are the two MVP-supported hosted
      # bundlers; deployments using a different bundler must set
      # `:bundler_rpc_url` so the dynamic path produces an exact
      # allowlist instead.
      assert csp =~ "https://api.pimlico.io"
      assert csp =~ "https://rpc.zerodev.app"
    end

    test "switching the configured bundler swaps the connect-src origin" do
      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall,
        bundler_rpc_url: "https://api.pimlico.io/v2/84532/rpc?apikey=pim_x"
      )

      pimlico_csp = PutCSP.build_csp()
      assert pimlico_csp =~ "https://api.pimlico.io"

      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall,
        bundler_rpc_url: "https://rpc.zerodev.app/api/v3/proj/chain/84532"
      )

      zerodev_csp = PutCSP.build_csp()
      assert zerodev_csp =~ "https://rpc.zerodev.app"
      # Pimlico origin must NOT linger when the active bundler is
      # ZeroDev. CSP is rebuilt per request so we read live config.
      refute zerodev_csp =~ "https://api.pimlico.io"
    end

    test "preserves the other directives" do
      Application.put_env(:bank, Bank.SessionPermissions.BrowserInstall,
        bundler_rpc_url: "https://api.pimlico.io/v2/84532/rpc"
      )

      csp = PutCSP.build_csp()

      assert csp =~ "default-src 'self'"
      assert csp =~ "script-src 'self'"
      assert csp =~ "style-src 'self' 'unsafe-inline'"
      assert csp =~ "img-src 'self' data:"
      assert csp =~ "frame-ancestors 'none'"
      assert csp =~ "object-src 'none'"
      assert csp =~ "base-uri 'self'"
      assert csp =~ "form-action 'self'"
      refute csp =~ "script-src 'self' 'unsafe-inline'"
    end
  end
end
