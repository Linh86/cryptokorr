defmodule Bank.DelegationsTest do
  use Bank.DataCase, async: true

  alias Bank.Delegations

  describe "grant/3" do
    test "creates an active delegation" do
      assert {:ok, record} =
               Delegations.grant("sa_1", "del_1", %{
                 scope: %{"asset" => "USDC"}
               })

      assert record.state == :active
      assert record.smart_account_id == "sa_1"
      assert record.delegation_id == "del_1"
      assert record.scope == %{"asset" => "USDC"}
      assert %DateTime{} = record.granted_at
    end

    test "rejects when a non-terminal delegation already exists" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")

      assert {:error, :already_exists} = Delegations.grant("sa_1", "del_2")
    end

    test "allows re-grant after prior delegation is revoked" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      {:ok, _} = Delegations.record_revoke_requested("sa_1")
      {:ok, _} = Delegations.record_revoked("sa_1")

      assert {:ok, re} = Delegations.grant("sa_1", "del_2")
      assert re.state == :active
      assert re.delegation_id == "del_2"
    end

    test "allows re-grant after prior delegation is expired" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      {:ok, _} = Delegations.record_expired("sa_1")

      assert {:ok, re} = Delegations.grant("sa_1", "del_2")
      assert re.state == :active
    end

    test "stamps workspace_id from attrs when supplied (#158d-c)" do
      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "grant-stamp",
          name: "Grant stamp",
          mainnet_enabled: true
        })

      assert {:ok, record} =
               Delegations.grant("sa_grant_ws", "del_grant_ws", %{workspace_id: ws.id})

      assert record.workspace_id == ws.id
    end

    test "leaves workspace_id nil when caller supplies no attr (legacy / adapter callback path)" do
      assert {:ok, record} = Delegations.grant("sa_legacy_grant", "del_legacy_grant")
      assert record.workspace_id == nil
    end

    test "subsequent delegation.state_changed audit event inherits workspace_id from the row" do
      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "grant-audit",
          name: "Grant audit",
          mainnet_enabled: true
        })

      {:ok, granted} =
        Delegations.grant("sa_grant_audit", "del_grant_audit", %{workspace_id: ws.id})

      # Build the audit attrs the adapter-callback emit path uses.
      # `Bank.Audit.Events.delegation_state_changed/3` (#158d-b)
      # reads `delegation.workspace_id` directly, so the stamped
      # row carries the scope onto the event.
      attrs = Bank.Audit.Events.delegation_state_changed(granted, :pending, actor: :adapter)

      {:ok, event} = Bank.Audit.append_event(attrs)
      assert event.workspace_id == ws.id
      assert event.event_type == "delegation.state_changed"
    end
  end

  describe "get/1" do
    test "returns the non-terminal delegation" do
      {:ok, original} = Delegations.grant("sa_1", "del_1")

      result = Delegations.get("sa_1")
      assert result.id == original.id
      assert result.state == :active
    end

    test "returns nil after delegation is revoked" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      {:ok, _} = Delegations.record_revoke_requested("sa_1")
      {:ok, _} = Delegations.record_revoked("sa_1")

      assert is_nil(Delegations.get("sa_1"))
    end

    test "returns nil for unknown smart account" do
      assert is_nil(Delegations.get("sa_ghost"))
    end
  end

  describe "get_by_id/1" do
    test "returns delegation by primary key" do
      {:ok, original} = Delegations.grant("sa_1", "del_1")

      assert {:ok, found} = Delegations.get_by_id(original.id)
      assert found.id == original.id
    end

    test "returns :not_found for unknown id" do
      assert {:error, :not_found} = Delegations.get_by_id(Ecto.UUID.generate())
    end
  end

  describe "revoke flow" do
    test "revoke_requested → revoked" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")

      assert {:ok, %{state: :revoking, revoke_requested_at: %DateTime{}}} =
               Delegations.record_revoke_requested("sa_1", %{last_reason: "operator_requested"})

      assert {:ok, %{state: :revoked, revoked_at: %DateTime{}}} =
               Delegations.record_revoked("sa_1")
    end

    test "duplicate revoke_requested callback is idempotent while already revoking" do
      {:ok, _} = Delegations.grant("sa_idempotent_revoke", "del_1")

      assert {:ok, %{state: :revoking} = first} =
               Delegations.record_revoke_requested("sa_idempotent_revoke", %{
                 last_reason: "operator_requested"
               })

      assert {:ok, %{state: :revoking} = second} =
               Delegations.record_revoke_requested("sa_idempotent_revoke", %{
                 last_reason: "adapter_ack"
               })

      assert second.id == first.id
      assert second.last_reason == "operator_requested"
    end

    test "record_revoked refuses to bypass :revoking (no fast-fail path)" do
      # Confirmed revoke means the chain said the revoke succeeded, so
      # :revoking must always be the prior state. Any failure of the
      # attempt itself routes through record_revoke_failed.
      {:ok, _} = Delegations.grant("sa_fast", "del_fast")

      assert {:error, :invalid_transition} = Delegations.record_revoked("sa_fast")
    end

    test "revoke on unknown smart account returns :not_found" do
      assert {:error, :not_found} = Delegations.record_revoke_requested("sa_missing")
      assert {:error, :not_found} = Delegations.record_revoked("sa_missing")
      assert {:error, :not_found} = Delegations.record_revoke_failed("sa_missing")
    end

    test "revoke on already-revoked delegation returns :not_found" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      {:ok, _} = Delegations.record_revoke_requested("sa_1")
      {:ok, _} = Delegations.record_revoked("sa_1")

      # get/1 returns nil for terminal states, so this is :not_found
      assert {:error, :not_found} = Delegations.record_revoke_requested("sa_1")
    end
  end

  describe "revoke_failed flow (issue #31)" do
    test "revoking → revoke_failed records reason and tx hash" do
      {:ok, _} = Delegations.grant("sa_fail", "del_fail")
      {:ok, _} = Delegations.record_revoke_requested("sa_fail")

      tx_hash = "0x" <> String.duplicate("ab", 32)

      assert {:ok, delegation} =
               Delegations.record_revoke_failed("sa_fail", %{
                 last_reason: "sentinel_reverted",
                 last_tx_hash: tx_hash
               })

      assert delegation.state == :revoke_failed
      assert delegation.last_reason == "sentinel_reverted"
      assert delegation.last_tx_hash == tx_hash
    end

    test "revoke_failed from anything other than :revoking is :invalid_transition" do
      {:ok, _} = Delegations.grant("sa_ny", "del_ny")
      assert {:error, :invalid_transition} = Delegations.record_revoke_failed("sa_ny")
    end

    test "operator retry: revoke_failed → revoking → revoked" do
      {:ok, _} = Delegations.grant("sa_retry", "del_retry")
      {:ok, _} = Delegations.record_revoke_requested("sa_retry")
      {:ok, _} = Delegations.record_revoke_failed("sa_retry", %{last_reason: "send_failed: rpc"})

      # Operator retries via record_revoke_requested
      assert {:ok, %{state: :revoking}} =
               Delegations.record_revoke_requested("sa_retry", %{last_reason: "operator_retry"})

      # Subsequent success lands in :revoked
      assert {:ok, %{state: :revoked}} = Delegations.record_revoked("sa_retry")
    end

    test "revoke_failed is non-executable and non-terminal" do
      {:ok, _} = Delegations.grant("sa_exec", "del_exec")
      {:ok, _} = Delegations.record_revoke_requested("sa_exec")
      {:ok, _} = Delegations.record_revoke_failed("sa_exec")

      # Fail-closed: not executable.
      refute Delegations.executable?("sa_exec")

      # Non-terminal: still visible to get/1 and blocks re-grant.
      assert %{state: :revoke_failed} = Delegations.get("sa_exec")
      assert {:error, :already_exists} = Delegations.grant("sa_exec", "del_new")
    end
  end

  describe "expiry" do
    test "record_expired marks active delegation as :expired" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      assert {:ok, %{state: :expired}} = Delegations.record_expired("sa_1")
    end

    test "record_expired on revoking returns :invalid_transition" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      {:ok, _} = Delegations.record_revoke_requested("sa_1")

      assert {:error, :invalid_transition} = Delegations.record_expired("sa_1")
    end

    test "record_expired on missing returns :not_found" do
      assert {:error, :not_found} = Delegations.record_expired("sa_missing")
    end
  end

  # --- Adapter callback race / late-callback resurrection guard (#212 P1) ---
  #
  # Without `FOR UPDATE` and a from-state guard inside the lock,
  # two concurrent adapter callbacks for the same `smart_account_id`
  # can both read the row at `:revoking`, both pass their in-memory
  # pattern guards, and the second `Repo.update/1` to commit can
  # overwrite a terminal `:revoked` with `:revoke_failed` (or any
  # other late-arriving stale transition). Mirror PR #314's pattern:
  # transaction + `lock: "FOR UPDATE"` + re-pattern-match inside the
  # lock window. These tests pin the post-fix from-state behaviour;
  # the under-the-hood lock prevents the race window itself.
  describe "callback transition lock guard against late writes (#212)" do
    alias Bank.Delegations.Delegation
    alias Bank.Repo

    test "record_revoke_failed: late callback after :revoked succeeded returns :not_found" do
      # Simulates: callback A (`revoked`) committed first; callback B
      # (`revoke_failed`) arrives stale. Pre-fix B's `get/1` saw the
      # delegation at :revoking inside its own snapshot and would
      # transition :revoked -> :revoke_failed, resurrecting a
      # terminal row. Post-fix: lock_active_delegation excludes
      # terminal :revoked rows, so B sees `nil` and returns
      # :not_found.
      {:ok, _} = Delegations.grant("sa_late_revfail", "del_late_revfail")
      {:ok, _} = Delegations.record_revoke_requested("sa_late_revfail")
      {:ok, _} = Delegations.record_revoked("sa_late_revfail")

      assert {:error, :not_found} =
               Delegations.record_revoke_failed("sa_late_revfail", %{
                 last_reason: "send_failed:rpc",
                 last_tx_hash: "0xstaleA"
               })

      # Row remains in terminal :revoked.
      reloaded = Repo.get_by(Delegation, smart_account_id: "sa_late_revfail")
      assert reloaded.state == :revoked
    end

    test "record_revoked: late callback after :revoke_failed returns :invalid_transition" do
      # Symmetric scenario: A (`revoke_failed`) committed first; B
      # (`revoked`) arrives stale. lock_active_delegation finds the
      # :revoke_failed row (still non-terminal), but the from-state
      # guard rejects because :revoked requires prior :revoking.
      {:ok, _} = Delegations.grant("sa_late_revoked", "del_late_revoked")
      {:ok, _} = Delegations.record_revoke_requested("sa_late_revoked")
      {:ok, _} = Delegations.record_revoke_failed("sa_late_revoked")

      assert {:error, :invalid_transition} =
               Delegations.record_revoked("sa_late_revoked")

      reloaded = Repo.get_by(Delegation, smart_account_id: "sa_late_revoked")
      assert reloaded.state == :revoke_failed
    end

    test "record_revoke_failed: idempotent after :revoke_failed already recorded" do
      # Adapter at-least-once delivery: a duplicate `revoke_failed`
      # for an already-:revoke_failed row must not crash and must
      # not transition. Pre-fix this returned :invalid_transition
      # (in-memory state guard), which is still the correct answer
      # post-fix (same guard, now under the lock).
      {:ok, _} = Delegations.grant("sa_dup_revfail", "del_dup_revfail")
      {:ok, _} = Delegations.record_revoke_requested("sa_dup_revfail")
      {:ok, _} = Delegations.record_revoke_failed("sa_dup_revfail")

      assert {:error, :invalid_transition} =
               Delegations.record_revoke_failed("sa_dup_revfail", %{
                 last_reason: "send_failed:rpc"
               })

      reloaded = Repo.get_by(Delegation, smart_account_id: "sa_dup_revfail")
      assert reloaded.state == :revoke_failed
    end

    test "record_expired: late callback after :revoked returns :not_found" do
      # An :expired callback that arrives after the chain confirmed
      # revoke must not resurrect the terminal row.
      {:ok, _} = Delegations.grant("sa_late_expired", "del_late_expired")
      {:ok, _} = Delegations.record_revoke_requested("sa_late_expired")
      {:ok, _} = Delegations.record_revoked("sa_late_expired")

      assert {:error, :not_found} = Delegations.record_expired("sa_late_expired")

      reloaded = Repo.get_by(Delegation, smart_account_id: "sa_late_expired")
      assert reloaded.state == :revoked
    end

    test "lock query selects FOR UPDATE on the active delegation row" do
      # Pin the query shape so a future refactor can't accidentally
      # drop the row lock without breaking a test. This is the only
      # deterministic assertion we can make against single-process
      # ExUnit; the lock's race-prevention value shows up only with
      # two concurrent DB connections.
      import Ecto.Query

      query =
        from(d in Delegation,
          where:
            d.smart_account_id == ^"sa_lock_check" and
              d.state in [:pending, :active, :revoking, :revoke_failed],
          order_by: [desc: d.inserted_at],
          limit: 1,
          lock: "FOR UPDATE"
        )

      {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)
      assert sql =~ "FOR UPDATE"
    end
  end

  # --- Stale callback for retired delegation_id must not mutate the
  # ---  freshly-granted current row (#212 / #318 review finding) ----
  #
  # The lock added in PR #318 only filtered by `smart_account_id`, so
  # an adapter callback for a retired `del_old` delegation could lock
  # and mutate the *current* `del_new` row that happens to share the
  # same `smart_account_id` (the unique slot is per-SA for
  # non-terminal rows; once the prior delegation reaches a terminal
  # state, the slot frees up for re-grant). The callback path now
  # also matches on `delegation_id` so stale callbacks for retired
  # rows collapse to `:not_found` and the controller acks with
  # `accepted_with_warning` without touching the active row.
  describe "callback delegation_id guard against stale-after-regrant (#212 / #318 review)" do
    alias Bank.Delegations.Delegation
    alias Bank.Repo

    setup do
      {:ok, _} = Delegations.grant("sa_regrant", "del_old")
      {:ok, _} = Delegations.record_revoke_requested("sa_regrant")
      {:ok, _} = Delegations.record_revoked("sa_regrant")
      {:ok, granted_new} = Delegations.grant("sa_regrant", "del_new")

      original_attrs = %{
        delegation_id: granted_new.delegation_id,
        state: granted_new.state,
        last_reason: granted_new.last_reason,
        revoke_requested_at: granted_new.revoke_requested_at,
        last_tx_hash: granted_new.last_tx_hash
      }

      %{new_delegation: granted_new, original_attrs: original_attrs}
    end

    defp assert_active_row_unchanged(original_attrs) do
      reloaded = Delegations.get("sa_regrant")
      assert reloaded.delegation_id == original_attrs.delegation_id
      assert reloaded.state == :active
      assert reloaded.last_reason == original_attrs.last_reason
      assert reloaded.revoke_requested_at == original_attrs.revoke_requested_at
      assert reloaded.last_tx_hash == original_attrs.last_tx_hash
    end

    test "late `revoking` callback for retired delegation_id is :not_found",
         %{original_attrs: original} do
      assert {:error, :not_found} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_regrant",
                 "delegation_id" => "del_old",
                 "state" => "revoking",
                 "reason" => "stale_old_callback"
               })

      assert_active_row_unchanged(original)
    end

    test "late `revoke_failed` callback for retired delegation_id is :not_found",
         %{original_attrs: original} do
      assert {:error, :not_found} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_regrant",
                 "delegation_id" => "del_old",
                 "state" => "revoke_failed",
                 "reason" => "stale_old_callback",
                 "tx_refs" => [
                   %{
                     "chain" => "base",
                     "hash" => "0x" <> String.duplicate("99", 32),
                     "block_number" => 1,
                     "status" => "reverted"
                   }
                 ]
               })

      assert_active_row_unchanged(original)
    end

    test "late `revoked` callback for retired delegation_id is :not_found",
         %{original_attrs: original} do
      assert {:error, :not_found} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_regrant",
                 "delegation_id" => "del_old",
                 "state" => "revoked",
                 "reason" => "stale_old_callback",
                 "tx_refs" => [
                   %{
                     "chain" => "base",
                     "hash" => "0x" <> String.duplicate("88", 32),
                     "block_number" => 2,
                     "status" => "success"
                   }
                 ]
               })

      assert_active_row_unchanged(original)
    end

    test "late `expired` callback for retired delegation_id is :not_found",
         %{original_attrs: original} do
      assert {:error, :not_found} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_regrant",
                 "delegation_id" => "del_old",
                 "state" => "expired",
                 "reason" => "stale_old_callback"
               })

      assert_active_row_unchanged(original)
    end

    test "stale `granted` callback for retired delegation_id does not silently ack the current row",
         %{original_attrs: original} do
      # Pre-fix the `granted` branch returned `{:ok, current_row}` if
      # the current row was :active, regardless of whether the
      # callback's delegation_id matched. That silently
      # acknowledged a callback for the WRONG delegation as if it
      # were the right one — and would also mutate :pending → :active
      # using the stale callback's `last_reason` if the current row
      # were :pending. Both behaviours are now refused with
      # :not_found.
      assert {:error, :not_found} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_regrant",
                 "delegation_id" => "del_old",
                 "state" => "granted",
                 "reason" => "stale_old_callback",
                 "permission" => %{},
                 "scope" => %{}
               })

      assert_active_row_unchanged(original)
    end

    test "happy path still works: matching delegation_id revoke transitions current row" do
      # Regression backstop: the delegation_id guard must not break
      # the normal callback path for the current delegation.
      assert {:ok, %Delegation{state: :revoking, delegation_id: "del_new"}} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_regrant",
                 "delegation_id" => "del_new",
                 "state" => "revoking",
                 "reason" => "operator_requested"
               })

      reloaded = Repo.get_by(Delegation, smart_account_id: "sa_regrant", state: :revoking)
      assert reloaded.delegation_id == "del_new"
    end
  end

  describe "executable?/2" do
    test "true only for active + non-expired" do
      now = ~U[2026-04-15 12:00:00Z]

      {:ok, _} = Delegations.grant("sa_never_expires", "del_1")
      assert Delegations.executable?("sa_never_expires", now)

      {:ok, _} =
        Delegations.grant("sa_future", "del_2", %{
          expires_at: ~U[2026-04-16 12:00:00Z]
        })

      assert Delegations.executable?("sa_future", now)

      {:ok, _} =
        Delegations.grant("sa_past", "del_3", %{
          expires_at: ~U[2026-04-15 11:00:00Z]
        })

      refute Delegations.executable?("sa_past", now)
    end

    test "false for revoking, revoked, expired, and missing" do
      {:ok, _} = Delegations.grant("sa_r1", "del_1")
      {:ok, _} = Delegations.record_revoke_requested("sa_r1")
      refute Delegations.executable?("sa_r1")

      {:ok, _} = Delegations.grant("sa_r2", "del_2")
      {:ok, _} = Delegations.record_revoke_requested("sa_r2")
      {:ok, _} = Delegations.record_revoked("sa_r2")
      refute Delegations.executable?("sa_r2")

      {:ok, _} = Delegations.grant("sa_e1", "del_3")
      {:ok, _} = Delegations.record_expired("sa_e1")
      refute Delegations.executable?("sa_e1")

      refute Delegations.executable?("sa_ghost")
    end
  end

  describe "apply_callback/1" do
    test "granted callback creates delegation when none exists" do
      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_1",
                 "delegation_id" => "del_1",
                 "state" => "granted",
                 "reason" => "initial_grant",
                 "scope" => %{"asset" => "USDC"}
               })

      assert delegation.state == :active
      assert delegation.smart_account_id == "sa_1"
    end

    test "granted callback on existing active is idempotent" do
      {:ok, existing} = Delegations.grant("sa_1", "del_1")

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_1",
                 "delegation_id" => "del_1",
                 "state" => "granted",
                 "reason" => "re_confirm"
               })

      assert delegation.id == existing.id
    end

    test "granted callback ignores a `workspace_id` smuggled in the HTTP body (#158d-c forge guard)" do
      # The adapter callback path is the only externally-reachable
      # entry to `Delegations.grant/3`, and it is intentionally
      # workspace-blind (#158d-c). A future regression that naively
      # spread `params` into the grant attrs would let a malicious
      # adapter forge a workspace assignment for a fresh row. Pin
      # the construction here: even if the HTTP body carries a
      # `workspace_id`, the resulting row stays unscoped.
      {:ok, ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "forge-guard",
          name: "Forge guard",
          mainnet_enabled: true
        })

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_forge",
                 "delegation_id" => "del_forge",
                 "state" => "granted",
                 "reason" => "wallet_connect",
                 # Hostile field — must be ignored.
                 "workspace_id" => ws.id
               })

      assert delegation.state == :active
      assert delegation.workspace_id == nil
    end

    test "revoking callback transitions active to revoking" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_1",
                 "delegation_id" => "del_1",
                 "state" => "revoking",
                 "reason" => "operator_requested"
               })

      assert delegation.state == :revoking
    end

    test "revoked callback transitions revoking to revoked" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")
      {:ok, _} = Delegations.record_revoke_requested("sa_1")

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_1",
                 "delegation_id" => "del_1",
                 "state" => "revoked",
                 "reason" => "confirmed_on_chain",
                 "tx_refs" => [%{"hash" => "0xabc123"}]
               })

      assert delegation.state == :revoked
      assert delegation.last_tx_hash == "0xabc123"
    end

    test "expired callback transitions active to expired" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_1",
                 "delegation_id" => "del_1",
                 "state" => "expired",
                 "reason" => "window_closed"
               })

      assert delegation.state == :expired
    end

    test "unknown state returns error" do
      {:ok, _} = Delegations.grant("sa_1", "del_1")

      assert {:error, :unknown_state} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_1",
                 "delegation_id" => "del_1",
                 "state" => "bogus",
                 "reason" => "test"
               })
    end

    test "grant_failed callback does not create an active delegation" do
      assert {:error, :grant_failed} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_failed_grant",
                 "delegation_id" => "grant_failed_1",
                 "state" => "grant_failed",
                 "reason" => "operator_key_missing"
               })

      refute Delegations.executable?("sa_failed_grant")
      assert is_nil(Delegations.get("sa_failed_grant"))
    end

    test "grant_failed callback emits a delegation.grant_failed audit event (#170)" do
      sa_id = "sa_grant_failed_audit_#{System.unique_integer([:positive])}"

      assert {:error, :grant_failed} =
               Delegations.apply_callback(%{
                 "smart_account_id" => sa_id,
                 "delegation_id" => "grant_failed_audit",
                 "state" => "grant_failed",
                 "reason" => "permission_install_failed"
               })

      events =
        Bank.Audit.list_events(%{subject_id: sa_id}, limit: 10)
        |> Map.fetch!(:events)

      assert event = Enum.find(events, &(&1.event_type == "delegation.grant_failed"))
      assert event.subject_type == "smart_account"
      assert event.subject_id == sa_id
      assert event.after_ref["reason"] == "permission_install_failed"
      assert event.after_ref["delegation_id"] == "grant_failed_audit"
    end

    test "granted callback with a known grant-failure reason is rejected defensively" do
      assert {:error, :grant_failed} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_old_failure_shape",
                 "delegation_id" => "grant_failed_legacy",
                 "state" => "granted",
                 "reason" => "operator_key_missing"
               })

      refute Delegations.executable?("sa_old_failure_shape")
      assert is_nil(Delegations.get("sa_old_failure_shape"))
    end

    test "invalid callback shape returns error" do
      assert {:error, :invalid_callback} = Delegations.apply_callback(%{"bad" => "shape"})
    end
  end

  describe "revoke callback tx_ref propagation (issue #31)" do
    test "revoked callback with full tx_refs records the on-chain hash and reason" do
      {:ok, _} = Delegations.grant("sa_ref", "del_ref")
      {:ok, _} = Delegations.record_revoke_requested("sa_ref")

      tx_hash = "0x" <> String.duplicate("ef", 32)

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_ref",
                 "delegation_id" => "del_ref",
                 "state" => "revoked",
                 "reason" => "operator_requested",
                 "tx_refs" => [
                   %{
                     "chain" => "base",
                     "hash" => tx_hash,
                     "block_number" => 12_345_678,
                     "status" => "success"
                   }
                 ]
               })

      assert delegation.state == :revoked
      assert delegation.last_tx_hash == tx_hash
      assert delegation.last_reason == "operator_requested"
      assert %DateTime{} = delegation.revoked_at
    end

    test "revoke_failed callback from :revoking records the failure and stays fail-closed" do
      # When the adapter's revoke attempt fails on-chain (send rejected,
      # confirmation timeout, sentinel reverted) it emits
      # state=revoke_failed — NOT revoked. Phoenix records the failure
      # on the existing :revoking row so the operator can retry.
      {:ok, _} = Delegations.grant("sa_fail_cb", "del_x")
      {:ok, _} = Delegations.record_revoke_requested("sa_fail_cb")

      tx_hash = "0x" <> String.duplicate("cd", 32)

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_fail_cb",
                 "delegation_id" => "del_x",
                 "state" => "revoke_failed",
                 "reason" => "send_failed: insufficient funds",
                 "tx_refs" => [%{"chain" => "base", "hash" => tx_hash, "status" => "unknown"}]
               })

      assert delegation.state == :revoke_failed
      assert delegation.last_reason == "send_failed: insufficient funds"
      assert delegation.last_tx_hash == tx_hash
      refute Delegations.executable?("sa_fail_cb")
    end

    test "revoked callback from :active is refused (:invalid_transition)" do
      # Success must always follow :revoking. A direct :active → :revoked
      # would mean the adapter somehow confirmed a revoke it never
      # acknowledged starting — that's a contract violation, not a
      # recoverable state.
      {:ok, _} = Delegations.grant("sa_direct", "del_x")

      assert {:error, :invalid_transition} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_direct",
                 "delegation_id" => "del_x",
                 "state" => "revoked",
                 "reason" => "operator_requested"
               })
    end

    test "a duplicate revoked callback is a benign :invalid_transition" do
      {:ok, _} = Delegations.grant("sa_dup", "del_dup")
      {:ok, _} = Delegations.record_revoke_requested("sa_dup")

      payload = %{
        "smart_account_id" => "sa_dup",
        "delegation_id" => "del_dup",
        "state" => "revoked",
        "reason" => "operator_requested"
      }

      assert {:ok, d} = Delegations.apply_callback(payload)
      assert d.state == :revoked

      # The second callback finds no non-terminal row and reports
      # :not_found rather than double-recording. The controller treats
      # this as accepted_with_warning.
      assert {:error, :not_found} = Delegations.apply_callback(payload)
    end

    test "granted callback for a row already in :revoking is :invalid_transition" do
      # Regression guard: if the adapter emits a stale `granted` callback
      # AFTER Phoenix has already moved the row to `:revoking` (e.g. an
      # in-flight grant beat its first callback while the operator
      # already kicked off a revoke), Phoenix MUST refuse rather than
      # silently snap the row back to :active. Without this pin, a
      # future change to apply_callback/1's `granted` branch could let
      # the `_` fallthrough convert :revoking back to :active and
      # un-fail-close the smart account.
      {:ok, _} = Delegations.grant("sa_grant_during_revoke", "del_x")
      {:ok, _} = Delegations.record_revoke_requested("sa_grant_during_revoke")

      assert {:error, :invalid_transition} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_grant_during_revoke",
                 "delegation_id" => "del_x",
                 "state" => "granted",
                 "reason" => "wallet_connect_install"
               })

      # Row stayed in :revoking; the smart account remains
      # non-executable until the revoke resolves.
      assert %{state: :revoking} = Delegations.get("sa_grant_during_revoke")
      refute Delegations.executable?("sa_grant_during_revoke")
    end

    test "revoked callback for a row in :revoke_failed is :invalid_transition" do
      # Operator-retry contract: a successful revoke MUST always follow
      # a fresh :revoking dispatch. A `revoked` callback arriving while
      # the row sits in :revoke_failed (e.g. a duplicated callback from
      # a previously-failed attempt that quietly confirmed) would be a
      # contract violation and must not flip the row terminal without
      # going through a fresh :revoking step. Without this pin, a
      # state-machine relaxation could let a stale callback retire the
      # row while the operator still believes a retry is needed.
      {:ok, _} = Delegations.grant("sa_failed_retry", "del_x")
      {:ok, _} = Delegations.record_revoke_requested("sa_failed_retry")
      {:ok, _} = Delegations.record_revoke_failed("sa_failed_retry")

      assert {:error, :invalid_transition} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_failed_retry",
                 "delegation_id" => "del_x",
                 "state" => "revoked",
                 "reason" => "stale_confirmation"
               })

      assert %{state: :revoke_failed} = Delegations.get("sa_failed_retry")
    end

    test "revoking callback applied to a :revoke_failed row drives the operator retry" do
      # Operator retry contract: when the previous on-chain revoke
      # attempt failed (`revoke_failed`), re-enqueueing the worker
      # produces a fresh dispatch. The adapter emits a `revoking`
      # callback BEFORE touching chain. apply_callback/1 must accept
      # that callback against a row in `:revoke_failed` (not just
      # `:active`) so the row visibly returns to `:revoking` for the
      # retry attempt. Without this pin, the underlying
      # `record_revoke_requested/2` path is exercised but the wire
      # contract from the controller is not.
      {:ok, _} = Delegations.grant("sa_retry_cb", "del_x")
      {:ok, _} = Delegations.record_revoke_requested("sa_retry_cb")

      {:ok, _} =
        Delegations.record_revoke_failed("sa_retry_cb", %{last_reason: "bundler_rejected"})

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_retry_cb",
                 "delegation_id" => "del_x",
                 "state" => "revoking",
                 "reason" => "operator_retry"
               })

      assert delegation.state == :revoking
      assert delegation.last_reason == "operator_retry"
    end

    test "every adapter grant_failed reason is recognized as a no-permission grant_failed signal" do
      # Tripwire: the adapter's `grant_failed` callback path emits one of
      # `operator_key_missing`, `chain_id_mismatch`,
      # `permission_install_failed`, `permission_serialization_failed`
      # (see chain_adapter/src/chains/base/grant.ts `GrantFailureCode`).
      # Phoenix's defensive guard at the top of the `granted` branch
      # rejects a callback whose `reason` is in @grant_failure_reasons
      # AND whose `permission` block is absent — i.e. a malformed
      # adapter that emitted state="granted" with a failure reason and
      # no artifact would still be refused. If the adapter introduces a
      # NEW failure code without updating the Phoenix list, that
      # callback would slip past the guard and create an active row
      # for a permission that was never installed.
      #
      # Pinning the list here makes the cross-repo contract explicit:
      # any change to the adapter's GrantFailureCode union forces a
      # corresponding edit to lib/bank/delegations.ex
      # @grant_failure_reasons + this fixture.
      adapter_codes = [
        "operator_key_missing",
        "chain_id_mismatch",
        "permission_install_failed",
        "permission_serialization_failed"
      ]

      for code <- adapter_codes do
        sa_id = "sa_grant_failed_#{code}"

        assert {:error, :grant_failed} =
                 Delegations.apply_callback(%{
                   "smart_account_id" => sa_id,
                   "delegation_id" => "grant_failed_#{:erlang.system_time()}",
                   "state" => "granted",
                   "reason" => code
                 })

        # No active row: the adapter never installed a permission.
        assert is_nil(Delegations.get(sa_id))
      end
    end
  end

  describe "ERC-4337 v0.7 AA-shaped callbacks (issue #32)" do
    # The adapter's AA path emits `tx_refs` carrying both `userop_hash`
    # (EntryPoint identity) and `hash` (chain-level tx hash) on
    # confirmed receipts, plus `bundler` + hex `nonce`. Phoenix only
    # keeps one identifier on the delegation row; the invariant is
    # "prefer `hash` when present, fall back to `userop_hash`". That
    # keeps pre-inclusion states (broadcast, confirmation_failed)
    # navigable in the control tower instead of showing a blank anchor.
    test "revoked callback with AA tx_refs records the on-chain hash (prefers hash over userop_hash)" do
      {:ok, _} = Delegations.grant("sa_aa_ok", "del_aa")
      {:ok, _} = Delegations.record_revoke_requested("sa_aa_ok")

      userop_hash = "0x" <> String.duplicate("aa", 32)
      tx_hash = "0x" <> String.duplicate("bb", 32)

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_aa_ok",
                 "delegation_id" => "del_aa",
                 "state" => "revoked",
                 "reason" => "operator_requested",
                 "tx_refs" => [
                   %{
                     "chain" => "base",
                     "userop_hash" => userop_hash,
                     "hash" => tx_hash,
                     "nonce" => "0x7",
                     "bundler" => "base-v07-bundler",
                     "block_number" => 42_000,
                     "status" => "success"
                   }
                 ]
               })

      assert delegation.state == :revoked
      assert delegation.last_tx_hash == tx_hash
    end

    test "revoke_failed with confirmation_failed (userop_hash only) records the user-op hash" do
      # `confirmation_failed` fires when the bundler accepted the
      # user-op but `waitForUserOperationReceipt` timed out — we have
      # a user-op hash to look up later but no on-chain tx hash yet.
      # Without the fallback, last_tx_hash would be nil and the
      # operator would have no anchor to resume the investigation.
      {:ok, _} = Delegations.grant("sa_aa_pend", "del_aa_pend")
      {:ok, _} = Delegations.record_revoke_requested("sa_aa_pend")

      userop_hash = "0x" <> String.duplicate("cc", 32)

      assert {:ok, delegation} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_aa_pend",
                 "delegation_id" => "del_aa_pend",
                 "state" => "revoke_failed",
                 "reason" => "confirmation_failed: timeout",
                 "tx_refs" => [
                   %{
                     "chain" => "base",
                     "userop_hash" => userop_hash,
                     "nonce" => "0x7",
                     "bundler" => "base-v07-bundler",
                     "status" => "unknown"
                   }
                 ]
               })

      assert delegation.state == :revoke_failed
      assert delegation.last_tx_hash == userop_hash
      refute Delegations.executable?("sa_aa_pend")
    end
  end

  describe "permission artifacts (issue #58)" do
    # ZeroDev permissionId is bytes4; validationId is bytes21
    # (`0x02 ‖ rightPad(permissionId, 20)`). The fixtures below match
    # the on-chain shape exactly so the changeset's byte-size
    # validation has something concrete to check.
    @perm_id <<0xA1, 0xB2, 0xC3, 0xD4>>
    @validation_id <<0x02>> <> @perm_id <> :binary.copy(<<0x00>>, 16)
    @blob_b64 "eyJzZXJpYWxpemVkUGVybWlzc2lvbkFjY291bnQiOiJ0ZXN0In0="
    # 20-byte session-signer EOA hex (0x + 40 hex chars).
    @session_signer "0x" <> String.duplicate("11", 20)

    test "grant accepts permission artifact attrs and persists them verbatim" do
      assert {:ok, d} =
               Delegations.grant("sa_crypto", "0xa1b2c3d4", %{
                 permission_blob: @blob_b64,
                 permission_id: @perm_id,
                 validation_id: @validation_id,
                 kernel_version: "0.3.1",
                 permission_package_version: "5.6.3",
                 installed_at_block: 12_345_678,
                 install_tx_hash: "0xdeadbeef",
                 session_signer_address: @session_signer
               })

      assert d.permission_blob == @blob_b64
      assert d.permission_id == @perm_id
      assert d.validation_id == @validation_id
      assert d.kernel_version == "0.3.1"
      assert d.permission_package_version == "5.6.3"
      assert d.installed_at_block == 12_345_678
      assert d.install_tx_hash == "0xdeadbeef"
      assert d.session_signer_address == @session_signer
    end

    test "grant rejects a permission_id that is not exactly 4 bytes" do
      assert {:error, %Ecto.Changeset{errors: errors}} =
               Delegations.grant("sa_bad_pid", "0xa1b2c3", %{
                 permission_id: <<0xA1, 0xB2, 0xC3>>,
                 validation_id: @validation_id
               })

      assert {:permission_id, {"must be exactly 4 bytes", _}} =
               List.keyfind(errors, :permission_id, 0)
    end

    test "grant rejects a validation_id that is not exactly 21 bytes" do
      # The kernel's `uninstallValidation` takes a `bytes21` argument.
      # A row carrying a 20-byte or 22-byte value would build malformed
      # calldata, so we refuse at the changeset boundary.
      assert {:error, %Ecto.Changeset{errors: errors}} =
               Delegations.grant("sa_bad_vid", "0xa1b2c3d4", %{
                 permission_id: @perm_id,
                 validation_id: :binary.copy(<<0x00>>, 22)
               })

      assert {:validation_id, {"must be exactly 21 bytes", _}} =
               List.keyfind(errors, :validation_id, 0)
    end

    test "cryptographically_revocable?/1 returns true when the complete wire-shape is present" do
      {:ok, d} =
        Delegations.grant("sa_yes", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3",
          session_signer_address: @session_signer
        })

      assert Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when session_signer_address is missing" do
      # A security review forces a keyless blob, which
      # means the session-signer EOA must travel separately. Without
      # it the adapter cannot rebuild the stub ModularSigner at
      # revoke-time, so the row is NOT cryptographically revocable.
      {:ok, d} =
        Delegations.grant("sa_partial_signer", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3"
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false on legacy sentinel rows" do
      {:ok, d} = Delegations.grant("sa_legacy", "del_legacy")
      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when blob is missing" do
      {:ok, d} =
        Delegations.grant("sa_partial_blob", "0xa1b2c3d4", %{
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3"
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when permission_id is missing" do
      {:ok, d} =
        Delegations.grant("sa_partial_pid", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3"
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when package version is missing" do
      {:ok, d} =
        Delegations.grant("sa_partial_pkg", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1"
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when validation_id is missing" do
      # The adapter feeds `validation_id` directly to
      # `Kernel.uninstallValidation(...)` as `vId`. Without it the
      # cryptographic revoke cannot run, so the predicate must
      # refuse and let the worker fall back to sentinel.
      {:ok, d} =
        Delegations.grant("sa_partial_vid", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3",
          session_signer_address: @session_signer
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when kernel_version is missing" do
      # The adapter pins kernel_version to deserialize the blob
      # against the right kernel implementation; missing it
      # invalidates the row.
      {:ok, d} =
        Delegations.grant("sa_partial_kv", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          permission_package_version: "5.6.3",
          session_signer_address: @session_signer
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when permission_id is the wrong byte size" do
      # `Delegations.grant/3` would refuse to insert a 3-byte
      # permission_id at the changeset boundary. The predicate
      # itself is a defense-in-depth pattern match — hand-construct
      # a struct that bypasses the changeset to confirm the
      # predicate ALSO refuses, so any future schema relaxation
      # cannot silently produce a malformed dispatch block.
      d = %Bank.Delegations.Delegation{
        smart_account_id: "sa_bad_pid_size",
        delegation_id: "0xa1b2c3",
        chain: "base",
        state: :active,
        permission_blob: @blob_b64,
        permission_id: <<0xA1, 0xB2, 0xC3>>,
        validation_id: @validation_id,
        kernel_version: "0.3.1",
        permission_package_version: "5.6.3",
        session_signer_address: @session_signer
      }

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when validation_id is the wrong byte size" do
      # Same defense-in-depth posture: bypass the changeset's
      # byte-size guard to confirm the predicate is independently
      # safe. Kernel.uninstallValidation takes bytes21; a 22-byte
      # value would build malformed calldata.
      d = %Bank.Delegations.Delegation{
        smart_account_id: "sa_bad_vid_size",
        delegation_id: "0xa1b2c3d4",
        chain: "base",
        state: :active,
        permission_blob: @blob_b64,
        permission_id: @perm_id,
        validation_id: :binary.copy(<<0x00>>, 22),
        kernel_version: "0.3.1",
        permission_package_version: "5.6.3",
        session_signer_address: @session_signer
      }

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "cryptographically_revocable?/1 returns false when session_signer_address is the wrong length" do
      # The wire requires `0x` + 40 hex chars (= 42 bytes UTF-8 in
      # the column). 41 or 43 bytes would fail the adapter's Zod
      # regex anyway, but the predicate refuses up-front so the
      # worker never selects the crypto path with bad input.
      {:ok, d} =
        Delegations.grant("sa_short_signer", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3",
          session_signer_address: "0x" <> String.duplicate("11", 19)
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "permission_dispatch_block/1 returns nil when the predicate returns false" do
      # Integration test for the predicate ↔ wire encoder contract:
      # any row that fails `cryptographically_revocable?/1` MUST
      # NOT produce a dispatch block, otherwise the adapter would
      # receive a malformed `permission` payload (Zod would
      # reject, but Phoenix should fail locally first with a
      # deterministic absent-block).
      {:ok, partial} =
        Delegations.grant("sa_partial_disp", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3"
          # session_signer_address intentionally omitted
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(partial)
      assert is_nil(Delegations.permission_dispatch_block(partial))
    end

    test "permission_dispatch_block/1 emits hex-encoded ids, the blob, and the session signer address" do
      {:ok, d} =
        Delegations.grant("sa_disp", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3",
          session_signer_address: @session_signer
        })

      block = Delegations.permission_dispatch_block(d)

      assert block.blob == @blob_b64
      assert block.permission_id == "0xa1b2c3d4"
      # 0x02 ++ permissionId ++ 16 zero bytes → 21 bytes / 42 hex chars.
      assert block.validation_id ==
               "0x02a1b2c3d400000000000000000000000000000000"

      assert block.kernel_version == "0.3.1"
      assert block.package_version == "5.6.3"
      assert block.session_signer_address == @session_signer
    end

    test "permission_dispatch_block/1 returns nil for legacy rows" do
      {:ok, d} = Delegations.grant("sa_legacy_disp", "del_legacy")
      assert is_nil(Delegations.permission_dispatch_block(d))
    end

    test "cryptographically_revocable?/1 returns false for user-rooted rows even with full artifacts (#475)" do
      # Browser-signed installs (#474) populate the artifact columns
      # the same way operator-signed installs do, but the kernel's
      # root validator is the user EOA — `OPERATOR_PRIVATE_KEY`
      # cannot sign `Kernel.uninstallValidation(...)` against it.
      # The predicate MUST refuse so the worker takes the sentinel
      # audit anchor path until the v0.2 browser-signed revoke
      # ships.
      {:ok, d} =
        Delegations.grant("sa_user_owner", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3",
          session_signer_address: @session_signer,
          root_validator_owner: "user"
        })

      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
      assert is_nil(Delegations.permission_dispatch_block(d))
    end

    test "Delegations.grant/3 defaults root_validator_owner to operator (#475)" do
      # `grant/3` is the legacy server-signed install entry point.
      # Defaulting to `"operator"` matches the migration's one-shot
      # backfill so the cryptographic-revoke path stays available
      # for these rows.
      {:ok, d} = Delegations.grant("sa_default_owner", "del_default")
      assert d.root_validator_owner == "operator"
    end

    test "revoke_method/1 returns :cryptographic for operator-rooted artifact rows (#475)" do
      {:ok, d} =
        Delegations.grant("sa_method_crypto", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3",
          session_signer_address: @session_signer
        })

      assert Bank.Delegations.Delegation.revoke_method(d) == :cryptographic
    end

    test "revoke_method/1 returns :sentinel for legacy artifact-less rows (#475)" do
      {:ok, d} = Delegations.grant("sa_method_sentinel", "del_legacy")
      assert Bank.Delegations.Delegation.revoke_method(d) == :sentinel
    end

    test "revoke_method/1 returns :sentinel for user-rooted rows (#475)" do
      {:ok, d} =
        Delegations.grant("sa_method_user", "0xa1b2c3d4", %{
          permission_blob: @blob_b64,
          permission_id: @perm_id,
          validation_id: @validation_id,
          kernel_version: "0.3.1",
          permission_package_version: "5.6.3",
          session_signer_address: @session_signer,
          root_validator_owner: "user"
        })

      assert Bank.Delegations.Delegation.revoke_method(d) == :sentinel
    end

    test "apply_callback granted with full permission block stores all artifacts decoded from hex" do
      assert {:ok, d} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_cb",
                 "delegation_id" => "0xa1b2c3d4",
                 "state" => "granted",
                 "reason" => "wallet_connect",
                 "permission" => %{
                   "blob" => @blob_b64,
                   "permission_id" => "0xa1b2c3d4",
                   "validation_id" => "0x02a1b2c3d400000000000000000000000000000000",
                   "kernel_version" => "0.3.1",
                   "package_version" => "5.6.3",
                   "session_signer_address" => @session_signer,
                   "installed_at_block" => 12_345_678,
                   "install_tx_hash" => "0xdeadbeef"
                 }
               })

      assert d.state == :active
      assert d.permission_blob == @blob_b64
      assert d.permission_id == @perm_id
      assert d.validation_id == @validation_id
      assert d.kernel_version == "0.3.1"
      assert d.permission_package_version == "5.6.3"
      assert d.session_signer_address == @session_signer
      assert d.installed_at_block == 12_345_678
      assert d.install_tx_hash == "0xdeadbeef"
      assert Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end

    test "apply_callback granted without session_signer_address produces a non-revocable row" do
      # Backwards-compat: an adapter that has not been upgraded to
      # emit `session_signer_address` still creates a Phoenix row,
      # but the row is NOT cryptographically revocable. The worker's
      # branch in `permission_dispatch_block/1` keeps such a row on
      # the sentinel revoke path until a future grant repopulates
      # the field.
      assert {:ok, d} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_partial_cb",
                 "delegation_id" => "0xa1b2c3d4",
                 "state" => "granted",
                 "reason" => "wallet_connect",
                 "permission" => %{
                   "blob" => @blob_b64,
                   "permission_id" => "0xa1b2c3d4",
                   "validation_id" => "0x02a1b2c3d400000000000000000000000000000000",
                   "kernel_version" => "0.3.1",
                   "package_version" => "5.6.3"
                 }
               })

      assert d.state == :active
      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
      assert is_nil(d.session_signer_address)
    end

    test "apply_callback granted without permission block keeps row legacy-shaped" do
      # Backward compat: pre-#58 callback fixtures (and the smoke task
      # in v0.1) still send no `permission` key. The row stays on the
      # sentinel revoke path until a future `granted` callback
      # populates the artifacts.
      assert {:ok, d} =
               Delegations.apply_callback(%{
                 "smart_account_id" => "sa_cb_legacy",
                 "delegation_id" => "del_legacy",
                 "state" => "granted",
                 "reason" => "smoke"
               })

      assert d.state == :active
      refute Bank.Delegations.Delegation.cryptographically_revocable?(d)
    end
  end
end
