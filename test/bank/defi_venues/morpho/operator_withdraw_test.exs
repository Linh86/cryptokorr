defmodule Bank.DefiVenues.Morpho.OperatorWithdrawTest do
  @moduledoc """
  Coverage for `Bank.DefiVenues.Morpho.OperatorWithdraw` (#207) —
  the operator-only Morpho ERC-4626 withdraw safety path.

  Tests are split into:

    * **Operator-role gate** — non-operator callers refused with
      `:operator_role_required`. The agent boundary itself is
      pinned by `agent_intent_no_withdraw_test.exs`.
    * **Vault allowlist gate** — only the workspace's
      `:allowed_vault` rules pass; mismatch refused.
    * **Snapshot lookup** — missing snapshot refused; otherwise
      preview is computed.
    * **Block-or-explicit-partial gate** — insufficient liquidity
      blocks; partial-without-consent refused; partial-with-consent
      clamps `effective_assets` to `max_withdrawable`.
    * **Audit/replay** — every accepted preview emits
      `morpho.withdraw_previewed`; every accepted plan emits
      `morpho.withdraw_planned`; every refused gate emits
      `morpho.withdraw_blocked`. All three carry the same
      `correlation_id` so replay can rebuild the operator
      narrative.

  All tests use injected `:rules_loader` and `:snapshot_loader`
  opts so they stay deterministic and DB-free for the gate logic;
  audit emission goes through the real `Bank.Runtime.emit_audit`
  → `Bank.Audit` write path so the audit-row assertions exercise
  end-to-end.
  """

  use Bank.DataCase, async: false

  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.DefiVenues.Morpho.{OperatorWithdraw, PersistedVaultSnapshot}
  alias Bank.Policies.PolicyRule
  alias Bank.Workspaces.Workspace

  @vault "0xbeef000000000000000000000000000000000099"
  @operator_id "22222222-2222-4222-8222-222222222222"
  @ws "11111111-1111-4111-8111-111111111111"

  # Insert a Workspaces row with the test's pinned UUID so the
  # audit-event FK on workspace_id is satisfied. Direct
  # `Repo.insert` of the schema (bypassing the changeset's
  # auto-id generation) keeps the test's `@ws` reference stable
  # across all the assertions.
  setup do
    {:ok, _ws} =
      Repo.insert(%Workspace{
        id: @ws,
        slug: "morpho-withdraw-#{System.unique_integer([:positive])}",
        name: "Morpho withdraw test",
        mainnet_enabled: false
      })

    :ok
  end

  defp current_snapshot(total_assets \\ "1000") do
    %PersistedVaultSnapshot{
      id: "33333333-3333-4333-8333-333333333333",
      chain_id: 84_532,
      vault_address: @vault,
      payload_hash: "demo-hash",
      fetched_at: ~U[2026-05-06 09:00:00.000000Z],
      state: %{"total_assets" => total_assets}
    }
  end

  defp allowlisted_rule(vault_address \\ @vault) do
    %PolicyRule{
      rule_type: :allowed_vault,
      params: %{"vault_address" => vault_address}
    }
  end

  defp default_opts(extras \\ []) do
    Keyword.merge(
      [
        actor_id: @operator_id,
        actor_role: :operator,
        rules_loader: fn _ws -> [allowlisted_rule()] end,
        snapshot_loader: fn _ci, _va -> current_snapshot() end
      ],
      extras
    )
  end

  defp audit_events_for_correlation(correlation_id) do
    Repo.all(
      from(e in AuditEvent,
        where: e.correlation_id == ^correlation_id,
        order_by: [asc: e.ts, asc: e.id],
        select: %{event_type: e.event_type, after_ref: e.after_ref}
      )
    )
  end

  describe "operator-role gate" do
    test "rejects :agent role with :operator_role_required" do
      assert {:error, :operator_role_required} =
               OperatorWithdraw.request_withdraw(
                 @ws,
                 @vault,
                 Decimal.new("10"),
                 default_opts(actor_role: :agent)
               )
    end

    test "rejects :runtime role" do
      assert {:error, :operator_role_required} =
               OperatorWithdraw.request_withdraw(
                 @ws,
                 @vault,
                 Decimal.new("10"),
                 default_opts(actor_role: :runtime)
               )
    end

    test "rejects missing actor_role" do
      opts = default_opts() |> Keyword.delete(:actor_role)

      assert {:error, :operator_role_required} =
               OperatorWithdraw.request_withdraw(@ws, @vault, Decimal.new("10"), opts)
    end

    test "preview/4 has the same role gate" do
      assert {:error, :operator_role_required} =
               OperatorWithdraw.preview(
                 @ws,
                 @vault,
                 Decimal.new("10"),
                 default_opts(actor_role: :agent)
               )
    end
  end

  describe "vault allowlist gate" do
    test "rejects when the vault is not in the workspace allowlist" do
      opts =
        default_opts(
          rules_loader: fn _ws ->
            [allowlisted_rule("0xdead000000000000000000000000000000000001")]
          end
        )

      assert {:error, :morpho_withdraw_vault_not_allowlisted} =
               OperatorWithdraw.request_withdraw(@ws, @vault, Decimal.new("10"), opts)
    end

    test "is case-insensitive on address comparison" do
      mixed_case = String.upcase(@vault)
      opts = default_opts(rules_loader: fn _ws -> [allowlisted_rule(mixed_case)] end)

      assert {:ok, _accepted} =
               OperatorWithdraw.request_withdraw(@ws, @vault, Decimal.new("10"), opts)
    end

    test "rejects when workspace has zero rules" do
      opts = default_opts(rules_loader: fn _ws -> [] end)

      assert {:error, :morpho_withdraw_vault_not_allowlisted} =
               OperatorWithdraw.request_withdraw(@ws, @vault, Decimal.new("10"), opts)
    end
  end

  describe "snapshot lookup" do
    test "rejects when no current snapshot exists" do
      opts = default_opts(snapshot_loader: fn _ci, _va -> nil end)

      assert {:error, :morpho_withdraw_snapshot_missing} =
               OperatorWithdraw.request_withdraw(@ws, @vault, Decimal.new("10"), opts)
    end
  end

  describe "block-or-explicit-partial gate" do
    test "blocks when vault has zero liquidity" do
      opts = default_opts(snapshot_loader: fn _ci, _va -> current_snapshot("0") end)

      assert {:error, :morpho_withdraw_blocked} =
               OperatorWithdraw.request_withdraw(@ws, @vault, Decimal.new("10"), opts)
    end

    test "rejects partial without :allow_partial consent" do
      opts = default_opts(snapshot_loader: fn _ci, _va -> current_snapshot("50") end)

      assert {:error, :morpho_withdraw_partial_required} =
               OperatorWithdraw.request_withdraw(@ws, @vault, Decimal.new("100"), opts)
    end

    test "accepts partial with :allow_partial true and clamps effective_assets" do
      opts =
        default_opts(
          snapshot_loader: fn _ci, _va -> current_snapshot("50") end,
          allow_partial: true
        )

      assert {:ok, accepted} =
               OperatorWithdraw.request_withdraw(@ws, @vault, Decimal.new("100"), opts)

      assert accepted.partial?
      assert Decimal.equal?(accepted.effective_assets, Decimal.new("50"))
      assert accepted.preview.would_partial?
      refute accepted.preview.would_block?
    end

    test "accepts full withdraw when request fits within liquidity" do
      opts = default_opts(snapshot_loader: fn _ci, _va -> current_snapshot("1000") end)

      assert {:ok, accepted} =
               OperatorWithdraw.request_withdraw(@ws, @vault, Decimal.new("100"), opts)

      refute accepted.partial?
      assert Decimal.equal?(accepted.effective_assets, Decimal.new("100"))
    end
  end

  describe "audit / replay surface" do
    test "accepted withdraw emits previewed + planned with the same correlation_id" do
      assert {:ok, accepted} =
               OperatorWithdraw.request_withdraw(
                 @ws,
                 @vault,
                 Decimal.new("100"),
                 default_opts()
               )

      events = audit_events_for_correlation(accepted.correlation_id)
      types = Enum.map(events, & &1.event_type)

      assert "morpho.withdraw_previewed" in types
      assert "morpho.withdraw_planned" in types
      assert "morpho.withdraw_blocked" not in types
    end

    test "blocked-by-zero-liquidity emits previewed + blocked with the same correlation_id" do
      opts =
        default_opts(
          snapshot_loader: fn _ci, _va -> current_snapshot("0") end,
          correlation_id: "55555555-5555-4555-8555-555555555555"
        )

      assert {:error, :morpho_withdraw_blocked} =
               OperatorWithdraw.request_withdraw(@ws, @vault, Decimal.new("100"), opts)

      events = audit_events_for_correlation("55555555-5555-4555-8555-555555555555")
      types = Enum.map(events, & &1.event_type)

      # Previewed always fires when preview computation succeeds;
      # blocked fires after the gate refuses.
      assert "morpho.withdraw_previewed" in types
      assert "morpho.withdraw_blocked" in types
      assert "morpho.withdraw_planned" not in types
    end

    test "blocked-by-partial-required emits previewed + blocked with reason" do
      opts =
        default_opts(
          snapshot_loader: fn _ci, _va -> current_snapshot("50") end,
          correlation_id: "66666666-6666-4666-8666-666666666666"
        )

      assert {:error, :morpho_withdraw_partial_required} =
               OperatorWithdraw.request_withdraw(@ws, @vault, Decimal.new("100"), opts)

      events = audit_events_for_correlation("66666666-6666-4666-8666-666666666666")
      blocked = Enum.find(events, &(&1.event_type == "morpho.withdraw_blocked"))

      assert blocked
      assert blocked.after_ref["reason"] == "morpho_withdraw_partial_required"
    end

    test "audit row carries vault, snapshot identity, and amounts" do
      assert {:ok, accepted} =
               OperatorWithdraw.request_withdraw(
                 @ws,
                 @vault,
                 Decimal.new("100"),
                 default_opts()
               )

      events = audit_events_for_correlation(accepted.correlation_id)
      planned = Enum.find(events, &(&1.event_type == "morpho.withdraw_planned"))

      assert planned
      assert planned.after_ref["vault_address"] == @vault
      assert planned.after_ref["chain_id"] == 84_532
      assert planned.after_ref["requested_assets"] == "100"
      assert planned.after_ref["effective_assets"] == "100"
      assert planned.after_ref["max_withdrawable"] == "1000"
      assert planned.after_ref["partial"] == false
      assert planned.after_ref["snapshot_id"] == "33333333-3333-4333-8333-333333333333"
      assert planned.after_ref["snapshot_payload_hash"] == "demo-hash"
    end

    test "preview/4 emits previewed but no planned/blocked" do
      correlation = "77777777-7777-4777-8777-777777777777"

      assert {:ok, _preview} =
               OperatorWithdraw.preview(
                 @ws,
                 @vault,
                 Decimal.new("100"),
                 default_opts(correlation_id: correlation)
               )

      events = audit_events_for_correlation(correlation)
      types = Enum.map(events, & &1.event_type)

      assert "morpho.withdraw_previewed" in types
      assert "morpho.withdraw_planned" not in types
      assert "morpho.withdraw_blocked" not in types
    end
  end
end
