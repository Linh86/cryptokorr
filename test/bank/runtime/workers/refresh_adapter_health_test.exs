defmodule Bank.Runtime.Workers.RefreshAdapterHealthTest do
  # async: false because the supervised AdapterHealthSnapshot ETS
  # cache is global and tests share it.
  use ExUnit.Case, async: false
  use Oban.Testing, repo: Bank.Repo

  alias Bank.Ops.AdapterHealthSnapshot
  alias Bank.Runtime.Workers.RefreshAdapterHealth

  setup do
    :ok = AdapterHealthSnapshot.reset()
    :ok
  end

  describe "perform/1" do
    test "calls AdapterHealthSnapshot.refresh and updates the cache" do
      # The default `health_fn` inside `refresh/1` is
      # `&Bank.Ops.Health.adapter/0`, which would try to hit the
      # adapter base_url. In :test that base_url is unconfigured (or
      # configured to a local stub), so it lands in the
      # `not_configured` / `transport_error` branch — either way the
      # snapshot must move out of `:unknown`. We assert just that
      # change here; the snapshot module's tests cover the per-branch
      # classification.
      bootstrap = AdapterHealthSnapshot.snapshot()
      assert bootstrap.status == :unknown
      assert is_nil(bootstrap.checked_at)

      assert :ok = perform_job(RefreshAdapterHealth, %{})

      after_run = AdapterHealthSnapshot.snapshot()
      assert after_run.status in [:ok, :degraded]
      assert %DateTime{} = after_run.checked_at
      assert after_run.source == :cache
    end

    test "tolerates running twice in a row (idempotent overwrite)" do
      assert :ok = perform_job(RefreshAdapterHealth, %{})
      first = AdapterHealthSnapshot.snapshot()

      assert :ok = perform_job(RefreshAdapterHealth, %{})
      second = AdapterHealthSnapshot.snapshot()

      # Both runs land a snapshot; the second is no earlier than
      # the first.
      assert %DateTime{} = first.checked_at
      assert %DateTime{} = second.checked_at
      assert DateTime.compare(second.checked_at, first.checked_at) in [:gt, :eq]
    end
  end
end
