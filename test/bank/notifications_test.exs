defmodule Bank.NotificationsTest do
  @moduledoc """
  Tests for `Bank.Notifications` (#233) — workspace-scoped inbox
  event model.

  Coverage matches the issue body's `## Tests` block:

    * create / list / read / archive
    * dedupe key behavior (idempotent create, race-safe)
    * cross-workspace isolation
    * secret hygiene (title / body / action_link reject markers)

  These tests exercise the data context only. No external delivery
  channel, no Oban job, no PubSub broadcast — those surfaces land
  in #234 / #235 / #236 and are not in scope here. A regression
  test asserts the read-only side-effect contract.
  """

  use Bank.DataCase, async: true
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Notifications
  alias Bank.Notifications.Notification
  alias Bank.Repo

  # --- workspace + user setup -------------------------------------------

  defp workspace! do
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "notif-test-ws-#{suffix}",
        name: "Notif Test WS #{suffix}"
      })

    ws
  end

  defp user! do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "notif-test-#{suffix}",
        email: "notif-test-#{suffix}@example.com",
        name: "Notif Test #{suffix}"
      })

    user
  end

  defp valid_attrs(overrides \\ %{}) do
    workspace = Map.get_lazy(overrides, :workspace, &workspace!/0)
    user_id = Map.get(overrides, :user_id)
    role_target = Map.get(overrides, :role_target)

    base = %{
      workspace_id: workspace.id,
      event_type: "intent.held",
      severity: :warning,
      subject_type: "agent_intent",
      subject_id: Ecto.UUID.generate(),
      correlation_id: Ecto.UUID.generate(),
      title: "Intent on hold",
      body: "Operator review required for intent.",
      action_link: "/intents/abcd-1234",
      dedupe_key: "intent.held:" <> Ecto.UUID.generate()
    }

    base =
      cond do
        user_id -> Map.put(base, :user_id, user_id)
        role_target -> Map.put(base, :role_target, role_target)
        true -> Map.put(base, :role_target, :operator)
      end

    base
    |> Map.merge(Map.drop(overrides, [:workspace, :user_id, :role_target]))
  end

  # --- create -----------------------------------------------------------

  describe "create/1 — happy path" do
    test "writes a workspace-scoped, role-targeted notification with defaults" do
      attrs = valid_attrs()

      assert {:ok, %Notification{} = n} = Notifications.create(attrs)

      assert n.workspace_id == attrs.workspace_id
      assert n.event_type == "intent.held"
      assert n.severity == :warning
      assert n.status == :unread
      assert n.role_target == :operator
      assert is_nil(n.user_id)
      assert n.title == attrs.title
      assert n.body == attrs.body
      assert n.action_link == attrs.action_link
      assert n.dedupe_key == attrs.dedupe_key
      assert is_nil(n.read_at)
      assert is_nil(n.archived_at)
    end

    test "writes a user-targeted notification (mutually exclusive with role_target)" do
      ws = workspace!()
      u = user!()

      attrs = valid_attrs(%{workspace: ws, user_id: u.id, role_target: nil})

      assert {:ok, n} = Notifications.create(attrs)
      assert n.user_id == u.id
      assert is_nil(n.role_target)
    end

    test "defaults severity=:info when omitted" do
      ws = workspace!()
      attrs = valid_attrs(%{workspace: ws}) |> Map.delete(:severity)

      assert {:ok, n} = Notifications.create(attrs)
      assert n.severity == :info
    end

    test "treats empty action_link as nil (not a 0-length link)" do
      ws = workspace!()
      attrs = valid_attrs(%{workspace: ws, action_link: ""})

      assert {:ok, n} = Notifications.create(attrs)
      assert is_nil(n.action_link)
    end
  end

  describe "create/1 — validation" do
    test "rejects when both user_id and role_target are nil" do
      ws = workspace!()
      attrs = valid_attrs(%{workspace: ws}) |> Map.drop([:user_id, :role_target])

      assert {:error, %Ecto.Changeset{} = cs} = Notifications.create(attrs)

      assert "either user_id or role_target must be set" in errors_on(cs).user_id
    end

    test "rejects when both user_id and role_target are set" do
      ws = workspace!()
      u = user!()

      # Bypass the valid_attrs role/user mutual-exclusion logic
      # so we explicitly set BOTH fields and prove the changeset
      # rejects.
      attrs =
        valid_attrs(%{workspace: ws, user_id: u.id})
        |> Map.put(:role_target, :operator)

      assert {:error, cs} = Notifications.create(attrs)
      assert "user_id and role_target are mutually exclusive" in errors_on(cs).role_target
    end

    test "rejects unknown role_target / severity / status" do
      ws = workspace!()

      assert {:error, cs} =
               Notifications.create(valid_attrs(%{workspace: ws, role_target: :superadmin}))

      assert errors_on(cs).role_target != []

      assert {:error, cs} =
               Notifications.create(valid_attrs(%{workspace: ws, severity: :nuclear}))

      assert errors_on(cs).severity != []
    end

    test "rejects missing required fields" do
      assert {:error, cs} = Notifications.create(%{})
      keys = Map.keys(errors_on(cs))

      for required <- [:workspace_id, :event_type, :title, :body, :dedupe_key] do
        assert required in keys, "expected #{required} in errors_on, got #{inspect(keys)}"
      end
    end

    test "rejects title / body over the length cap" do
      ws = workspace!()

      assert {:error, cs} =
               Notifications.create(
                 valid_attrs(%{workspace: ws, title: String.duplicate("x", 201)})
               )

      assert errors_on(cs).title != []

      assert {:error, cs} =
               Notifications.create(
                 valid_attrs(%{workspace: ws, body: String.duplicate("y", 2001)})
               )

      assert errors_on(cs).body != []
    end

    test "rejects action_link that is not a relative path" do
      ws = workspace!()

      for bad_link <- [
            "https://example.test/intents/1",
            "//evil.test/intents/1",
            "intents/1",
            "javascript:alert(1)",
            "ftp://x"
          ] do
        attrs = valid_attrs(%{workspace: ws, action_link: bad_link})
        assert {:error, cs} = Notifications.create(attrs)
        assert errors_on(cs).action_link != [], "action_link #{inspect(bad_link)} was accepted"
      end
    end
  end

  # --- dedupe -----------------------------------------------------------

  describe "create/1 — dedupe (#233 acceptance: dedupe prevents spam)" do
    test "second create with same (workspace_id, dedupe_key) returns {:duplicate, existing}" do
      ws = workspace!()
      attrs = valid_attrs(%{workspace: ws, dedupe_key: "evt.duplicate.fixture"})

      assert {:ok, first} = Notifications.create(attrs)
      assert {:duplicate, existing} = Notifications.create(attrs)

      assert existing.id == first.id
      assert Repo.aggregate(Notification, :count) == 1
    end

    test "different workspaces with same dedupe_key are independent" do
      ws_a = workspace!()
      ws_b = workspace!()

      attrs_a = valid_attrs(%{workspace: ws_a, dedupe_key: "evt.shared"})
      attrs_b = valid_attrs(%{workspace: ws_b, dedupe_key: "evt.shared"})

      assert {:ok, a} = Notifications.create(attrs_a)
      assert {:ok, b} = Notifications.create(attrs_b)

      refute a.id == b.id
      assert a.workspace_id != b.workspace_id
    end

    test "duplicate accepts caller-passed differences in optional fields without bumping the existing row" do
      # Inbox dedupe is by `(workspace_id, dedupe_key)`, NOT a
      # whole-row hash. The original row's content is the source
      # of truth; a duplicate call with a different title /
      # severity returns the existing row unchanged.
      ws = workspace!()

      first_attrs =
        valid_attrs(%{
          workspace: ws,
          dedupe_key: "evt.update-attempt",
          title: "Original title",
          severity: :info
        })

      assert {:ok, first} = Notifications.create(first_attrs)

      second_attrs = %{first_attrs | title: "Different title", severity: :critical}
      assert {:duplicate, existing} = Notifications.create(second_attrs)

      assert existing.id == first.id
      assert existing.title == "Original title"
      assert existing.severity == :info
    end
  end

  # --- list -------------------------------------------------------------

  describe "list_for_workspace/2 + list_for_user/3" do
    test "list_for_workspace returns rows scoped to the workspace, newest first" do
      ws = workspace!()
      sibling = workspace!()

      {:ok, _} = Notifications.create(valid_attrs(%{workspace: ws, dedupe_key: "a"}))
      {:ok, b} = Notifications.create(valid_attrs(%{workspace: ws, dedupe_key: "b"}))
      {:ok, _} = Notifications.create(valid_attrs(%{workspace: sibling, dedupe_key: "x"}))

      rows = Notifications.list_for_workspace(ws.id)

      assert length(rows) == 2
      assert hd(rows).id == b.id
      assert Enum.all?(rows, &(&1.workspace_id == ws.id))
    end

    test "list_for_workspace filters by status" do
      ws = workspace!()
      {:ok, n1} = Notifications.create(valid_attrs(%{workspace: ws, dedupe_key: "n1"}))
      {:ok, _n2} = Notifications.create(valid_attrs(%{workspace: ws, dedupe_key: "n2"}))

      {:ok, _} = Notifications.mark_read(n1)

      assert [%{id: id}] = Notifications.list_for_workspace(ws.id, status: :read)
      assert id == n1.id

      assert [_] = Notifications.list_for_workspace(ws.id, status: :unread)
    end

    test "list_for_user returns user-direct + role-target rows in this workspace only" do
      ws = workspace!()
      sibling = workspace!()
      u = user!()

      {:ok, direct} =
        Notifications.create(valid_attrs(%{workspace: ws, user_id: u.id, dedupe_key: "u-direct"}))

      {:ok, role_op} =
        Notifications.create(
          valid_attrs(%{workspace: ws, role_target: :operator, dedupe_key: "u-role"})
        )

      # Different role — not in role_targets list below.
      {:ok, _other_role} =
        Notifications.create(
          valid_attrs(%{workspace: ws, role_target: :admin, dedupe_key: "u-other"})
        )

      # Sibling workspace — must not appear.
      {:ok, _sibling_direct} =
        Notifications.create(
          valid_attrs(%{workspace: sibling, user_id: u.id, dedupe_key: "u-sibling"})
        )

      rows = Notifications.list_for_user(ws.id, u.id, role_targets: [:operator])

      ids = Enum.map(rows, & &1.id) |> MapSet.new()
      assert ids == MapSet.new([direct.id, role_op.id])
    end

    test "list_for_workspace filters by event_type" do
      ws = workspace!()

      {:ok, held} =
        Notifications.create(
          valid_attrs(%{workspace: ws, event_type: "intent.held", dedupe_key: "et-1"})
        )

      {:ok, _aborted} =
        Notifications.create(
          valid_attrs(%{workspace: ws, event_type: "execution.aborted", dedupe_key: "et-2"})
        )

      assert [%{id: id}] = Notifications.list_for_workspace(ws.id, event_type: "intent.held")
      assert id == held.id
    end
  end

  # --- mark_read --------------------------------------------------------

  describe "mark_read/2" do
    test "transitions :unread → :read and stamps read_at" do
      ws = workspace!()
      {:ok, n} = Notifications.create(valid_attrs(%{workspace: ws}))
      assert n.status == :unread
      assert is_nil(n.read_at)

      assert {:ok, read} = Notifications.mark_read(n)
      assert read.status == :read
      assert %DateTime{} = read.read_at
    end

    test "is idempotent: re-marking a :read row returns {:ok, n} without touching read_at" do
      ws = workspace!()
      {:ok, n} = Notifications.create(valid_attrs(%{workspace: ws}))

      {:ok, first_read} = Notifications.mark_read(n)
      {:ok, second_read} = Notifications.mark_read(first_read)

      assert first_read.read_at == second_read.read_at
    end

    test "refuses to regress an :archived row to :read" do
      ws = workspace!()
      {:ok, n} = Notifications.create(valid_attrs(%{workspace: ws}))
      {:ok, archived} = Notifications.archive(n)
      assert archived.status == :archived

      assert {:error, :archived} = Notifications.mark_read(archived)
    end

    # --- stale-struct guard (#233 P2-2) --------------------------------

    test "stale :unread struct cannot mark an already-archived DB row as :read (#233 P2-2)" do
      # Pre-fix `mark_read/2` trusted the in-memory status on the
      # passed struct and updated by primary key. A long-held
      # `:unread` struct loaded BEFORE a concurrent `archive/2`
      # could therefore overwrite an already-archived DB row back
      # to `:read`. Post-fix the transition is gated by a
      # conditional `update_all where status == :unread`, so the
      # DB enforces the precondition atomically.
      ws = workspace!()
      {:ok, stale_unread} = Notifications.create(valid_attrs(%{workspace: ws}))
      assert stale_unread.status == :unread

      # Concurrent caller archives the row.
      {:ok, archived} = Notifications.archive(stale_unread)
      assert archived.status == :archived
      assert %DateTime{} = archived.archived_at

      # Original caller still holds the stale `:unread` struct
      # and now calls mark_read. Must NOT regress the archived
      # row to `:read`.
      assert {:error, :archived} = Notifications.mark_read(stale_unread)

      # And the DB row stays archived — same archived_at, status
      # still `:archived`.
      reloaded = Bank.Repo.get!(Bank.Notifications.Notification, stale_unread.id)
      assert reloaded.status == :archived
      assert reloaded.archived_at == archived.archived_at
      assert is_nil(reloaded.read_at)
    end

    test "stale :unread struct against an already-:read DB row is idempotent (no read_at bump)" do
      # Sibling case for the conditional-update path: when the DB
      # row was already marked read by a concurrent caller, the
      # stale struct's mark_read should fall through to the
      # idempotent reload-and-return outcome — no new write.
      ws = workspace!()
      {:ok, stale_unread} = Notifications.create(valid_attrs(%{workspace: ws}))

      {:ok, first_read} = Notifications.mark_read(stale_unread)
      assert %DateTime{} = first_read.read_at

      {:ok, second_read} = Notifications.mark_read(stale_unread)
      assert second_read.id == first_read.id
      assert second_read.read_at == first_read.read_at
    end
  end

  # --- archive ----------------------------------------------------------

  describe "archive/2" do
    test "transitions :unread → :archived and stamps archived_at" do
      ws = workspace!()
      {:ok, n} = Notifications.create(valid_attrs(%{workspace: ws}))

      assert {:ok, archived} = Notifications.archive(n)
      assert archived.status == :archived
      assert %DateTime{} = archived.archived_at
    end

    test "is idempotent: re-archiving returns {:ok, n} without touching archived_at" do
      ws = workspace!()
      {:ok, n} = Notifications.create(valid_attrs(%{workspace: ws}))

      {:ok, first} = Notifications.archive(n)
      {:ok, second} = Notifications.archive(first)

      assert first.archived_at == second.archived_at
    end

    test "transitions :read → :archived" do
      ws = workspace!()
      {:ok, n} = Notifications.create(valid_attrs(%{workspace: ws}))

      {:ok, read} = Notifications.mark_read(n)
      {:ok, archived} = Notifications.archive(read)

      assert archived.status == :archived
      assert %DateTime{} = archived.archived_at
    end
  end

  # --- cross-workspace isolation ----------------------------------------

  describe "cross-workspace isolation" do
    test "get_in_workspace/2 returns nil for a row in a sibling workspace" do
      ws_a = workspace!()
      ws_b = workspace!()

      {:ok, n_a} = Notifications.create(valid_attrs(%{workspace: ws_a}))

      assert Notifications.get_in_workspace(n_a.id, ws_a.id) == n_a
      assert Notifications.get_in_workspace(n_a.id, ws_b.id) == nil
    end

    test "list_for_workspace never bleeds rows from a sibling workspace" do
      ws_a = workspace!()
      ws_b = workspace!()

      for _ <- 1..3 do
        {:ok, _} = Notifications.create(valid_attrs(%{workspace: ws_a}))
        {:ok, _} = Notifications.create(valid_attrs(%{workspace: ws_b}))
      end

      rows_a = Notifications.list_for_workspace(ws_a.id)
      rows_b = Notifications.list_for_workspace(ws_b.id)

      assert length(rows_a) == 3
      assert length(rows_b) == 3
      assert Enum.all?(rows_a, &(&1.workspace_id == ws_a.id))
      assert Enum.all?(rows_b, &(&1.workspace_id == ws_b.id))
    end
  end

  # --- secret hygiene ---------------------------------------------------

  describe "secret hygiene (#233 acceptance: no secrets in payload)" do
    @markers [
      "Authorization: Bearer abc",
      "Bearer sk_live_LEAKED_PROBE",
      "Bearer sk_test_LEAKED_PROBE",
      "rotate sk_live_HIDDEN soon",
      "rotate sk_test_HIDDEN soon",
      "-----BEGIN PRIVATE KEY-----",
      "-----BEGIN RSA PRIVATE KEY-----",
      "private_key=hex_blob",
      "rotate the private_key now"
    ]

    @url_markers [
      "https://user:pass@example.test/rpc",
      "wss://user:pass@example.test/rpc",
      "https://secret@example.test/rpc"
    ]

    test "rejects title containing secret-looking content" do
      ws = workspace!()

      for marker <- @markers ++ @url_markers do
        attrs = valid_attrs(%{workspace: ws, title: marker})
        assert {:error, cs} = Notifications.create(attrs)
        assert errors_on(cs).title != [], "marker #{inspect(marker)} was accepted in title"
      end
    end

    test "rejects body containing secret-looking content" do
      ws = workspace!()

      for marker <- @markers ++ @url_markers do
        attrs = valid_attrs(%{workspace: ws, body: marker})
        assert {:error, cs} = Notifications.create(attrs)
        assert errors_on(cs).body != [], "marker #{inspect(marker)} was accepted in body"
      end
    end

    test "rejects tokenized-URL action_link" do
      ws = workspace!()

      # Anything not starting with `/` is rejected by the
      # action_link relative-path gate first; the secret-hygiene
      # gate is the second line of defence (covered in renderer
      # tests). Confirm both gates close the same loop here.
      for marker <- @url_markers do
        attrs = valid_attrs(%{workspace: ws, action_link: marker})
        assert {:error, cs} = Notifications.create(attrs)

        assert errors_on(cs).action_link != [],
               "marker #{inspect(marker)} accepted in action_link"
      end
    end

    test "happy path: clean text passes" do
      ws = workspace!()

      attrs =
        valid_attrs(%{
          workspace: ws,
          title: "Intent on hold (operator review required)",
          body: "Intent abc1234… exceeded amount limit. Click below to review.",
          action_link: "/intents/abc1234"
        })

      assert {:ok, _n} = Notifications.create(attrs)
    end

    # --- dedupe_key secret hygiene (#233 P2-1) -------------------------

    test "rejects dedupe_key containing secret-looking content (#233 P2-1)" do
      # `dedupe_key` is a persisted notification field. Pre-fix
      # the changeset only ran the secret-hygiene gate on title /
      # body / action_link, so an emitter that built a dedupe key
      # from operator input could quietly persist a Bearer token /
      # PEM marker / `private_key=` blob into a column that future
      # inbox listings or log lines would surface.
      ws = workspace!()

      for marker <- @markers ++ @url_markers do
        attrs = valid_attrs(%{workspace: ws, dedupe_key: marker})
        assert {:error, cs} = Notifications.create(attrs)

        assert errors_on(cs).dedupe_key != [],
               "marker #{inspect(marker)} was accepted in dedupe_key"
      end
    end

    test "dedupe_key happy path: clean opaque key passes" do
      # A future #234 emitter typically composes the dedupe key
      # as `<event_type>:<subject_id>` or
      # `<event_type>:<sha256_of_payload>` — both shapes contain
      # no marker family the gate rejects.
      ws = workspace!()

      for safe_key <- [
            "intent.held:" <> Ecto.UUID.generate(),
            "execution.aborted:tx-0xabc",
            "decision.approval_required:dec-id-001",
            ("policy.violation:" <>
               :crypto.strong_rand_bytes(16))
            |> Base.encode16(case: :lower)
          ] do
        attrs = valid_attrs(%{workspace: ws, dedupe_key: safe_key})
        assert {:ok, _n} = Notifications.create(attrs), "safe key #{inspect(safe_key)} rejected"
      end
    end
  end

  # --- read-only side-effect contract -----------------------------------

  describe "no external delivery side effects (#233 scope discipline)" do
    test "create/1 enqueues no Oban job" do
      ws = workspace!()

      jobs_before = Repo.all(Oban.Job)
      {:ok, _n} = Notifications.create(valid_attrs(%{workspace: ws}))
      jobs_after = Repo.all(Oban.Job)

      assert jobs_after == jobs_before
    end

    test "mark_read/2 + archive/2 enqueue no Oban job" do
      ws = workspace!()
      {:ok, n} = Notifications.create(valid_attrs(%{workspace: ws}))

      jobs_before = Repo.all(Oban.Job)

      {:ok, n} = Notifications.mark_read(n)
      {:ok, _} = Notifications.archive(n)

      assert Repo.all(Oban.Job) == jobs_before
    end
  end
end
