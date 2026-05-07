defmodule Bank.Runtime.Workers.AggregateAPIKeyUsageTest do
  @moduledoc """
  Coverage for `Bank.Runtime.Workers.AggregateAPIKeyUsage` (#218d).
  """

  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Ecto.Query, only: [from: 2]

  alias Bank.APIKeys
  alias Bank.APIKeys.APIKey
  alias Bank.Audit
  alias Bank.Runtime.Workers.AggregateAPIKeyUsage
  alias Bank.Workspaces

  defp ws_user_key(name) do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "agg-#{suffix}",
        email: "agg-#{suffix}@example.com",
        name: "Agg #{name}"
      })

    {:ok, ws} = Workspaces.create_workspace(%{slug: "agg-#{suffix}", name: "Agg #{name}"})

    {:ok, _} =
      Workspaces.create_membership(%{user_id: user.id, workspace_id: ws.id, role: :admin})

    {:ok, key, _raw} = APIKeys.create_key(ws, user, :operator, "agg-#{name}-#{suffix}")
    %{ws: ws, user: user, key: key}
  end

  defp stamp_last_used(api_key, %DateTime{} = ts) do
    {1, _} =
      Bank.Repo.update_all(
        from(k in APIKey, where: k.id == ^api_key.id),
        set: [last_used_at: ts]
      )

    Bank.Repo.get!(APIKey, api_key.id)
  end

  defp args_for(%DateTime{} = window_start, %DateTime{} = window_end) do
    %{
      "window_start" => DateTime.to_iso8601(window_start),
      "window_end" => DateTime.to_iso8601(window_end)
    }
  end

  describe "perform/1 emits one api_key.used per key in the window" do
    test "emits for keys touched inside the window; ignores keys outside" do
      window_start = ~U[2026-04-30 00:00:00.000000Z]
      window_end = ~U[2026-05-01 00:00:00.000000Z]

      %{key: key_in, ws: ws} = ws_user_key("in")
      stamp_last_used(key_in, ~U[2026-04-30 12:00:00.000000Z])

      %{key: key_before} = ws_user_key("before")
      stamp_last_used(key_before, ~U[2026-04-29 23:59:59.999999Z])

      %{key: key_after} = ws_user_key("after")
      stamp_last_used(key_after, ~U[2026-05-01 00:00:00.000001Z])

      %{key: key_unused} = ws_user_key("unused")

      assert :ok =
               perform_job(AggregateAPIKeyUsage, args_for(window_start, window_end))

      %{events: events} = Audit.list_events(%{event_type: "api_key.used"})

      ids = events |> Enum.map(& &1.subject_id) |> MapSet.new()

      assert key_in.id in ids
      refute key_before.id in ids
      refute key_after.id in ids
      refute key_unused.id in ids

      # Stamping invariant — workspace passthrough lands on the row.
      [in_event] = Enum.filter(events, &(&1.subject_id == key_in.id))
      assert in_event.workspace_id == ws.id
      assert in_event.actor == :agent
      assert in_event.actor_id == key_in.id
    end
  end

  describe "perform/1 idempotency" do
    test "is a no-op on a re-run for the same window" do
      window_start = ~U[2026-04-30 00:00:00.000000Z]
      window_end = ~U[2026-05-01 00:00:00.000000Z]

      %{key: key} = ws_user_key("idem")
      stamp_last_used(key, ~U[2026-04-30 12:00:00.000000Z])

      :ok = perform_job(AggregateAPIKeyUsage, args_for(window_start, window_end))
      :ok = perform_job(AggregateAPIKeyUsage, args_for(window_start, window_end))

      %{events: events} = Audit.list_events(%{event_type: "api_key.used"})
      events = Enum.filter(events, &(&1.subject_id == key.id))

      assert length(events) == 1, "second run must NOT emit a duplicate api_key.used"
    end

    test "a NEW window emits a new event for the same key" do
      window_a_start = ~U[2026-04-30 00:00:00.000000Z]
      window_a_end = ~U[2026-05-01 00:00:00.000000Z]
      window_b_start = ~U[2026-05-01 00:00:00.000000Z]
      window_b_end = ~U[2026-05-02 00:00:00.000000Z]

      %{key: key} = ws_user_key("two-windows")

      # First window — usage on day 1
      stamp_last_used(key, ~U[2026-04-30 12:00:00.000000Z])
      :ok = perform_job(AggregateAPIKeyUsage, args_for(window_a_start, window_a_end))

      # Second window — usage on day 2
      stamp_last_used(key, ~U[2026-05-01 12:00:00.000000Z])
      :ok = perform_job(AggregateAPIKeyUsage, args_for(window_b_start, window_b_end))

      %{events: events} = Audit.list_events(%{event_type: "api_key.used"})
      events = Enum.filter(events, &(&1.subject_id == key.id))

      assert length(events) == 2
    end

    test "audit M8: SQL-level partial unique index dedupes parallel emitters bypassing pre-check" do
      # Manual back-fill paralleling cron previously broke
      # idempotency at the SQL layer — the per-key pre-check is
      # SELECT-then-INSERT, not atomic. With the
      # `audit_events_recurring_dedupe_idx` partial unique index in
      # place and `dedupe: :recurring_window` on the writer, two
      # inserts of the same `(subject_id, after_ref->>'window_start')`
      # row collapse to one.
      window_start = ~U[2026-04-30 00:00:00.000000Z]
      window_end = ~U[2026-05-01 00:00:00.000000Z]

      %{key: key} = ws_user_key("m8-dedupe")

      attrs =
        Bank.Audit.Events.api_key_used(key, %{
          window_start: window_start,
          window_end: window_end,
          last_used_at: ~U[2026-04-30 12:00:00.000000Z]
        })

      assert {:ok, %Bank.Audit.AuditEvent{}} =
               Bank.Audit.append_event(attrs, dedupe: :recurring_window)

      assert {:ok, :already_exists} =
               Bank.Audit.append_event(attrs, dedupe: :recurring_window)

      window_iso = DateTime.to_iso8601(window_start)

      assert Bank.Repo.aggregate(
               from(e in Bank.Audit.AuditEvent,
                 where:
                   e.event_type == "api_key.used" and
                     e.subject_id == ^key.id and
                     fragment("?->>'window_start' = ?", e.after_ref, ^window_iso)
               ),
               :count
             ) == 1
    end
  end

  describe "secret hygiene" do
    test "the audit event JSON does not contain `cb_` (raw key prefix) anywhere" do
      window_start = ~U[2026-04-30 00:00:00.000000Z]
      window_end = ~U[2026-05-01 00:00:00.000000Z]

      %{key: key} = ws_user_key("hygiene")
      stamp_last_used(key, ~U[2026-04-30 12:00:00.000000Z])

      :ok = perform_job(AggregateAPIKeyUsage, args_for(window_start, window_end))

      %{events: events} = Audit.list_events(%{event_type: "api_key.used"})
      [event] = Enum.filter(events, &(&1.subject_id == key.id))

      sanitized = event |> Map.from_struct() |> Map.drop([:__meta__, :workspace])
      json = Jason.encode!(sanitized)

      refute json =~ "cb_"
      refute json =~ "secret_hash"
    end
  end
end
