defmodule BankWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://hexdocs.pm/telemetry_metrics
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("bank.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("bank.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("bank.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("bank.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("bank.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # --- Bank runtime (v0.1 observability baseline) -----------------
      # One counter per decision outcome and risk tier so operators
      # can answer "how many auto_execs / holds / blocks in the last
      # hour" without reading audit. Emitted from
      # Bank.Runtime.Telemetry.
      counter("bank.autonomy.decision.count",
        tags: [:outcome, :risk_tier, :reason_code],
        description: "Autonomy decisions grouped by outcome and risk tier"
      ),

      # Quote provider health. Counted on every preview; tagged
      # result is :ok | :provider_unavailable | :stale |
      # :simulation_failed.
      counter("bank.quotes.preview.count",
        tags: [:provider, :result],
        description: "Quote/simulation provider calls by outcome"
      ),

      # Execution outcomes as they progress through the engine.
      counter("bank.execution.lifecycle.count",
        tags: [:status],
        description:
          "Execution-plan transitions (prepared | broadcast | completed | failed | aborted)"
      ),

      # Emergency controls, observed for dashboard health.
      counter("bank.security.event.count",
        tags: [:event, :scope],
        description: "Pause/resume/revoke events grouped by scope"
      ),

      # Oban queue-depth: one summary per MVP queue name so operators
      # can see whether a queue is backing up without touching the DB.
      summary("oban.job.stop.duration",
        unit: {:native, :millisecond},
        tags: [:queue, :state]
      ),

      # --- Operational health (issue #37) -----------------------------
      # Emitted by Bank.Ops.Health.emit_telemetry/0, invoked by the
      # telemetry poller. `last_value` so dashboards read the current
      # value rather than aggregating across time.
      last_value("bank.ops.health.stuck_plans",
        description: "Execution plans non-terminal past threshold minutes"
      ),
      last_value("bank.ops.health.adapter_up",
        description: "1 if the adapter's /healthz returned <500, 0 otherwise"
      ),
      last_value("bank.ops.health.database_up",
        description: "1 if SELECT 1 succeeded, 0 otherwise"
      )
    ]
  end

  defp periodic_measurements do
    [
      {Bank.Ops.Health, :emit_telemetry, []}
    ]
  end
end
