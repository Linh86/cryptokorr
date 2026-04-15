defmodule Bank.CounterpartiesTest do
  use Bank.DataCase, async: true

  alias Bank.Audit.AuditEvent
  alias Bank.Counterparties
  alias Bank.Counterparties.{AddressLabel, Counterparty, EvidenceArtifact, TrustAssertion}
  alias Bank.Fixtures

  # ---------------------------------------------------------------------
  # list / search / get
  # ---------------------------------------------------------------------

  describe "list_counterparties/2" do
    test "returns counterparties ordered by inserted_at, cursorable" do
      a = Fixtures.counterparty(name: "Alpha")
      b = Fixtures.counterparty(name: "Bravo")
      c = Fixtures.counterparty(name: "Charlie")

      %{entries: page1, next_cursor: cursor} =
        Counterparties.list_counterparties(%{}, limit: 2)

      assert length(page1) == 2
      assert cursor

      %{entries: page2, next_cursor: nil} =
        Counterparties.list_counterparties(%{}, limit: 2, cursor: cursor)

      # All three rows appear exactly once across the two pages.
      page1_ids = Enum.map(page1, & &1.id)
      page2_ids = Enum.map(page2, & &1.id)
      assert MapSet.new(page1_ids ++ page2_ids) == MapSet.new([a.id, b.id, c.id])
      assert MapSet.disjoint?(MapSet.new(page1_ids), MapSet.new(page2_ids))
    end

    test "filters by case-insensitive name substring" do
      _a = Fixtures.counterparty(name: "Payroll Provider")
      _b = Fixtures.counterparty(name: "Coffee Vendor")

      %{entries: entries} = Counterparties.list_counterparties(%{q: "payroll"})
      assert Enum.map(entries, & &1.name) == ["Payroll Provider"]

      %{entries: entries} = Counterparties.list_counterparties(%{q: "VENDOR"})
      assert Enum.map(entries, & &1.name) == ["Coffee Vendor"]
    end

    test "filters by active flag" do
      active = Fixtures.counterparty(name: "Active")
      archived = Fixtures.counterparty(name: "Archived", active: false)

      %{entries: active_only} = Counterparties.list_counterparties(%{active: true})
      %{entries: archived_only} = Counterparties.list_counterparties(%{active: false})
      %{entries: both} = Counterparties.list_counterparties(%{})

      assert Enum.map(active_only, & &1.id) == [active.id]
      assert Enum.map(archived_only, & &1.id) == [archived.id]
      assert length(both) == 2
    end
  end

  describe "get_counterparty/1 + get_counterparty_with_preloads/1" do
    test "returns :not_found for unknown id" do
      assert {:error, :not_found} = Counterparties.get_counterparty(Ecto.UUID.generate())

      assert {:error, :not_found} =
               Counterparties.get_counterparty_with_preloads(Ecto.UUID.generate())
    end

    test "preloads active labels, effective trust assertions, and evidence" do
      cp = Fixtures.counterparty()
      active = Fixtures.address_label(counterparty: cp)
      retired = Fixtures.address_label(counterparty: cp, retired_at: DateTime.utc_now())
      assertion = Fixtures.trust_assertion(subject: cp, level: :trusted)
      _superseded = Fixtures.trust_assertion(subject: cp, superseded_at: DateTime.utc_now())
      evidence = Fixtures.evidence_artifact(subject: cp)

      {:ok, loaded} = Counterparties.get_counterparty_with_preloads(cp.id)

      label_ids = Enum.map(loaded.address_labels, & &1.id)
      assert active.id in label_ids
      refute retired.id in label_ids

      assertion_ids = Enum.map(loaded.trust_assertions, & &1.id)
      assert assertion.id in assertion_ids
      assert length(assertion_ids) == 1

      assert Enum.map(loaded.evidence_artifacts, & &1.id) == [evidence.id]
    end
  end

  # ---------------------------------------------------------------------
  # create / update / archive
  # ---------------------------------------------------------------------

  describe "create_counterparty/2" do
    test "inserts with defaults and emits counterparty.created audit event" do
      attrs = %{"name" => "Vendor Inc.", "notes" => "POC", "created_by" => "user"}

      assert {:ok, %Counterparty{} = cp} = Counterparties.create_counterparty(attrs)
      assert cp.name == "Vendor Inc."
      assert cp.active == true
      assert cp.created_by == :user

      assert_audit_event("counterparty.created",
        subject_type: "counterparty",
        subject_id: cp.id,
        correlation_id: cp.id
      )
    end

    test "returns changeset error on missing name" do
      assert {:error, %Ecto.Changeset{}} =
               Counterparties.create_counterparty(%{"created_by" => "user"})
    end
  end

  describe "update_counterparty/3" do
    test "updates mutable fields and emits counterparty.updated" do
      cp = Fixtures.counterparty(name: "Before")

      assert {:ok, updated} =
               Counterparties.update_counterparty(cp, %{"name" => "After", "notes" => "new"})

      assert updated.name == "After"
      assert updated.notes == "new"

      assert_audit_event("counterparty.updated", subject_id: cp.id)
    end

    test "refuses to mutate current_trust_level through this path" do
      cp = Fixtures.counterparty(current_trust_level: :unknown)

      assert {:ok, unchanged} =
               Counterparties.update_counterparty(cp, %{
                 "name" => "Still Same",
                 "current_trust_level" => "trusted"
               })

      assert unchanged.current_trust_level == :unknown
    end

    test "flipping active to false emits counterparty.archived as well" do
      cp = Fixtures.counterparty()

      assert {:ok, %Counterparty{active: false}} =
               Counterparties.update_counterparty(cp, %{"active" => false})

      assert_audit_event("counterparty.updated", subject_id: cp.id)
      assert_audit_event("counterparty.archived", subject_id: cp.id)
    end
  end

  describe "archive_counterparty/2" do
    test "archives once and is idempotent on a second call" do
      cp = Fixtures.counterparty()

      assert {:ok, %Counterparty{active: false}} = Counterparties.archive_counterparty(cp)
      assert count_events("counterparty.archived") == 1

      {:ok, archived} = Counterparties.get_counterparty(cp.id)
      assert {:ok, ^archived} = Counterparties.archive_counterparty(archived)
      assert count_events("counterparty.archived") == 1
    end
  end

  # ---------------------------------------------------------------------
  # address labels
  # ---------------------------------------------------------------------

  describe "attach_address/3" do
    test "creates a label and emits address_label.attached" do
      cp = Fixtures.counterparty()
      attrs = %{"chain" => "base", "address" => "0xabc", "role" => "payout"}

      assert {:ok, %AddressLabel{} = label} = Counterparties.attach_address(cp, attrs)
      assert label.counterparty_id == cp.id
      assert label.role == :payout
      assert is_nil(label.retired_at)

      assert_audit_event("address_label.attached",
        subject_type: "address_label",
        subject_id: label.id,
        correlation_id: cp.id
      )
    end

    test "rejects attaching to an archived counterparty" do
      cp = Fixtures.counterparty(active: false)

      assert {:error, :archived} =
               Counterparties.attach_address(cp, %{chain: "base", address: "0x1"})
    end

    test "rejects duplicate active (chain, address)" do
      cp = Fixtures.counterparty()
      {:ok, _} = Counterparties.attach_address(cp, %{chain: "base", address: "0xDEAD"})

      assert {:error, %Ecto.Changeset{} = cs} =
               Counterparties.attach_address(cp, %{chain: "base", address: "0xDEAD"})

      errors = Keyword.keys(cs.errors)
      assert :chain in errors or :address in errors
    end
  end

  describe "update_address_label/3" do
    test "updates alias / role / verified and emits address_label.updated" do
      label = Fixtures.address_label()

      assert {:ok, updated} =
               Counterparties.update_address_label(label, %{
                 "alias" => "hot wallet",
                 "verified" => true
               })

      assert updated.alias == "hot wallet"
      assert updated.verified == true

      assert_audit_event("address_label.updated", subject_id: label.id)
    end

    test "silently drops address/chain edits" do
      label = Fixtures.address_label(chain: "base", address: "0xAAA")

      assert {:ok, updated} =
               Counterparties.update_address_label(label, %{
                 "chain" => "ethereum",
                 "address" => "0xBBB",
                 "alias" => "renamed"
               })

      assert updated.chain == "base"
      assert updated.address == "0xAAA"
      assert updated.alias == "renamed"
    end

    test "retired: true routes to retirement" do
      label = Fixtures.address_label()

      assert {:ok, retired} = Counterparties.update_address_label(label, %{"retired" => true})
      assert %DateTime{} = retired.retired_at

      assert_audit_event("address_label.retired", subject_id: label.id)
    end

    test "rejects edits to already-retired labels" do
      label = Fixtures.address_label()
      {:ok, retired} = Counterparties.retire_address_label(label)

      assert {:error, :already_retired} =
               Counterparties.update_address_label(retired, %{"alias" => "late"})
    end
  end

  describe "retire_address_label/2" do
    test "stamps retired_at and is idempotent" do
      label = Fixtures.address_label()

      assert {:ok, retired} = Counterparties.retire_address_label(label)
      assert %DateTime{} = retired.retired_at
      assert count_events("address_label.retired") == 1

      # second call: no audit emitted
      {:ok, again} = Counterparties.retire_address_label(retired)
      assert again.id == retired.id
      assert count_events("address_label.retired") == 1
    end
  end

  describe "resolve_address/2" do
    test "finds an active label by (chain, address) and preloads cp" do
      cp = Fixtures.counterparty()
      {:ok, label} = Counterparties.attach_address(cp, %{chain: "base", address: "0xFeEd"})

      assert {:ok, %{label: resolved_label, counterparty: resolved_cp}} =
               Counterparties.resolve_address("base", "0xfeed")

      assert resolved_label.id == label.id
      assert resolved_cp.id == cp.id
    end

    test "ignores retired labels" do
      cp = Fixtures.counterparty()
      {:ok, label} = Counterparties.attach_address(cp, %{chain: "base", address: "0xfeed"})
      {:ok, _} = Counterparties.retire_address_label(label)

      assert {:error, :not_found} = Counterparties.resolve_address("base", "0xfeed")
    end
  end

  # ---------------------------------------------------------------------
  # evidence
  # ---------------------------------------------------------------------

  describe "pin_evidence/3" do
    test "pins an artifact on a counterparty and emits evidence.attached" do
      cp = Fixtures.counterparty()

      attrs = %{
        "kind" => "user_note",
        "content_uri" => "mem://why-we-trust-them",
        "source" => "ops-review",
        "weight" => "medium"
      }

      assert {:ok, %EvidenceArtifact{} = ev} = Counterparties.pin_evidence(cp, attrs)
      assert ev.subject_type == "counterparty"
      assert ev.subject_id == cp.id
      assert ev.payload_hash

      assert_audit_event("evidence.attached",
        subject_type: "counterparty",
        subject_id: cp.id,
        correlation_id: cp.id
      )
    end

    test "pins an artifact on an address label and correlates on the counterparty" do
      cp = Fixtures.counterparty()
      label = Fixtures.address_label(counterparty: cp)

      attrs = %{kind: :signed_message, content_uri: "mem://msg", source: "operator"}
      assert {:ok, ev} = Counterparties.pin_evidence(label, attrs)

      assert ev.subject_type == "address_label"
      assert ev.subject_id == label.id

      assert_audit_event("evidence.attached",
        subject_type: "address_label",
        subject_id: label.id,
        correlation_id: cp.id
      )
    end

    test "supersedes by linking through supersedes_id (append-only)" do
      cp = Fixtures.counterparty()
      {:ok, first} = Counterparties.pin_evidence(cp, %{kind: :user_note, content_uri: "mem://a"})

      {:ok, second} =
        Counterparties.pin_evidence(cp, %{
          kind: :user_note,
          content_uri: "mem://b",
          supersedes_id: first.id
        })

      assert second.supersedes_id == first.id

      reloaded_first = Repo.get!(EvidenceArtifact, first.id)
      assert reloaded_first.content_uri == "mem://a"
    end

    test "rejects evidence on archived counterparties" do
      cp = Fixtures.counterparty(active: false)

      assert {:error, :archived} =
               Counterparties.pin_evidence(cp, %{kind: :user_note, content_uri: "mem://x"})
    end
  end

  # ---------------------------------------------------------------------
  # trust assertions
  # ---------------------------------------------------------------------

  describe "issue_trust_assertion/4" do
    test "inserts a broad assertion and refreshes current_trust_level cache" do
      cp = Fixtures.counterparty(current_trust_level: :unknown)

      assert {:ok, %TrustAssertion{level: :trusted, scope: scope}} =
               Counterparties.issue_trust_assertion("counterparty", cp.id, %{
                 "level" => "trusted",
                 "scope" => %{},
                 "rationale" => "onboarded vendor"
               })

      assert scope == %{}
      assert Repo.get!(Counterparty, cp.id).current_trust_level == :trusted

      assert_audit_event("trust_assertion.issued",
        subject_type: "counterparty",
        subject_id: cp.id,
        correlation_id: cp.id
      )
    end

    test "scoped assertion does NOT refresh the broad cache" do
      cp = Fixtures.counterparty(current_trust_level: :unknown)

      {:ok, _assertion} =
        Counterparties.issue_trust_assertion("counterparty", cp.id, %{
          level: :trusted,
          scope: %{"asset" => "USDC", "amount_ceiling" => "500"}
        })

      assert Repo.get!(Counterparty, cp.id).current_trust_level == :unknown
    end

    test "broad assertion supersedes every prior effective assertion on the subject" do
      cp = Fixtures.counterparty()

      {:ok, prior_broad} =
        Counterparties.issue_trust_assertion("counterparty", cp.id, %{
          level: :sensitive,
          scope: %{}
        })

      {:ok, prior_scoped} =
        Counterparties.issue_trust_assertion("counterparty", cp.id, %{
          level: :trusted,
          scope: %{"chain" => "base"}
        })

      {:ok, _new_broad} =
        Counterparties.issue_trust_assertion("counterparty", cp.id, %{level: :unknown, scope: %{}})

      assert %TrustAssertion{superseded_at: %DateTime{}} =
               Repo.get!(TrustAssertion, prior_broad.id)

      assert %TrustAssertion{superseded_at: %DateTime{}} =
               Repo.get!(TrustAssertion, prior_scoped.id)
    end

    test "narrower new scope does not supersede a broader prior" do
      cp = Fixtures.counterparty()

      {:ok, broad} =
        Counterparties.issue_trust_assertion("counterparty", cp.id, %{level: :trusted, scope: %{}})

      {:ok, _scoped} =
        Counterparties.issue_trust_assertion("counterparty", cp.id, %{
          level: :sensitive,
          scope: %{"chain" => "base"}
        })

      assert is_nil(Repo.get!(TrustAssertion, broad.id).superseded_at)
    end

    test "returns :not_found for unknown / archived subjects" do
      assert {:error, :not_found} =
               Counterparties.issue_trust_assertion("counterparty", Ecto.UUID.generate(), %{
                 level: :trusted
               })

      archived = Fixtures.counterparty(active: false)

      assert {:error, :not_found} =
               Counterparties.issue_trust_assertion("counterparty", archived.id, %{
                 level: :trusted
               })
    end

    test "address_label subject emits audit correlated to the owning counterparty" do
      cp = Fixtures.counterparty()
      label = Fixtures.address_label(counterparty: cp)

      {:ok, _} =
        Counterparties.issue_trust_assertion("address_label", label.id, %{level: :sensitive})

      assert_audit_event("trust_assertion.issued",
        subject_type: "address_label",
        subject_id: label.id,
        correlation_id: cp.id
      )
    end
  end

  describe "effective_trust_assertions/2" do
    test "returns non-superseded unexpired assertions newest-first" do
      cp = Fixtures.counterparty()

      first = Fixtures.trust_assertion(subject: cp, level: :sensitive)
      _superseded = Fixtures.trust_assertion(subject: cp, superseded_at: DateTime.utc_now())

      expired =
        Fixtures.trust_assertion(
          subject: cp,
          expires_at: DateTime.add(DateTime.utc_now(), -3600, :second)
        )

      second = Fixtures.trust_assertion(subject: cp, level: :trusted)

      ids = Counterparties.effective_trust_assertions("counterparty", cp.id) |> Enum.map(& &1.id)
      assert ids == [second.id, first.id]
      refute expired.id in ids
    end
  end

  # ---------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------

  defp assert_audit_event(event_type, match) do
    {match, _opts} = Keyword.split(match, [:subject_type, :subject_id, :correlation_id])
    query = from e in AuditEvent, where: e.event_type == ^event_type

    query =
      Enum.reduce(match, query, fn {k, v}, q ->
        where(q, [e], field(e, ^k) == ^v)
      end)

    assert Repo.one(query),
           "expected an audit event matching #{inspect(event_type)} " <>
             "with #{inspect(match)}"
  end

  defp count_events(event_type) do
    from(e in AuditEvent, where: e.event_type == ^event_type)
    |> Repo.aggregate(:count)
  end
end
