defmodule Bank.Runtime.Workers.SweepExpiredPausesTest do
  # async: false because the in-memory PauseState GenServer is global
  # and the workspace fixture mutates a shared process dict slot.
  use Bank.DataCase, async: false
  use Oban.Testing, repo: Bank.Repo

  import Ecto.Query

  alias Bank.Audit.AuditEvent
  alias Bank.Repo
  alias Bank.Runtime.Workers.SweepExpiredPauses
  alias Bank.Security.Pauses

  describe "perform/1" do
    test "expires an active pause whose expires_at <= now" do
      ws = create_workspace!("sweep-expire")
      user = create_user!()
      expires_at = DateTime.utc_now() |> DateTime.add(60, :second)

      {:ok, :paused, pause} =
        Pauses.create_pause(ws.id, :chain, "base", actor: user, expires_at: expires_at)

      now = DateTime.utc_now() |> DateTime.add(120, :second)

      assert :ok = perform_job(SweepExpiredPauses, %{"now" => DateTime.to_iso8601(now)})

      refute Pauses.paused?(ws.id, :chain, "base")
      assert audit_count("security.scope_expired", ws.id) == 1

      reloaded = Repo.get!(Bank.Security.Pause, pause.id)
      assert DateTime.compare(reloaded.resumed_at, expires_at) == :eq
    end

    test "leaves not-yet-expired active pauses untouched" do
      ws = create_workspace!("sweep-future")
      user = create_user!()
      expires_at = DateTime.utc_now() |> DateTime.add(7200, :second)

      {:ok, :paused, _} =
        Pauses.create_pause(ws.id, :chain, "base", actor: user, expires_at: expires_at)

      now = DateTime.utc_now() |> DateTime.add(60, :second)

      assert :ok = perform_job(SweepExpiredPauses, %{"now" => DateTime.to_iso8601(now)})

      assert Pauses.paused?(ws.id, :chain, "base")
      assert audit_count("security.scope_expired", ws.id) == 0
    end

    test "leaves pauses with no expires_at untouched" do
      ws = create_workspace!("sweep-no-expiry")
      user = create_user!()

      {:ok, :paused, _} = Pauses.create_pause(ws.id, :chain, "base", actor: user)

      now = DateTime.utc_now() |> DateTime.add(7200, :second)

      assert :ok = perform_job(SweepExpiredPauses, %{"now" => DateTime.to_iso8601(now)})

      assert Pauses.paused?(ws.id, :chain, "base")
      assert audit_count("security.scope_expired", ws.id) == 0
    end

    test "leaves already-resumed rows untouched" do
      ws = create_workspace!("sweep-already-resumed")
      user = create_user!()
      expires_at = DateTime.utc_now() |> DateTime.add(60, :second)

      {:ok, :paused, _} =
        Pauses.create_pause(ws.id, :chain, "base", actor: user, expires_at: expires_at)

      {:ok, :resumed, _} = Pauses.resume(ws.id, :chain, "base", actor: user)

      now = DateTime.utc_now() |> DateTime.add(120, :second)

      assert :ok = perform_job(SweepExpiredPauses, %{"now" => DateTime.to_iso8601(now)})

      # The operator-driven resume already emitted security.scope_resumed;
      # the sweeper must NOT emit a second security.scope_expired.
      assert audit_count("security.scope_expired", ws.id) == 0
    end

    test "second sweep over the same row emits no second audit / broadcast" do
      ws = create_workspace!("sweep-idem")
      user = create_user!()
      expires_at = DateTime.utc_now() |> DateTime.add(60, :second)

      {:ok, :paused, _} =
        Pauses.create_pause(ws.id, :chain, "base", actor: user, expires_at: expires_at)

      now = DateTime.utc_now() |> DateTime.add(120, :second)

      assert :ok = perform_job(SweepExpiredPauses, %{"now" => DateTime.to_iso8601(now)})
      assert :ok = perform_job(SweepExpiredPauses, %{"now" => DateTime.to_iso8601(now)})

      assert audit_count("security.scope_expired", ws.id) == 1
    end

    test "handles sibling workspaces independently" do
      a = create_workspace!("sweep-iso-a")
      b = create_workspace!("sweep-iso-b")
      user = create_user!()
      expires_at = DateTime.utc_now() |> DateTime.add(60, :second)
      far = DateTime.utc_now() |> DateTime.add(7200, :second)

      {:ok, :paused, _} =
        Pauses.create_pause(a.id, :chain, "base", actor: user, expires_at: expires_at)

      {:ok, :paused, _} =
        Pauses.create_pause(b.id, :chain, "base", actor: user, expires_at: far)

      now = DateTime.utc_now() |> DateTime.add(120, :second)

      assert :ok = perform_job(SweepExpiredPauses, %{"now" => DateTime.to_iso8601(now)})

      refute Pauses.paused?(a.id, :chain, "base")
      assert Pauses.paused?(b.id, :chain, "base")

      assert audit_count("security.scope_expired", a.id) == 1
      assert audit_count("security.scope_expired", b.id) == 0
    end

    test "rejects malformed ISO 8601 `now` arg" do
      assert_raise ArgumentError, fn ->
        perform_job(SweepExpiredPauses, %{"now" => "not-an-iso"})
      end
    end
  end

  # ---- helpers ----

  defp create_workspace!(slug_suffix) do
    suffix = System.unique_integer([:positive])

    {:ok, ws} =
      Bank.Workspaces.create_workspace(%{
        slug: "#{slug_suffix}-#{suffix}",
        name: "WS #{slug_suffix} #{suffix}"
      })

    ws
  end

  defp create_user! do
    suffix = System.unique_integer([:positive])

    {:ok, user} =
      Bank.Accounts.find_or_create_from_oauth(%{
        provider: :google,
        subject: "sweep-test-#{suffix}",
        email: "sweep-test-#{suffix}@example.com",
        name: "Sweep Test #{suffix}"
      })

    user
  end

  defp audit_count(event_type, workspace_id) do
    Repo.aggregate(
      from(e in AuditEvent,
        where: e.event_type == ^event_type and e.workspace_id == ^workspace_id
      ),
      :count,
      :id
    )
  end
end
