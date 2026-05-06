defmodule BankWeb.SessionPermissionInstallHookSafetyTest do
  @moduledoc """
  Source-level invariants for `assets/js/hooks/session_permission_install.js`
  (#473).

  The browser-driven session permission install hook must obey
  the same hard safety boundaries as `wallet_connect.js` plus a
  few install-specific ones documented in the hook's moduledoc:

    * No private keys, no mnemonic, no seed-phrase material.
    * No transaction broadcast methods (`eth_sendTransaction`,
      `eth_sendRawTransaction`, `wallet_sendTransaction`).
    * Only `personal_sign` is allowed for signing — typed-data
      and legacy `eth_sign` are forbidden so the hook can never
      be talked into signing a structured payload it didn't
      author.
    * The scope-bound message is server-issued via a
      `session_permission_install:scope_message` push event. The
      hook does not build the message itself.
    * The active chain is restricted to Base Sepolia (84532); any
      other chain pushes `session_permission_install:wrong_chain`
      and refuses to attempt a chain switch on the operator's
      behalf.
    * No unlimited approval, no arbitrary calldata, no
      borrow/leverage/withdraw authority surface — these are all
      Phoenix-side scope decisions; the hook never reaches for
      them.

  Pinned at source level so the rule survives future edits even
  when no JS test stack is wired up. Mirrors
  `wallet_connect_hook_safety_test.exs`.
  """

  use ExUnit.Case, async: true

  @hook_path Path.expand(
               "../../../assets/js/hooks/session_permission_install.js",
               __DIR__
             )

  setup_all do
    full = File.read!(@hook_path)
    # Source-pin tests focus on actual JS code, not documentation.
    # Strip `//` line comments so the moduledoc can use plain
    # English to enumerate forbidden tokens (e.g. "no mnemonic")
    # without the test flagging its own description.
    code_only =
      full
      |> String.split("\n")
      |> Enum.map(&String.replace(&1, ~r{//.*$}, ""))
      |> Enum.join("\n")

    {:ok, source: full, code: code_only}
  end

  test "hook file exists at the documented path" do
    assert File.exists?(@hook_path),
           "Expected session_permission_install hook at #{@hook_path}"
  end

  test "hook code never references private key or mnemonic material", %{code: code} do
    refute code =~ "privateKey"
    refute code =~ "private_key"
    refute code =~ "mnemonic"
    refute code =~ "seed_phrase"
  end

  test "hook code never invokes broadcast JSON-RPC methods", %{code: code} do
    forbidden = [
      "eth_sendTransaction",
      "eth_sendRawTransaction",
      "wallet_sendTransaction",
      "wallet_addEthereumChain",
      "wallet_switchEthereumChain"
    ]

    for method <- forbidden do
      refute code =~ method,
             "session_permission_install.js must not invoke #{method} (out of scope)"
    end
  end

  test "hook code never invokes signing methods other than personal_sign", %{code: code} do
    forbidden = [
      "eth_signTransaction",
      "eth_signTypedData",
      "eth_signTypedData_v3",
      "eth_signTypedData_v4"
    ]

    for method <- forbidden do
      refute code =~ method,
             "session_permission_install.js must not invoke #{method} — only personal_sign is in scope"
    end

    refute code =~ ~r/"eth_sign"/,
           "session_permission_install.js must not invoke the legacy eth_sign method — use personal_sign"
  end

  test "hook only uses approved JSON-RPC methods", %{source: source} do
    # Approved set:
    #   - eth_chainId:    passive read of active network
    #   - personal_sign:  only invoked from `signScopeMessage` in
    #                     response to a server-issued scope message
    allowed = ~w(eth_chainId personal_sign)

    used =
      ~r/method:\s*"([a-zA-Z_][a-zA-Z0-9_]*)"/
      |> Regex.scan(source)
      |> Enum.map(fn [_full, m] -> m end)
      |> Enum.uniq()

    extras = used -- allowed

    assert extras == [],
           "session_permission_install.js uses unexpected JSON-RPC methods: #{inspect(extras)}. " <>
             "Only #{inspect(allowed)} are approved."
  end

  test "hook gates beginInstall behind a user click", %{source: source} do
    assert source =~ "beginInstall"
    assert source =~ "handleClick"
    assert source =~ ~r/handleClick.*?session-permission-browser-install-btn/s
    assert source =~ ~r/beginInstall.*?eth_chainId/s
  end

  test "hook gates personal_sign behind a server-issued scope message", %{source: source} do
    # personal_sign must only run from `signScopeMessage`, which
    # is wired to the server-pushed
    # `session_permission_install:scope_message` event. The hook
    # must not build the message itself — Phoenix is the source
    # of truth for the canonical scope summary.
    assert source =~ "signScopeMessage"
    assert source =~ ~r/session_permission_install:scope_message.*?signScopeMessage/s
    assert source =~ ~r/signScopeMessage.*?personal_sign/s
  end

  test "hook restricts the active chain to Base Sepolia for the MVP", %{source: source} do
    assert source =~ ~r/SUPPORTED_CHAIN_IDS\s*=\s*\[84_?532\]/,
           "session_permission_install.js must declare Base Sepolia as the only supported chain"

    refute source =~ ~r/SUPPORTED_CHAIN_IDS\s*=\s*\[8453/,
           "session_permission_install.js must not list Base mainnet (8453) in SUPPORTED_CHAIN_IDS for the MVP"
  end

  test "hook pushes a wrong-chain event instead of switching chains", %{source: source} do
    assert source =~ "session_permission_install:wrong_chain",
           "session_permission_install.js must push wrong_chain when the wallet is on a non-Sepolia network"
  end

  test "hook classifies failures into the documented allowlist", %{source: source} do
    # The Phoenix-side `parse_install_failure_reason/1` accepts
    # exactly this set; any new failure atom must be added on
    # both sides simultaneously.
    expected_reasons = [
      "user_rejected",
      "insufficient_gas",
      "bundler_rejected",
      "network_error",
      "unknown_error"
    ]

    for reason <- expected_reasons do
      assert source =~ ~s/return "#{reason}"/,
             "session_permission_install.js classifyError must produce `#{reason}`"
    end
  end

  test "hook code does NOT reach for unlimited approval / arbitrary calldata / withdraw surfaces",
       %{code: code} do
    # Code-level forbidden: actual function calls or token
    # references the hook would only have if it were trying to
    # build an approval / withdraw / borrow path. The moduledoc
    # explains what's NOT in scope using these same words; this
    # test runs against `code` (comments stripped) so the
    # moduledoc explanation is allowed.
    forbidden = [
      "MaxUint256",
      "approve(",
      "withdraw(",
      "redeem(",
      "borrow("
    ]

    for token <- forbidden do
      refute code =~ token,
             "session_permission_install.js code must not reference `#{token}` — those surfaces belong to operator-only or post-MVP paths"
    end
  end
end
