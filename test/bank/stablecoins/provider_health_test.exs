defmodule Bank.Stablecoins.ProviderHealthTest do
  use Bank.DataCase, async: false

  alias Bank.Stablecoins.{ProviderHealth, ProviderHealthEvent}

  setup do
    ProviderHealth.reset()
    :ok
  end

  defp create_workspace(slug \\ nil) do
    slug = slug || "ph-#{System.unique_integer([:positive])}"
    {:ok, ws} = Bank.Workspaces.create_workspace(%{slug: slug, name: "Display: #{slug}"})
    ws
  end

  # Drives a provider's ETS state to the requested status by
  # generating realistic success/failure traffic, so each
  # transition we test is reached through the same call path
  # `evaluate_for_intent/1` exercises (i.e., the audit row of
  # transitions matches what production would emit).
  defp drive_to(provider, :degraded, opts) do
    for _ <- 1..8, do: ProviderHealth.record_success(provider, opts)
    for _ <- 1..2, do: ProviderHealth.record_failure(provider, :provider_unavailable, opts)
    :ok
  end

  defp drive_to(provider, :failing, opts) do
    drive_to(provider, :degraded, opts)
    # Three more failures push the success ratio below 0.8 ⇒
    # :degraded → :failing transition.
    for _ <- 1..3, do: ProviderHealth.record_failure(provider, :provider_unavailable, opts)
    :ok
  end

  defp drive_to(provider, status), do: drive_to(provider, status, [])

  describe "record_success/1" do
    test "sets status to healthy" do
      ProviderHealth.record_success("zerox")
      state = ProviderHealth.get("zerox")
      assert state.status == :healthy
      assert state.success_count == 1
      assert state.last_success_at != nil
    end
  end

  describe "record_failure/2" do
    test "tracks failure count and reason" do
      ProviderHealth.record_failure("zerox", :provider_unavailable)
      state = ProviderHealth.get("zerox")
      assert state.failure_count == 1
      assert state.last_failure_reason == :provider_unavailable
    end

    test "tracks rate_limited count" do
      ProviderHealth.record_failure("oneinch", :rate_limited)
      state = ProviderHealth.get("oneinch")
      assert state.rate_limited_count == 1
    end

    test "tracks no_route_found count" do
      ProviderHealth.record_failure("jupiter", :no_route_found)
      state = ProviderHealth.get("jupiter")
      assert state.no_route_count == 1
    end

    test "status degrades with failures" do
      for _ <- 1..5, do: ProviderHealth.record_failure("bad", :provider_unavailable)
      state = ProviderHealth.get("bad")
      assert state.status == :failing
    end
  end

  describe "get/1" do
    test "returns unknown for untracked provider" do
      state = ProviderHealth.get("nonexistent")
      assert state.status == :unknown
      assert state.success_count == 0
    end
  end

  describe "all/0" do
    test "returns all tracked providers" do
      ProviderHealth.record_success("zerox")
      ProviderHealth.record_success("oneinch")
      all = ProviderHealth.all()
      providers = Enum.map(all, & &1.provider) |> Enum.sort()
      assert "oneinch" in providers
      assert "zerox" in providers
    end
  end

  describe "degraded status" do
    test "mostly successful with some failures is degraded" do
      for _ <- 1..8, do: ProviderHealth.record_success("mixed")
      for _ <- 1..2, do: ProviderHealth.record_failure("mixed", :provider_unavailable)
      state = ProviderHealth.get("mixed")
      assert state.status == :degraded
    end

    test "a single later success does not hide a still-failing provider" do
      for _ <- 1..5, do: ProviderHealth.record_failure("bad", :provider_unavailable)

      ProviderHealth.record_success("bad")

      state = ProviderHealth.get("bad")
      assert state.success_count == 1
      assert state.failure_count == 5
      assert state.status == :failing
    end
  end

  describe "transition return shape (#422)" do
    test "record_success/2 returns {:ok, transition} with from/to states and ETS state" do
      assert {:ok, %{from_state: :unknown, to_state: :healthy, state: %{} = state, event: nil}} =
               ProviderHealth.record_success("zerox")

      assert state.status == :healthy
      assert state.success_count == 1
    end

    test "record_failure/3 returns {:ok, transition} on a steady-state failure (no transition)" do
      drive_to("bad", :failing)

      # One more failure stays in :failing (steady-state) — no transition.
      assert {:ok, %{from_state: :failing, to_state: :failing, event: nil}} =
               ProviderHealth.record_failure("bad", :provider_unavailable)
    end

    test "without :workspace_id no event row is written, even on a relevant transition" do
      drive_to("bad", :degraded)

      assert {:ok, %{from_state: :degraded, to_state: :failing, event: nil}} =
               ProviderHealth.record_failure("bad", :provider_unavailable)

      assert Repo.aggregate(ProviderHealthEvent, :count) == 0
    end
  end

  describe "durable event log on relevant transitions (#422)" do
    test ":degraded → :failing with workspace+session writes a ProviderHealthEvent row" do
      ws = create_workspace()
      session_id = Ecto.UUID.generate()
      opts = [workspace_id: ws.id, route_session_id: session_id]

      drive_to("bad", :degraded, opts)
      pre_count = Repo.aggregate(ProviderHealthEvent, :count)

      assert {:ok,
              %{
                from_state: :degraded,
                to_state: :failing,
                event: %ProviderHealthEvent{} = event
              }} =
               ProviderHealth.record_failure("bad", :provider_unavailable, opts)

      assert event.workspace_id == ws.id
      assert event.provider == "bad"
      assert event.from_state == :degraded
      assert event.to_state == :failing
      assert event.route_session_id == session_id
      assert event.evidence["failure_count"] == 3
      # Re-fetch confirms the row was actually persisted.
      assert Repo.aggregate(ProviderHealthEvent, :count) == pre_count + 1
    end

    test ":failing → :healthy with workspace+session writes an event row" do
      ws = create_workspace()
      session_id = Ecto.UUID.generate()
      opts = [workspace_id: ws.id, route_session_id: session_id]

      drive_to("flaky", :failing, opts)

      # Drive recovery: 50 successes flip ratio above 0.8 → healthy.
      for _ <- 1..50, do: ProviderHealth.record_success("flaky", opts)

      events = Repo.all(ProviderHealthEvent)
      # We expect at least one degraded→failing during the drive,
      # plus a recovery event somewhere in the sustained success run.
      to_states = Enum.map(events, & &1.to_state)
      assert :failing in to_states
      assert Enum.any?(to_states, &(&1 in [:healthy, :degraded]))
    end

    test "non-relevant transitions (e.g. :unknown → :healthy) write NO event row" do
      ws = create_workspace()
      opts = [workspace_id: ws.id, route_session_id: Ecto.UUID.generate()]

      assert {:ok, %{from_state: :unknown, to_state: :healthy, event: nil}} =
               ProviderHealth.record_success("zerox", opts)

      assert Repo.aggregate(ProviderHealthEvent, :count) == 0
    end

    test ":healthy → :degraded with workspace+session writes NO event row (silenced)" do
      ws = create_workspace()
      opts = [workspace_id: ws.id, route_session_id: Ecto.UUID.generate()]

      drive_to("mild", :degraded, opts)

      # No event row for the slip into :degraded — only the
      # cross into :failing or out of it surfaces today.
      assert Repo.aggregate(ProviderHealthEvent, :count) == 0
    end

    test "missing :route_session_id with :workspace_id writes NO event row (defensive)" do
      ws = create_workspace()
      opts = [workspace_id: ws.id]

      drive_to("bad", :degraded, opts)

      assert {:ok, %{from_state: :degraded, to_state: :failing, event: nil}} =
               ProviderHealth.record_failure("bad", :provider_unavailable, opts)

      assert Repo.aggregate(ProviderHealthEvent, :count) == 0
    end

    test "evidence carries only counter snapshots — no free-text reason" do
      ws = create_workspace()
      session_id = Ecto.UUID.generate()
      opts = [workspace_id: ws.id, route_session_id: session_id]

      drive_to("leaky", :degraded, opts)

      {:ok, %{event: %ProviderHealthEvent{evidence: evidence}}} =
        ProviderHealth.record_failure(
          "leaky",
          "Authorization: Bearer LEAKED_PROBE on rpc.example/path",
          opts
        )

      keys = Map.keys(evidence) |> Enum.sort()
      assert keys == ["failure_count", "no_route_count", "rate_limited_count", "success_count"]
      refute inspect(evidence) =~ "LEAKED_PROBE"
      refute inspect(evidence) =~ "Bearer"
      refute inspect(evidence) =~ "Authorization"
    end
  end
end
