defmodule Bank.SmartAccountsTest do
  @moduledoc """
  Repo-roundtrip behaviour for the workspace-scoped
  `smart_accounts` model (#183, epic #167).

  Pins:

    * Changeset rules (required fields, address format,
      address normalisation, chain normalisation, status
      enum).
    * `(workspace_id, chain, lower(address))` uniqueness +
      cross-workspace duplicate-address allowance.
    * Workspace-boundary enforcement via `get_in_workspace/2`.
    * Lifecycle transitions including `:active` /
      `:revoked` timestamp stamping and `:revoked` terminal
      semantics.
    * Audit emission on create + status change (verified
      against the `audit_events` row count, not the row body —
      the body shape is the audit module's contract, not
      ours).
  """

  use Bank.DataCase, async: true

  alias Bank.SmartAccounts
  alias Bank.SmartAccounts.SmartAccount

  defp create_workspace(slug \\ nil) do
    slug = slug || "sa-ws-#{System.unique_integer([:positive])}"
    {:ok, ws} = Bank.Workspaces.create_workspace(%{slug: slug, name: "Display: #{slug}"})
    ws
  end

  defp create_user(opts \\ []) do
    email = Keyword.get(opts, :email, "user-#{System.unique_integer([:positive])}@example.com")
    subject = Keyword.get(opts, :subject, "google-#{System.unique_integer([:positive])}")

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: subject,
        email: email,
        name: Keyword.get(opts, :name, "Test User")
      })

    user
  end

  defp valid_attrs(ws, overrides \\ %{}) do
    Map.merge(
      %{
        workspace_id: ws.id,
        chain: "base",
        address: "0x" <> String.duplicate("a", 40)
      },
      overrides
    )
  end

  describe "create_smart_account/1 — basics" do
    test "creates a smart account with default :provisioning status" do
      ws = create_workspace()

      assert {:ok, %SmartAccount{} = sa} =
               SmartAccounts.create_smart_account(valid_attrs(ws))

      assert sa.workspace_id == ws.id
      assert sa.chain == "base"
      assert sa.address == "0x" <> String.duplicate("a", 40)
      assert sa.status == :provisioning
      assert sa.provisioned_at == nil
      assert sa.revoked_at == nil
      assert sa.metadata == %{}
    end

    test "accepts an explicit status, owner_user_id, owner_wallet_address, metadata" do
      ws = create_workspace()
      user = create_user()
      wallet = "0x" <> String.duplicate("b", 40)

      assert {:ok, sa} =
               SmartAccounts.create_smart_account(
                 valid_attrs(ws, %{
                   status: :active,
                   owner_user_id: user.id,
                   owner_wallet_address: wallet,
                   metadata: %{"factory" => "0x" <> String.duplicate("c", 40)}
                 })
               )

      assert sa.status == :active
      assert sa.owner_user_id == user.id
      assert sa.owner_wallet_address == wallet
      assert sa.metadata["factory"] == "0x" <> String.duplicate("c", 40)
    end

    test "normalises checksum-cased address to lowercase" do
      ws = create_workspace()
      mixed = "0x" <> String.duplicate("aB", 20)

      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws, %{address: mixed}))
      assert sa.address == String.downcase(mixed)
    end

    test "normalises chain whitespace and case" do
      ws = create_workspace()

      {:ok, sa} =
        SmartAccounts.create_smart_account(valid_attrs(ws, %{chain: "  Base-Sepolia  "}))

      assert sa.chain == "base-sepolia"
    end

    test "rejects missing required fields" do
      assert {:error, changeset} = SmartAccounts.create_smart_account(%{})
      errors = errors_on(changeset)
      assert errors[:workspace_id]
      assert errors[:chain]
      assert errors[:address]
    end

    test "rejects malformed address (wrong length)" do
      ws = create_workspace()

      assert {:error, changeset} =
               SmartAccounts.create_smart_account(valid_attrs(ws, %{address: "0xabc"}))

      assert errors_on(changeset)[:address]
    end

    test "rejects malformed address (no 0x prefix)" do
      ws = create_workspace()

      assert {:error, changeset} =
               SmartAccounts.create_smart_account(
                 valid_attrs(ws, %{address: String.duplicate("a", 40)})
               )

      assert errors_on(changeset)[:address]
    end

    test "rejects malformed chain id (uppercase, special chars)" do
      ws = create_workspace()

      assert {:error, changeset} =
               SmartAccounts.create_smart_account(valid_attrs(ws, %{chain: "Base!"}))

      assert errors_on(changeset)[:chain]
    end

    test "rejects an unknown status atom" do
      ws = create_workspace()

      assert {:error, changeset} =
               SmartAccounts.create_smart_account(valid_attrs(ws, %{status: :nope}))

      assert errors_on(changeset)[:status]
    end

    test "rejects a non-existent workspace_id (FK violation)" do
      assert {:error, changeset} =
               SmartAccounts.create_smart_account(valid_attrs(%{id: Ecto.UUID.generate()}))

      assert errors_on(changeset)[:workspace_id]
    end
  end

  describe "create_smart_account/1 — uniqueness" do
    test "rejects duplicate (workspace_id, chain, address)" do
      ws = create_workspace()
      attrs = valid_attrs(ws)

      assert {:ok, _} = SmartAccounts.create_smart_account(attrs)

      assert {:error, changeset} = SmartAccounts.create_smart_account(attrs)
      assert Enum.any?(changeset.errors, fn {_, {msg, _}} -> msg =~ "has already been taken" end)
    end

    test "duplicate detection is case-insensitive on address" do
      ws = create_workspace()
      lowered = "0x" <> String.duplicate("a", 40)
      mixed = "0x" <> String.duplicate("A", 40)

      assert {:ok, _} = SmartAccounts.create_smart_account(valid_attrs(ws, %{address: lowered}))

      assert {:error, changeset} =
               SmartAccounts.create_smart_account(valid_attrs(ws, %{address: mixed}))

      assert Enum.any?(changeset.errors, fn {_, {msg, _}} -> msg =~ "has already been taken" end)
    end

    test "ALLOWS the same address in different workspaces (#183 acceptance)" do
      ws_a = create_workspace("sa-iso-a")
      ws_b = create_workspace("sa-iso-b")
      address = "0x" <> String.duplicate("d", 40)

      assert {:ok, _} = SmartAccounts.create_smart_account(valid_attrs(ws_a, %{address: address}))

      assert {:ok, _} = SmartAccounts.create_smart_account(valid_attrs(ws_b, %{address: address}))
    end

    test "ALLOWS the same address in the same workspace on different chains" do
      ws = create_workspace()
      address = "0x" <> String.duplicate("e", 40)

      assert {:ok, _} =
               SmartAccounts.create_smart_account(
                 valid_attrs(ws, %{chain: "base", address: address})
               )

      assert {:ok, _} =
               SmartAccounts.create_smart_account(
                 valid_attrs(ws, %{chain: "base-sepolia", address: address})
               )
    end
  end

  describe "get_smart_account/1 + get_in_workspace/2 — workspace boundary" do
    test "get_smart_account/1 returns nil for an unknown id" do
      assert SmartAccounts.get_smart_account(Ecto.UUID.generate()) == nil
      assert SmartAccounts.get_smart_account("not-a-uuid") == nil
    end

    test "get_smart_account/1 returns the row for any workspace (no boundary)" do
      ws = create_workspace()
      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws))

      assert %SmartAccount{id: id} = SmartAccounts.get_smart_account(sa.id)
      assert id == sa.id
    end

    test "get_in_workspace/2 returns {:ok, _} for the matching workspace" do
      ws = create_workspace()
      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws))

      assert {:ok, %SmartAccount{id: id}} = SmartAccounts.get_in_workspace(sa.id, ws.id)
      assert id == sa.id
    end

    test "get_in_workspace/2 refuses cross-workspace ids" do
      ws_a = create_workspace("sa-bound-a")
      ws_b = create_workspace("sa-bound-b")
      {:ok, sa_a} = SmartAccounts.create_smart_account(valid_attrs(ws_a))

      assert {:error, :not_found} = SmartAccounts.get_in_workspace(sa_a.id, ws_b.id)
    end

    test "get_in_workspace/2 returns {:error, :not_found} for unknown id" do
      ws = create_workspace()

      assert {:error, :not_found} =
               SmartAccounts.get_in_workspace(Ecto.UUID.generate(), ws.id)
    end

    test "get_in_workspace/2 returns {:error, :not_found} for malformed id/workspace_id" do
      assert {:error, :not_found} = SmartAccounts.get_in_workspace(nil, "ws")
      assert {:error, :not_found} = SmartAccounts.get_in_workspace("id", nil)
    end
  end

  describe "list_for_workspace/2" do
    test "returns rows scoped to the workspace" do
      ws_a = create_workspace("sa-list-a")
      ws_b = create_workspace("sa-list-b")

      {:ok, sa_a1} = SmartAccounts.create_smart_account(valid_attrs(ws_a))

      {:ok, sa_a2} =
        SmartAccounts.create_smart_account(
          valid_attrs(ws_a, %{address: "0x" <> String.duplicate("2", 40)})
        )

      {:ok, _sa_b} = SmartAccounts.create_smart_account(valid_attrs(ws_b))

      ids = ws_a.id |> SmartAccounts.list_for_workspace() |> Enum.map(& &1.id) |> Enum.sort()
      expected = Enum.sort([sa_a1.id, sa_a2.id])
      assert ids == expected
    end

    test "filters by single status atom" do
      ws = create_workspace()
      {:ok, _} = SmartAccounts.create_smart_account(valid_attrs(ws))

      {:ok, _} =
        SmartAccounts.create_smart_account(
          valid_attrs(ws, %{address: "0x" <> String.duplicate("9", 40), status: :active})
        )

      provisioning =
        SmartAccounts.list_for_workspace(ws.id, status: :provisioning)

      active =
        SmartAccounts.list_for_workspace(ws.id, status: :active)

      assert length(provisioning) == 1
      assert hd(provisioning).status == :provisioning
      assert length(active) == 1
      assert hd(active).status == :active
    end

    test "filters by status list" do
      ws = create_workspace()
      {:ok, _prov} = SmartAccounts.create_smart_account(valid_attrs(ws))

      {:ok, _active} =
        SmartAccounts.create_smart_account(
          valid_attrs(ws, %{address: "0x" <> String.duplicate("8", 40), status: :active})
        )

      {:ok, doomed} =
        SmartAccounts.create_smart_account(
          valid_attrs(ws, %{address: "0x" <> String.duplicate("c", 40), status: :active})
        )

      {:ok, :changed, _} = SmartAccounts.set_status(doomed, :revoked)

      rows = SmartAccounts.list_for_workspace(ws.id, status: [:provisioning, :active])
      statuses = rows |> Enum.map(& &1.status) |> Enum.sort()
      assert statuses == [:active, :provisioning]
    end

    test "filters by chain" do
      ws = create_workspace()

      {:ok, _} =
        SmartAccounts.create_smart_account(valid_attrs(ws, %{chain: "base"}))

      {:ok, _} =
        SmartAccounts.create_smart_account(
          valid_attrs(ws, %{chain: "base-sepolia", address: "0x" <> String.duplicate("7", 40)})
        )

      base = SmartAccounts.list_for_workspace(ws.id, chain: "base")
      sepolia = SmartAccounts.list_for_workspace(ws.id, chain: "base-sepolia")

      assert length(base) == 1
      assert hd(base).chain == "base"
      assert length(sepolia) == 1
      assert hd(sepolia).chain == "base-sepolia"
    end

    test "respects :limit (capped at 500)" do
      ws = create_workspace()

      for i <- 1..3 do
        addr = "0x" <> String.pad_leading(Integer.to_string(i, 16), 40, "0")
        {:ok, _} = SmartAccounts.create_smart_account(valid_attrs(ws, %{address: addr}))
      end

      assert SmartAccounts.list_for_workspace(ws.id, limit: 2) |> length() == 2
    end
  end

  describe "find_by_address/3" do
    test "finds the row by exact (workspace, chain, address)" do
      ws = create_workspace()
      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws))

      assert %SmartAccount{id: id} = SmartAccounts.find_by_address(ws.id, "base", sa.address)
      assert id == sa.id
    end

    test "find_by_address normalises chain + address" do
      ws = create_workspace()
      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws))
      mixed_address = "0x" <> String.duplicate("A", 40)

      assert %SmartAccount{id: id} =
               SmartAccounts.find_by_address(ws.id, "  BASE  ", mixed_address)

      assert id == sa.id
    end

    test "returns nil when no match" do
      ws = create_workspace()

      refute SmartAccounts.find_by_address(
               ws.id,
               "base",
               "0x" <> String.duplicate("0", 40)
             )
    end

    test "returns nil for malformed args" do
      refute SmartAccounts.find_by_address(nil, "base", "0xabc")
      refute SmartAccounts.find_by_address("ws", nil, "0xabc")
      refute SmartAccounts.find_by_address("ws", "base", nil)
    end

    test "does not cross workspace boundary" do
      ws_a = create_workspace("sa-find-a")
      ws_b = create_workspace("sa-find-b")
      {:ok, sa_a} = SmartAccounts.create_smart_account(valid_attrs(ws_a))

      assert SmartAccounts.find_by_address(ws_a.id, "base", sa_a.address) != nil
      refute SmartAccounts.find_by_address(ws_b.id, "base", sa_a.address)
    end
  end

  describe "set_status/2 — lifecycle" do
    test "transitions :provisioning → :active and stamps provisioned_at" do
      ws = create_workspace()
      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws))

      assert {:ok, :changed, %SmartAccount{} = active} = SmartAccounts.set_status(sa, :active)
      assert active.status == :active
      assert %DateTime{} = active.provisioned_at
    end

    test "re-running :active does not move provisioned_at (idempotent stamp)" do
      ws = create_workspace()
      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws))
      {:ok, :changed, active1} = SmartAccounts.set_status(sa, :active)

      assert {:ok, :unchanged, ^active1} = SmartAccounts.set_status(active1, :active)
    end

    test "transitions :active → :inactive and back" do
      ws = create_workspace()
      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws))
      {:ok, :changed, active} = SmartAccounts.set_status(sa, :active)
      provisioned_at_before = active.provisioned_at

      assert {:ok, :changed, inactive} = SmartAccounts.set_status(active, :inactive)
      assert inactive.status == :inactive
      # Provisioned_at preserved.
      assert inactive.provisioned_at == provisioned_at_before

      assert {:ok, :changed, reactivated} = SmartAccounts.set_status(inactive, :active)
      # Still no second stamp.
      assert reactivated.provisioned_at == provisioned_at_before
    end

    test ":revoked is terminal — refuses subsequent transitions" do
      ws = create_workspace()
      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws))
      {:ok, :changed, revoked} = SmartAccounts.set_status(sa, :revoked)
      assert revoked.status == :revoked
      assert %DateTime{} = revoked.revoked_at

      assert {:error, :terminal} = SmartAccounts.set_status(revoked, :active)
    end

    test "noop transition to current status returns :unchanged with no audit row" do
      ws = create_workspace()
      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws))
      audit_count_before = audit_event_count_for(sa.id)

      assert {:ok, :unchanged, ^sa} = SmartAccounts.set_status(sa, :provisioning)
      assert audit_event_count_for(sa.id) == audit_count_before
    end

    test "rejects an unknown status atom" do
      ws = create_workspace()
      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws))

      assert {:error, :invalid_status} = SmartAccounts.set_status(sa, :nope)
    end
  end

  describe "revoke/1" do
    test "revokes a fresh row and stamps revoked_at" do
      ws = create_workspace()
      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws))

      assert {:ok, :changed, revoked} = SmartAccounts.revoke(sa)
      assert revoked.status == :revoked
      assert %DateTime{} = revoked.revoked_at
    end

    test "is idempotent on an already-revoked row" do
      ws = create_workspace()
      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws))
      {:ok, :changed, revoked} = SmartAccounts.revoke(sa)

      assert {:ok, :unchanged, _} = SmartAccounts.revoke(revoked)
    end
  end

  describe "audit emission" do
    test "create writes one smart_account.created audit row" do
      ws = create_workspace()
      pre = audit_event_count_for_event_type("smart_account.created")

      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws))

      post = audit_event_count_for_event_type("smart_account.created")
      assert post == pre + 1
      [event] = audit_events_for_subject(sa.id, "smart_account.created")
      assert event.subject_id == sa.id
      assert event.actor == :runtime
      assert event.after_ref["chain"] == "base"
      assert event.after_ref["status"] == "provisioning"
    end

    test "real status change writes one smart_account.status_changed audit row" do
      ws = create_workspace()
      {:ok, sa} = SmartAccounts.create_smart_account(valid_attrs(ws))
      pre = audit_event_count_for_event_type("smart_account.status_changed")

      {:ok, :changed, _} = SmartAccounts.set_status(sa, :active)

      post = audit_event_count_for_event_type("smart_account.status_changed")
      assert post == pre + 1
      [event] = audit_events_for_subject(sa.id, "smart_account.status_changed")
      assert event.before_ref["status"] == "provisioning"
      assert event.after_ref["status"] == "active"
    end
  end

  # --- Helpers --------------------------------------------------------------

  defp audit_event_count_for(subject_id) do
    import Ecto.Query

    Repo.aggregate(
      from(a in Bank.Audit.AuditEvent, where: a.subject_id == ^subject_id),
      :count
    )
  end

  defp audit_event_count_for_event_type(event_type) do
    import Ecto.Query

    Repo.aggregate(
      from(a in Bank.Audit.AuditEvent, where: a.event_type == ^event_type),
      :count
    )
  end

  defp audit_events_for_subject(subject_id, event_type) do
    import Ecto.Query

    Repo.all(
      from(a in Bank.Audit.AuditEvent,
        where: a.subject_id == ^subject_id and a.event_type == ^event_type
      )
    )
  end
end
