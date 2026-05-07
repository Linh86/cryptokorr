defmodule Mix.Tasks.Bank.BrowserInstall.SmokeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  @env_vars ~w(BANK_ENDPOINT OPERATOR_API_KEY BASE_RPC_URL BUNDLER_RPC_URL BASE_SEPOLIA_CHAIN_ID BASE_CHAIN_ID)

  setup do
    saved =
      Enum.map(@env_vars, fn key -> {key, System.get_env(key)} end)

    saved_app_config =
      Application.get_env(:bank, Bank.SessionPermissions.BrowserInstall, [])

    on_exit(fn ->
      Enum.each(saved, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      Application.put_env(
        :bank,
        Bank.SessionPermissions.BrowserInstall,
        saved_app_config
      )
    end)

    Enum.each(@env_vars, &System.delete_env/1)
    :ok
  end

  describe "mix bank.browser_install.smoke (preflight only)" do
    test "with no env, exits non-zero and prints reviewer checklist + per-var errors" do
      output =
        capture_io(:stdio, fn ->
          assert catch_exit(Mix.Tasks.Bank.BrowserInstall.Smoke.run([])) == {:shutdown, 1}
        end)

      # Header.
      assert output =~ "Browser ZeroDev install smoke"
      assert output =~ "preflight only"

      # Per-var failures.
      for var <- ~w(BANK_ENDPOINT OPERATOR_API_KEY BASE_RPC_URL BUNDLER_RPC_URL) do
        assert output =~ var,
               "expected output to mention required env var #{var}"
      end

      assert output =~ "ERROR",
             "expected per-var error markers"

      # Reviewer checklist mirrors the runbook.
      assert output =~ "Reviewer checklist"
      assert output =~ "EIP-191 binding challenge"
      assert output =~ "EIP-712 install signature"
      assert output =~ "delegation.install_envelope_issued"
      assert output =~ "delegation.install_signed_by_user"
      assert output =~ "delegation.install_broadcast"
      assert output =~ "delegation.install_confirmed_onchain"

      # Closing posture.
      assert output =~ "No RPC calls were made."
      assert output =~ "No bundler calls were made."
      assert output =~ "No secret values were printed."
      assert output =~ "No chain state was modified."
    end

    test "with all required env set, exits 0 and prints ok markers" do
      System.put_env("BANK_ENDPOINT", "http://localhost:4000")
      System.put_env("OPERATOR_API_KEY", "cb_abcdefgh_ignored_in_output")
      System.put_env("BASE_RPC_URL", "https://sepolia.base.org")

      System.put_env(
        "BUNDLER_RPC_URL",
        "https://api.pimlico.io/v1/base-sepolia/rpc?apikey=secret"
      )

      Application.put_env(
        :bank,
        Bank.SessionPermissions.BrowserInstall,
        bundler_rpc_url: "https://api.pimlico.io/v1/base-sepolia/rpc?apikey=secret"
      )

      output =
        capture_io(:stdio, fn ->
          assert :ok = Mix.Tasks.Bank.BrowserInstall.Smoke.run([])
        end)

      assert output =~ "BANK_ENDPOINT:"
      assert output =~ "http://localhost:4000"
      assert output =~ "ok"
      refute output =~ "ERROR"

      # API key is reduced to a safe prefix; full key never present.
      refute output =~ "cb_abcdefgh_ignored_in_output",
             "preflight task leaked the full API key into stdout"

      assert output =~ "cb_abcdefgh***",
             "preflight task did not redact the API key to its safe prefix"

      # URL with embedded api key flagged as sensitive without printing the value.
      assert output =~ "key in URL — treat as sensitive"

      refute output =~ "apikey=secret",
             "preflight task leaked the bundler URL's embedded API key"
    end

    test "refuses --confirm and exits {:shutdown, 2} with a clear message" do
      System.put_env("BANK_ENDPOINT", "http://localhost:4000")

      output =
        capture_io(:stderr, fn ->
          assert catch_exit(Mix.Tasks.Bank.BrowserInstall.Smoke.run(["--confirm"])) ==
                   {:shutdown, 2}
        end)

      assert output =~ "refused argument: --confirm"
      assert output =~ "preflight-only"
      assert output =~ "Path A" or output =~ "browser hook's job"
      assert output =~ "Path B" or output =~ "cast"
    end

    test "refuses --broadcast / --send / --sign / --execute the same way" do
      for arg <- ["--broadcast", "--send", "--sign", "--execute"] do
        output =
          capture_io(:stderr, fn ->
            assert catch_exit(Mix.Tasks.Bank.BrowserInstall.Smoke.run([arg])) == {:shutdown, 2}
          end)

        assert output =~ "refused argument: #{arg}",
               "expected refusal for #{arg}; got #{inspect(output)}"
      end
    end

    test "refuses Base mainnet chain id (8453) loudly" do
      System.put_env("BANK_ENDPOINT", "http://localhost:4000")
      System.put_env("OPERATOR_API_KEY", "cb_xyz")
      System.put_env("BASE_RPC_URL", "https://example")
      System.put_env("BUNDLER_RPC_URL", "https://example")
      System.put_env("BASE_SEPOLIA_CHAIN_ID", "8453")

      Application.put_env(
        :bank,
        Bank.SessionPermissions.BrowserInstall,
        bundler_rpc_url: "https://example"
      )

      output =
        capture_io(:stdio, fn ->
          assert catch_exit(Mix.Tasks.Bank.BrowserInstall.Smoke.run([])) == {:shutdown, 1}
        end)

      assert output =~ "Base Sepolia only",
             "task did not refuse Base mainnet chain id 8453"

      assert output =~ "84532",
             "task did not name the expected Base Sepolia chain id"
    end

    test "BASE_CHAIN_ID also triggers the chain check (alternate var name)" do
      System.put_env("BANK_ENDPOINT", "http://localhost:4000")
      System.put_env("OPERATOR_API_KEY", "cb_xyz")
      System.put_env("BASE_RPC_URL", "https://example")
      System.put_env("BUNDLER_RPC_URL", "https://example")
      System.put_env("BASE_CHAIN_ID", "84532")

      Application.put_env(
        :bank,
        Bank.SessionPermissions.BrowserInstall,
        bundler_rpc_url: "https://example"
      )

      output =
        capture_io(:stdio, fn ->
          assert :ok = Mix.Tasks.Bank.BrowserInstall.Smoke.run([])
        end)

      assert output =~ "84532"
      refute output =~ "ERROR"
    end

    test "non-integer chain id is reported, not crashed" do
      System.put_env("BANK_ENDPOINT", "http://localhost:4000")
      System.put_env("OPERATOR_API_KEY", "cb_xyz")
      System.put_env("BASE_RPC_URL", "https://example")
      System.put_env("BUNDLER_RPC_URL", "https://example")
      System.put_env("BASE_SEPOLIA_CHAIN_ID", "not_a_number")

      Application.put_env(
        :bank,
        Bank.SessionPermissions.BrowserInstall,
        bundler_rpc_url: "https://example"
      )

      output =
        capture_io(:stdio, fn ->
          assert catch_exit(Mix.Tasks.Bank.BrowserInstall.Smoke.run([])) == {:shutdown, 1}
        end)

      assert output =~ "not an integer"
    end

    test "missing :bank, BrowserInstall :bundler_rpc_url is reported as a config error" do
      System.put_env("BANK_ENDPOINT", "http://localhost:4000")
      System.put_env("OPERATOR_API_KEY", "cb_xyz")
      System.put_env("BASE_RPC_URL", "https://example")
      System.put_env("BUNDLER_RPC_URL", "https://example")

      Application.put_env(
        :bank,
        Bank.SessionPermissions.BrowserInstall,
        []
      )

      output =
        capture_io(:stdio, fn ->
          assert catch_exit(Mix.Tasks.Bank.BrowserInstall.Smoke.run([])) == {:shutdown, 1}
        end)

      assert output =~ "BrowserInstall"
      assert output =~ "bundler_rpc_url"
      assert output =~ "ERROR"
    end
  end
end
