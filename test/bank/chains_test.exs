defmodule Bank.ChainsTest do
  use Bank.DataCase, async: true

  alias Bank.Chains
  alias Bank.Workspaces

  describe "mainnet?/1" do
    test "true for canonical mainnet chains" do
      assert Chains.mainnet?("base")
      assert Chains.mainnet?("ethereum")
    end

    test "false for testnet chains" do
      refute Chains.mainnet?("base-sepolia")
      refute Chains.mainnet?("sepolia")
      refute Chains.mainnet?("goerli")
    end

    test "false for nil, empty, and unknown strings" do
      refute Chains.mainnet?(nil)
      refute Chains.mainnet?("")
      refute Chains.mainnet?("unknown-chain")
      refute Chains.mainnet?(:base)
    end
  end

  describe "testnet?/1" do
    test "true for canonical testnet chains" do
      assert Chains.testnet?("base-sepolia")
      assert Chains.testnet?("sepolia")
      assert Chains.testnet?("goerli")
    end

    test "false for mainnet, nil, empty, and unknown" do
      refute Chains.testnet?("base")
      refute Chains.testnet?("ethereum")
      refute Chains.testnet?(nil)
      refute Chains.testnet?("unknown")
    end
  end

  describe "classify/1" do
    test "labels canonical mainnet chains :mainnet" do
      assert Chains.classify("base") == :mainnet
      assert Chains.classify("ethereum") == :mainnet
    end

    test "labels canonical testnet chains :testnet" do
      assert Chains.classify("base-sepolia") == :testnet
      assert Chains.classify("sepolia") == :testnet
      assert Chains.classify("goerli") == :testnet
    end

    test "labels unknown / nil / non-string :unknown" do
      assert Chains.classify("foobar") == :unknown
      assert Chains.classify(nil) == :unknown
      assert Chains.classify("") == :unknown
      assert Chains.classify(:base) == :unknown
    end
  end

  describe "mainnet_allowed_for?/2 + validate_mainnet_allowed/2" do
    setup do
      # ws_off is left with the schema default mainnet_enabled=false
      # to exercise the rejection path. The perl-driven test fixture
      # update for #178 explicitly skips this file because the
      # gate's negative test cases need a workspace WITHOUT the
      # flag flipped.
      {:ok, ws_off} =
        Workspaces.create_workspace(%{slug: "ws-mainnet-off", name: "Mainnet off"})

      {:ok, ws_on} =
        Workspaces.create_workspace(%{
          slug: "ws-mainnet-on",
          name: "Mainnet on",
          mainnet_enabled: true
        })

      %{ws_off: ws_off, ws_on: ws_on}
    end

    test "testnet chain is always allowed regardless of workspace flag", ctx do
      assert Chains.mainnet_allowed_for?("base-sepolia", ctx.ws_off.id)
      assert Chains.mainnet_allowed_for?("base-sepolia", ctx.ws_on.id)

      assert Chains.validate_mainnet_allowed("base-sepolia", ctx.ws_off.id) == :ok
      assert Chains.validate_mainnet_allowed("base-sepolia", ctx.ws_on.id) == :ok
    end

    test "unknown chain is allowed (the broader chain allowlist gates it elsewhere)", ctx do
      assert Chains.mainnet_allowed_for?("unknown", ctx.ws_off.id)
      assert Chains.validate_mainnet_allowed("unknown", ctx.ws_off.id) == :ok
    end

    test "mainnet chain is rejected when the workspace flag is off", ctx do
      refute Chains.mainnet_allowed_for?("base", ctx.ws_off.id)
      refute Chains.mainnet_allowed_for?("ethereum", ctx.ws_off.id)

      assert Chains.validate_mainnet_allowed("base", ctx.ws_off.id) ==
               {:error, :mainnet_disabled}

      assert Chains.validate_mainnet_allowed("ethereum", ctx.ws_off.id) ==
               {:error, :mainnet_disabled}
    end

    test "mainnet chain is allowed when the workspace flag is on", ctx do
      assert Chains.mainnet_allowed_for?("base", ctx.ws_on.id)
      assert Chains.validate_mainnet_allowed("base", ctx.ws_on.id) == :ok
    end

    test "nil workspace_id passes through (legacy-safe, mirrors validate_not_paused/2)" do
      # Legacy unscoped paths (#158 tail) bypass the workspace-scoped
      # gate entirely. Every production chain-touching boundary
      # carries a workspace_id; this fallback exists only for
      # transitional / test code paths.
      assert Chains.mainnet_allowed_for?("base", nil)
      assert Chains.validate_mainnet_allowed("base", nil) == :ok
    end

    test "nil workspace_id allows testnet (the gate only restricts mainnet)" do
      assert Chains.mainnet_allowed_for?("base-sepolia", nil)
      assert Chains.validate_mainnet_allowed("base-sepolia", nil) == :ok
    end

    test "non-binary, non-nil workspace_id rejects mainnet (defensive shape check)" do
      refute Chains.mainnet_allowed_for?("base", 123)
      assert Chains.validate_mainnet_allowed("base", 123) == {:error, :mainnet_disabled}
    end
  end

  describe "Bank.Workspaces.mainnet_enabled?/1 + set_mainnet_enabled/2" do
    setup do
      # Default schema state: mainnet_enabled=false. This is the
      # safe production default per #178 acceptance.
      {:ok, ws} = Workspaces.create_workspace(%{slug: "ws-flag", name: "Flag"})
      %{ws: ws}
    end

    test "default is false on a freshly-created workspace", ctx do
      refute Workspaces.mainnet_enabled?(ctx.ws.id)
      refute Bank.Workspaces.Workspace.mainnet_enabled?(ctx.ws)
    end

    test "set_mainnet_enabled/2 flips the flag and the read-side helper sees it", ctx do
      assert {:ok, %{mainnet_enabled: true}} = Workspaces.set_mainnet_enabled(ctx.ws, true)
      assert Workspaces.mainnet_enabled?(ctx.ws.id)
    end

    test "set_mainnet_enabled/2 accepts a workspace id and returns :not_found for unknown ids" do
      assert {:error, :not_found} = Workspaces.set_mainnet_enabled(Ecto.UUID.generate(), true)
    end

    test "mainnet_enabled?/1 returns false for nil and unknown ids" do
      refute Workspaces.mainnet_enabled?(nil)
      refute Workspaces.mainnet_enabled?(Ecto.UUID.generate())
    end
  end
end
