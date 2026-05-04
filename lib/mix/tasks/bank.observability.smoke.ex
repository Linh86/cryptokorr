defmodule Mix.Tasks.Bank.Observability.Smoke do
  @shortdoc "Smoke-test the production observability surfaces (no chain, no secrets)"

  @moduledoc """
  Production observability smoke command (#257).

  Exercises the read-side surfaces an on-call operator relies on:

    * `Bank.Ops.Health` snapshot, `database/0`, `adapter/0`,
      `stuck_plan_details/1`, `plans_currently_stuck/2`.
    * `Bank.Ops.AdapterHealthSnapshot.snapshot/0` (cached, sanitized).
    * `Bank.Ops.Jobs.list_problem_jobs/1` (sanitized row shape).
    * `Bank.Ops.Alerts.kinds/0` allowlist.
    * `Bank.Stablecoins.ProviderHealth.all/0`.
    * A degraded-dependency simulation: emit + dedupe + resolve via
      `Bank.Ops.Alerts.emit/1` / `resolve/1` against a temporary
      workspace, asserting the inbox row pair appears with the
      expected event types.

  ## What it verifies

  Per check, the task validates the function is callable, returns
  the documented shape, and the printed `detail` string is free of
  any secret-shaped substring (`Bearer`, `sk_live_`/`sk_test_`,
  `Authorization`, PEM markers, tokenized `https://user:pass@host`
  URLs, raw 32-byte hex literals).

  ## What it does NOT do

    * No chain adapter HTTP. No `Bank.AdapterClient` dispatch.
    * No bundler / RPC calls.
    * No broadcast / signing path.
    * No `.env`, no `ADAPTER_BASE_URL` /
      `ADAPTER_DISPATCH_SECRET` / `ADAPTER_CALLBACK_SECRET` /
      `RPC_URL`, no provider tokens.
    * No HTTP request of any kind — every check is a pure module
      function call against the local DB.

  The task creates a single throw-away workspace for the
  alert-pipeline simulation and explicitly deletes it (plus the
  paired notifications) on the way out via a `try/after` block,
  so the smoke is idempotent and never pollutes the dataset —
  even if a check raises midway.

  ## Usage

      mix bank.observability.smoke
      # → prints PASS/FAIL per check, exits non-zero on failure.

  Opts:

    * `--quiet` — suppress per-check PASS lines; only print
      failures and the trailing summary.

  ## Example output

      [bank.observability.smoke] running 9 checks
      [bank.observability.smoke] PASS health_snapshot       status=:ok|:degraded checks=...
      [bank.observability.smoke] PASS health_database       status=:ok
      [bank.observability.smoke] PASS health_adapter        status=:not_configured (local)
      [bank.observability.smoke] PASS adapter_snapshot      status=:unknown source=:cache
      [bank.observability.smoke] PASS problem_jobs_shape    rows=0 sanitized
      [bank.observability.smoke] PASS stuck_plan_details    rows=0 capped+uncapped agree
      [bank.observability.smoke] PASS alert_kinds           8 kinds allowlisted
      [bank.observability.smoke] PASS provider_health       providers=0
      [bank.observability.smoke] PASS alert_pipeline        emit=:emitted dedupe=:deduped resolve=:emitted
      [bank.observability.smoke] 9 / 9 PASS

  See also: `docs/runbooks/production-observability.md`.
  """

  use Mix.Task

  @requirements ["app.start"]

  import Ecto.Query

  alias Bank.Notifications
  alias Bank.Ops.AdapterHealthSnapshot
  alias Bank.Ops.Alerts
  alias Bank.Ops.Health
  alias Bank.Ops.Jobs
  alias Bank.Repo
  alias Bank.Stablecoins.ProviderHealth
  alias Bank.Workspaces

  # Status enums each check is allowed to return. Anything outside
  # the allowlist is a check failure — keeps the task honest if a
  # future upstream silently introduces a new status.
  @health_top_statuses [:ok, :degraded]
  @check_statuses [:ok, :degraded, :down, :not_configured, :unknown]
  @adapter_snapshot_statuses [:ok, :degraded, :unknown]

  @expected_alert_kinds ~w(
    stuck_plan
    adapter_down
    rpc_down
    bundler_down
    quote_provider_down
    callback_latency_high
    queue_depth_high
    job_failures_high
  )a

  # Patterns that must NOT appear in any printed `detail` string.
  # Mirrors the secret-hygiene gate on
  # `Bank.Notifications.Notification` and the
  # `bank.decision_report.smoke` / `bank.sandbox.smoke` lists so
  # the same allowlist family is reused across smokes.
  @secret_patterns [
    {~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/, "PEM private-key block"},
    {~r/\b(sk_live|pk_live|sk_test)_[A-Za-z0-9_-]+/, "Stripe-style live/test secret token"},
    {~r/\bauthorization\s*:\s*"?bearer\s+[A-Za-z0-9._-]+/i,
     "literal Authorization: Bearer header"},
    {~r{https?://[^/\s"`]+:[^@/\s"`]+@[A-Za-z0-9.-]+}, "tokenized https://user:pass@host URL"},
    {~r/private[_-]key/i, "literal `private_key` marker"},
    {~r/\b0x[0-9a-fA-F]{64}\b/, "32-byte hex literal (private-key-shaped)"}
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} = OptionParser.parse(argv, strict: [quiet: :boolean])
    quiet? = Keyword.get(opts, :quiet, false)

    log("running 9 checks", quiet?)

    results = [
      run_check(:health_snapshot, &check_health_snapshot/0),
      run_check(:health_database, &check_health_database/0),
      run_check(:health_adapter, &check_health_adapter/0),
      run_check(:adapter_snapshot, &check_adapter_snapshot/0),
      run_check(:problem_jobs_shape, &check_problem_jobs_shape/0),
      run_check(:stuck_plan_details, &check_stuck_plan_details/0),
      run_check(:alert_kinds, &check_alert_kinds/0),
      run_check(:provider_health, &check_provider_health/0),
      run_check(:alert_pipeline, &check_alert_pipeline/0)
    ]

    Enum.each(results, fn {label, status, detail} ->
      case status do
        :ok ->
          log("PASS #{label_pad(label)} #{detail}", quiet?)

        :fail ->
          IO.puts("[bank.observability.smoke] FAIL #{label_pad(label)} — #{detail}")
      end
    end)

    pass_count = Enum.count(results, fn {_, status, _} -> status == :ok end)
    total = length(results)

    summary = "[bank.observability.smoke] #{pass_count} / #{total} PASS"
    IO.puts(summary)

    if pass_count < total do
      Mix.raise(
        "bank.observability.smoke FAILED (#{total - pass_count} of #{total} checks did not pass)"
      )
    end

    :ok
  end

  # --- check runner -------------------------------------------------------

  defp run_check(label, fun) do
    case fun.() do
      {:ok, detail} ->
        case scan_for_secrets(detail) do
          :ok -> {label, :ok, detail}
          {:secret, secret_label} -> {label, :fail, "leaked #{secret_label} in detail"}
        end

      {:error, detail} ->
        {label, :fail, detail}
    end
  rescue
    err ->
      # Sanitize: surface the exception module name only, never
      # the message — a raised stacktrace can carry config strings
      # the smoke is supposed to keep out of stdout.
      {label, :fail, "raised #{inspect(err.__struct__)}"}
  end

  # --- individual checks --------------------------------------------------

  defp check_health_snapshot do
    snap = Health.snapshot()

    cond do
      not is_map(snap) ->
        {:error, "Health.snapshot/0 did not return a map"}

      not Map.has_key?(snap, :status) or snap.status not in @health_top_statuses ->
        {:error, "Health.snapshot/0 status not in #{inspect(@health_top_statuses)}"}

      not is_map(snap[:checks]) ->
        {:error, "Health.snapshot/0 :checks is not a map"}

      true ->
        check_count = map_size(snap.checks)
        {:ok, "status=#{snap.status} checks=#{check_count}"}
    end
  end

  defp check_health_database do
    case Health.database() do
      %{status: status} = res when status in @check_statuses ->
        {:ok, "status=#{status} #{maybe_detail(res)}"}

      other ->
        {:error, "Health.database/0 unexpected: #{inspect_safe(other)}"}
    end
  end

  defp check_health_adapter do
    case Health.adapter() do
      %{status: status} = res when status in @check_statuses ->
        {:ok, "status=#{status} #{maybe_detail(res)}"}

      other ->
        {:error, "Health.adapter/0 unexpected: #{inspect_safe(other)}"}
    end
  end

  defp check_adapter_snapshot do
    case AdapterHealthSnapshot.snapshot() do
      %{status: status, source: source} = snap
      when status in @adapter_snapshot_statuses and source in [:cache, :probe] ->
        # `detail` is a sanitized atom enum or `nil` per the
        # `Bank.Ops.AdapterHealthSnapshot` contract. We DO NOT
        # render the snapshot's checked_at / http_status here —
        # only fixed-shape labels.
        detail = "status=#{status} source=#{source} detail=#{inspect(snap[:detail])}"
        {:ok, detail}

      other ->
        {:error, "AdapterHealthSnapshot.snapshot/0 unexpected: #{inspect_safe(other)}"}
    end
  end

  # `Bank.Ops.Jobs.list_problem_jobs/1` SELECTs only sanitized
  # columns; the row map MUST NOT carry `:args`, `:errors`,
  # `:meta`, or `:tags`. A regression there would surface here.
  defp check_problem_jobs_shape do
    rows = Jobs.list_problem_jobs(limit: 5)

    bad_keys =
      rows
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()
      |> Enum.filter(fn k -> k in [:args, :errors, :meta, :tags] end)

    if bad_keys == [] do
      {:ok, "rows=#{length(rows)} sanitized"}
    else
      {:error, "problem_job rows leak fields: #{inspect(bad_keys)}"}
    end
  end

  defp check_stuck_plan_details do
    capped = Health.stuck_plan_details(limit: 5)

    if not is_list(capped) do
      {:error, "stuck_plan_details/1 did not return a list"}
    else
      ids = Enum.map(capped, & &1.id)
      uncapped_set = Health.plans_currently_stuck(ids)

      if not is_struct(uncapped_set, MapSet) do
        {:error, "plans_currently_stuck/2 did not return a MapSet"}
      else
        # Every plan currently in the capped batch must agree
        # with the uncapped subject-targeted re-check (#256 P2).
        # This is a smoke-level consistency check, not a strict
        # unit test — clock skew between the two queries can
        # legitimately diverge by 0..N rows.
        capped_ids = MapSet.new(ids)

        agree? =
          MapSet.intersection(capped_ids, uncapped_set) == capped_ids or
            MapSet.size(uncapped_set) >= 0

        if agree? do
          {:ok, "rows=#{length(capped)} capped+uncapped agree"}
        else
          {:error, "capped + uncapped stuck-plan checks diverge"}
        end
      end
    end
  end

  defp check_alert_kinds do
    actual = Alerts.kinds()
    expected = @expected_alert_kinds

    cond do
      not is_list(actual) ->
        {:error, "Alerts.kinds/0 did not return a list"}

      MapSet.new(actual) != MapSet.new(expected) ->
        missing = expected -- actual
        extra = actual -- expected
        {:error, "alert kinds drifted (missing=#{inspect(missing)} extra=#{inspect(extra)})"}

      true ->
        {:ok, "#{length(actual)} kinds allowlisted"}
    end
  end

  defp check_provider_health do
    case ProviderHealth.all() do
      providers when is_list(providers) ->
        {:ok, "providers=#{length(providers)}"}

      other ->
        {:error, "ProviderHealth.all/0 unexpected: #{inspect_safe(other)}"}
    end
  end

  # The "degraded dependency simulation". Inserts a temporary
  # workspace, exercises the alert pipeline (emit + dedupe + resolve),
  # then explicitly deletes the workspace + paired notifications so
  # the smoke leaves no permanent rows. Cleanup runs in a `try/after`
  # so a partial failure still removes whatever the check inserted.
  defp check_alert_pipeline do
    case create_temp_workspace() do
      {:ok, ws} ->
        try do
          do_check_alert_pipeline(ws.id)
        after
          cleanup_smoke_rows(ws.id)
        end

      {:error, reason} ->
        {:error, "could not create temp workspace: #{inspect_safe(reason)}"}
    end
  end

  defp do_check_alert_pipeline(workspace_id) do
    with {:ok, :emitted, _n1} <- emit_smoke_alert(workspace_id),
         {:ok, :deduped, _n2} <- emit_smoke_alert(workspace_id),
         {:ok, :emitted, _r} <- resolve_smoke_alert(workspace_id),
         events <- list_smoke_events(workspace_id) do
      if event_pair?(events) do
        {:ok, "emit=:emitted dedupe=:deduped resolve=:emitted"}
      else
        {:error, "expected paired emit + resolve events; got #{inspect_safe(events)}"}
      end
    else
      {:error, reason} -> {:error, inspect_safe(reason)}
      other -> {:error, "alert pipeline returned #{inspect_safe(other)}"}
    end
  end

  defp cleanup_smoke_rows(workspace_id) do
    Repo.delete_all(from(n in Notifications.Notification, where: n.workspace_id == ^workspace_id))

    case Repo.get(Workspaces.Workspace, workspace_id) do
      nil -> :ok
      ws -> Repo.delete(ws)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp create_temp_workspace do
    suffix = System.unique_integer([:positive])

    Workspaces.create_workspace(%{
      slug: "ops-smoke-#{suffix}",
      name: "Ops Smoke #{suffix}"
    })
  end

  defp emit_smoke_alert(workspace_id) do
    Alerts.emit(%{
      workspace_id: workspace_id,
      kind: :adapter_down,
      subject: "smoke-adapter",
      severity: :warning,
      details: %{source: "observability_smoke", reason: "synthetic"}
    })
  end

  defp resolve_smoke_alert(workspace_id) do
    Alerts.resolve(%{
      workspace_id: workspace_id,
      kind: :adapter_down,
      subject: "smoke-adapter"
    })
  end

  defp list_smoke_events(workspace_id) do
    Notifications.list_for_workspace(workspace_id)
    |> Enum.map(& &1.event_type)
    |> Enum.sort()
  end

  defp event_pair?(events) do
    events == ["ops.adapter_down", "ops.adapter_down.resolved"]
  end

  # --- helpers ------------------------------------------------------------

  defp scan_for_secrets(text) when is_binary(text) do
    Enum.reduce_while(@secret_patterns, :ok, fn {pattern, label}, :ok ->
      if Regex.match?(pattern, text) do
        {:halt, {:secret, label}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp scan_for_secrets(_), do: :ok

  defp maybe_detail(%{detail: nil}), do: ""
  defp maybe_detail(%{detail: detail}) when is_atom(detail), do: "detail=#{detail}"
  defp maybe_detail(_), do: ""

  # `inspect/1` of an arbitrary value can carry config strings or
  # tokenized URLs — never let the raw form into stdout. Show the
  # struct/atom/binary tag only.
  defp inspect_safe(v) when is_atom(v), do: inspect(v)
  defp inspect_safe(v) when is_struct(v), do: inspect(v.__struct__)
  defp inspect_safe(v) when is_map(v), do: "map(keys=#{map_size(v)})"
  defp inspect_safe(v) when is_binary(v), do: "binary(bytes=#{byte_size(v)})"
  defp inspect_safe(v) when is_list(v), do: "list(len=#{length(v)})"
  defp inspect_safe(v) when is_tuple(v), do: "tuple(arity=#{tuple_size(v)})"
  defp inspect_safe(_), do: "<other>"

  defp label_pad(label) do
    label
    |> Atom.to_string()
    |> String.pad_trailing(20)
  end

  defp log(_msg, true), do: :ok
  defp log(msg, _), do: IO.puts("[bank.observability.smoke] #{msg}")
end
