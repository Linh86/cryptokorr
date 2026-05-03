defmodule Bank.Runtime.Workers.RefreshAdapterHealth do
  @moduledoc """
  Periodic refresh of the cached adapter health snapshot (#229).

  Runs on the Oban cron every minute (configured in
  `config/config.exs`) and calls
  `Bank.Ops.AdapterHealthSnapshot.refresh/0`. The snapshot module
  rescues exceptions and degrades the cached snapshot accordingly,
  so per-tick failures do not propagate up to Oban's retry path.

  The worker itself never reads the live result — UI callers
  should hit `Bank.Ops.AdapterHealthSnapshot.snapshot/0`, which is
  a single ETS lookup and never blocks.

  ## Idempotency

  Each tick overwrites the single cached row keyed by
  `:latest`. Two overlapping ticks are coalesced via
  `unique: [period: {45, :seconds}]` so a delayed Oban worker
  does not pile up duplicate probes.

  ## No audit / no broadcast

  This worker is a pure cache refresher. It does not emit audit
  events or PubSub broadcasts — operator UI surfaces should poll
  `snapshot/0` or be wired to whatever telemetry the underlying
  `Bank.Ops.Health.adapter/0` already emits.
  """

  use Oban.Worker,
    queue: :ops_scan,
    max_attempts: 3,
    unique: [period: {45, :seconds}, fields: [:worker, :args]]

  alias Bank.Ops.AdapterHealthSnapshot

  @impl Oban.Worker
  def perform(%Oban.Job{args: _args}) do
    _ = AdapterHealthSnapshot.refresh()
    :ok
  end
end
