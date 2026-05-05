defmodule BankWeb.WalletConnectHookSafetyTest do
  @moduledoc """
  Source-level invariants for `assets/js/hooks/wallet_connect.js`.

  Issue #168 explicitly forbids the hook from signing or broadcasting
  anything. The acceptance criteria pin "no private key handling
  exists anywhere" and "no transaction broadcast" as hard rules. We
  enforce that at source level so the rule survives future edits even
  if the JS test stack is unavailable.
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

  test "hook never invokes signing JSON-RPC methods", %{source: source} do
    forbidden = [
      "personal_sign",
      "eth_sign",
      "eth_signTransaction",
      "eth_signTypedData",
      "eth_signTypedData_v3",
      "eth_signTypedData_v4"
    ]

    for method <- forbidden do
      refute source =~ method,
             "wallet_connect.js must not invoke #{method} (signing is out of scope for #168)"
    end
  end

  test "hook never invokes broadcast JSON-RPC methods", %{source: source} do
    forbidden = [
      "eth_sendTransaction",
      "eth_sendRawTransaction",
      "wallet_sendTransaction"
    ]

    for method <- forbidden do
      refute source =~ method,
             "wallet_connect.js must not broadcast (#{method} is out of scope for #168)"
    end
  end

  test "hook only uses the read-only EIP-1193 methods declared in scope", %{source: source} do
    allowed = ~w(eth_requestAccounts eth_accounts eth_chainId)

    used =
      ~r/method:\s*"(eth_[A-Za-z0-9_]+)"/
      |> Regex.scan(source)
      |> Enum.map(fn [_full, m] -> m end)
      |> Enum.uniq()

    extras = used -- allowed

    assert extras == [],
           "wallet_connect.js uses unexpected EIP-1193 methods: #{inspect(extras)}. " <>
             "Only #{inspect(allowed)} are in scope for #168."
  end

  test "hook gates eth_requestAccounts behind a user click", %{source: source} do
    # The hook must only call eth_requestAccounts inside a click-driven path.
    # We assert the method is reached through the `beginConnect` function
    # which is invoked from the click delegation in `handleClick`.
    assert source =~ "beginConnect"
    assert source =~ "handleClick"
    assert source =~ ~r/handleClick.*?wallet-connect-btn/s
    assert source =~ ~r/beginConnect.*?eth_requestAccounts/s
  end
end
