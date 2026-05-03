defmodule Bank.ActivityTest do
  @moduledoc """
  Context-level tests for `Bank.Activity` — the imported activity
  ledger (#243).
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Activity
  alias Bank.Activity.ImportedActivity
  alias Bank.Decisions.ExecutionPlan
  alias Bank.Repo

  setup do
    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "activity-#{System.unique_integer([:positive])}",
        name: "Activity"
      })

    %{workspace: ws}
  end

  # --- create / list / query --------------------------------------------

  describe "create_imported_activity/1" do
    test "inserts a fully-populated CSV row and returns :inserted",
         %{workspace: ws} do
      attrs = base_attrs(ws.id, source_type: :csv, source_ref: "csv:row:1")

      assert {:ok, :inserted, %ImportedActivity{} = row} =
               Activity.create_imported_activity(attrs)

      assert row.workspace_id == ws.id
      assert row.source_type == :csv
      assert row.source_ref == "csv:row:1"
      assert row.asset == "USDC"
      assert row.direction == :inbound
      assert row.status == :imported
      assert row.confidence == :medium
      assert row.dedupe_key
      assert byte_size(row.dedupe_key) == 64
    end

    test "accepts string-keyed attrs (CSV importer convention)",
         %{workspace: ws} do
      attrs =
        ws.id
        |> base_attrs(source_type: :wallet_chain, source_hash: "hash-string-keys")
        |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)

      assert {:ok, :inserted, %ImportedActivity{}} =
               Activity.create_imported_activity(attrs)
    end

    test "errors when neither source_ref nor source_hash is provided",
         %{workspace: ws} do
      attrs =
        ws.id
        |> base_attrs(source_type: :manual)
        |> Map.delete(:source_ref)
        |> Map.delete(:source_hash)

      assert {:error, %Ecto.Changeset{} = cs} =
               Activity.create_imported_activity(attrs)

      assert {"either :source_ref or :source_hash must be present", _} =
               cs.errors[:source_ref]
    end

    test "errors when amount is negative", %{workspace: ws} do
      attrs =
        ws.id
        |> base_attrs(source_ref: "neg-amount")
        |> Map.put(:amount, Decimal.new("-1"))

      assert {:error, %Ecto.Changeset{} = cs} =
               Activity.create_imported_activity(attrs)

      assert {msg, _} = cs.errors[:amount]
      assert msg =~ "non-negative"
    end
  end

  # --- duplicate-key idempotency ----------------------------------------

  describe "duplicate-key behaviour" do
    test "re-inserting the same source row returns {:ok, :duplicate, existing}",
         %{workspace: ws} do
      attrs = base_attrs(ws.id, source_ref: "csv:row:dup")

      assert {:ok, :inserted, first} = Activity.create_imported_activity(attrs)
      assert {:ok, :duplicate, second} = Activity.create_imported_activity(attrs)

      assert first.id == second.id
      assert first.dedupe_key == second.dedupe_key
      assert Repo.aggregate(ImportedActivity, :count, :id) == 1
    end

    test "compute_dedupe_key/1 is deterministic across calls",
         %{workspace: ws} do
      attrs = base_attrs(ws.id, source_ref: "csv:row:hash")
      key1 = Activity.compute_dedupe_key(attrs)
      key2 = Activity.compute_dedupe_key(attrs)

      assert key1 == key2
      assert is_binary(key1) and byte_size(key1) == 64
    end

    test "compute_dedupe_key/1 returns nil if neither ref nor hash is present",
         %{workspace: ws} do
      attrs =
        ws.id
        |> base_attrs(source_type: :manual)
        |> Map.delete(:source_ref)
        |> Map.delete(:source_hash)

      assert Activity.compute_dedupe_key(attrs) == nil
    end

    test "different source rows produce different dedupe keys",
         %{workspace: ws} do
      a = Activity.compute_dedupe_key(base_attrs(ws.id, source_ref: "csv:row:a"))
      b = Activity.compute_dedupe_key(base_attrs(ws.id, source_ref: "csv:row:b"))

      assert a != b
    end
  end

  # --- list / cross-workspace isolation ---------------------------------

  describe "list_imported_activities/1" do
    test "returns the workspace's activities, newest-occurred first",
         %{workspace: ws} do
      now = DateTime.utc_now()

      _old =
        Activity.create_imported_activity(
          base_attrs(ws.id,
            source_ref: "csv:row:old",
            occurred_at: DateTime.add(now, -3600, :second)
          )
        )

      _mid =
        Activity.create_imported_activity(
          base_attrs(ws.id,
            source_ref: "csv:row:mid",
            occurred_at: DateTime.add(now, -1800, :second)
          )
        )

      _new =
        Activity.create_imported_activity(
          base_attrs(ws.id, source_ref: "csv:row:new", occurred_at: now)
        )

      rows = Activity.list_imported_activities(workspace_id: ws.id)

      refs = Enum.map(rows, & &1.source_ref)
      assert refs == ["csv:row:new", "csv:row:mid", "csv:row:old"]
    end

    test "returns [] when workspace_id is missing or non-binary",
         %{workspace: ws} do
      _ = Activity.create_imported_activity(base_attrs(ws.id, source_ref: "guard"))

      assert Activity.list_imported_activities() == []
      assert Activity.list_imported_activities(workspace_id: nil) == []
      assert Activity.list_imported_activities(workspace_id: 12_345) == []
    end

    test "filters by :source_type when provided", %{workspace: ws} do
      _csv =
        Activity.create_imported_activity(
          base_attrs(ws.id, source_type: :csv, source_ref: "csv:t1")
        )

      _wallet =
        Activity.create_imported_activity(
          base_attrs(ws.id, source_type: :wallet_chain, source_hash: "wallet:t1")
        )

      rows =
        Activity.list_imported_activities(workspace_id: ws.id, source_type: :wallet_chain)

      assert Enum.map(rows, & &1.source_type) == [:wallet_chain]
    end

    test "cross-workspace: workspace A cannot list workspace B's activity",
         %{workspace: ws_a} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "activity-sib-#{System.unique_integer([:positive])}",
          name: "Sibling"
        })

      _b_row =
        Activity.create_imported_activity(base_attrs(ws_b.id, source_ref: "sibling:row:1"))

      assert Activity.list_imported_activities(workspace_id: ws_a.id) == []

      assert [%ImportedActivity{source_ref: "sibling:row:1"}] =
               Activity.list_imported_activities(workspace_id: ws_b.id)
    end

    test "the same dedupe_key in a sibling workspace inserts independently",
         %{workspace: ws_a} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "activity-sib-dup-#{System.unique_integer([:positive])}",
          name: "Sibling"
        })

      # Pin `occurred_at` so both attrs maps hash to the same
      # `dedupe_key` — this is what the unique-constraint scope
      # check actually exercises.
      pinned_at = ~U[2026-04-01 12:00:00.000000Z]

      attrs_a = base_attrs(ws_a.id, source_ref: "shared:row:1", occurred_at: pinned_at)
      attrs_b = base_attrs(ws_b.id, source_ref: "shared:row:1", occurred_at: pinned_at)

      assert {:ok, :inserted, row_a} = Activity.create_imported_activity(attrs_a)
      assert {:ok, :inserted, row_b} = Activity.create_imported_activity(attrs_b)

      # The unique constraint is `(workspace_id, dedupe_key)`, so
      # the same source row in two workspaces is not a collision.
      assert row_a.id != row_b.id
      assert row_a.dedupe_key == row_b.dedupe_key
      assert row_a.workspace_id == ws_a.id
      assert row_b.workspace_id == ws_b.id
    end

    test "get_by_dedupe_key/2 is workspace-scoped",
         %{workspace: ws_a} do
      {:ok, ws_b} =
        Bank.Workspaces.create_workspace(%{
          slug: "activity-sib-get-#{System.unique_integer([:positive])}",
          name: "Sibling"
        })

      {:ok, :inserted, row_a} =
        Activity.create_imported_activity(base_attrs(ws_a.id, source_ref: "lookup-1"))

      assert Activity.get_by_dedupe_key(ws_a.id, row_a.dedupe_key).id == row_a.id

      # The same dedupe key in workspace B returns nil — refusing
      # to leak even when caller already has the key.
      assert Activity.get_by_dedupe_key(ws_b.id, row_a.dedupe_key) == nil
      assert Activity.get_by_dedupe_key(nil, row_a.dedupe_key) == nil
      assert Activity.get_by_dedupe_key(ws_a.id, nil) == nil
    end
  end

  # --- unknown fields preserved ----------------------------------------

  describe "metadata: unknown source-side fields preserved" do
    test "non-secret unknown fields land verbatim in metadata",
         %{workspace: ws} do
      meta = %{
        "csv_row_index" => 42,
        "raw_memo" => "lunch",
        "tags" => ["payroll", "q2"],
        "external_provider_id" => "stripe_charge_abc123"
      }

      attrs = base_attrs(ws.id, source_ref: "meta-1") |> Map.put(:metadata, meta)

      {:ok, :inserted, row} = Activity.create_imported_activity(attrs)

      assert row.metadata == meta
    end

    test "metadata of any shape round-trips through the DB",
         %{workspace: ws} do
      meta = %{
        "nested" => %{"a" => 1, "b" => [2, 3, 4]},
        "boolean" => true,
        "null_field" => nil
      }

      {:ok, :inserted, row} =
        Activity.create_imported_activity(
          base_attrs(ws.id, source_ref: "meta-roundtrip")
          |> Map.put(:metadata, meta)
        )

      reloaded = Repo.get!(ImportedActivity, row.id)
      assert reloaded.metadata == meta
    end
  end

  # --- secret hygiene -------------------------------------------------

  describe "metadata: well-known secret keys are redacted" do
    test "Authorization / Bearer / api_key / private_key / secret keys are replaced",
         %{workspace: ws} do
      meta = %{
        "Authorization" => "Bearer sk_live_LEAKED_PROBE",
        "api_key" => "sk_live_LEAKED_PROBE",
        "ApiKey" => "pk_live_LEAKED_PROBE",
        "private_key" => "0xLEAKED_PROBE",
        "secret" => "LEAKED_PROBE",
        "password" => "hunter2",
        "Cookie" => "session=LEAKED_PROBE",
        "set-cookie" => "auth=LEAKED_PROBE",
        "token" => "sk_live_LEAKED_PROBE",
        "access_token" => "BEGIN PRIVATE KEY ---- LEAKED_PROBE",
        "refresh_token" => "rt_LEAKED_PROBE",
        "session" => "session-id-LEAKED_PROBE",
        # Non-secret entries pass through.
        "csv_row_index" => 1,
        "memo" => "lunch"
      }

      {:ok, :inserted, row} =
        Activity.create_imported_activity(
          base_attrs(ws.id, source_ref: "secret-redact")
          |> Map.put(:metadata, meta)
        )

      # Every flagged key is now `[REDACTED]`.
      for key <- [
            "Authorization",
            "api_key",
            "ApiKey",
            "private_key",
            "secret",
            "password",
            "Cookie",
            "set-cookie",
            "token",
            "access_token",
            "refresh_token",
            "session"
          ] do
        assert row.metadata[key] == "[REDACTED]"
      end

      # Non-secret entries are untouched.
      assert row.metadata["csv_row_index"] == 1
      assert row.metadata["memo"] == "lunch"

      # And the leak-probe substring does not appear anywhere in
      # the persisted metadata's serialized form.
      refute inspect(row.metadata) =~ "LEAKED_PROBE"
    end

    test "nested maps are walked: secret keys redacted at any depth",
         %{workspace: ws} do
      # P2 regression: prior to the recursive walk, only top-level
      # keys were redacted. A common CSV-importer shape stashes the
      # raw source row under a benign key like `"raw"` — and that
      # nested map carries every secret-key permutation the source
      # had. Pin that those nested keys are redacted too while the
      # surrounding non-secret keys are preserved.
      meta = %{
        "csv_row_index" => 7,
        "raw" => %{
          "Authorization" => "Bearer sk_live_LEAKED_PROBE",
          "memo" => "ok",
          "deeper" => %{
            "private_key" => "0xLEAKED_PROBE",
            "label" => "payroll"
          }
        }
      }

      {:ok, :inserted, row} =
        Activity.create_imported_activity(
          base_attrs(ws.id, source_ref: "nested-secret-map")
          |> Map.put(:metadata, meta)
        )

      assert row.metadata["csv_row_index"] == 7
      assert row.metadata["raw"]["Authorization"] == "[REDACTED]"
      assert row.metadata["raw"]["memo"] == "ok"
      assert row.metadata["raw"]["deeper"]["private_key"] == "[REDACTED]"
      assert row.metadata["raw"]["deeper"]["label"] == "payroll"

      refute inspect(row.metadata) =~ "LEAKED_PROBE"
    end

    test "lists are traversed: secret keys inside list-of-maps are redacted",
         %{workspace: ws} do
      # P2 regression: the same nested-redaction blind spot applied
      # to list values like `%{"rows" => [%{...}, %{...}]}`. Pin
      # that the per-row secret keys are redacted while the list
      # shape and non-secret entries survive intact.
      meta = %{
        "rows" => [
          %{"private_key" => "0xLEAKED_PROBE", "memo" => "row-1"},
          %{"memo" => "row-2"},
          %{"nested_list" => [%{"Authorization" => "Bearer LEAKED_PROBE"}]}
        ]
      }

      {:ok, :inserted, row} =
        Activity.create_imported_activity(
          base_attrs(ws.id, source_ref: "nested-secret-list")
          |> Map.put(:metadata, meta)
        )

      [r0, r1, r2] = row.metadata["rows"]
      assert r0["private_key"] == "[REDACTED]"
      assert r0["memo"] == "row-1"
      assert r1 == %{"memo" => "row-2"}
      [inner] = r2["nested_list"]
      assert inner["Authorization"] == "[REDACTED]"

      meta_dump = inspect(row.metadata)
      refute meta_dump =~ "LEAKED_PROBE"
      refute meta_dump =~ "Bearer "
      refute meta_dump =~ "sk_"
      refute meta_dump =~ "BEGIN "
      refute meta_dump =~ "0xLEAKED_PROBE"
    end

    test "secret value is redacted even when it is itself a nested structure",
         %{workspace: _ws} do
      # If the secret-bearing key holds a map / list (e.g. an
      # importer that stashed an entire request body under
      # `"Authorization"`), the value MUST collapse to the literal
      # `"[REDACTED]"` — not a recursively-walked map that might
      # leak unexpected internals.
      meta = %{
        "Authorization" => %{
          "header" => "Bearer LEAKED_PROBE",
          "raw_token" => "LEAKED_PROBE"
        },
        "tokens" => ["LEAKED_PROBE_1", "LEAKED_PROBE_2"]
      }

      assert Activity.redact_metadata(meta) == %{
               "Authorization" => "[REDACTED]",
               "tokens" => ["LEAKED_PROBE_1", "LEAKED_PROBE_2"]
             }

      # `tokens` is the surrounding key; it is not in the secret
      # allowlist so its list values pass through. (The actual
      # values would be caught by an importer-side validation, not
      # by `redact_metadata/1`.)
    end

    test "redact_metadata/1 is a pure function and matches insert behaviour",
         %{workspace: _ws} do
      meta = %{"Authorization" => "Bearer x", "memo" => "ok"}

      assert Activity.redact_metadata(meta) == %{
               "Authorization" => "[REDACTED]",
               "memo" => "ok"
             }

      assert Activity.redact_metadata(:not_a_map) == :not_a_map
    end
  end

  # --- read-only ledger contract --------------------------------------

  describe "imported activity does not mutate execution state" do
    test "creating an activity does not insert or mutate ExecutionPlan rows",
         %{workspace: ws} do
      before_count = Repo.aggregate(ExecutionPlan, :count, :id)

      assert {:ok, :inserted, _} =
               Activity.create_imported_activity(
                 base_attrs(ws.id, source_ref: "ledger:no-plan-mutation")
               )

      after_count = Repo.aggregate(ExecutionPlan, :count, :id)
      assert before_count == after_count
    end

    test "creating an activity does not enqueue any Oban job",
         %{workspace: ws} do
      assert {:ok, :inserted, _} =
               Activity.create_imported_activity(
                 base_attrs(ws.id, source_ref: "ledger:no-oban-enqueue")
               )

      # No job of any worker / queue is enqueued by the ledger
      # insert path. Oban.Testing's `all_enqueued/1` returns every
      # currently-enqueued job in the test sandbox.
      assert all_enqueued() == []
    end
  end

  # --- helpers ---------------------------------------------------------

  defp base_attrs(workspace_id, overrides) do
    Map.merge(
      %{
        workspace_id: workspace_id,
        source_type: :csv,
        source_ref: "csv:row:default",
        occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        asset: "USDC",
        chain: "base",
        amount: Decimal.new("100.50"),
        direction: :inbound,
        status: :imported,
        confidence: :medium
      },
      Enum.into(overrides, %{})
    )
  end
end
