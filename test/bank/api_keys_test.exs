defmodule Bank.APIKeysTest do
  @moduledoc """
  End-to-end coverage for `Bank.APIKeys` (#218a).

  Covers:
    * `create_key/4` returns the one-time raw secret and persists
      ONLY a SHA-256 hash. Wire format `cb_<prefix>_<rest>` is
      sane.
    * Audit `api_key.created` event is appended in the same
      transaction as the key insert and stamps `workspace_id`.
    * `revoke_key/2` is idempotent and emits `api_key.revoked`
      only on the first transition.
    * Listing helpers honor revoked / non-revoked filtering.
    * Secret hygiene: no field on the persisted row, the audit
      `after_ref`, the audit `before_ref`, or `inspect/1` of the
      struct contains the raw secret.
  """

  use Bank.DataCase, async: false

  alias Bank.APIKeys
  alias Bank.APIKeys.APIKey
  alias Bank.Audit
  alias Bank.Repo
  alias Bank.Workspaces

  setup do
    {:ok, workspace} =
      Workspaces.create_workspace(%{
        slug: "ak-#{System.unique_integer([:positive])}",
        name: "API Key WS"
      })

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "ak-#{System.unique_integer([:positive])}",
        email: "ak-#{System.unique_integer([:positive])}@example.com",
        name: "API Key Creator"
      })

    {:ok, _} =
      Workspaces.create_membership(%{
        user_id: user.id,
        workspace_id: workspace.id,
        role: :admin
      })

    {:ok, %{workspace: workspace, user: user}}
  end

  # --- create_key/4 ---------------------------------------------------------

  describe "create_key/4" do
    test "returns the row + raw secret on success", %{workspace: ws, user: user} do
      assert {:ok, %APIKey{} = key, raw_secret} =
               APIKeys.create_key(ws, user, :operator, "ci-runner")

      assert is_binary(raw_secret)
      assert String.starts_with?(raw_secret, "cb_")
      assert key.role == :operator
      assert key.name == "ci-runner"
      assert key.workspace_id == ws.id
      assert key.created_by_user_id == user.id
      assert is_nil(key.revoked_at)
    end

    test "the persisted secret_hash equals SHA-256 of the secret body (without `cb_`)",
         %{workspace: ws, user: user} do
      {:ok, key, raw_secret} = APIKeys.create_key(ws, user, :viewer, "hashcheck")

      "cb_" <> body = raw_secret
      expected = :crypto.hash(:sha256, body)

      reloaded = Repo.get!(APIKey, key.id)
      assert reloaded.secret_hash == expected
    end

    test "the prefix matches the first 8 chars of the secret body",
         %{workspace: ws, user: user} do
      {:ok, key, raw_secret} = APIKeys.create_key(ws, user, :viewer, "prefixcheck")
      "cb_" <> body = raw_secret

      assert key.prefix == String.slice(body, 0, 8)
      assert String.length(key.prefix) == 8
    end

    test "two keys produce different prefixes and secrets",
         %{workspace: ws, user: user} do
      {:ok, key_a, raw_a} = APIKeys.create_key(ws, user, :viewer, "a")
      {:ok, key_b, raw_b} = APIKeys.create_key(ws, user, :viewer, "b")

      refute key_a.prefix == key_b.prefix
      refute key_a.secret_hash == key_b.secret_hash
      refute raw_a == raw_b
    end

    test "honors :expires_at opt", %{workspace: ws, user: user} do
      ttl = ~U[2027-01-01 00:00:00.000000Z]
      {:ok, key, _} = APIKeys.create_key(ws, user, :viewer, "ttl", expires_at: ttl)

      assert key.expires_at == ttl
    end

    test "rejects unknown role at function head", %{workspace: ws, user: user} do
      assert_raise FunctionClauseError, fn ->
        APIKeys.create_key(ws, user, :superuser, "bogus")
      end
    end

    test "appends an `api_key.created` audit event stamped with the workspace_id",
         %{workspace: ws, user: user} do
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :operator, "audited")

      %{events: events} = Audit.list_events(%{event_type: "api_key.created"})

      [event] = Enum.filter(events, &(&1.subject_id == key.id))

      assert event.actor == :user
      assert event.actor_id == user.id
      assert event.subject_type == "api_key"
      assert event.correlation_id == key.id
      assert event.workspace_id == ws.id
    end

    test "audit after_ref does NOT carry the raw secret OR its hash",
         %{workspace: ws, user: user} do
      {:ok, key, raw_secret} = APIKeys.create_key(ws, user, :operator, "hygiene")

      %{events: events} = Audit.list_events(%{event_type: "api_key.created"})
      [event] = Enum.filter(events, &(&1.subject_id == key.id))

      json = Jason.encode!(event.after_ref)

      refute json =~ raw_secret, "audit after_ref must not include the raw secret"

      refute json =~ Base.encode16(key.secret_hash, case: :lower),
             "audit after_ref must not include the secret_hash"

      # And it MUST include the public public-facing metadata.
      assert event.after_ref["prefix"] == key.prefix or
               event.after_ref[:prefix] == key.prefix

      assert event.after_ref["role"] == "operator" or event.after_ref[:role] == "operator"
    end
  end

  # --- revoke_key/2 ---------------------------------------------------------

  describe "revoke_key/2" do
    test "stamps revoked_at and emits api_key.revoked audit event",
         %{workspace: ws, user: user} do
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :operator, "to-revoke")

      assert {:ok, revoked} = APIKeys.revoke_key(key, actor: user)
      assert %DateTime{} = revoked.revoked_at

      %{events: events} = Audit.list_events(%{event_type: "api_key.revoked"})
      [event] = Enum.filter(events, &(&1.subject_id == key.id))

      assert event.actor == :user
      assert event.actor_id == user.id
      assert event.workspace_id == ws.id
      assert event.before_ref["status"] == "active" or event.before_ref[:status] == "active"
      assert event.after_ref["status"] == "revoked" or event.after_ref[:status] == "revoked"
    end

    test "is idempotent on a key that is already revoked",
         %{workspace: ws, user: user} do
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :viewer, "idempotent")
      {:ok, revoked_first} = APIKeys.revoke_key(key, actor: user)
      first_ts = revoked_first.revoked_at

      assert {:ok, revoked_again} = APIKeys.revoke_key(revoked_first, actor: user)
      assert revoked_again.revoked_at == first_ts

      # And only ONE audit event was emitted, despite two calls.
      %{events: events} = Audit.list_events(%{event_type: "api_key.revoked"})
      events = Enum.filter(events, &(&1.subject_id == key.id))
      assert length(events) == 1
    end

    test "actor defaults to the original creator if no :actor opt is supplied",
         %{workspace: ws, user: user} do
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :viewer, "default-actor")
      assert {:ok, _} = APIKeys.revoke_key(key)

      %{events: events} = Audit.list_events(%{event_type: "api_key.revoked"})
      [event] = Enum.filter(events, &(&1.subject_id == key.id))

      assert event.actor_id == user.id
    end
  end

  # --- listing --------------------------------------------------------------

  describe "list_active_keys/1 and list_keys/1" do
    test "list_active_keys excludes revoked rows", %{workspace: ws, user: user} do
      {:ok, k1, _} = APIKeys.create_key(ws, user, :viewer, "active-1")
      {:ok, k2, _} = APIKeys.create_key(ws, user, :viewer, "active-2")
      {:ok, k3, _} = APIKeys.create_key(ws, user, :viewer, "to-be-revoked")

      {:ok, _} = APIKeys.revoke_key(k3)

      ids = APIKeys.list_active_keys(ws.id) |> Enum.map(& &1.id)

      assert k1.id in ids
      assert k2.id in ids
      refute k3.id in ids
    end

    test "list_keys includes revoked rows", %{workspace: ws, user: user} do
      {:ok, k1, _} = APIKeys.create_key(ws, user, :viewer, "k1")
      {:ok, k2, _} = APIKeys.create_key(ws, user, :viewer, "k2")
      {:ok, _} = APIKeys.revoke_key(k2)

      ids = APIKeys.list_keys(ws.id) |> Enum.map(& &1.id)

      assert k1.id in ids
      assert k2.id in ids
    end

    test "lists are workspace-scoped (no cross-workspace bleed)",
         %{workspace: ws_a, user: user} do
      {:ok, ws_b} =
        Workspaces.create_workspace(%{slug: "ak-other", name: "Other"})

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws_b.id, role: :admin})

      {:ok, k_a, _} = APIKeys.create_key(ws_a, user, :viewer, "a")
      {:ok, k_b, _} = APIKeys.create_key(ws_b, user, :viewer, "b")

      ids_a = APIKeys.list_active_keys(ws_a.id) |> Enum.map(& &1.id)
      ids_b = APIKeys.list_active_keys(ws_b.id) |> Enum.map(& &1.id)

      assert k_a.id in ids_a
      refute k_b.id in ids_a
      assert k_b.id in ids_b
      refute k_a.id in ids_b
    end
  end

  # --- verify_key/1 ---------------------------------------------------------

  describe "verify_key/1 (#218b)" do
    test "returns {:ok, key, workspace} for a valid raw secret",
         %{workspace: ws, user: user} do
      {:ok, original, raw} = APIKeys.create_key(ws, user, :operator, "verify-ok")

      assert {:ok, %APIKey{} = key, ^ws} = APIKeys.verify_key(raw)
      assert key.id == original.id
      assert key.role == :operator
    end

    test "rejects malformed wire format with :malformed", %{workspace: _ws, user: _user} do
      assert {:error, :malformed} = APIKeys.verify_key("not-a-key")
      assert {:error, :malformed} = APIKeys.verify_key("cb_")
      # Too short to even split off a prefix.
      assert {:error, :malformed} = APIKeys.verify_key("cb_short")
    end

    test "rejects unknown prefix with :not_found",
         %{workspace: _ws, user: _user} do
      assert {:error, :not_found} =
               APIKeys.verify_key("cb_aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee")
    end

    test "rejects right prefix + wrong secret with :hash_mismatch",
         %{workspace: ws, user: user} do
      {:ok, _key, raw} = APIKeys.create_key(ws, user, :viewer, "tampered")

      # Replace the body's TAIL while keeping the prefix intact —
      # this hits the prefix lookup but fails the hash compare.
      "cb_" <> body = raw
      tampered_body = String.slice(body, 0, 8) <> String.duplicate("a", String.length(body) - 8)

      assert {:error, :hash_mismatch} = APIKeys.verify_key("cb_" <> tampered_body)
    end

    test "rejects revoked keys with :revoked",
         %{workspace: ws, user: user} do
      {:ok, key, raw} = APIKeys.create_key(ws, user, :operator, "revoked-verify")
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      assert {:error, :revoked} = APIKeys.verify_key(raw)
    end

    test "rejects expired keys with :expired",
         %{workspace: ws, user: user} do
      past = DateTime.utc_now() |> DateTime.add(-1, :hour)
      {:ok, _key, raw} = APIKeys.create_key(ws, user, :operator, "exp", expires_at: past)

      assert {:error, :expired} = APIKeys.verify_key(raw)
    end
  end

  # --- secret hygiene -------------------------------------------------------

  describe "secret hygiene (no raw secret leaks)" do
    test "the persisted row carries no raw-secret field",
         %{workspace: ws, user: user} do
      {:ok, key, raw} = APIKeys.create_key(ws, user, :viewer, "hygiene")

      reloaded = Repo.get!(APIKey, key.id)

      # `inspect/1` on the struct must not echo the raw secret. The
      # struct only has secret_hash + prefix (the prefix is public).
      reloaded_inspected = inspect(reloaded)
      refute reloaded_inspected =~ raw

      # Defensively: scan the row Map for any field whose value is
      # the full raw secret. Should be none.
      reloaded
      |> Map.from_struct()
      |> Enum.each(fn {_field, value} ->
        if is_binary(value), do: refute(value == raw)
      end)
    end

    test "inspect/1 redacts secret_hash bytes (`@derive Inspect, except`)",
         %{workspace: ws, user: user} do
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :viewer, "redact-inspect")

      # The hash is exactly 32 bytes. Even though SHA-256 is one-
      # way, the hash + prefix together are the lookup pair the
      # auth plug will compare against — never echo them in logs.
      reloaded = Repo.get!(APIKey, key.id)
      assert byte_size(reloaded.secret_hash) == 32

      inspected = inspect(reloaded)

      refute inspected =~ "secret_hash:",
             "inspect/1 should not surface the secret_hash field at all"

      # Sanity: hex of any 8 contiguous hash bytes shouldn't appear
      # either (cheap structural check that no other field leaked
      # the hash).
      hex = Base.encode16(reloaded.secret_hash, case: :lower)
      sample = String.slice(hex, 0, 16)

      refute inspected =~ sample,
             "inspect/1 leaked hash bytes through some other field"
    end

    test "raw secret is not included in the api_key.created audit event payload",
         %{workspace: ws, user: user} do
      {:ok, key, raw} = APIKeys.create_key(ws, user, :operator, "no-leak")

      %{events: events} = Audit.list_events(%{event_type: "api_key.created"})
      [event] = Enum.filter(events, &(&1.subject_id == key.id))

      # The whole event JSON-encoded must not contain the raw secret.
      # Build the same JSON shape `Bank.Audit.append_event/1` would
      # serialise (just the persisted columns; drop Ecto's internal
      # __meta__).
      sanitized = event |> Map.from_struct() |> Map.drop([:__meta__, :workspace])
      full_json = Jason.encode!(sanitized)

      refute full_json =~ raw,
             "api_key.created event MUST NOT include the raw secret anywhere"
    end

    test "raw secret is not included in the api_key.revoked audit event payload",
         %{workspace: ws, user: user} do
      {:ok, key, raw} = APIKeys.create_key(ws, user, :operator, "no-leak-revoke")
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      %{events: events} = Audit.list_events(%{event_type: "api_key.revoked"})
      [event] = Enum.filter(events, &(&1.subject_id == key.id))

      # Build the same JSON shape `Bank.Audit.append_event/1` would
      # serialise (just the persisted columns; drop Ecto's internal
      # __meta__).
      sanitized = event |> Map.from_struct() |> Map.drop([:__meta__, :workspace])
      full_json = Jason.encode!(sanitized)

      refute full_json =~ raw,
             "api_key.revoked event MUST NOT include the raw secret anywhere"
    end
  end
end
