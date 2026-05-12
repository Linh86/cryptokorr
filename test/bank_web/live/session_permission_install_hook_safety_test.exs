defmodule BankWeb.SessionPermissionInstallHookSafetyTest do
  @moduledoc """
  Source-level invariants for the browser-driven session permission
  install hook (#473, rewritten to use the real ZeroDev SDK +
  bundler under #501).

  The hook now constructs an EIP-4337 install UserOperation with
  ZeroDev SDK + viem, signs it via the user's wallet, and submits
  to a Phoenix-issued bundler RPC URL. The hard safety boundaries
  are:

    * No private keys, no mnemonics, no seed-phrase material.
    * No transaction broadcast methods (`eth_sendTransaction`,
      `eth_sendRawTransaction`, `wallet_sendTransaction`,
      `wallet_addEthereumChain`, `wallet_switchEthereumChain`).
    * No legacy `eth_sign` and no hand-built typed-data payloads.
      The install enable signature is built by the ZeroDev SDK +
      viem against the canonical envelope; the hook source never
      authors a typed-data struct or invokes
      `eth_signTypedData*` literally — that string must not appear
      in the hook source. (The SDK calls it internally inside
      `node_modules`, which the hook source does not contain.)
    * No hardcoded bundler URLs — the hook reads
      `envelope.bundler_rpc_url`.
    * No production `setTimeout(...)` confirmation transition —
      the synthetic stand-in from the original scaffold is gone.
    * The active chain is restricted to Base Sepolia (84532); the
      wallet chain AND the envelope chain BOTH must equal 84532.
    * Failure reasons are restricted to
      `Bank.SessionPermissions.BrowserInstall.failure_categories/0`.
    * No unlimited approval, no arbitrary calldata, no
      borrow/leverage/withdraw authority surface — those are
      Phoenix-side scope decisions; the hook never reaches for
      them.

  Pinned at source level so the rule survives future edits even
  when no JS test stack is wired up. Mirrors
  `wallet_connect_hook_safety_test.exs`.
  """

  use ExUnit.Case, async: true

  @hook_dir Path.expand("../../../assets/js/hooks", __DIR__)
  @hook_path Path.join(@hook_dir, "session_permission_install.js")
  @envelope_path Path.join(@hook_dir, "install_envelope_client.js")
  @zerodev_path Path.join(@hook_dir, "install_zerodev_client.js")

  setup_all do
    full = File.read!(@hook_path)
    envelope = File.read!(@envelope_path)
    zerodev = File.read!(@zerodev_path)
    # Source-pin tests focus on actual JS code, not documentation.
    # Strip `//` line comments so the moduledoc can use plain
    # English to enumerate forbidden tokens (e.g. "no mnemonic")
    # without the test flagging its own description.
    code_only =
      [full, envelope, zerodev]
      |> Enum.map(&strip_line_comments/1)
      |> Enum.join("\n")

    {:ok,
     source_combined: full <> "\n" <> envelope <> "\n" <> zerodev,
     hook_source: full,
     code: code_only}
  end

  defp strip_line_comments(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.replace(&1, ~r{//.*$}, ""))
    |> Enum.join("\n")
  end

  test "hook file exists at the documented path" do
    assert File.exists?(@hook_path),
           "Expected session_permission_install hook at #{@hook_path}"

    assert File.exists?(@envelope_path),
           "Expected install envelope client at #{@envelope_path}"

    assert File.exists?(@zerodev_path),
           "Expected ZeroDev install client at #{@zerodev_path}"
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
             "session permission install hook source must not invoke #{method} (out of scope for #501)"
    end
  end

  test "hook source never literally invokes eth_signTypedData* or legacy eth_sign", %{
    source_combined: source
  } do
    # The ZeroDev SDK + viem call `eth_signTypedData_v4` internally
    # to sign the install enable typed-data; those calls live in
    # `node_modules/...` and never appear in our hook source. We
    # pin that the hook itself never authors the literal RPC name.
    forbidden = [
      "eth_signTransaction",
      "eth_signTypedData",
      "eth_signTypedData_v3",
      "eth_signTypedData_v4"
    ]

    for method <- forbidden do
      refute source =~ method,
             "session permission install hook source must not invoke #{method} — those calls happen INSIDE the SDK / viem, not in our source"
    end

    refute source =~ ~r/"eth_sign"/,
           "session permission install hook source must not invoke the legacy eth_sign method"
  end

  test "hook only invokes the documented allowlist of provider RPC methods", %{
    source_combined: source
  } do
    # `eth_accounts` is added by the wallet-state-divergence preflight
    # (P0). It is the PASSIVE counterpart of `eth_requestAccounts` —
    # returns currently-exposed accounts without prompting MetaMask —
    # and is signing-free / fund-safe. The hook uses it once, before
    # `fetchInstallEnvelope`, to refuse early when the operator's
    # browser provider has dropped the origin (or switched to a
    # different account) since the DB binding was issued.
    #
    # `eth_maxPriorityFeePerGas` + `eth_gasPrice` are the standard
    # EIP-1559 gas-price probes used by the bundler-agnostic
    # `estimateFeesPerGas` fallback in `submitInstall`. ZeroDev SDK's
    # default callback calls `zd_getUserOperationGasPrice` — a
    # ZeroDev-bundler-only RPC method. When the operator's bundler is
    # Pimlico / Stackup / Candide (which don't implement that method),
    # we fall through to standard EIP-1559 via the chain RPC. Both
    # methods are read-only and signing-free / fund-safe.
    allowed =
      ~w(eth_chainId eth_requestAccounts eth_accounts eth_getBalance eth_maxPriorityFeePerGas eth_gasPrice)

    # Match only EIP-1193 / wallet RPC method strings — anything
    # named `eth_*` / `wallet_*` / `personal_*` inside a `method:`
    # property. This ignores HTTP method literals (`"GET"`,
    # `"POST"`) that the envelope client uses with `fetch`.
    used =
      ~r/method:\s*"((?:eth|wallet|personal)_[a-zA-Z0-9_]*)"/
      |> Regex.scan(source)
      |> Enum.map(fn [_full, m] -> m end)
      |> Enum.uniq()

    extras = used -- allowed

    assert extras == [],
           "session permission install hook source uses unexpected JSON-RPC methods: #{inspect(extras)}. Only #{inspect(allowed)} are approved."
  end

  test "hook gates the install behind a user click", %{hook_source: source} do
    assert source =~ "beginInstall"
    assert source =~ "handleClick"
    assert source =~ ~r/handleClick.*?session-permission-browser-install-btn/s
    assert source =~ ~r/beginInstall.*?eth_chainId/s
  end

  test "hook fetches the canonical envelope from the browser route", %{source_combined: source} do
    # Browser routes (no /v1/ prefix) — Phoenix is the source of
    # truth for the envelope. Worker B ships #500.
    assert source =~ "/wallet_bindings/"
    assert source =~ "/install_envelope"
    assert source =~ "/install_attestation"
    assert source =~ "csrf-token"

    refute source =~ "/v1/wallet_bindings/",
           "browser routes intentionally drop the /v1/ prefix; #500 contract"
  end

  test "hook never hardcodes a bundler URL", %{source_combined: source} do
    assert source =~ "envelope.bundler_rpc_url",
           "the bundler URL must come from the canonical Phoenix envelope"

    refute source =~ ~r{https?://[^\s"']*pimlico\.io}i,
           "no Pimlico URL may be hardcoded in the hook source"

    refute source =~ ~r{https?://[^\s"']*alchemy\.com}i,
           "no Alchemy URL may be hardcoded in the hook source"

    refute source =~ ~r{https?://[^\s"']*rpc\.zerodev\.app}i,
           "no ZeroDev hosted bundler URL may be hardcoded in the hook source"
  end

  test "hook restricts the active chain to Base Sepolia for the MVP", %{hook_source: source} do
    assert source =~ ~r/SUPPORTED_CHAIN_IDS\s*=\s*\[84_?532\]/,
           "session_permission_install.js must declare Base Sepolia as the only supported chain"

    refute source =~ ~r/SUPPORTED_CHAIN_IDS\s*=\s*\[8453/,
           "session_permission_install.js must not list Base mainnet (8453) in SUPPORTED_CHAIN_IDS for the MVP"
  end

  test "hook pushes a wrong-chain event for both wallet and envelope chain mismatches", %{
    hook_source: source
  } do
    assert source =~ "session_permission_install:wrong_chain"
    assert source =~ ~r/walletChainId.*wrong_chain/s
    assert source =~ ~r/envelope\.chain_id.*wrong_chain/s
  end

  test "hook is wired through the real ZeroDev SDK + bundler submission", %{
    source_combined: source
  } do
    # Mirrors chain_adapter/src/chains/base/grant.ts call shape.
    assert source =~ "submitInstall"
    assert source =~ "@zerodev/sdk"
    assert source =~ "@zerodev/permissions"
    assert source =~ "@zerodev/ecdsa-validator"
    assert source =~ "viem"
    assert source =~ "createKernelAccount"
    assert source =~ "createKernelAccountClient"
    assert source =~ "sendUserOperation"
    assert source =~ "waitForUserOperationReceipt"
    assert source =~ "toPermissionValidator"
    assert source =~ "toSudoPolicy"
    assert source =~ "signerToEcdsaValidator"
  end

  test "hook source no longer carries the synthetic setTimeout confirmation transition", %{
    hook_source: hook_source,
    source_combined: combined
  } do
    # The original scaffold synthesised the bundler
    # `submitted → confirmed` transition with
    # `window.setTimeout(...)`. #501 replaces it with a real
    # bundler receipt poll; the literal must not survive.
    refute hook_source =~ "setTimeout",
           "production hook must not carry a setTimeout confirmation stand-in (#501)"

    refute hook_source =~ "SYNTHETIC_CONFIRMATION_MS",
           "production hook must not carry the synthetic confirmation constant"

    # Defense in depth: even the helpers shouldn't fire setTimeout
    # for the confirmation transition. (Tests under
    # `assets/js/hooks/__tests__/` may use timers — they're not
    # covered by this combined-source assertion since the test
    # files don't sit under hooks/.)
    refute combined =~ ~r/setTimeout\s*\(\s*[^)]*confirmed/,
           "synthetic confirmation transition must not survive in any production hook source"
  end

  test "hook classifies failures into the BrowserInstall.failure_categories allowlist", %{
    source_combined: source
  } do
    # Phoenix's `parse_install_failure_reason/1` accepts exactly
    # these atoms; any new failure reason must be added on both
    # sides simultaneously.
    expected_reasons = [
      "user_rejected",
      "bundler_rejected",
      "bundler_unavailable",
      "bundler_not_configured",
      "chain_id_mismatch",
      "insufficient_funds",
      "userop_reverted",
      "attestation_timeout",
      "wallet_not_connected",
      "account_mismatch",
      "kernel_account_collision",
      "session_signer_unavailable",
      "session_signer_refused",
      "unknown"
    ]

    for reason <- expected_reasons do
      assert source =~ ~s/return "#{reason}"/ or
               source =~ ~s/reason: "#{reason}"/ or
               source =~ ~s/case "#{reason}"/,
             "browser install hook must reference failure reason `#{reason}` from BrowserInstall.failure_categories/0"
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
             "session permission install hook source must not reference `#{token}` — those surfaces belong to operator-only or post-MVP paths"
    end
  end

  test "hook reads binding id from the install button's data-binding-id attribute", %{
    hook_source: source
  } do
    assert source =~ "data-binding-id" or source =~ "dataset.bindingId" or
             source =~ "bindingId",
           "hook must read the binding id from a data-binding-id attribute (Worker B's #500 contract)"
  end
end
