defmodule BankWeb.WalletConnectHookSafetyTest do
  @moduledoc """
  Source-level invariants for `assets/js/hooks/wallet_connect.js`.

  Acceptance criteria pinned by #168 and tightened by #169:

    * No private key handling anywhere.
    * No transaction broadcast.
    * Only `personal_sign` is allowed for signing — typed-data,
      legacy `eth_sign`, and `eth_signTransaction` stay forbidden so
      the hook can never be talked into signing a transaction or an
      arbitrary structured payload.
    * `personal_sign` is only ever invoked inside `signChallenge`,
      which the server triggers via a `wallet_connect:challenge` push
      event. The hook never builds the message itself.

  We enforce these at source level so the rule survives future edits
  even when no JS test stack is wired up.
  """

  use ExUnit.Case, async: true

  @hook_path Path.expand("../../../assets/js/hooks/wallet_connect.js", __DIR__)

  setup_all do
    {:ok, source: File.read!(@hook_path)}
  end

  test "hook file exists at the documented path" do
    assert File.exists?(@hook_path),
           "Expected wallet_connect hook at #{@hook_path}"
  end

  test "hook never references private key or mnemonic material", %{source: source} do
    refute source =~ "privateKey"
    refute source =~ "private_key"
    refute source =~ "mnemonic"
    refute source =~ "seed_phrase"
  end

  test "hook never invokes broadcast JSON-RPC methods", %{source: source} do
    forbidden = [
      "eth_sendTransaction",
      "eth_sendRawTransaction",
      "wallet_sendTransaction"
    ]

    for method <- forbidden do
      refute source =~ method,
             "wallet_connect.js must not broadcast (#{method} is out of scope)"
    end
  end

  test "hook never invokes signing methods other than personal_sign", %{source: source} do
    # `personal_sign` is the only signing method #169 allows. The hook
    # must NOT touch typed-data signing, raw eth_sign, or transaction
    # signing — even by accident, so the substring is forbidden.
    forbidden = [
      "eth_signTransaction",
      "eth_signTypedData",
      "eth_signTypedData_v3",
      "eth_signTypedData_v4"
    ]

    for method <- forbidden do
      refute source =~ method,
             "wallet_connect.js must not invoke #{method} — only personal_sign is in scope"
    end

    # Bare `eth_sign` is dangerous because it signs any 32-byte hash.
    # Allow it only as a substring inside `eth_signTransaction` or
    # `eth_signTypedData`, which we've already banned. A standalone
    # `"eth_sign"` literal must not appear.
    refute source =~ ~r/"eth_sign"/,
           "wallet_connect.js must not invoke the legacy eth_sign method — use personal_sign"
  end

  test "hook only uses approved JSON-RPC methods", %{source: source} do
    # Approved set:
    #   - eth_requestAccounts: gated behind a user click
    #   - eth_accounts:        passive read after `accountsChanged`
    #   - eth_chainId:         passive read of active network
    #   - personal_sign:       only invoked from `signChallenge` in
    #                          response to a server-issued challenge
    allowed = ~w(eth_requestAccounts eth_accounts eth_chainId personal_sign)

    used =
      ~r/method:\s*"([a-zA-Z_][a-zA-Z0-9_]*)"/
      |> Regex.scan(source)
      |> Enum.map(fn [_full, m] -> m end)
      |> Enum.uniq()

    extras = used -- allowed

    assert extras == [],
           "wallet_connect.js uses unexpected JSON-RPC methods: #{inspect(extras)}. " <>
             "Only #{inspect(allowed)} are approved."
  end

  test "hook gates eth_requestAccounts behind a user click", %{source: source} do
    assert source =~ "beginConnect"
    assert source =~ "handleClick"
    assert source =~ ~r/handleClick.*?wallet-connect-btn/s
    assert source =~ ~r/beginConnect.*?eth_requestAccounts/s
  end

  test "hook gates personal_sign behind a server-issued challenge", %{source: source} do
    # personal_sign must only run from `signChallenge`, which is wired
    # to the server-pushed `wallet_connect:challenge` event. The hook
    # must not build the message itself — the server alone owns nonce,
    # expiry, and shape.
    assert source =~ "signChallenge"
    assert source =~ ~r/wallet_connect:challenge.*?signChallenge/s
    assert source =~ ~r/signChallenge.*?personal_sign/s
  end

  test "hook restricts the active chain to Base Sepolia for the MVP", %{source: source} do
    # Base mainnet (8453) must surface as wrong-chain so the operator
    # switches before a binding challenge is issued. Only 84532 is
    # supported in the MVP.
    assert source =~ ~r/SUPPORTED_CHAIN_IDS\s*=\s*\[84_?532\]/,
           "wallet_connect.js must declare Base Sepolia as the only supported chain"

    refute source =~ ~r/SUPPORTED_CHAIN_IDS\s*=\s*\[8453/,
           "wallet_connect.js must not list Base mainnet (8453) in SUPPORTED_CHAIN_IDS for the MVP"
  end
end
