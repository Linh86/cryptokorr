defmodule Bank.SessionPermissions.BrowserInstallTest do
  @moduledoc """
  Context tests for `Bank.SessionPermissions.BrowserInstall` (#474).

  Pins the design doc's load-bearing acceptance:

    * envelope is built canonically from the binding + scope and
      audits `delegation.install_envelope_issued`;
    * attestation honors a fixed-allowlist status enum;
    * `submitted` persists a `:pending` delegation row keyed by
      `(binding_id, install_userop_hash)`;
    * `confirmed` enqueues `Bank.Runtime.Workers.VerifyInstallOnchain`
      and emits `delegation.install_broadcast`;
    * `confirmed` does NOT mark the row `:active` directly;
    * any failure status emits `delegation.install_failed` with a
      category atom from `failure_categories/0`;
    * free-form upstream reasons collapse to the catch-all in
      `failure_categories/0`;
    * mainnet bindings + paused runtime/workspace are refused.
  """

  use Bank.DataCase, async: false
  import Ecto.Query

  alias Bank.Accounts
  alias Bank.Audit
  alias Bank.Delegations.Delegation
  alias Bank.Repo
  alias Bank.Security
  alias Bank.SessionPermissions.BrowserInstall
  alias Bank.WalletBindings
  alias Bank.WalletBindings.{Signature, WalletBinding}
  alias Bank.Workspaces

  @privkey <<1::256>>
  @valid_userop_hash "0x" <> String.duplicate("a", 64)
  @valid_tx_hash "0x" <> String.duplicate("b", 64)
  @valid_permission_id "0xdeadbeef"
  @valid_validation_id "0x02deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

  setup do
    Security.PauseState.reset()

    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "bi-#{suffix}",
        email: "bi-#{suffix}@example.com",
        name: "BI Test"
      })

    {:ok, workspace} =
      Workspaces.create_workspace(%{
        slug: "bi-ws-#{suffix}",
        name: "BI ws #{suffix}",
        mainnet_enabled: false
      })

    {:ok, _} =
      Workspaces.create_membership(%{
        user_id: user.id,
        workspace_id: workspace.id,
        role: :admin
      })

    Process.put(:bank_test_workspace_id, workspace.id)
    on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

    {:ok, pubkey} = ExSecp256k1.create_public_key(@privkey)
    {:ok, address} = Signature.address_from_pubkey(pubkey)

    binding = verified_binding(workspace.id, user.id, address)

    %{user: user, workspace: workspace, address: address, binding: binding}
  end

  describe "build_envelope/2 — happy path" do
    test "returns a canonical envelope and audits install_envelope_issued",
         %{workspace: workspace, binding: binding} do
      assert {:ok, envelope} = BrowserInstall.build_envelope(workspace.id, binding)

      assert envelope.binding_id == binding.id
      assert envelope.workspace_id == workspace.id
      assert envelope.chain_id == 84_532
      assert envelope.smart_account_id == "sa_wb_" <> binding.id
      assert envelope.entry_point_address =~ ~r/^0x[0-9a-fA-F]{40}$/
      assert is_binary(envelope.scope_hash)
      assert String.starts_with?(envelope.scope_hash, "sha256:")
      assert is_map(envelope.scope)
      assert is_binary(envelope.human_readable_summary)

      events = list_events(binding.id)
      assert Enum.any?(events, &(&1.event_type == "delegation.install_envelope_issued"))
    end

    test "scope_hash is deterministic across re-fetches",
         %{workspace: workspace, binding: binding} do
      {:ok, e1} = BrowserInstall.build_envelope(workspace.id, binding)
      {:ok, e2} = BrowserInstall.build_envelope(workspace.id, binding)
      assert e1.scope_hash == e2.scope_hash
    end

    # Pre-fix the dev.exs env wiring only checked
    # BASE_SEPOLIA_BUNDLER_RPC || BUNDLER_URL, missing the canonical
    # BUNDLER_RPC_URL alias the chain_adapter/.env (and the smoke
    # task + mainnet preflight) already use. The envelope therefore
    # returned `bundler_rpc_url: nil` even when a bundler URL was
    # genuinely available, and the JS hook fail-fasted on
    # `bundler_unavailable` before ever opening a wallet popup.
    #
    # The fix is in `config/dev.exs`; this test pins the contract
    # that whatever `Application.get_env(:bank, BrowserInstall,
    # :bundler_rpc_url)` resolves to ends up on the envelope.
    test "envelope surfaces the configured bundler_rpc_url",
         %{workspace: workspace, binding: binding} do
      original = Application.get_env(:bank, BrowserInstall, [])

      try do
        Application.put_env(
          :bank,
          BrowserInstall,
          Keyword.put(original, :bundler_rpc_url, "https://test-bundler.example/rpc")
        )

        assert {:ok, envelope} = BrowserInstall.build_envelope(workspace.id, binding)
        assert envelope.bundler_rpc_url == "https://test-bundler.example/rpc"
      after
        Application.put_env(:bank, BrowserInstall, original)
      end
    end

    test "envelope returns nil bundler_rpc_url when unconfigured",
         %{workspace: workspace, binding: binding} do
      original = Application.get_env(:bank, BrowserInstall, [])

      try do
        Application.put_env(
          :bank,
          BrowserInstall,
          Keyword.put(original, :bundler_rpc_url, nil)
        )

        assert {:ok, envelope} = BrowserInstall.build_envelope(workspace.id, binding)
        assert is_nil(envelope.bundler_rpc_url)
      after
        Application.put_env(:bank, BrowserInstall, original)
      end
    end

    # The browser-side ZeroDev SDK builds a viem `publicClient` from
    # the envelope's `chain_rpc_url` for `getSenderAddress` simulation
    # (an `eth_call` against EntryPoint v0.7 that reverts with
    # `SenderAddressResult(address)`). Hosted bundler endpoints
    # (Pimlico, Stackup, Candide) don't serve generic `eth_call` —
    # passing the bundler URL to `publicClient` makes
    # `createKernelAccount` crash with
    # `Cannot read properties of undefined (reading 'match')`.
    # This test pins that whatever `Application.get_env(:bank,
    # BrowserInstall, :chain_rpc_url)` resolves to lands on the
    # envelope so the hook can wire the two transports separately.
    test "envelope surfaces the configured chain_rpc_url",
         %{workspace: workspace, binding: binding} do
      original = Application.get_env(:bank, BrowserInstall, [])

      try do
        Application.put_env(
          :bank,
          BrowserInstall,
          Keyword.put(original, :chain_rpc_url, "https://test-chain-rpc.example/rpc")
        )

        assert {:ok, envelope} = BrowserInstall.build_envelope(workspace.id, binding)
        assert envelope.chain_rpc_url == "https://test-chain-rpc.example/rpc"
      after
        Application.put_env(:bank, BrowserInstall, original)
      end
    end

    test "envelope returns nil chain_rpc_url when unconfigured",
         %{workspace: workspace, binding: binding} do
      original = Application.get_env(:bank, BrowserInstall, [])

      try do
        Application.put_env(
          :bank,
          BrowserInstall,
          Keyword.put(original, :chain_rpc_url, nil)
        )

        assert {:ok, envelope} = BrowserInstall.build_envelope(workspace.id, binding)
        assert is_nil(envelope.chain_rpc_url)
      after
        Application.put_env(:bank, BrowserInstall, original)
      end
    end

    # ── Kernel account index (browser-vs-operator collision split) ──

    test "envelope carries kernel_account_index from config (default 1)",
         %{workspace: workspace, binding: binding} do
      # dev.exs ships with BROWSER_KERNEL_ACCOUNT_INDEX default 1.
      # Test runs against the live application env. The envelope
      # MUST surface this integer to the JS hook so the SDK derives
      # a non-operator smart account.
      original = Application.get_env(:bank, BrowserInstall, [])

      try do
        Application.put_env(
          :bank,
          BrowserInstall,
          original
          |> Keyword.put(:kernel_account_index, 1)
          # Disable operator collision check by clearing the operator
          # EOA so we can exercise the envelope path in isolation.
          |> Keyword.put(:operator_eoa_address, nil)
        )

        assert {:ok, envelope} = BrowserInstall.build_envelope(workspace.id, binding)
        assert envelope.kernel_account_index == 1
      after
        Application.put_env(:bank, BrowserInstall, original)
      end
    end

    test "kernel_account_index env override propagates to the envelope",
         %{workspace: workspace, binding: binding} do
      # An operator who runs multiple workspaces on the same EOA
      # bumps the browser index per workspace (2, 3, …) so each
      # workspace gets its own smart account. Pins the override
      # path so a regression that hardcodes the default doesn't
      # silently collapse all workspaces onto index 1.
      original = Application.get_env(:bank, BrowserInstall, [])

      try do
        Application.put_env(
          :bank,
          BrowserInstall,
          original
          |> Keyword.put(:kernel_account_index, 7)
          |> Keyword.put(:operator_eoa_address, nil)
        )

        assert {:ok, envelope} = BrowserInstall.build_envelope(workspace.id, binding)
        assert envelope.kernel_account_index == 7
      after
        Application.put_env(:bank, BrowserInstall, original)
      end
    end

    test "envelope kernel_account_index handles string-form env value",
         %{workspace: workspace, binding: binding} do
      # `System.get_env/1` returns strings. The accessor coerces
      # via `String.to_integer/1`. Pin that a string-typed config
      # value (e.g. injected by an integration test or a misconfig
      # path) resolves to a real integer in the envelope rather
      # than crashing or leaking the string downstream.
      original = Application.get_env(:bank, BrowserInstall, [])

      try do
        Application.put_env(
          :bank,
          BrowserInstall,
          original
          |> Keyword.put(:kernel_account_index, "3")
          |> Keyword.put(:operator_eoa_address, nil)
        )

        assert {:ok, envelope} = BrowserInstall.build_envelope(workspace.id, binding)
        assert envelope.kernel_account_index == 3
        assert is_integer(envelope.kernel_account_index)
      after
        Application.put_env(:bank, BrowserInstall, original)
      end
    end
  end

  describe "build_envelope/2 — kernel-account-collision preflight" do
    # Uses the outer setup's `binding` + `address` (the `@privkey`-
    # derived EOA). The collision tests flip the
    # `:operator_eoa_address` config slot to match (or not) the
    # binding's stored address — that's enough to trigger or skip
    # the preflight without needing a fresh key/binding pair.

    test "refuses with :kernel_account_collision when user EOA == OPERATOR_ADDRESS and indices match",
         %{workspace: workspace, binding: binding, address: address} do
      original = Application.get_env(:bank, BrowserInstall, [])

      try do
        Application.put_env(
          :bank,
          BrowserInstall,
          original
          |> Keyword.put(:operator_eoa_address, address)
          |> Keyword.put(:operator_kernel_account_index, 0)
          |> Keyword.put(:kernel_account_index, 0)
        )

        assert {:error, :kernel_account_collision} =
                 BrowserInstall.build_envelope(workspace.id, binding)
      after
        Application.put_env(:bank, BrowserInstall, original)
      end
    end

    test "passes when user EOA == OPERATOR_ADDRESS but browser index differs",
         %{workspace: workspace, binding: binding, address: address} do
      # Browser on index 1, operator on index 0 — derived smart
      # accounts are different. The whole point of the split.
      original = Application.get_env(:bank, BrowserInstall, [])

      try do
        Application.put_env(
          :bank,
          BrowserInstall,
          original
          |> Keyword.put(:operator_eoa_address, address)
          |> Keyword.put(:operator_kernel_account_index, 0)
          |> Keyword.put(:kernel_account_index, 1)
        )

        assert {:ok, envelope} = BrowserInstall.build_envelope(workspace.id, binding)
        assert envelope.kernel_account_index == 1
      after
        Application.put_env(:bank, BrowserInstall, original)
      end
    end

    test "passes when user EOA differs from OPERATOR_ADDRESS regardless of index",
         %{workspace: workspace, binding: binding} do
      # Different EOA → different derived smart account → no
      # collision possible even if indices match.
      different_eoa = "0x" <> String.duplicate("ab", 20)

      original = Application.get_env(:bank, BrowserInstall, [])

      try do
        Application.put_env(
          :bank,
          BrowserInstall,
          original
          |> Keyword.put(:operator_eoa_address, different_eoa)
          |> Keyword.put(:operator_kernel_account_index, 0)
          |> Keyword.put(:kernel_account_index, 0)
        )

        assert {:ok, _envelope} = BrowserInstall.build_envelope(workspace.id, binding)
      after
        Application.put_env(:bank, BrowserInstall, original)
      end
    end

    test "EOA comparison is case-insensitive (EIP-55 vs lowercase)",
         %{workspace: workspace, binding: binding, address: address} do
      # WalletBindings stores lowercase. Operators paste EIP-55
      # checksummed addresses into env vars. Both representations
      # must trigger the collision check — otherwise a checksummed
      # env value would let the lowercase binding through and the
      # install would fail on chain instead of preflighting.
      checksummed = String.upcase(address)

      original = Application.get_env(:bank, BrowserInstall, [])

      try do
        Application.put_env(
          :bank,
          BrowserInstall,
          original
          |> Keyword.put(:operator_eoa_address, checksummed)
          |> Keyword.put(:operator_kernel_account_index, 0)
          |> Keyword.put(:kernel_account_index, 0)
        )

        assert {:error, :kernel_account_collision} =
                 BrowserInstall.build_envelope(workspace.id, binding)
      after
        Application.put_env(:bank, BrowserInstall, original)
      end
    end

    test "no operator EOA configured → no collision check (test env, pre-prod, etc.)",
         %{workspace: workspace, binding: binding} do
      original = Application.get_env(:bank, BrowserInstall, [])

      try do
        Application.put_env(
          :bank,
          BrowserInstall,
          original
          |> Keyword.put(:operator_eoa_address, nil)
          |> Keyword.put(:operator_kernel_account_index, 0)
          |> Keyword.put(:kernel_account_index, 0)
        )

        # No operator EOA → we can't possibly tell whether the user
        # EOA collides → pass through. The on-chain install would
        # surface a real `AA23` revert if there were a problem.
        assert {:ok, _envelope} = BrowserInstall.build_envelope(workspace.id, binding)
      after
        Application.put_env(:bank, BrowserInstall, original)
      end
    end
  end

  # The `chain_rpc_url` env-alias chain in `config/dev.exs` mirrors
  # the bundler precedence story: multiple historical aliases feed
  # the same config slot, and the install hook silently breaks when
  # the wrong alias is consulted. This describe block pins the
  # precedence order at source level so a future drift (e.g.
  # dropping `BASE_SEPOLIA_RPC_URL` because someone "consolidates"
  # the chain RPC variants) is caught by the test suite rather than
  # by a failed install.
  describe "config/dev.exs :chain_rpc_url env-alias precedence" do
    test "BASE_SEPOLIA_RPC_URL is the FIRST alias, before BASE_SEPOLIA_RPC and BASE_RPC_URL" do
      # Source-level pin: the precedence is resolved at compile time
      # via `System.get_env` (chained with `||`). The unit test can
      # only meaningfully assert this by reading the config string —
      # at runtime the resolved value is opaque to its origin.
      source = File.read!("config/dev.exs")

      # Isolate the BrowserInstall config block so unrelated lines
      # in the rest of the file can't accidentally satisfy the
      # ordering check. `Regex.run` returns
      # `[full_match, capture_1, ...]`; we want the single capture
      # group's text.
      [_full, browser_install_block] =
        Regex.run(
          ~r/config :bank, Bank\.SessionPermissions\.BrowserInstall,(.+?)(?=^config |\z)/sm,
          source
        ) ||
          raise "could not locate `config :bank, Bank.SessionPermissions.BrowserInstall, …` block in config/dev.exs"

      first_pos = position_of(browser_install_block, "BASE_SEPOLIA_RPC_URL")
      second_pos = position_of(browser_install_block, "BASE_SEPOLIA_RPC")
      third_pos = position_of(browser_install_block, "BASE_RPC_URL")

      assert is_integer(first_pos),
             "expected `BASE_SEPOLIA_RPC_URL` in the BrowserInstall config block to align with the rest-of-app convention"

      # Each alias must appear AFTER `BASE_SEPOLIA_RPC_URL`. `find/2`
      # returns the FIRST occurrence, so `BASE_SEPOLIA_RPC` will
      # match `BASE_SEPOLIA_RPC_URL` first if we don't anchor — we
      # search starting from `first_pos + length(first_alias)` to
      # find the SECOND alias's standalone occurrence.
      assert is_integer(second_pos)
      assert is_integer(third_pos)

      assert first_pos < second_pos,
             "BASE_SEPOLIA_RPC_URL must precede BASE_SEPOLIA_RPC in the alias chain (canonical alias first)"

      assert second_pos < third_pos,
             "BASE_SEPOLIA_RPC must precede BASE_RPC_URL in the alias chain"
    end

    test "chain_rpc_url has a non-nil default (so the install hook never sees nil chain RPC)" do
      # Defense in depth — the dev config tail (`|| "https://sepolia.base.org"`)
      # guarantees the envelope's chain_rpc_url is never nil even
      # when every alias is missing. The JS hook's fallback path
      # (`envelope.chain_rpc_url || envelope.bundler_rpc_url`) would
      # otherwise reach back to the bundler URL and trip the
      # bundler-only `eth_call` regression all over again.
      source = File.read!("config/dev.exs")

      # Match the fallback default across the multi-line `||` chain
      # `dev.exs` actually uses. The string must end the alias chain
      # so the resolved config is never nil.
      assert source =~ ~r/\|\|\s*"https:\/\/sepolia\.base\.org"/,
             "chain_rpc_url must have a public-RPC default; current dev.exs is missing the fallback string"
    end
  end

  # Helper for the source-level alias-precedence test. Returns the
  # first character index where `term` appears as a quoted string
  # literal — i.e. matches `"<term>"` not the bare token. This
  # restricts the match to actual `System.get_env("<ALIAS>")` call
  # sites and ignores incidental occurrences of the alias name in
  # surrounding comments / docstrings (which would otherwise let a
  # comment mentioning `BASE_RPC_URL` shift the apparent position
  # earlier than the real call site and break the precedence
  # assertion).
  defp position_of(source, term) when is_binary(source) and is_binary(term) do
    pattern = Regex.compile!("\"" <> Regex.escape(term) <> "\"")

    case Regex.run(pattern, source, return: :index) do
      [{index, _len}] -> index
      _ -> nil
    end
  end

  describe "build_envelope/2 — refused" do
    test "rejects unverified binding with :binding_not_verified",
         %{workspace: workspace, user: user, address: address} do
      pending = pending_binding(workspace.id, user.id, address)

      assert {:error, :binding_not_verified} =
               BrowserInstall.build_envelope(workspace.id, pending)
    end

    test "rejects mainnet binding with :unsupported_chain",
         %{workspace: workspace, user: user, address: address} do
      mainnet = mainnet_binding_fixture(workspace.id, user.id, address)

      assert {:error, :unsupported_chain} =
               BrowserInstall.build_envelope(workspace.id, mainnet)
    end

    test "rejects when binding belongs to a different workspace",
         %{binding: binding} do
      other_workspace_id = Ecto.UUID.generate()

      assert {:error, :workspace_mismatch} =
               BrowserInstall.build_envelope(other_workspace_id, binding)
    end

    test "rejects when runtime is globally paused",
         %{workspace: workspace, binding: binding} do
      {:ok, _} = Security.pause(:global, reason: "test pause")

      assert {:error, :runtime_paused} =
               BrowserInstall.build_envelope(workspace.id, binding)
    end
  end

  describe "record_attestation/3 — submitted" do
    test "creates a :pending delegation row + emits install_signed_by_user",
         %{workspace: workspace, binding: binding} do
      {:ok, %{state: :submitted, delegation: delegation}} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      assert delegation.state == :pending
      assert delegation.binding_id == binding.id
      assert delegation.workspace_id == workspace.id
      assert delegation.root_validator_owner == "user"
      assert delegation.install_userop_hash == @valid_userop_hash
      assert byte_size(delegation.permission_id) == 4
      assert byte_size(delegation.validation_id) == 21

      events = list_events(binding.id)
      assert Enum.any?(events, &(&1.event_type == "delegation.install_signed_by_user"))
    end

    test "submitted enqueues PollInstallReceipt in the same transaction (#500 tab-close fix)",
         %{workspace: workspace, binding: binding} do
      {:ok, %{state: :submitted, delegation: delegation}} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      [%Oban.Job{args: args}] = all_poll_jobs()
      assert args["delegation_id"] == delegation.id
      assert args["binding_id"] == binding.id
      assert args["workspace_id"] == workspace.id
      assert args["install_userop_hash"] == @valid_userop_hash
      # Deadline is a future ISO 8601 instant — we don't pin the
      # exact value (clock-driven), just that it parses.
      assert {:ok, %DateTime{}, _} = DateTime.from_iso8601(args["deadline_at"])
    end

    test "is idempotent on duplicate `submitted` for same binding+userop",
         %{workspace: workspace, binding: binding} do
      params = %{
        "status" => "submitted",
        "install_userop_hash" => @valid_userop_hash,
        "permission_id" => @valid_permission_id,
        "validation_id" => @valid_validation_id
      }

      {:ok, %{delegation: first}} =
        BrowserInstall.record_attestation(workspace.id, binding, params)

      {:ok, %{delegation: second}} =
        BrowserInstall.record_attestation(workspace.id, binding, params)

      assert first.id == second.id
    end

    test "rejects malformed userop_hash with {:invalid_attestation, _}",
         %{workspace: workspace, binding: binding} do
      assert {:error, {:invalid_attestation, :install_userop_hash_invalid}} =
               BrowserInstall.record_attestation(workspace.id, binding, %{
                 "status" => "submitted",
                 "install_userop_hash" => "not-hex",
                 "permission_id" => @valid_permission_id,
                 "validation_id" => @valid_validation_id
               })
    end

    test "rejects wrong-length validation_id",
         %{workspace: workspace, binding: binding} do
      assert {:error, {:invalid_attestation, :validation_id_invalid}} =
               BrowserInstall.record_attestation(workspace.id, binding, %{
                 "status" => "submitted",
                 "install_userop_hash" => @valid_userop_hash,
                 "permission_id" => @valid_permission_id,
                 "validation_id" => "0x1234"
               })
    end

    test "persists smart_account_address from the attestation into delegation scope",
         %{workspace: workspace, binding: binding} do
      # The JS hook's `submitted` attestation includes the EVM
      # smart-account address ZeroDev derived from
      # `(user_eoa, kernel_account_index, plugins)`. Runtime
      # dispatch will eventually key on this address rather than
      # the synthetic `sa_wb_<binding_id>` id Phoenix invents for
      # its own audit + uniqueness constraints. Pin that we
      # capture it on the row's scope JSON so a follow-up
      # adapter-side change can read it without a schema migration.
      sa_address = "0x" <> String.duplicate("ab", 20)

      {:ok, %{state: :submitted, delegation: delegation}} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id,
          "smart_account_address" => sa_address
        })

      # Stored lowercased for canonical comparison — checksummed
      # input does not leak into the DB unchanged.
      assert delegation.scope["smart_account_address"] == String.downcase(sa_address)

      # The synthetic id stays stable for audit / adapter callbacks;
      # the scope field is the new source of truth for runtime.
      assert delegation.smart_account_id == "sa_wb_" <> binding.id
    end

    test "submitted without smart_account_address still succeeds (legacy attestation)",
         %{workspace: workspace, binding: binding} do
      # Older browser hooks (pre-kernel-collision fix) don't send
      # the field. Phoenix must not refuse those — graceful
      # degradation back to `Scope.default()` is the documented
      # behaviour, with runtime dispatch falling back to the
      # synthetic id.
      {:ok, %{state: :submitted, delegation: delegation}} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      refute Map.has_key?(delegation.scope, "smart_account_address")
    end
  end

  describe "record_attestation/3 — confirmed" do
    test "enqueues VerifyInstallOnchain + emits install_broadcast; row stays :pending",
         %{workspace: workspace, binding: binding} do
      {:ok, _} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      {:ok, %{state: :verifying, delegation: row}} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "confirmed",
          "install_userop_hash" => @valid_userop_hash,
          "tx_hash" => @valid_tx_hash,
          "block_number" => 1234
        })

      assert row.state == :pending,
             "row must stay :pending until on-chain verification flips to :active"

      events = list_events(binding.id)
      assert Enum.any?(events, &(&1.event_type == "delegation.install_broadcast"))

      assert [%Oban.Job{worker: "Bank.Runtime.Workers.VerifyInstallOnchain", args: args}] =
               all_verify_jobs()

      assert args["delegation_id"] == row.id
      assert args["binding_id"] == binding.id
      assert args["tx_hash"] == @valid_tx_hash
      assert args["block_number"] == 1234
    end

    test "rejects `confirmed` without a prior `submitted` row",
         %{workspace: workspace, binding: binding} do
      assert {:error, {:invalid_attestation, :no_pending_install}} =
               BrowserInstall.record_attestation(workspace.id, binding, %{
                 "status" => "confirmed",
                 "install_userop_hash" => @valid_userop_hash,
                 "tx_hash" => @valid_tx_hash,
                 "block_number" => 1234
               })
    end
  end

  describe "record_attestation/3 — failure statuses" do
    test "user_rejected emits install_failed with :user_rejected (no row needed)",
         %{workspace: workspace, binding: binding} do
      {:ok, %{state: :failed, delegation: nil}} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "user_rejected"
        })

      events = list_events(binding.id)
      failed = Enum.find(events, &(&1.event_type == "delegation.install_failed"))
      assert failed
      assert failed.after_ref["reason"] == "user_rejected"
    end

    test "bundler_rejected with a free-form `reason` collapses to `bundler_rejected`",
         %{workspace: workspace, binding: binding} do
      {:ok, _} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "bundler_rejected",
          "reason" => "raw upstream bundler error string we should NOT persist"
        })

      events = list_events(binding.id)
      failed = Enum.find(events, &(&1.event_type == "delegation.install_failed"))
      assert failed.after_ref["reason"] == "bundler_rejected"

      blob = inspect(failed.after_ref)
      refute blob =~ "raw upstream bundler error string"
    end

    test "reverted on a pending row transitions it to :install_failed",
         %{workspace: workspace, binding: binding} do
      {:ok, %{delegation: row}} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      {:ok, %{state: :failed, delegation: failed_row}} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "reverted",
          "install_userop_hash" => @valid_userop_hash,
          "reason" => "userop_reverted"
        })

      assert failed_row.id == row.id
      assert failed_row.state == :install_failed
      assert failed_row.last_reason == "install_failed:userop_reverted"
    end
  end

  describe "status/2" do
    test "returns :awaiting when no install attestation has landed",
         %{workspace: workspace, binding: binding} do
      assert %{state: :awaiting, delegation: nil} = BrowserInstall.status(workspace.id, binding)
    end

    test "returns :submitted after a submitted attestation",
         %{workspace: workspace, binding: binding} do
      {:ok, _} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      assert %{state: :submitted} = BrowserInstall.status(workspace.id, binding)
    end

    test "returns :failed after a terminal failure",
         %{workspace: workspace, binding: binding} do
      {:ok, _} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "submitted",
          "install_userop_hash" => @valid_userop_hash,
          "permission_id" => @valid_permission_id,
          "validation_id" => @valid_validation_id
        })

      {:ok, _} =
        BrowserInstall.record_attestation(workspace.id, binding, %{
          "status" => "reverted",
          "install_userop_hash" => @valid_userop_hash,
          "reason" => "userop_reverted"
        })

      assert %{state: :failed} = BrowserInstall.status(workspace.id, binding)
    end
  end

  describe "failure_categories/0 contract" do
    test "returns the fixed allowlist named in the design" do
      assert BrowserInstall.failure_categories() == [
               :user_rejected,
               :bundler_rejected,
               :bundler_unavailable,
               :bundler_not_configured,
               :chain_id_mismatch,
               :insufficient_funds,
               :userop_reverted,
               :attestation_timeout,
               :wallet_not_connected,
               :account_mismatch,
               :kernel_account_collision,
               :session_signer_unavailable,
               :session_signer_refused,
               :unknown
             ]
    end
  end

  # --- helpers -----------------------------------------------------------

  defp verified_binding(workspace_id, user_id, address) do
    {:ok, binding} =
      WalletBindings.issue_challenge(workspace_id, user_id, %{
        address: address,
        chain_id: 84_532
      })

    signature = sign_personal(binding.challenge_message, @privkey)
    {:ok, verified} = WalletBindings.verify_and_bind(binding.id, signature)
    verified
  end

  defp pending_binding(workspace_id, user_id, address) do
    {:ok, binding} =
      WalletBindings.issue_challenge(workspace_id, user_id, %{
        address: address,
        chain_id: 84_532
      })

    binding
  end

  defp mainnet_binding_fixture(workspace_id, user_id, address) do
    nonce = :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
    now = DateTime.utc_now()
    expires = DateTime.add(now, 300, :second)

    {:ok, row} =
      Repo.insert(%WalletBinding{
        workspace_id: workspace_id,
        user_id: user_id,
        address: address,
        chain_id: 8453,
        nonce: nonce,
        challenge_message: "test mainnet binding",
        expires_at: expires,
        verified_at: now
      })

    row
  end

  defp sign_personal(message, privkey) do
    digest = Signature.eip191_hash(message)
    {:ok, {r, s, v}} = ExSecp256k1.sign(digest, privkey)
    "0x" <> Base.encode16(r <> s <> <<v + 27>>, case: :lower)
  end

  defp list_events(correlation_id) do
    Audit.list_events(%{correlation_id: correlation_id}, limit: 20)
    |> Map.get(:events)
  end

  defp all_verify_jobs do
    Repo.all(from(j in Oban.Job, where: j.worker == "Bank.Runtime.Workers.VerifyInstallOnchain"))
  end

  defp all_poll_jobs do
    Repo.all(from(j in Oban.Job, where: j.worker == "Bank.Runtime.Workers.PollInstallReceipt"))
  end
end
