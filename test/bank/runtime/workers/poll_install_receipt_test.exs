defmodule Bank.Runtime.Workers.PollInstallReceiptTest do
  @moduledoc """
  Tests for `Bank.Runtime.Workers.PollInstallReceipt` (#500).

  The poller is the SAFETY NET that carries a `:pending` browser-
  signed install row to a verdict if the browser tab closes
  between `submitted` and `confirmed`. It is the only path that
  guarantees a `:pending` row anchored to a real bundler-accepted
  UserOp eventually reaches `:active` or `:install_failed`.

  These tests pin every bullet in the design's § 2.5.1 contract:

    * null receipt → `:snooze` (worker reschedules without
      burning attempts).
    * receipt `success: true` → audits `delegation.install_broadcast`
      AND enqueues `VerifyInstallOnchain` with the on-chain
      `tx_hash` + `block_number`. The verifier remains the SOLE
      writer of the `:active` transition.
    * receipt `success: false` → marks `:install_failed` with
      reason `:userop_reverted`.
    * past wall-clock deadline → marks `:install_failed` with
      reason `:attestation_timeout`.
    * bundler 5xx / transport error within budget → returns
      `{:error, _}` so Oban retries.
    * bundler 5xx / transport error at `attempt >= max_attempts`
      → marks `:install_failed` with reason `:bundler_unavailable`.
    * idempotency — already-`:active` row is a no-op.
    * idempotency — already-`:install_failed` row is a no-op.
    * missing bundler URL → marks `:install_failed` with reason
      `:bundler_unavailable` (configuration regression — fail
      closed).
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit
  alias Bank.Delegations.Delegation
  alias Bank.Repo
  alias Bank.Runtime.Workers.PollInstallReceipt
  alias Bank.Runtime.Workers.VerifyInstallOnchain
  alias Bank.SessionPermissions.Scope
  alias Bank.Workspaces

  import Ecto.Query

  @valid_userop_hash "0x" <> String.duplicate("a", 64)
  @valid_tx_hash "0x" <> String.duplicate("b", 64)
  @bundler_url "https://api.example.com/bundler/key"

  setup do
    suffix = System.unique_integer([:positive])

    {:ok, workspace} =
      Workspaces.create_workspace(%{
        slug: "pir-ws-#{suffix}",
        name: "PIR ws #{suffix}",
        mainnet_enabled: false
      })

    binding_id = Ecto.UUID.generate()

    {:ok, delegation} =
      %Delegation{}
      |> Delegation.changeset(%{
        smart_account_id: "sa_pir_" <> Integer.to_string(suffix),
        delegation_id: @valid_userop_hash,
        state: :pending,
        chain: "base-sepolia",
        scope: Scope.default(),
        workspace_id: workspace.id,
        root_validator_owner: "user",
        binding_id: binding_id,
        install_userop_hash: @valid_userop_hash,
        permission_id: <<0xDE, 0xAD, 0xBE, 0xEF>>,
        validation_id: <<0x02>> <> :binary.copy(<<0xCA, 0xFE>>, 10),
        kernel_version: "v3.1",
        permission_package_version: "5.6.3",
        session_signer_address: "0x" <> String.duplicate("c", 40)
      })
      |> Repo.insert()

    original = Application.get_env(:bank, PollInstallReceipt, [])

    on_exit(fn -> Application.put_env(:bank, PollInstallReceipt, original) end)

    %{workspace: workspace, delegation: delegation, binding_id: binding_id}
  end

  describe "perform/1 — null receipt" do
    test "snoozes when bundler returns nil receipt", %{
      delegation: delegation,
      binding_id: binding_id,
      workspace: workspace
    } do
      stub_bundler(fn _url, %{"method" => "eth_getUserOperationReceipt"} -> {:ok, nil} end)

      assert {:snooze, snooze} = perform(default_args(delegation, binding_id, workspace))
      assert is_integer(snooze) and snooze > 0

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :pending
    end
  end

  describe "perform/1 — successful receipt" do
    test "enqueues VerifyInstallOnchain + audits install_broadcast", %{
      delegation: delegation,
      binding_id: binding_id,
      workspace: workspace
    } do
      stub_bundler(fn _url, %{"method" => "eth_getUserOperationReceipt"} ->
        {:ok,
         %{
           "userOpHash" => @valid_userop_hash,
           "success" => true,
           "receipt" => %{
             "transactionHash" => @valid_tx_hash,
             "blockNumber" => "0x1e240"
           }
         }}
      end)

      assert :ok = perform(default_args(delegation, binding_id, workspace))

      # Verifier was enqueued with the on-chain identifiers.
      assert_enqueued(
        worker: VerifyInstallOnchain,
        args: %{
          "delegation_id" => delegation.id,
          "tx_hash" => @valid_tx_hash,
          "block_number" => 123_456
        }
      )

      # Row stays :pending — the verifier remains the sole writer
      # of the :active transition.
      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :pending

      events = list_events(binding_id)
      broadcast = Enum.find(events, &(&1.event_type == "delegation.install_broadcast"))
      assert broadcast
      assert broadcast.after_ref["tx_hash"] == @valid_tx_hash
      assert broadcast.after_ref["block_number"] == 123_456
    end
  end

  describe "perform/1 — reverted receipt" do
    test "marks the row :install_failed with reason :userop_reverted", %{
      delegation: delegation,
      binding_id: binding_id,
      workspace: workspace
    } do
      stub_bundler(fn _url, _ ->
        {:ok,
         %{
           "userOpHash" => @valid_userop_hash,
           "success" => false,
           "reason" => "AA13 initCode failed or OOG"
         }}
      end)

      assert :ok = perform(default_args(delegation, binding_id, workspace))

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :install_failed
      assert reloaded.last_reason == "install_failed:userop_reverted"

      events = list_events(binding_id)
      failed = Enum.find(events, &(&1.event_type == "delegation.install_failed"))
      assert failed.after_ref["reason"] == "userop_reverted"

      # The free-form bundler reason MUST NOT leak into the audit
      # row (failure-category allowlist contract).
      refute inspect(failed.after_ref) =~ "AA13 initCode"
    end
  end

  describe "perform/1 — wall-clock deadline" do
    test "past deadline marks the row :install_failed with reason :attestation_timeout", %{
      delegation: delegation,
      binding_id: binding_id,
      workspace: workspace
    } do
      args =
        default_args(delegation, binding_id, workspace)
        |> Map.put(
          "deadline_at",
          DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_iso8601()
        )

      assert :ok = perform(args)

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :install_failed
      assert reloaded.last_reason == "install_failed:attestation_timeout"

      events = list_events(binding_id)
      failed = Enum.find(events, &(&1.event_type == "delegation.install_failed"))
      assert failed.after_ref["reason"] == "attestation_timeout"
    end
  end

  describe "perform/1 — bundler transport errors" do
    test "transient error within attempt budget returns {:error, _} so Oban retries", %{
      delegation: delegation,
      binding_id: binding_id,
      workspace: workspace
    } do
      stub_bundler(fn _url, _ -> {:error, :transport_error} end)

      assert {:error, :transport_error} =
               perform(default_args(delegation, binding_id, workspace), attempt: 1)

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :pending
    end

    test "transient error at attempt >= max_attempts marks :install_failed bundler_unavailable",
         %{delegation: delegation, binding_id: binding_id, workspace: workspace} do
      stub_bundler(fn _url, _ -> {:error, :transport_error} end)

      assert :ok = perform(default_args(delegation, binding_id, workspace), attempt: 8)

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :install_failed
      assert reloaded.last_reason == "install_failed:bundler_unavailable"

      events = list_events(binding_id)
      failed = Enum.find(events, &(&1.event_type == "delegation.install_failed"))
      assert failed.after_ref["reason"] == "bundler_unavailable"
    end
  end

  describe "perform/1 — idempotency with the browser fast-path" do
    test "row already :active is a no-op (no audit, no enqueue, no row write)", %{
      delegation: delegation,
      binding_id: binding_id,
      workspace: workspace
    } do
      {:ok, active} =
        delegation
        |> Delegation.changeset(%{state: :active, granted_at: DateTime.utc_now()})
        |> Repo.update()

      assert :ok = perform(default_args(active, binding_id, workspace))

      reloaded = Repo.get!(Delegation, active.id)
      assert reloaded.state == :active
      # No new install_broadcast / install_failed audit emitted.
      events = list_events(binding_id)
      refute Enum.any?(events, &(&1.event_type == "delegation.install_broadcast"))
      refute Enum.any?(events, &(&1.event_type == "delegation.install_failed"))
      # No verifier enqueue.
      assert [] = all_verify_jobs()
    end

    test "row already :install_failed is a no-op", %{
      delegation: delegation,
      binding_id: binding_id,
      workspace: workspace
    } do
      {:ok, _} =
        delegation
        |> Delegation.changeset(%{
          state: :install_failed,
          last_reason: "install_failed:user_rejected"
        })
        |> Repo.update()

      assert :ok = perform(default_args(delegation, binding_id, workspace))

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :install_failed
      assert [] = all_verify_jobs()
    end

    test "missing delegation row → :cancel" do
      assert {:cancel, :delegation_not_found} =
               perform(%{
                 "delegation_id" => Ecto.UUID.generate(),
                 "binding_id" => Ecto.UUID.generate(),
                 "install_userop_hash" => @valid_userop_hash,
                 "bundler_rpc_url" => @bundler_url
               })
    end
  end

  describe "perform/1 — configuration regression" do
    test "missing bundler URL fails closed as :bundler_unavailable", %{
      delegation: delegation,
      binding_id: binding_id,
      workspace: workspace
    } do
      args =
        default_args(delegation, binding_id, workspace)
        |> Map.put("bundler_rpc_url", nil)

      assert :ok = perform(args)

      reloaded = Repo.get!(Delegation, delegation.id)
      assert reloaded.state == :install_failed
      assert reloaded.last_reason == "install_failed:bundler_unavailable"
    end
  end

  describe "deadline_at_iso/1" do
    test "produces an ISO 8601 timestamp `deadline_ms` in the future" do
      Application.put_env(:bank, PollInstallReceipt, deadline_ms: 60_000)
      now_ms = System.os_time(:millisecond)
      iso = PollInstallReceipt.deadline_at_iso(now_ms)

      {:ok, dt, _} = DateTime.from_iso8601(iso)
      diff_ms = DateTime.diff(dt, DateTime.from_unix!(now_ms, :millisecond), :millisecond)
      assert diff_ms == 60_000
    end
  end

  # --- helpers ----------------------------------------------------------

  defp default_args(%Delegation{} = d, binding_id, workspace) do
    %{
      "delegation_id" => d.id,
      "binding_id" => binding_id,
      "workspace_id" => workspace.id,
      "install_userop_hash" => d.install_userop_hash,
      "bundler_rpc_url" => @bundler_url,
      "deadline_at" => DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.to_iso8601()
    }
  end

  defp perform(args, opts \\ []) do
    job = %Oban.Job{
      args: args,
      attempt: Keyword.get(opts, :attempt, 1),
      max_attempts: 8,
      worker: "Bank.Runtime.Workers.PollInstallReceipt"
    }

    PollInstallReceipt.perform(job)
  end

  defp stub_bundler(fun) when is_function(fun, 2) do
    Application.put_env(:bank, PollInstallReceipt, rpc_fn: fun)
  end

  defp list_events(binding_id) do
    Audit.list_events(%{correlation_id: binding_id}, limit: 50)
    |> Map.get(:events)
  end

  defp all_verify_jobs do
    Repo.all(from(j in Oban.Job, where: j.worker == "Bank.Runtime.Workers.VerifyInstallOnchain"))
  end
end
