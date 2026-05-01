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

  import Ecto.Query, only: [from: 2]

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

  # --- rotate_key/3 ---------------------------------------------------------

  describe "rotate_key/3 (#220)" do
    test "atomically replaces the old key with a fresh one", %{workspace: ws, user: user} do
      {:ok, old_key, _old_raw} = APIKeys.create_key(ws, user, :operator, "ci-runner")

      assert {:ok, new_key, raw_secret} = APIKeys.rotate_key(old_key, user)

      # New key is fresh.
      assert new_key.id != old_key.id
      assert new_key.prefix != old_key.prefix
      assert String.starts_with?(raw_secret, "cb_")

      # Inherits role/name/workspace.
      assert new_key.role == old_key.role
      assert new_key.name == old_key.name
      assert new_key.workspace_id == old_key.workspace_id

      # Old key is revoked atomically.
      reloaded = Repo.get!(APIKey, old_key.id)
      assert %DateTime{} = reloaded.revoked_at
    end

    test "old key fails verification immediately after rotate (no grace period)",
         %{workspace: ws, user: user} do
      {:ok, old_key, old_raw} = APIKeys.create_key(ws, user, :operator, "no-grace")
      {:ok, _new_key, _new_raw} = APIKeys.rotate_key(old_key, user)

      assert {:error, :revoked} = APIKeys.verify_key(old_raw)
    end

    test "new key authenticates", %{workspace: ws, user: user} do
      {:ok, old_key, _} = APIKeys.create_key(ws, user, :operator, "swap")
      {:ok, new_key, new_raw} = APIKeys.rotate_key(old_key, user)

      assert {:ok, %APIKey{id: id}, %_{} = verified_ws} = APIKeys.verify_key(new_raw)
      assert id == new_key.id
      assert verified_ws.id == ws.id
    end

    test "rotating an already-revoked key returns :already_revoked",
         %{workspace: ws, user: user} do
      {:ok, key, _} = APIKeys.create_key(ws, user, :operator, "stale")
      {:ok, _} = APIKeys.revoke_key(key, actor: user)
      revoked = Repo.get!(APIKey, key.id)

      assert {:error, :already_revoked} = APIKeys.rotate_key(revoked, user)
    end

    test "concurrent rotates leave only ONE replacement (race-safe)",
         %{workspace: ws, user: user} do
      {:ok, old_key, _} = APIKeys.create_key(ws, user, :operator, "race")

      # Two callers both holding the same pre-rotate struct in
      # memory — simulates the API hitting the controller twice
      # before the first transaction commits.
      task_a = Task.async(fn -> APIKeys.rotate_key(old_key, user) end)
      task_b = Task.async(fn -> APIKeys.rotate_key(old_key, user) end)

      results = [Task.await(task_a), Task.await(task_b)]

      successes = Enum.count(results, &match?({:ok, _, _}, &1))
      already_revoked = Enum.count(results, &match?({:error, :already_revoked}, &1))

      assert successes == 1
      assert already_revoked == 1

      # Exactly one replacement key should be active in the workspace
      # (the original is revoked).
      active = APIKeys.list_active_keys(ws.id)
      assert length(active) == 1
      [%APIKey{id: replacement_id}] = active
      assert replacement_id != old_key.id
    end

    test "emits api_key.rotated event linking old → new",
         %{workspace: ws, user: user} do
      {:ok, old_key, _} = APIKeys.create_key(ws, user, :operator, "audited")
      {:ok, new_key, _} = APIKeys.rotate_key(old_key, user)

      %{events: events} = Audit.list_events(%{event_type: "api_key.rotated"})
      [event] = Enum.filter(events, &(&1.subject_id == new_key.id))

      assert event.workspace_id == ws.id
      assert event.actor_id == user.id

      # Before-ref points at the old key's id+prefix.
      assert event.before_ref["id"] == old_key.id
      assert event.before_ref["prefix"] == old_key.prefix
      # before_ref records the terminal state of the old key.
      assert event.before_ref["revoked_at"]

      # After-ref carries the new key's public metadata.
      assert event.after_ref["id"] == new_key.id
      assert event.after_ref["prefix"] == new_key.prefix
    end

    test "audit event JSON contains NO raw secret and NO secret_hash",
         %{workspace: ws, user: user} do
      {:ok, old_key, _} = APIKeys.create_key(ws, user, :viewer, "hygiene")
      {:ok, _new_key, _new_raw} = APIKeys.rotate_key(old_key, user)

      %{events: events} = Audit.list_events(%{event_type: "api_key.rotated"})
      [event] = events

      sanitized = event |> Map.from_struct() |> Map.drop([:__meta__, :workspace])
      json = Jason.encode!(sanitized)

      refute json =~ "cb_"
      refute json =~ "secret_hash"
    end

    test "honours :expires_at override when supplied", %{workspace: ws, user: user} do
      {:ok, old_key, _} = APIKeys.create_key(ws, user, :viewer, "ttl-override")
      assert is_nil(old_key.expires_at)

      future = ~U[2030-01-01 00:00:00.000000Z]

      assert {:ok, new_key, _} = APIKeys.rotate_key(old_key, user, expires_at: future)
      assert DateTime.compare(new_key.expires_at, future) == :eq
    end

    test "inherits :expires_at from the old key by default",
         %{workspace: ws, user: user} do
      future = ~U[2030-06-01 00:00:00.000000Z]

      {:ok, old_key, _} =
        APIKeys.create_key(ws, user, :viewer, "ttl-inherit", expires_at: future)

      {:ok, new_key, _} = APIKeys.rotate_key(old_key, user)

      assert DateTime.compare(new_key.expires_at, future) == :eq
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

  # --- touch_last_used / list_keys_used_between (#218d) -------------------

  describe "touch_last_used/2" do
    test "advances last_used_at on a key with no prior usage",
         %{workspace: ws, user: user} do
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :viewer, "fresh")
      assert is_nil(key.last_used_at)

      assert {:ok, %APIKey{last_used_at: %DateTime{}}} =
               APIKeys.touch_last_used(key)
    end

    test "is a no-op when last_used_at is within the throttle window",
         %{workspace: ws, user: user} do
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :viewer, "throttled")
      now = DateTime.utc_now()

      Bank.Repo.update_all(
        from(k in APIKey, where: k.id == ^key.id),
        set: [last_used_at: now]
      )

      key = Bank.Repo.get!(APIKey, key.id)

      # Ten-second threshold; the row was just touched, so the
      # call returns the existing timestamp unchanged.
      assert {:ok, returned} = APIKeys.touch_last_used(key, 10)
      assert returned.last_used_at == key.last_used_at
    end

    test "advances last_used_at when prior usage is older than the threshold",
         %{workspace: ws, user: user} do
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :viewer, "stale")

      stale = DateTime.add(DateTime.utc_now(), -3600, :second)

      Bank.Repo.update_all(
        from(k in APIKey, where: k.id == ^key.id),
        set: [last_used_at: stale]
      )

      key = Bank.Repo.get!(APIKey, key.id)

      assert {:ok, %APIKey{last_used_at: %DateTime{} = new_ts}} =
               APIKeys.touch_last_used(key, 60)

      assert DateTime.compare(new_ts, stale) == :gt
    end

    test "is a no-op on a key revoked between verify and touch (TOCTOU race)",
         %{workspace: ws, user: user} do
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :viewer, "toctou")
      assert is_nil(key.last_used_at)

      # Simulate the race: the in-memory struct from verify_key/1
      # shows revoked_at=nil, but a parallel actor revokes the key
      # before touch lands.
      {:ok, _} = APIKeys.revoke_key(key, actor: user)

      # Touch invoked with the stale (pre-revoke) struct. The
      # DB-level filter MUST refuse the bump.
      assert {:error, :no_match} = APIKeys.touch_last_used(key)

      reloaded = Bank.Repo.get!(APIKey, key.id)

      assert is_nil(reloaded.last_used_at),
             "revoked key MUST NOT have last_used_at advanced (TOCTOU race close)"
    end

    test "is a no-op on a key whose expires_at is in the past",
         %{workspace: ws, user: user} do
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :viewer, "expired", expires_at: past)
      assert is_nil(key.last_used_at)

      assert {:error, :no_match} = APIKeys.touch_last_used(key)
      reloaded = Bank.Repo.get!(APIKey, key.id)
      assert is_nil(reloaded.last_used_at)
    end

    test "concurrent calls are safe (no Ecto.StaleEntryError)",
         %{workspace: ws, user: user} do
      # `update_all` is the right tool here precisely because
      # `Repo.update/1` would race on the optimistic-lock-style
      # `updated_at` check. Pin the contract with a small
      # parallel batch.
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :viewer, "concurrent")

      results =
        1..5
        |> Task.async_stream(fn _ -> APIKeys.touch_last_used(key, 60) end,
          ordered: false,
          max_concurrency: 5
        )
        |> Enum.map(fn {:ok, result} -> result end)

      for result <- results, do: assert(match?({:ok, _}, result))
    end
  end

  describe "list_keys_used_between/2 and used_event_exists?/2" do
    test "list returns only keys whose last_used_at falls in the half-open window",
         %{workspace: ws, user: user} do
      {:ok, k_in, _} = APIKeys.create_key(ws, user, :viewer, "in")
      {:ok, k_before, _} = APIKeys.create_key(ws, user, :viewer, "before")
      {:ok, k_after, _} = APIKeys.create_key(ws, user, :viewer, "after")
      {:ok, k_unused, _} = APIKeys.create_key(ws, user, :viewer, "unused")

      window_start = ~U[2026-04-30 00:00:00.000000Z]
      window_end = ~U[2026-05-01 00:00:00.000000Z]

      Bank.Repo.update_all(
        from(k in APIKey, where: k.id == ^k_in.id),
        set: [last_used_at: ~U[2026-04-30 12:00:00.000000Z]]
      )

      Bank.Repo.update_all(
        from(k in APIKey, where: k.id == ^k_before.id),
        set: [last_used_at: ~U[2026-04-29 23:59:59.999999Z]]
      )

      Bank.Repo.update_all(
        from(k in APIKey, where: k.id == ^k_after.id),
        set: [last_used_at: ~U[2026-05-01 00:00:00.000001Z]]
      )

      ids = APIKeys.list_keys_used_between(window_start, window_end) |> Enum.map(& &1.id)

      assert k_in.id in ids
      refute k_before.id in ids
      refute k_after.id in ids
      refute k_unused.id in ids
    end

    test "used_event_exists? matches on (subject_id, after_ref.window_start)",
         %{workspace: ws, user: user} do
      {:ok, key, _raw} = APIKeys.create_key(ws, user, :viewer, "exists")
      window_start = ~U[2026-04-30 00:00:00.000000Z]
      window_start_iso = DateTime.to_iso8601(window_start)

      refute APIKeys.used_event_exists?(key.id, window_start_iso)

      attrs =
        Bank.Audit.Events.api_key_used(key, %{
          window_start: window_start,
          window_end: ~U[2026-05-01 00:00:00.000000Z],
          last_used_at: ~U[2026-04-30 12:00:00.000000Z]
        })

      {:ok, _event} = Bank.Audit.append_event(attrs)

      assert APIKeys.used_event_exists?(key.id, window_start_iso)

      # A different window for the same key still returns false.
      refute APIKeys.used_event_exists?(
               key.id,
               DateTime.to_iso8601(~U[2026-05-01 00:00:00.000000Z])
             )
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

  # --- Workspace agent-key pause (#231-a) ---------------------------------

  describe "pause_workspace/3 + resume_workspace/3" do
    test "first pause flips the flag and emits agent_keys.paused once",
         %{workspace: ws, user: user} do
      assert {:ok, :paused, paused} = APIKeys.pause_workspace(ws, user, reason: "smoke")

      assert %DateTime{} = paused.agent_keys_paused_at
      assert paused.agent_keys_paused_reason == "smoke"
      assert paused.agent_keys_paused_by_user_id == user.id

      %{events: events} = Audit.list_events(%{event_type: "agent_keys.paused"})
      [event] = Enum.filter(events, &(&1.workspace_id == ws.id))

      assert event.actor == :user
      assert event.actor_id == user.id
      assert event.subject_type == "workspace"
      assert event.subject_id == ws.id
      assert event.correlation_id == ws.id
      assert event.after_ref["paused_by_user_id"] == user.id
      assert event.after_ref["reason"] == "smoke"
    end

    test "second pause on already-paused workspace is a no-op (no second audit)",
         %{workspace: ws, user: user} do
      {:ok, :paused, paused} = APIKeys.pause_workspace(ws, user)

      assert {:ok, :already_paused, ^paused} = APIKeys.pause_workspace(paused, user)

      %{events: events} = Audit.list_events(%{event_type: "agent_keys.paused"})
      assert length(Enum.filter(events, &(&1.workspace_id == ws.id))) == 1
    end

    test "resume on an unpaused workspace is a no-op (no audit)",
         %{workspace: ws, user: user} do
      assert {:ok, :already_unpaused, _} = APIKeys.resume_workspace(ws, user)

      %{events: events} = Audit.list_events(%{event_type: "agent_keys.resumed"})
      assert Enum.filter(events, &(&1.workspace_id == ws.id)) == []
    end

    test "resume after pause clears the flag and emits agent_keys.resumed",
         %{workspace: ws, user: user} do
      {:ok, :paused, paused} = APIKeys.pause_workspace(ws, user)
      paused_at = paused.agent_keys_paused_at

      assert {:ok, :resumed, resumed} = APIKeys.resume_workspace(paused, user)

      assert is_nil(resumed.agent_keys_paused_at)
      assert is_nil(resumed.agent_keys_paused_reason)
      assert is_nil(resumed.agent_keys_paused_by_user_id)

      %{events: events} = Audit.list_events(%{event_type: "agent_keys.resumed"})
      [event] = Enum.filter(events, &(&1.workspace_id == ws.id))

      assert event.actor == :user
      assert event.actor_id == user.id
      assert event.before_ref["paused_at"] == DateTime.to_iso8601(paused_at)
      assert event.before_ref["paused_by_user_id"] == user.id
      assert event.after_ref == %{"paused_at" => nil}
    end

    test "pausing workspace A does not affect workspace B",
         %{workspace: ws_a, user: user} do
      {:ok, ws_b} = Workspaces.create_workspace(%{slug: "ak-pause-b", name: "B"})

      {:ok, _} =
        Workspaces.create_membership(%{user_id: user.id, workspace_id: ws_b.id, role: :admin})

      assert {:ok, :paused, _} = APIKeys.pause_workspace(ws_a, user)

      reloaded_b = Bank.Repo.get!(Bank.Workspaces.Workspace, ws_b.id)
      refute Bank.Workspaces.Workspace.agent_keys_paused?(reloaded_b)
    end

    test "audit event JSON contains NO api key prefix / secret_hash / Bearer",
         %{workspace: ws, user: user} do
      # Mint a key so the workspace has something concrete to leak.
      {:ok, key, raw} = APIKeys.create_key(ws, user, :viewer, "leak-canary")

      {:ok, :paused, _} = APIKeys.pause_workspace(ws, user, reason: "incident")

      %{events: events} = Audit.list_events(%{event_type: "agent_keys.paused"})
      [event] = Enum.filter(events, &(&1.workspace_id == ws.id))

      sanitized = event |> Map.from_struct() |> Map.drop([:__meta__, :workspace])
      json = Jason.encode!(sanitized)

      refute json =~ raw, "raw bearer must NOT appear in agent_keys.paused audit"
      refute json =~ key.prefix, "api key prefix must NOT appear in workspace-level audit"
      refute json =~ "secret_hash"
      refute json =~ "Bearer "
    end
  end

  # --- verify_key with workspace pause (#231-a) ---------------------------

  describe "verify_key/1 with workspace pause" do
    test "returns :workspace_paused when the workspace is paused",
         %{workspace: ws, user: user} do
      {:ok, _key, raw} = APIKeys.create_key(ws, user, :operator, "paused-target")
      {:ok, :paused, _} = APIKeys.pause_workspace(ws, user)

      assert {:error, :workspace_paused} = APIKeys.verify_key(raw)
    end

    test "still returns :revoked when the key is revoked AND workspace is paused",
         %{workspace: ws, user: user} do
      # Revoke wins: the row's terminal state takes precedence over
      # the workspace overlay so audit replay surfaces the durable
      # revocation rather than a transient pause.
      {:ok, key, raw} = APIKeys.create_key(ws, user, :operator, "revoked-and-paused")
      {:ok, _} = APIKeys.revoke_key(key, actor: user)
      {:ok, :paused, _} = APIKeys.pause_workspace(ws, user)

      assert {:error, :revoked} = APIKeys.verify_key(raw)
    end

    test "still returns :expired when the key is expired AND workspace is paused",
         %{workspace: ws, user: user} do
      past = ~U[2000-01-01 00:00:00.000000Z]
      {:ok, _key, raw} = APIKeys.create_key(ws, user, :operator, "expired", expires_at: past)
      {:ok, :paused, _} = APIKeys.pause_workspace(ws, user)

      assert {:error, :expired} = APIKeys.verify_key(raw)
    end

    test "resume restores authentication for the same key",
         %{workspace: ws, user: user} do
      {:ok, _key, raw} = APIKeys.create_key(ws, user, :operator, "resumable")
      {:ok, :paused, paused} = APIKeys.pause_workspace(ws, user)
      assert {:error, :workspace_paused} = APIKeys.verify_key(raw)

      {:ok, :resumed, _} = APIKeys.resume_workspace(paused, user)

      assert {:ok, _key, _ws} = APIKeys.verify_key(raw)
    end
  end
end
