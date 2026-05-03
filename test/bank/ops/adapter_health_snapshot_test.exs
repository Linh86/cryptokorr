defmodule Bank.Ops.AdapterHealthSnapshotTest do
  # async: false because the supervised GenServer + ETS table are
  # global; tests share state and reset between runs.
  use ExUnit.Case, async: false

  alias Bank.Ops.AdapterHealthSnapshot

  setup do
    # The application starts AdapterHealthSnapshot under
    # supervision, so it is already running. Reset the cache to the
    # bootstrap snapshot before each test so an earlier test's
    # write does not bleed in.
    :ok = AdapterHealthSnapshot.reset()
    :ok
  end

  describe "snapshot/0 (no prior refresh)" do
    test "returns the bootstrap :unknown snapshot, never blocks" do
      snap = AdapterHealthSnapshot.snapshot()

      assert snap.status == :unknown
      assert is_nil(snap.detail)
      assert is_nil(snap.http_status)
      assert is_nil(snap.checked_at)
      assert snap.source == :cache
    end

    test "snapshot/0 does not invoke the live adapter check" do
      counter = :counters.new(1, [])

      probe_fn = fn ->
        :counters.add(counter, 1, 1)
        %{status: :ok, detail: "http 200"}
      end

      # We never refresh; reading must not call the probe.
      _ = AdapterHealthSnapshot.snapshot()
      _ = AdapterHealthSnapshot.snapshot()
      _ = AdapterHealthSnapshot.snapshot()

      assert :counters.get(counter, 1) == 0

      # Now refresh once with the injected fn — counter advances by
      # exactly one, proving the probe is gated on refresh, not
      # snapshot.
      _ = AdapterHealthSnapshot.refresh(health_fn: probe_fn)
      assert :counters.get(counter, 1) == 1

      _ = AdapterHealthSnapshot.snapshot()
      _ = AdapterHealthSnapshot.snapshot()
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "refresh/1" do
    test "stores a sanitized OK snapshot from a successful probe" do
      probe_fn = fn -> %{status: :ok, detail: "http 200"} end

      assert %{status: :ok} = AdapterHealthSnapshot.refresh(health_fn: probe_fn)

      snap = AdapterHealthSnapshot.snapshot()
      assert snap.status == :ok
      assert snap.detail == "ok"
      assert snap.http_status == 200
      assert %DateTime{} = snap.checked_at
      assert snap.source == :cache
    end

    test "5xx response classifies as :degraded with adapter_5xx detail" do
      probe_fn = fn -> %{status: :error, detail: "adapter 5xx: 503"} end

      _ = AdapterHealthSnapshot.refresh(health_fn: probe_fn)
      snap = AdapterHealthSnapshot.snapshot()

      assert snap.status == :degraded
      assert snap.detail == "adapter_5xx"
      assert snap.http_status == 503
    end

    test "transport-level error sanitizes raw inspect to transport_error" do
      # `Health.adapter/0` would build this detail via `inspect(reason)`
      # for a Req transport error. Snapshot must NOT propagate that
      # raw text to consumers.
      raw_detail =
        ~s({:transport_error, %{url: "https://[email protected]/healthz", reason: :econnrefused}})

      probe_fn = fn -> %{status: :error, detail: raw_detail} end

      _ = AdapterHealthSnapshot.refresh(health_fn: probe_fn)
      snap = AdapterHealthSnapshot.snapshot()

      assert snap.status == :degraded
      assert snap.detail == "transport_error"
      assert is_nil(snap.http_status)

      # JSON-scan: nothing leaked into the cached snapshot.
      json = Jason.encode!(snap)

      for needle <- ["secret", "@adapter", "Bearer", "Authorization", "0x", "https://"] do
        refute String.contains?(json, needle),
               "snapshot must not leak #{needle}: #{inspect(json)}"
      end
    end

    test "missing-config error classifies as not_configured" do
      probe_fn = fn -> %{status: :error, detail: "adapter base_url not configured"} end

      _ = AdapterHealthSnapshot.refresh(health_fn: probe_fn)
      snap = AdapterHealthSnapshot.snapshot()

      assert snap.status == :degraded
      assert snap.detail == "not_configured"
      assert is_nil(snap.http_status)
    end

    test "raised exception in probe collapses to degraded :error without crashing the cache" do
      probe_fn = fn -> raise "boom" end

      assert %{status: :degraded, detail: "error"} =
               AdapterHealthSnapshot.refresh(health_fn: probe_fn)

      snap = AdapterHealthSnapshot.snapshot()
      assert snap.status == :degraded
      assert snap.detail == "error"
      assert snap.source == :cache

      # The GenServer is still alive and responsive.
      assert is_pid(Process.whereis(AdapterHealthSnapshot))
    end

    test "exit in probe also collapses cleanly" do
      probe_fn = fn -> exit(:kaboom) end

      _ = AdapterHealthSnapshot.refresh(health_fn: probe_fn)
      snap = AdapterHealthSnapshot.snapshot()
      assert snap.status == :degraded
      assert snap.detail == "error"
      assert is_pid(Process.whereis(AdapterHealthSnapshot))
    end

    test "refresh overwrites the cached row, not appends" do
      _ = AdapterHealthSnapshot.refresh(health_fn: fn -> %{status: :ok, detail: "http 200"} end)

      _ =
        AdapterHealthSnapshot.refresh(
          health_fn: fn -> %{status: :error, detail: "adapter 5xx: 502"} end
        )

      snap = AdapterHealthSnapshot.snapshot()
      assert snap.status == :degraded
      assert snap.http_status == 502
    end

    test "unrecognised probe shape collapses to degraded :error" do
      probe_fn = fn -> %{not: "the expected shape"} end

      _ = AdapterHealthSnapshot.refresh(health_fn: probe_fn)
      snap = AdapterHealthSnapshot.snapshot()
      assert snap.status == :degraded
      assert snap.detail == "error"
    end
  end
end
