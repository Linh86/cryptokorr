defmodule Bank.IntentsTest do
  @moduledoc """
  Context-level tests for `Bank.Intents`.

  Three surfaces are pinned here:

    * `counts_by_state/1` (issue #53) — the chip-bar count breakdown
      that the intents page renders. The semantics: counts respect
      `:kind` and `:search`, but not `:state`. The breakdown groups
      by state itself, so applying a state filter would be useless.

    * `submit/2` (issue #135) — the public agent-facing facade
      `POST /v1/intents` calls. Tests cover the happy paths,
      idempotent replay, hash mismatch conflict, and boundary
      validation (chain / asset / amount / target shape).

    * `cancel/2` (issue #139) — the operator pre-execution cancel
      facade `POST /v1/intents/:id/cancel` calls. Tests cover the
      allowed-state matrix, idempotent re-cancel, the wrong-state
      matrix (executing / executed / blocked / expired), the
      not-found / malformed-id cases, and the missing-reason guard.
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Bank.Fixtures
  import Ecto.Query

  alias Bank.Intents
  alias Bank.Intents.AgentIntent
  alias Bank.Runtime.Workers.EvaluateIntent

  describe "counts_by_state/1 with no filters" do
    test "returns all known states with zero when the table is empty" do
      counts = Intents.counts_by_state()

      for state <- [
            :submitted,
            :evaluating,
            :decided,
            :executing,
            :executed,
            :blocked,
            :cancelled,
            :expired
          ] do
        assert Map.fetch!(counts, state) == 0
      end
    end

    test "groups intents by state across all kinds" do
      _a = agent_intent(kind: :transfer)
      _b = agent_intent(kind: :transfer)

      swap = agent_intent(kind: :swap)
      {:ok, _} = swap |> Ecto.Changeset.change(%{state: :blocked}) |> Bank.Repo.update()

      counts = Intents.counts_by_state()

      assert counts.submitted == 2
      assert counts.blocked == 1
    end
  end

  describe "counts_by_state/1 scoped by :kind" do
    test "only counts intents whose kind matches" do
      _transfer = agent_intent(kind: :transfer)
      swap1 = agent_intent(kind: :swap)
      swap2 = agent_intent(kind: :swap)
      {:ok, _} = swap2 |> Ecto.Changeset.change(%{state: :executed}) |> Bank.Repo.update()

      counts = Intents.counts_by_state(kind: :swap)

      # Two swaps: one submitted, one executed. The transfer is not counted.
      assert counts.submitted == 1
      assert counts.executed == 1
      assert counts.blocked == 0

      _ = swap1
    end

    test "kind=:all is equivalent to no filter" do
      _a = agent_intent(kind: :transfer)
      _b = agent_intent(kind: :swap)

      assert Intents.counts_by_state(kind: :all) == Intents.counts_by_state()
    end
  end

  describe "counts_by_state/1 scoped by :search" do
    test "matches on agent_id substring" do
      _alpha = agent_intent(agent_id: "agent-alpha")
      _beta = agent_intent(agent_id: "agent-beta")

      counts = Intents.counts_by_state(search: "alpha")

      assert counts.submitted == 1
    end

    test "matches on intent id prefix" do
      target = agent_intent()
      _other = agent_intent()

      prefix = String.slice(target.id, 0, 8)
      counts = Intents.counts_by_state(search: prefix)

      assert counts.submitted == 1
    end

    test "empty and whitespace-only search is ignored" do
      _a = agent_intent()
      _b = agent_intent()

      assert Intents.counts_by_state(search: "").submitted == 2
      assert Intents.counts_by_state(search: "   ").submitted == 2
    end
  end

  describe "counts_by_state/1 — :state opt is ignored by design" do
    test "counts ignore the :state opt even when supplied" do
      submitted = agent_intent()
      blocked = agent_intent()
      {:ok, _} = blocked |> Ecto.Changeset.change(%{state: :blocked}) |> Bank.Repo.update()

      # Even though we pass state: :blocked, the breakdown still shows
      # submitted=1, blocked=1. This is the contract the intents page
      # relies on: chips remain meaningful navigation targets.
      counts = Intents.counts_by_state(state: :blocked)

      assert counts.submitted == 1
      assert counts.blocked == 1

      _ = submitted
    end
  end

  describe "counts_by_state/1 combined with :kind + :search" do
    test "applies both filters conjunctively" do
      # Two transfers with "alpha" in the agent_id; one stays submitted,
      # one is moved to executed.
      t1 = agent_intent(kind: :transfer, agent_id: "agent-alpha-1")
      t2 = agent_intent(kind: :transfer, agent_id: "agent-alpha-2")
      {:ok, _} = t2 |> Ecto.Changeset.change(%{state: :executed}) |> Bank.Repo.update()

      # Noise that must NOT be counted.
      _swap_alpha = agent_intent(kind: :swap, agent_id: "agent-alpha-swap")
      _transfer_other = agent_intent(kind: :transfer, agent_id: "agent-other")

      counts = Intents.counts_by_state(kind: :transfer, search: "alpha")

      assert counts.submitted == 1
      assert counts.executed == 1
      assert counts.blocked == 0

      _ = t1
    end
  end

  describe "submit/2 — happy paths" do
    test "persists, audits, and enqueues evaluation for a counterparty target" do
      cp = counterparty()

      assert {:ok, %{intent: %AgentIntent{} = intent, replay?: false}} =
               Intents.submit(
                 valid_body(%{
                   "agent_id" => "agent-submit-cp",
                   "idempotency_key" => "k-submit-cp",
                   "target" => %{"counterparty_id" => cp.id}
                 })
               )

      assert intent.state == :submitted
      assert intent.target_counterparty_id == cp.id
      assert intent.target_raw_address == nil
      assert intent.kind == :transfer
      assert intent.asset == "USDC"
      assert intent.chain == "base"
      assert is_binary(intent.payload_hash)

      assert_enqueued(
        worker: EvaluateIntent,
        queue: :intents_evaluate,
        args: %{"intent_id" => intent.id}
      )
    end

    test "accepts a raw-address target" do
      assert {:ok, %{intent: intent, replay?: false}} =
               Intents.submit(
                 valid_body(%{
                   "agent_id" => "agent-submit-raw",
                   "idempotency_key" => "k-submit-raw",
                   "target" => %{
                     "raw_address" => "0x1234567890abcdef1234567890abcdef12345678"
                   }
                 })
               )

      assert intent.target_raw_address == "0x1234567890abcdef1234567890abcdef12345678"
      assert intent.target_counterparty_id == nil
    end
  end

  describe "submit/2 — idempotency" do
    test "same body with same key returns the existing intent and skips work" do
      cp = counterparty()

      body =
        valid_body(%{
          "agent_id" => "agent-replay",
          "idempotency_key" => "k-replay",
          "target" => %{"counterparty_id" => cp.id}
        })

      assert {:ok, %{intent: first, replay?: false}} = Intents.submit(body)
      assert {:ok, %{intent: second, replay?: true}} = Intents.submit(body)

      assert first.id == second.id

      # Only the first call enqueues the evaluation worker.
      assert all_enqueued(worker: EvaluateIntent, args: %{"intent_id" => first.id})
             |> length() == 1
    end

    test "same key with a different body returns idempotency_conflict" do
      cp = counterparty()

      body =
        valid_body(%{
          "agent_id" => "agent-mismatch",
          "idempotency_key" => "k-mismatch",
          "target" => %{"counterparty_id" => cp.id}
        })

      assert {:ok, %{intent: first}} = Intents.submit(body)

      mismatched = Map.put(body, "amount", "9.99")

      assert {:error, {:idempotency_conflict, prior}} = Intents.submit(mismatched)
      assert prior.id == first.id
    end
  end

  describe "cancel/2 — happy paths" do
    test "cancels a :submitted intent, audits, and returns the updated record" do
      intent = agent_intent()

      assert {:ok, %AgentIntent{} = cancelled} =
               Intents.cancel(intent.id, reason: "operator change of plans")

      assert cancelled.state == :cancelled
      assert cancelled.id == intent.id

      audits =
        Bank.Repo.all(
          from(e in Bank.Audit.AuditEvent,
            where: e.subject_id == ^intent.id and e.event_type == "intent.cancelled"
          )
        )

      assert [event] = audits
      assert event.actor == :user
      assert event.before_ref["state"] == "submitted"
      assert event.after_ref["state"] == "cancelled"
      assert event.after_ref["reason"] == "operator change of plans"
    end

    test "cancels a :decided intent" do
      intent =
        agent_intent()
        |> Ecto.Changeset.change(%{state: :decided})
        |> Bank.Repo.update!()

      assert {:ok, cancelled} =
               Intents.cancel(intent.id, reason: "supersession")

      assert cancelled.state == :cancelled
    end

    test "cancels an :evaluating intent" do
      intent =
        agent_intent()
        |> Ecto.Changeset.change(%{state: :evaluating})
        |> Bank.Repo.update!()

      assert {:ok, cancelled} =
               Intents.cancel(intent.id, reason: "policy change")

      assert cancelled.state == :cancelled
    end

    test "accepts an %AgentIntent{} struct directly" do
      intent = agent_intent()

      assert {:ok, cancelled} = Intents.cancel(intent, reason: "by struct")
      assert cancelled.state == :cancelled
    end

    test "honours an :actor_id stamp on the audit event" do
      intent = agent_intent()

      assert {:ok, _} =
               Intents.cancel(intent.id,
                 reason: "operator-initiated",
                 actor_id: "operator-bob"
               )

      [event] =
        Bank.Repo.all(
          from(e in Bank.Audit.AuditEvent,
            where: e.subject_id == ^intent.id and e.event_type == "intent.cancelled"
          )
        )

      assert event.actor_id == "operator-bob"
      assert event.actor == :user
    end
  end

  describe "cancel/2 — idempotent re-cancel" do
    test "re-cancelling an already-cancelled intent does not write a second audit row" do
      intent = agent_intent()

      assert {:ok, _first} = Intents.cancel(intent.id, reason: "first")

      audits_before =
        Bank.Repo.all(
          from(e in Bank.Audit.AuditEvent,
            where: e.subject_id == ^intent.id and e.event_type == "intent.cancelled"
          )
        )

      assert length(audits_before) == 1

      assert {:ok, :already_cancelled, %AgentIntent{state: :cancelled} = same} =
               Intents.cancel(intent.id, reason: "second")

      assert same.id == intent.id

      audits_after =
        Bank.Repo.all(
          from(e in Bank.Audit.AuditEvent,
            where: e.subject_id == ^intent.id and e.event_type == "intent.cancelled"
          )
        )

      assert length(audits_after) == 1
    end
  end

  describe "cancel/2 — wrong state" do
    test "rejects an :executing intent with :wrong_state" do
      intent =
        agent_intent()
        |> Ecto.Changeset.change(%{state: :executing})
        |> Bank.Repo.update!()

      assert {:error, {:wrong_state, :executing}} =
               Intents.cancel(intent.id, reason: "halt")

      reloaded = Bank.Repo.get!(AgentIntent, intent.id)
      assert reloaded.state == :executing
    end

    test "rejects an :executed intent with :wrong_state" do
      intent =
        agent_intent()
        |> Ecto.Changeset.change(%{state: :executed})
        |> Bank.Repo.update!()

      assert {:error, {:wrong_state, :executed}} =
               Intents.cancel(intent.id, reason: "n/a")
    end

    test "rejects a :blocked intent with :wrong_state" do
      intent =
        agent_intent()
        |> Ecto.Changeset.change(%{state: :blocked})
        |> Bank.Repo.update!()

      assert {:error, {:wrong_state, :blocked}} =
               Intents.cancel(intent.id, reason: "n/a")
    end

    test "rejects an :expired intent with :wrong_state" do
      intent =
        agent_intent()
        |> Ecto.Changeset.change(%{state: :expired})
        |> Bank.Repo.update!()

      assert {:error, {:wrong_state, :expired}} =
               Intents.cancel(intent.id, reason: "n/a")
    end
  end

  describe "cancel/2 — not found" do
    test "returns :not_found for an unknown UUID" do
      assert {:error, :not_found} = Intents.cancel(Ecto.UUID.generate(), reason: "x")
    end

    test "returns :not_found for a malformed id" do
      assert {:error, :not_found} = Intents.cancel("not-a-uuid", reason: "x")
    end
  end

  describe "cancel/2 — invalid opts" do
    test "rejects a missing reason" do
      intent = agent_intent()
      assert {:error, {:invalid, :reason_required}} = Intents.cancel(intent.id, [])
    end

    test "rejects a blank reason" do
      intent = agent_intent()
      assert {:error, {:invalid, :reason_required}} = Intents.cancel(intent.id, reason: "")
    end

    test "rejects a non-string reason" do
      intent = agent_intent()
      assert {:error, {:invalid, :reason_required}} = Intents.cancel(intent.id, reason: 42)
    end
  end

  describe "submit/2 — boundary validation" do
    test "rejects a non-base chain with :unsupported_chain" do
      cp = counterparty()

      body =
        valid_body(%{
          "chain" => "ethereum",
          "target" => %{"counterparty_id" => cp.id}
        })

      assert {:error, {:unsupported_chain, "ethereum"}} = Intents.submit(body)
    end

    test "rejects a non-USDC asset with :unsupported_asset" do
      cp = counterparty()

      body =
        valid_body(%{
          "asset" => "DAI",
          "target" => %{"counterparty_id" => cp.id}
        })

      assert {:error, {:unsupported_asset, "DAI"}} = Intents.submit(body)
    end

    test "rejects a missing target shape" do
      assert {:error, {:invalid, :target_missing}} =
               Intents.submit(valid_body(%{"target" => %{}}))
    end

    test "rejects a target with both counterparty and raw address" do
      cp = counterparty()

      body =
        valid_body(%{
          "target" => %{
            "counterparty_id" => cp.id,
            "raw_address" => "0xabcdef1234567890abcdef1234567890abcdef12"
          }
        })

      assert {:error, {:invalid, :target_ambiguous}} = Intents.submit(body)
    end

    test "rejects a non-positive amount" do
      cp = counterparty()

      body =
        valid_body(%{
          "amount" => "0",
          "target" => %{"counterparty_id" => cp.id}
        })

      assert {:error, {:invalid, :amount}} = Intents.submit(body)
    end
  end

  # #184 / epic #167 — explicit smart_account_id selector contract.
  # `valid_body/1` defaults `chain: "base"` and a raw-address target,
  # so each test focuses on the smart-account axis only. The workspace
  # is the one stamped into the process dictionary by `setup_workspace`
  # below (mirrors how `BankWeb.ConnCase.register_and_log_in_user/1`
  # populates it for HTTP tests).
  describe "submit/2 — smart_account_id contract" do
    setup :setup_workspace

    test "accepts an explicit smart_account_id that belongs to the workspace and matches the chain",
         %{workspace_id: ws_id} do
      sa = smart_account(%{chain: "base-sepolia"})

      body =
        valid_body(%{
          "agent_id" => "agent-sa-explicit",
          "idempotency_key" => "k-sa-explicit",
          "chain" => "base-sepolia",
          "smart_account_id" => sa.id
        })

      assert {:ok, %{intent: intent, replay?: false}} =
               Intents.submit(body, workspace_id: ws_id)

      assert intent.smart_account_id == sa.id
    end

    test "auto-resolves (compat mode) when the workspace has zero smart accounts",
         %{workspace_id: ws_id} do
      body = testnet_body("agent-sa-zero", "k-sa-zero")

      assert {:ok, %{intent: intent}} = Intents.submit(body, workspace_id: ws_id)
      assert intent.smart_account_id == nil
    end

    test "auto-resolves (compat mode) when the workspace has exactly one non-revoked smart account",
         %{workspace_id: ws_id} do
      _solo = smart_account(%{chain: "base-sepolia"})

      body = testnet_body("agent-sa-single", "k-sa-single")

      assert {:ok, %{intent: intent}} = Intents.submit(body, workspace_id: ws_id)
      assert intent.smart_account_id == nil
    end

    test "rejects an absent smart_account_id when the workspace has two non-revoked accounts",
         %{workspace_id: ws_id} do
      _a = smart_account(%{chain: "base-sepolia"})
      _b = smart_account(%{chain: "base-sepolia"})

      body = testnet_body("agent-sa-multi", "k-sa-multi")

      assert {:error, :smart_account_required} =
               Intents.submit(body, workspace_id: ws_id)
    end

    test "ignores revoked smart accounts when counting workspace ambiguity",
         %{workspace_id: ws_id} do
      _live = smart_account(%{chain: "base-sepolia"})
      revoked = smart_account(%{chain: "base-sepolia"})
      {:ok, :changed, _} = Bank.SmartAccounts.revoke(revoked)

      body = testnet_body("agent-sa-revoked-ignored", "k-sa-revoked-ignored")

      assert {:ok, %{intent: intent}} = Intents.submit(body, workspace_id: ws_id)
      assert intent.smart_account_id == nil
    end

    test "rejects a smart_account_id that belongs to a different workspace as :smart_account_not_found",
         %{workspace_id: ws_id} do
      {:ok, foreign_ws} =
        Bank.Workspaces.create_workspace(%{
          slug: "foreign-#{System.unique_integer([:positive])}",
          name: "Foreign workspace"
        })

      foreign_sa = smart_account(%{workspace_id: foreign_ws.id, chain: "base-sepolia"})

      body =
        testnet_body("agent-sa-foreign", "k-sa-foreign", %{
          "smart_account_id" => foreign_sa.id
        })

      assert {:error, :smart_account_not_found} =
               Intents.submit(body, workspace_id: ws_id)
    end

    test "rejects an unknown UUID smart_account_id as :smart_account_not_found",
         %{workspace_id: ws_id} do
      body =
        testnet_body("agent-sa-unknown", "k-sa-unknown", %{
          "smart_account_id" => Ecto.UUID.generate()
        })

      assert {:error, :smart_account_not_found} =
               Intents.submit(body, workspace_id: ws_id)
    end

    test "rejects a smart_account on a different chain as :smart_account_chain_mismatch",
         %{workspace_id: ws_id} do
      # Intent on base-sepolia (testnet — bypasses mainnet gating);
      # account on a non-matching testnet alias.
      sa = smart_account(%{chain: "sepolia"})

      body =
        testnet_body("agent-sa-chain-mismatch", "k-sa-chain-mismatch", %{
          "smart_account_id" => sa.id
        })

      assert {:error, :smart_account_chain_mismatch} =
               Intents.submit(body, workspace_id: ws_id)
    end

    test "rejects a malformed smart_account_id at normalize-time", %{workspace_id: ws_id} do
      body =
        testnet_body("agent-sa-malformed", "k-sa-malformed", %{
          "smart_account_id" => "not-a-uuid"
        })

      assert {:error, {:invalid, :smart_account_id}} =
               Intents.submit(body, workspace_id: ws_id)
    end

    test "treats blank / whitespace smart_account_id as absent",
         %{workspace_id: ws_id} do
      body =
        testnet_body("agent-sa-blank", "k-sa-blank", %{
          "smart_account_id" => ""
        })

      assert {:ok, %{intent: intent}} = Intents.submit(body, workspace_id: ws_id)
      assert intent.smart_account_id == nil
    end

    test "smart_account_id participates in the idempotency hash",
         %{workspace_id: ws_id} do
      sa_a = smart_account(%{chain: "base-sepolia"})
      sa_b = smart_account(%{chain: "base-sepolia"})

      base = testnet_body("agent-sa-idem", "k-sa-idem")

      assert {:ok, %{intent: first, replay?: false}} =
               Intents.submit(Map.put(base, "smart_account_id", sa_a.id), workspace_id: ws_id)

      assert {:error, {:idempotency_conflict, prior}} =
               Intents.submit(Map.put(base, "smart_account_id", sa_b.id), workspace_id: ws_id)

      assert prior.id == first.id
    end
  end

  defp setup_workspace(_ctx) do
    {:ok, workspace} =
      Bank.Workspaces.create_workspace(%{
        slug: "ws-#{System.unique_integer([:positive])}",
        name: "Workspace fixture"
      })

    Process.put(:bank_test_workspace_id, workspace.id)

    on_exit(fn -> Process.delete(:bank_test_workspace_id) end)

    {:ok, workspace_id: workspace.id, workspace: workspace}
  end

  defp testnet_body(agent_id, idem_key, extras \\ %{}) do
    %{
      "agent_id" => agent_id,
      "idempotency_key" => idem_key,
      "chain" => "base-sepolia"
    }
    |> Map.merge(extras)
    |> valid_body()
  end

  defp valid_body(overrides) when is_map(overrides) do
    %{
      "idempotency_key" => "k-#{System.unique_integer([:positive])}",
      "source" => "agent",
      "agent_id" => "agent-#{System.unique_integer([:positive])}",
      "kind" => "transfer",
      "asset" => "USDC",
      "chain" => "base",
      "amount" => "12.50",
      "target" => %{"raw_address" => "0xabcdef0000000000000000000000000000000001"}
    }
    |> Map.merge(overrides)
  end
end
