defmodule Bank.Policies.VersionsTest do
  @moduledoc """
  Tests for `Bank.Policies.Versions` (#223) — workspace-scoped
  draft/publish/rollback context for policy bundles.

  Coverage matches the issue body's `## Tests` block:

    * draft edit does not affect runtime
    * publish changes runtime for new decisions only
    * rollback works
    * published snapshot immutable

  Plus per-issue concerns:

    * cross-workspace isolation
    * audit events on draft/publish/rollback
    * version_number sequence is dense and per-workspace
    * duplicate-publish race resolves to a single :published row
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Audit.AuditEvent
  alias Bank.Policies.{PolicyVersion, Versions}
  alias Bank.Repo

  import Ecto.Query

  setup do
    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "policy-ver-#{System.unique_integer([:positive])}",
        name: "Policy Versions"
      })

    %{workspace: ws, actor_id: Ecto.UUID.generate()}
  end

  # --- create_draft -----------------------------------------------------

  describe "create_draft/2" do
    test "greenfield workspace: opens an empty draft", %{workspace: ws, actor_id: actor_id} do
      assert {:ok, draft} =
               Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)

      assert draft.workspace_id == ws.id
      assert draft.status == :draft
      assert draft.version_number == 1
      assert draft.rule_ids == %{"items" => []}
      assert draft.created_by == :user
      assert is_nil(draft.supersedes_id)
      assert is_nil(draft.published_by)
      assert is_nil(draft.published_at)
    end

    test "clones rule_ids from current published version", %{
      workspace: ws,
      actor_id: actor_id
    } do
      seed_rule_ids = %{"items" => [Ecto.UUID.generate(), Ecto.UUID.generate()]}

      {:ok, draft1} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: actor_id,
          rule_ids: seed_rule_ids
        )

      {:ok, _published1} =
        Versions.publish_draft(draft1, published_by: :user, actor_id: actor_id)

      # The next draft inherits the rule_ids list AND points at
      # the published row via supersedes_id.
      assert {:ok, draft2} =
               Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)

      assert draft2.version_number == 2
      assert draft2.rule_ids == seed_rule_ids
      assert draft2.supersedes_id == draft1.id
    end

    test "explicit :rule_ids opt overrides the clone", %{workspace: ws, actor_id: actor_id} do
      explicit = %{"items" => [Ecto.UUID.generate()]}

      {:ok, draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: actor_id,
          rule_ids: explicit
        )

      assert draft.rule_ids == explicit
    end

    test "rejects malformed rule_ids shape", %{workspace: ws, actor_id: actor_id} do
      assert {:error, %Ecto.Changeset{}} =
               Versions.create_draft(ws.id,
                 created_by: :user,
                 actor_id: actor_id,
                 rule_ids: %{"wrong_key" => []}
               )

      assert {:error, %Ecto.Changeset{}} =
               Versions.create_draft(ws.id,
                 created_by: :user,
                 actor_id: actor_id,
                 rule_ids: %{"items" => ["not-a-uuid"]}
               )
    end

    test "emits a policy.version.draft_created audit event", %{
      workspace: ws,
      actor_id: actor_id
    } do
      {:ok, draft} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)

      events = list_events_for_subject(draft.id)
      assert [event] = events
      assert event.event_type == "policy.version.draft_created"
      assert event.workspace_id == ws.id
      assert event.subject_id == draft.id
      assert event.actor_id == actor_id
    end
  end

  # --- update_draft_rule_ids --------------------------------------------

  describe "update_draft_rule_ids/3 — draft edit does not affect runtime" do
    test "edits the draft's rule_ids list and leaves current published unchanged",
         %{workspace: ws, actor_id: actor_id} do
      v1_rule_ids = %{"items" => [Ecto.UUID.generate()]}

      {:ok, draft1} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: actor_id,
          rule_ids: v1_rule_ids
        )

      {:ok, published1} =
        Versions.publish_draft(draft1, published_by: :user, actor_id: actor_id)

      # Open a new draft and edit it — the published v1 must not
      # change at all.
      {:ok, draft2} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)

      new_rule_ids = %{"items" => [Ecto.UUID.generate(), Ecto.UUID.generate()]}

      {:ok, updated_draft} =
        Versions.update_draft_rule_ids(draft2, new_rule_ids)

      assert updated_draft.rule_ids == new_rule_ids
      assert updated_draft.status == :draft

      # Runtime still sees v1.
      current = Versions.current_published(ws.id)
      assert current.id == published1.id
      assert current.rule_ids == v1_rule_ids
    end

    test "refuses to edit a non-draft row (race-safe via FOR UPDATE reload)",
         %{workspace: ws, actor_id: actor_id} do
      {:ok, draft} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      {:ok, published} = Versions.publish_draft(draft, published_by: :user, actor_id: actor_id)

      assert {:error, :not_a_draft} =
               Versions.update_draft_rule_ids(published, %{"items" => [Ecto.UUID.generate()]})
    end

    test "rejects malformed rule_ids", %{workspace: ws, actor_id: actor_id} do
      {:ok, draft} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)

      assert {:error, %Ecto.Changeset{}} =
               Versions.update_draft_rule_ids(draft, %{"items" => ["not-a-uuid"]})
    end
  end

  # --- publish_draft ----------------------------------------------------

  describe "publish_draft/2" do
    test "flips draft to :published and supersedes the prior published",
         %{workspace: ws, actor_id: actor_id} do
      v1_rule_ids = %{"items" => [Ecto.UUID.generate()]}

      {:ok, draft1} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: actor_id,
          rule_ids: v1_rule_ids
        )

      {:ok, published1} =
        Versions.publish_draft(draft1, published_by: :user, actor_id: actor_id)

      assert published1.status == :published
      assert published1.published_by == :user
      assert %DateTime{} = published1.published_at
      assert %DateTime{} = published1.effective_at

      # Open a second draft and publish — v1 must be superseded.
      {:ok, draft2} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      {:ok, published2} = Versions.publish_draft(draft2, published_by: :user, actor_id: actor_id)

      assert published2.status == :published
      assert published2.version_number == 2

      reloaded_v1 = Repo.get!(PolicyVersion, published1.id)
      assert reloaded_v1.status == :superseded
    end

    test "refuses to publish a non-draft (idempotent / race-safe)",
         %{workspace: ws, actor_id: actor_id} do
      {:ok, draft} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      {:ok, published} = Versions.publish_draft(draft, published_by: :user, actor_id: actor_id)

      # Re-publishing the now-:published row is rejected.
      assert {:error, :not_a_draft} =
               Versions.publish_draft(published, published_by: :user, actor_id: actor_id)
    end

    test "publish changes runtime for new decisions only (current_published returns the new version)",
         %{workspace: ws, actor_id: actor_id} do
      assert is_nil(Versions.current_published(ws.id))

      {:ok, draft} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      assert is_nil(Versions.current_published(ws.id)), "draft must not surface as current"

      {:ok, published} = Versions.publish_draft(draft, published_by: :user, actor_id: actor_id)
      assert Versions.current_published(ws.id).id == published.id
    end

    test "emits a policy.version.published audit event with workspace_id",
         %{workspace: ws, actor_id: actor_id} do
      {:ok, draft} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      {:ok, published} = Versions.publish_draft(draft, published_by: :user, actor_id: actor_id)

      events = list_events_for_subject(published.id)
      publish_event = Enum.find(events, &(&1.event_type == "policy.version.published"))

      assert publish_event
      assert publish_event.workspace_id == ws.id
      assert publish_event.subject_id == published.id
    end

    test "at most one :published row per workspace at any time", %{
      workspace: ws,
      actor_id: actor_id
    } do
      {:ok, draft1} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      {:ok, _} = Versions.publish_draft(draft1, published_by: :user, actor_id: actor_id)

      {:ok, draft2} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      {:ok, _} = Versions.publish_draft(draft2, published_by: :user, actor_id: actor_id)

      published =
        Repo.all(
          from(v in PolicyVersion,
            where: v.workspace_id == ^ws.id and v.status == ^:published
          )
        )

      assert length(published) == 1
    end
  end

  # --- published snapshot immutability ----------------------------------

  describe "published snapshot is immutable" do
    test "schema changeset rejects rule_ids edit on a :published row",
         %{workspace: ws, actor_id: actor_id} do
      {:ok, draft} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      {:ok, published} = Versions.publish_draft(draft, published_by: :user, actor_id: actor_id)

      cs = PolicyVersion.update_draft_changeset(published, %{rule_ids: %{"items" => []}})
      refute cs.valid?
      assert {_, _} = cs.errors[:status]
    end

    test "context's update_draft_rule_ids/3 also refuses on :published",
         %{workspace: ws, actor_id: actor_id} do
      {:ok, draft} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      {:ok, published} = Versions.publish_draft(draft, published_by: :user, actor_id: actor_id)

      assert {:error, :not_a_draft} =
               Versions.update_draft_rule_ids(published, %{"items" => [Ecto.UUID.generate()]})

      # And the row's rule_ids is genuinely unchanged.
      reloaded = Repo.get!(PolicyVersion, published.id)
      assert reloaded.rule_ids == published.rule_ids
    end
  end

  # --- rollback ---------------------------------------------------------

  describe "rollback_to_version/2" do
    test "re-publishes a :superseded version and supersedes the current published",
         %{workspace: ws, actor_id: actor_id} do
      v1_ids = %{"items" => [Ecto.UUID.generate()]}
      v2_ids = %{"items" => [Ecto.UUID.generate(), Ecto.UUID.generate()]}

      {:ok, draft1} =
        Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id, rule_ids: v1_ids)

      {:ok, v1_published} =
        Versions.publish_draft(draft1, published_by: :user, actor_id: actor_id)

      {:ok, draft2} =
        Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id, rule_ids: v2_ids)

      {:ok, v2_published} =
        Versions.publish_draft(draft2, published_by: :user, actor_id: actor_id)

      # v1 is now :superseded; v2 is :published.
      assert Repo.get!(PolicyVersion, v1_published.id).status == :superseded
      assert Repo.get!(PolicyVersion, v2_published.id).status == :published

      # Roll back to v1.
      v1_superseded = Repo.get!(PolicyVersion, v1_published.id)

      assert {:ok, restored} =
               Versions.rollback_to_version(v1_superseded, actor: :user, actor_id: actor_id)

      assert restored.id == v1_published.id
      assert restored.status == :published
      assert restored.rule_ids == v1_ids

      # v2 is now :superseded.
      assert Repo.get!(PolicyVersion, v2_published.id).status == :superseded

      # current_published reflects v1 again.
      assert Versions.current_published(ws.id).id == v1_published.id
    end

    test "rollback updates effective_at but preserves the original published_at",
         %{workspace: ws, actor_id: actor_id} do
      original_published_at = ~U[2026-04-15 12:00:00.000000Z]

      v1_ids = %{"items" => [Ecto.UUID.generate()]}

      {:ok, draft1} =
        Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id, rule_ids: v1_ids)

      {:ok, v1_published} =
        Versions.publish_draft(draft1,
          published_by: :user,
          actor_id: actor_id,
          now: original_published_at,
          effective_at: original_published_at
        )

      {:ok, draft2} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      {:ok, _v2} = Versions.publish_draft(draft2, published_by: :user, actor_id: actor_id)

      v1_superseded = Repo.get!(PolicyVersion, v1_published.id)

      rollback_at = ~U[2026-05-04 12:00:00.000000Z]

      {:ok, restored} =
        Versions.rollback_to_version(v1_superseded,
          actor: :user,
          actor_id: actor_id,
          now: rollback_at
        )

      assert restored.published_at == original_published_at
      assert restored.effective_at == rollback_at
    end

    test "refuses to rollback to a row that is not :superseded",
         %{workspace: ws, actor_id: actor_id} do
      {:ok, draft} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      {:ok, published} = Versions.publish_draft(draft, published_by: :user, actor_id: actor_id)

      assert {:error, :not_a_superseded_version} =
               Versions.rollback_to_version(published, actor: :user, actor_id: actor_id)
    end

    test "emits a policy.version.rolled_back audit event", %{
      workspace: ws,
      actor_id: actor_id
    } do
      {:ok, draft1} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      {:ok, v1} = Versions.publish_draft(draft1, published_by: :user, actor_id: actor_id)

      {:ok, draft2} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      {:ok, _v2} = Versions.publish_draft(draft2, published_by: :user, actor_id: actor_id)

      v1_superseded = Repo.get!(PolicyVersion, v1.id)
      {:ok, _} = Versions.rollback_to_version(v1_superseded, actor: :user, actor_id: actor_id)

      events = list_events_for_subject(v1.id)
      rolled = Enum.find(events, &(&1.event_type == "policy.version.rolled_back"))

      assert rolled
      assert rolled.workspace_id == ws.id
    end
  end

  # --- read helpers + cross-workspace isolation -------------------------

  describe "list_versions/2 + current_published/1 + get_in_workspace/2" do
    test "list_versions returns rows newest-first, scoped to the workspace",
         %{workspace: ws, actor_id: actor_id} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "policy-ver-other-#{System.unique_integer([:positive])}",
          name: "Other"
        })

      {:ok, draft_a1} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      {:ok, _pub_a1} = Versions.publish_draft(draft_a1, published_by: :user, actor_id: actor_id)
      {:ok, draft_a2} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)

      {:ok, draft_b1} = Versions.create_draft(ws_b.id, created_by: :user, actor_id: actor_id)
      {:ok, _} = Versions.publish_draft(draft_b1, published_by: :user, actor_id: actor_id)

      rows_a = Versions.list_versions(ws.id)
      assert length(rows_a) == 2
      assert hd(rows_a).id == draft_a2.id
      assert Enum.all?(rows_a, &(&1.workspace_id == ws.id))
    end

    test "list_versions filters by status", %{workspace: ws, actor_id: actor_id} do
      {:ok, draft1} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      {:ok, _pub1} = Versions.publish_draft(draft1, published_by: :user, actor_id: actor_id)
      {:ok, _draft2} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)

      assert [pub] = Versions.list_versions(ws.id, status: :published)
      assert pub.status == :published

      assert [d] = Versions.list_versions(ws.id, status: :draft)
      assert d.status == :draft
    end

    test "get_in_workspace/2 collapses cross-workspace probes to nil",
         %{workspace: ws_a, actor_id: actor_id} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "policy-ver-iso-#{System.unique_integer([:positive])}",
          name: "Iso"
        })

      {:ok, draft_a} = Versions.create_draft(ws_a.id, created_by: :user, actor_id: actor_id)

      assert Versions.get_in_workspace(draft_a.id, ws_a.id).id == draft_a.id
      assert is_nil(Versions.get_in_workspace(draft_a.id, ws_b.id))
    end

    test "current_published returns nil when no version has been published",
         %{workspace: ws, actor_id: actor_id} do
      {:ok, _draft} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
      assert is_nil(Versions.current_published(ws.id))
    end
  end

  # --- version_number sequence ------------------------------------------

  describe "version_number sequence" do
    test "is dense and increasing per workspace", %{workspace: ws, actor_id: actor_id} do
      for expected <- 1..3 do
        {:ok, draft} = Versions.create_draft(ws.id, created_by: :user, actor_id: actor_id)
        assert draft.version_number == expected
      end
    end

    test "two workspaces have independent sequences", %{workspace: ws_a, actor_id: actor_id} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "policy-ver-seq-#{System.unique_integer([:positive])}",
          name: "Seq"
        })

      {:ok, da1} = Versions.create_draft(ws_a.id, created_by: :user, actor_id: actor_id)
      {:ok, db1} = Versions.create_draft(ws_b.id, created_by: :user, actor_id: actor_id)

      assert da1.version_number == 1
      assert db1.version_number == 1
    end
  end

  # --- helpers ----------------------------------------------------------

  defp list_events_for_subject(subject_id) do
    Repo.all(
      from(e in AuditEvent,
        where: e.subject_id == ^subject_id,
        order_by: [asc: e.ts, asc: e.id]
      )
    )
  end

  # --- snapshot_for_workspace + decision pinning (#226) -----------------

  describe "snapshot_for_workspace/1 (#226)" do
    test "returns nil when no published version exists for the workspace",
         %{workspace: ws} do
      assert is_nil(Versions.snapshot_for_workspace(ws.id))
    end

    test "returns nil for non-binary workspace_id (defensive)" do
      assert is_nil(Versions.snapshot_for_workspace(nil))
      assert is_nil(Versions.snapshot_for_workspace(123))
    end

    test "returns rules + version metadata when a published version exists",
         %{workspace: ws, actor_id: actor_id} do
      rule_a = Bank.Fixtures.policy_rule(rule_type: :amount_limit, state: :active)
      rule_b = Bank.Fixtures.policy_rule(rule_type: :amount_limit, state: :active)

      {:ok, draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: actor_id,
          rule_ids: %{"items" => [rule_a.id, rule_b.id]}
        )

      {:ok, published} = Versions.publish_draft(draft, published_by: :user, actor_id: actor_id)

      snapshot = Versions.snapshot_for_workspace(ws.id)

      assert snapshot.version_id == published.id
      assert snapshot.version_number == published.version_number

      ids_returned = snapshot.rules |> Enum.map(& &1.id) |> Enum.sort()
      assert ids_returned == Enum.sort([rule_a.id, rule_b.id])
      assert snapshot.rule_ids_in_version == [rule_a.id, rule_b.id]
    end

    test "drops rule_ids that no longer resolve to :active rules but preserves the version's authoritative list",
         %{workspace: ws, actor_id: actor_id} do
      rule_active = Bank.Fixtures.policy_rule(rule_type: :amount_limit, state: :active)
      rule_archived = Bank.Fixtures.policy_rule(rule_type: :amount_limit, state: :archived)
      ghost_id = Ecto.UUID.generate()

      {:ok, draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: actor_id,
          rule_ids: %{"items" => [rule_active.id, rule_archived.id, ghost_id]}
        )

      {:ok, _} = Versions.publish_draft(draft, published_by: :user, actor_id: actor_id)

      snapshot = Versions.snapshot_for_workspace(ws.id)

      # Only the :active rule is returned in :rules.
      assert Enum.map(snapshot.rules, & &1.id) == [rule_active.id]

      # But the version's authoritative list is preserved verbatim
      # so a reviewer / decision can pin the ORIGINAL list.
      assert snapshot.rule_ids_in_version == [rule_active.id, rule_archived.id, ghost_id]
    end
  end

  # --- end-to-end decision pinning (#226) -------------------------------

  describe "decision pinning (#226 end-to-end via Bank.Decisions.evaluate_intent/2)" do
    test "decision in a workspace WITH a published version pins to it",
         %{workspace: ws, actor_id: actor_id} do
      rule = Bank.Fixtures.policy_rule(rule_type: :amount_limit, state: :active)

      {:ok, draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: actor_id,
          rule_ids: %{"items" => [rule.id]}
        )

      {:ok, published} = Versions.publish_draft(draft, published_by: :user, actor_id: actor_id)

      cp = Bank.Fixtures.counterparty(workspace_id: ws.id)
      _label = Bank.Fixtures.address_label(counterparty: cp, chain: "base")

      _ =
        Bank.Fixtures.trust_assertion(
          subject: cp,
          level: :trusted,
          scope: %{}
        )

      intent =
        Bank.Fixtures.agent_intent(
          counterparty: cp,
          workspace_id: ws.id,
          amount: Decimal.new("25")
        )

      preview = preview_for(intent)

      assert {:ok, result} =
               Bank.Decisions.evaluate_intent(intent, preview: {:ok, preview})

      ref = result.decision.policy_snapshot_ref
      assert ref["policy_version_id"] == published.id
      assert ref["policy_version_number"] == published.version_number
      assert is_list(ref["rule_ids"])
    end

    test "decision in a workspace WITHOUT a published version stamps no version metadata (legacy fallback)",
         _context do
      # Greenfield workspace with no published version. The legacy
      # rule-loading path runs and the snapshot ref carries only
      # rule_ids — no version_id / version_number keys.
      cp = Bank.Fixtures.counterparty()
      _label = Bank.Fixtures.address_label(counterparty: cp, chain: "base")
      _ = Bank.Fixtures.trust_assertion(subject: cp, level: :trusted, scope: %{})

      intent = Bank.Fixtures.agent_intent(counterparty: cp, amount: Decimal.new("25"))
      preview = preview_for(intent)

      assert {:ok, result} =
               Bank.Decisions.evaluate_intent(intent, preview: {:ok, preview})

      ref = result.decision.policy_snapshot_ref
      refute Map.has_key?(ref, "policy_version_id")
      refute Map.has_key?(ref, "policy_version_number")
    end

    test "old decision's pinned version survives a new publish (replay determinism)",
         %{workspace: ws, actor_id: actor_id} do
      rule_v1 = Bank.Fixtures.policy_rule(rule_type: :amount_limit, state: :active)

      {:ok, draft1} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: actor_id,
          rule_ids: %{"items" => [rule_v1.id]}
        )

      {:ok, v1} = Versions.publish_draft(draft1, published_by: :user, actor_id: actor_id)

      cp = Bank.Fixtures.counterparty(workspace_id: ws.id)
      _label = Bank.Fixtures.address_label(counterparty: cp, chain: "base")
      _ = Bank.Fixtures.trust_assertion(subject: cp, level: :trusted, scope: %{})

      intent =
        Bank.Fixtures.agent_intent(
          counterparty: cp,
          workspace_id: ws.id,
          amount: Decimal.new("25")
        )

      preview = preview_for(intent)

      {:ok, result} = Bank.Decisions.evaluate_intent(intent, preview: {:ok, preview})

      assert result.decision.policy_snapshot_ref["policy_version_id"] == v1.id
      assert result.decision.policy_snapshot_ref["policy_version_number"] == 1

      # Operator publishes a new version with a different rule id.
      rule_v2 = Bank.Fixtures.policy_rule(rule_type: :amount_limit, state: :active)

      {:ok, draft2} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: actor_id,
          rule_ids: %{"items" => [rule_v2.id]}
        )

      {:ok, _v2} = Versions.publish_draft(draft2, published_by: :user, actor_id: actor_id)

      # The OLD decision's pinned snapshot is unchanged. Replay
      # determinism is preserved at the decision row level — the
      # decision was pinned to v1 and stays pinned to v1.
      reloaded = Repo.get!(Bank.Decisions.DecisionEnvelope, result.decision.id)
      assert reloaded.policy_snapshot_ref["policy_version_id"] == v1.id
      assert reloaded.policy_snapshot_ref["policy_version_number"] == 1
    end

    test "fail-closed: published version that resolves to 0 active rules blocks the decision",
         %{workspace: ws, actor_id: actor_id} do
      # Publish a version with rule_ids that don't resolve to any
      # :active rule (use a ghost UUID and an :archived rule).
      rule_archived = Bank.Fixtures.policy_rule(rule_type: :amount_limit, state: :archived)
      ghost = Ecto.UUID.generate()

      {:ok, draft} =
        Versions.create_draft(ws.id,
          created_by: :user,
          actor_id: actor_id,
          rule_ids: %{"items" => [rule_archived.id, ghost]}
        )

      {:ok, _published} = Versions.publish_draft(draft, published_by: :user, actor_id: actor_id)

      cp = Bank.Fixtures.counterparty(workspace_id: ws.id)
      _label = Bank.Fixtures.address_label(counterparty: cp, chain: "base")
      _ = Bank.Fixtures.trust_assertion(subject: cp, level: :trusted, scope: %{})

      intent =
        Bank.Fixtures.agent_intent(
          counterparty: cp,
          workspace_id: ws.id,
          amount: Decimal.new("25")
        )

      preview = preview_for(intent)

      assert {:ok, result} =
               Bank.Decisions.evaluate_intent(intent, preview: {:ok, preview})

      # Fail-closed: blocked by the policy_version_unresolved guard.
      assert result.outcome == :block
    end
  end

  # --- preview helper --------------------------------------------------

  defp preview_for(intent) do
    %Bank.Quotes.Preview{
      balance_impact: %{intent.asset => Decimal.negate(intent.amount)},
      estimated_gas: 120_000,
      estimated_fee: Decimal.new("0.00015"),
      fee_asset: "ETH",
      route: %{"type" => "erc20_transfer", "asset" => intent.asset},
      failure_conditions: ["balance falls below requested amount"],
      provider: "stub",
      provider_trace_ref: "stub-fixture",
      generated_at: DateTime.utc_now(),
      freshness_ttl_seconds: 30
    }
  end
end
