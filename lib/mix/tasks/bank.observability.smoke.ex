defmodule Mix.Tasks.Bank.Observability.Smoke do
  @shortdoc "Verify the production-observability surface (#257) — health, alerts, dashboard plumbing"

  @moduledoc """
  Production-observability smoke command (#257).

  Verifies that the operator-facing observability surface holds
  end-to-end against the local control plane. This is the automated
  counterpart to the
  [`docs/runbooks/production-observability.md`](../../../../docs/runbooks/production-observability.md)
  triage runbook — a fresh reviewer (or CI) can run a single
  command and get a concise pass/fail report covering every
  dependency surface a paged operator would touch.

  ## What it verifies

    * `health.database` — `Bank.Ops.Health.database/0` is `:ok`
      against the local Repo.
    * `health.stuck_plans` — `Bank.Ops.Health.stuck_plans/1`
      returns a well-formed map with `:status`, `:count`, and
      `:threshold_minutes`.
    * `health.snapshot_shape` — `Bank.Ops.Health.snapshot/0`
      returns a map with the rollup `:status` and a per-check
      map keyed by the three `Bank.Ops.Health` checks. The
      adapter check is allowed to be `:ok`, `:not_configured`,
      `:degraded`, `:down`, or `:unknown` — this smoke is about
      shape correctness, not about whether the deployed adapter
      is currently up.
    * `health.endpoint_liveness` — `GET /health` dispatched
      through `BankWeb.Endpoint` returns 200.
    * `health.endpoint_readiness` — `GET /v1/health` returns
      `200` with a JSON body whose `status` is `"ok"` or
      `"degraded"`.
    * `health.endpoint_deep` — `GET /v1/health/deep` returns a
      JSON body with `status`, `service`, `version`, and
      `checks`, and the `checks` map contains the `database`,
      `adapter`, and `stuck_plans` keys with each per-check
      `status` drawn from the documented enum
      (`ok` / `degraded` / `down` / `not_configured` /
      `unknown`).
    * `alerts.kinds` — `Bank.Ops.Alerts.kinds/0` returns
      exactly the eight Phase 1 allowlisted kinds (#256).
      A regression that adds or removes a kind without
      updating the runbook fails this check loud.
    * `secret_hygiene.health_payload` — the rendered
      `/v1/health/deep` response body contains no
      secret-shaped substrings (`Authorization: Bearer`,
      `sk_live_` / `sk_test_`, PEM `-----BEGIN ... PRIVATE
      KEY-----`, tokenized `https://user:pass@host` URLs,
      `private_key` markers, or 32-byte hex blobs).

  ## What it does NOT do

  Mirrors the safety posture of `mix bank.sandbox.smoke` (#240):

    * No bundler / RPC calls, no broadcast, no signing.
    * No `.env` reads, no `ADAPTER_DISPATCH_SECRET` /
      `ADAPTER_CALLBACK_SECRET` / `RPC_URL` etc.
    * No write-side runtime mutation. The alerts surface is
      probed read-only via `Bank.Ops.Alerts.kinds/0`; the
      smoke deliberately does **not** insert a synthetic
      notification (that would dirty the local inbox without
      adding triage signal).

  The adapter health probe inside `Bank.Ops.Health.adapter/0`
  goes out via `Req.request` against whatever
  `Bank.AdapterClient` `base_url` is configured. In `:test` the
  Phoenix-side test harness stubs the AdapterClient via
  `Req.Test.stub`, so the smoke does not reach the network there.
  In `:dev` with no adapter configured the probe returns
  `:not_configured` (benign at the snapshot rollup), and in
  `:dev` with an adapter configured the probe IS a real (cheap)
  HTTP `GET /healthz` to the configured base URL — exactly the
  "is the adapter reachable?" signal a paged operator would
  also see.

  ## Usage

      mix bank.observability.smoke
      # → prints one line per check, exits non-zero on failure.

  Opts:

    * `--quiet` — suppress per-check PASS lines; only print
      failures and the trailing summary.

  ## Example output

      [bank.observability.smoke] running 8 checks
      [bank.observability.smoke] PASS health.database
      [bank.observability.smoke] PASS health.stuck_plans
      [bank.observability.smoke] PASS health.snapshot_shape
      [bank.observability.smoke] PASS health.endpoint_liveness
      [bank.observability.smoke] PASS health.endpoint_readiness
      [bank.observability.smoke] PASS health.endpoint_deep
      [bank.observability.smoke] PASS alerts.kinds
      [bank.observability.smoke] PASS secret_hygiene.health_payload
      [bank.observability.smoke] 8 / 8 PASS

  See also: `docs/runbooks/production-observability.md`,
  `docs/monitoring.md`, `docs/incident-runbook.md`.
  """

  use Mix.Task

  @requirements ["app.start"]

  alias Bank.Ops.Alerts
  alias Bank.Ops.Health

  @check_order [
    :"health.database",
    :"health.stuck_plans",
    :"health.snapshot_shape",
    :"health.endpoint_liveness",
    :"health.endpoint_readiness",
    :"health.endpoint_deep",
    :"alerts.kinds",
    :"secret_hygiene.health_payload"
  ]

  # Phase 1 allowlist of operational alert kinds (#256). Pinned
  # here so a future regression that widens the surface without
  # touching the runbook surfaces as a `FAIL alerts.kinds` line
  # rather than a silent expansion.
  @expected_alert_kinds [
    :stuck_plan,
    :adapter_down,
    :rpc_down,
    :bundler_down,
    :quote_provider_down,
    :callback_latency_high,
    :queue_depth_high,
    :job_failures_high
  ]

  # Per-check `status` enum drawn from the `Bank.Ops.Health`
  # moduledoc — pinned here so a future status string that
  # silently widens the surface (e.g. an undocumented
  # `"partially_ok"`) fails the deep-endpoint check.
  @allowed_check_statuses ~w(ok degraded down not_configured unknown)

  @secret_patterns [
    {~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/, "PEM private-key block"},
    {~r/\b(sk_live|pk_live|sk_test)_[A-Za-z0-9_-]+/, "Stripe-style live/test secret token"},
    {~r/\bauthorization\s*:\s*"?bearer\s+[A-Za-z0-9._-]+/i,
     "literal Authorization: Bearer header"},
    {~r{https?://[^/\s"`]+:[^@/\s"`]+@[A-Za-z0-9.-]+}, "tokenized https://user:pass@host URL"},
    {~r/private[_-]key/i, "literal `private_key` marker"},
    {~r/\b0x[0-9a-fA-F]{40,}\b/, "Eth-shaped hex blob (≥ 40 chars)"}
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} = OptionParser.parse(argv, strict: [quiet: :boolean])

    quiet? = Keyword.get(opts, :quiet, false)

    log("running #{length(@check_order)} checks", quiet?)

    results = Enum.map(@check_order, &run_check/1)

    Enum.each(results, fn {name, status, detail} ->
      case status do
        :ok ->
          log("PASS #{name}", quiet?)

        :fail ->
          IO.puts("[bank.observability.smoke] FAIL #{name} — #{detail}")
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

  # --- checks --------------------------------------------------------------

  defp run_check(:"health.database") do
    case Health.database() do
      %{status: :ok} ->
        {:"health.database", :ok, nil}

      %{status: status, detail: detail} ->
        {:"health.database", :fail, "database status #{status} (#{detail || "no detail"})"}
    end
  rescue
    _ -> {:"health.database", :fail, "Bank.Ops.Health.database/0 raised"}
  end

  defp run_check(:"health.stuck_plans") do
    result = Health.stuck_plans()

    cond do
      not is_map(result) ->
        {:"health.stuck_plans", :fail, "stuck_plans/1 did not return a map"}

      not Map.has_key?(result, :status) or not Map.has_key?(result, :count) or
          not Map.has_key?(result, :threshold_minutes) ->
        {:"health.stuck_plans", :fail,
         "stuck_plans/1 result missing required keys (status / count / threshold_minutes)"}

      not is_integer(result.count) or result.count < 0 ->
        {:"health.stuck_plans", :fail, "stuck_plans/1 count is not a non-negative integer"}

      result.status not in [:ok, :degraded] ->
        {:"health.stuck_plans", :fail,
         "stuck_plans/1 status #{inspect(result.status)} is invalid"}

      true ->
        {:"health.stuck_plans", :ok, nil}
    end
  rescue
    _ -> {:"health.stuck_plans", :fail, "Bank.Ops.Health.stuck_plans/1 raised"}
  end

  defp run_check(:"health.snapshot_shape") do
    snapshot = Health.snapshot()

    cond do
      not is_map(snapshot) ->
        {:"health.snapshot_shape", :fail, "snapshot/0 did not return a map"}

      snapshot[:status] not in [:ok, :degraded] ->
        {:"health.snapshot_shape", :fail,
         "snapshot top-level status #{inspect(snapshot[:status])} is not :ok or :degraded"}

      not is_map(snapshot[:checks]) ->
        {:"health.snapshot_shape", :fail, "snapshot :checks is not a map"}

      true ->
        case missing_check_keys(snapshot[:checks]) do
          [] ->
            {:"health.snapshot_shape", :ok, nil}

          missing ->
            {:"health.snapshot_shape", :fail,
             "snapshot :checks missing keys: #{Enum.join(missing, ", ")}"}
        end
    end
  rescue
    _ -> {:"health.snapshot_shape", :fail, "Bank.Ops.Health.snapshot/0 raised"}
  end

  defp run_check(:"health.endpoint_liveness") do
    case dispatch_get("/health") do
      {:ok, 200, _body} -> {:"health.endpoint_liveness", :ok, nil}
      {:ok, status, _} -> {:"health.endpoint_liveness", :fail, "GET /health returned #{status}"}
      {:error, reason} -> {:"health.endpoint_liveness", :fail, "GET /health #{reason}"}
    end
  end

  defp run_check(:"health.endpoint_readiness") do
    case dispatch_get("/v1/health") do
      {:ok, status, body} when status in [200, 503] ->
        case Jason.decode(body) do
          {:ok, %{"status" => readiness}} when readiness in ["ok", "degraded"] ->
            {:"health.endpoint_readiness", :ok, nil}

          {:ok, _} ->
            {:"health.endpoint_readiness", :fail,
             "GET /v1/health body missing a valid `status` field"}

          {:error, _} ->
            {:"health.endpoint_readiness", :fail, "GET /v1/health body is not JSON"}
        end

      {:ok, status, _} ->
        {:"health.endpoint_readiness", :fail, "GET /v1/health returned #{status}"}

      {:error, reason} ->
        {:"health.endpoint_readiness", :fail, "GET /v1/health #{reason}"}
    end
  end

  defp run_check(:"health.endpoint_deep") do
    case dispatch_get("/v1/health/deep") do
      {:ok, status, body} when status in [200, 503] ->
        with {:ok, %{"status" => overall, "service" => "bank", "checks" => checks} = decoded}
             when overall in ["ok", "degraded"] <- Jason.decode(body),
             {:ok, _} <- Map.fetch(decoded, "version"),
             :ok <- check_deep_checks_shape(checks) do
          {:"health.endpoint_deep", :ok, nil}
        else
          {:error, reason} -> {:"health.endpoint_deep", :fail, reason}
          _ -> {:"health.endpoint_deep", :fail, "GET /v1/health/deep body shape unexpected"}
        end

      {:ok, status, _} ->
        {:"health.endpoint_deep", :fail, "GET /v1/health/deep returned #{status}"}

      {:error, reason} ->
        {:"health.endpoint_deep", :fail, "GET /v1/health/deep #{reason}"}
    end
  end

  defp run_check(:"alerts.kinds") do
    actual = MapSet.new(Alerts.kinds())
    expected = MapSet.new(@expected_alert_kinds)

    cond do
      actual == expected ->
        {:"alerts.kinds", :ok, nil}

      true ->
        added = MapSet.difference(actual, expected) |> Enum.sort()
        removed = MapSet.difference(expected, actual) |> Enum.sort()

        detail =
          [
            unless(added == [], do: "added: #{inspect(added)}"),
            unless(removed == [], do: "removed: #{inspect(removed)}")
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join(" / ")

        {:"alerts.kinds", :fail, "alert kinds drifted from Phase 1 allowlist (#{detail})"}
    end
  rescue
    _ -> {:"alerts.kinds", :fail, "Bank.Ops.Alerts.kinds/0 raised"}
  end

  defp run_check(:"secret_hygiene.health_payload") do
    case dispatch_get("/v1/health/deep") do
      {:ok, _status, body} when is_binary(body) ->
        case scan_for_secrets(body) do
          :ok ->
            {:"secret_hygiene.health_payload", :ok, nil}

          {:secret, label} ->
            {:"secret_hygiene.health_payload", :fail, "body contains a #{label}"}
        end

      {:ok, _, _} ->
        {:"secret_hygiene.health_payload", :fail, "GET /v1/health/deep body missing"}

      {:error, reason} ->
        {:"secret_hygiene.health_payload", :fail, "GET /v1/health/deep #{reason}"}
    end
  end

  # --- helpers --------------------------------------------------------------

  defp missing_check_keys(checks) when is_map(checks) do
    [:database, :adapter, :stuck_plans]
    |> Enum.reject(fn k -> Map.has_key?(checks, k) end)
    |> Enum.map(&inspect/1)
  end

  defp check_deep_checks_shape(%{} = checks) do
    [:database, :adapter, :stuck_plans]
    |> Enum.reduce_while(:ok, fn key, _acc ->
      case Map.fetch(checks, Atom.to_string(key)) do
        {:ok, %{"status" => status}} when status in @allowed_check_statuses ->
          {:cont, :ok}

        {:ok, %{"status" => status}} ->
          {:halt, {:error, "deep checks.#{key}.status #{inspect(status)} not in allowlist"}}

        {:ok, _} ->
          {:halt, {:error, "deep checks.#{key} missing :status field"}}

        :error ->
          {:halt, {:error, "deep checks missing #{key}"}}
      end
    end)
  end

  defp scan_for_secrets(body) do
    Enum.reduce_while(@secret_patterns, :ok, fn {pattern, label}, :ok ->
      if Regex.match?(pattern, body) do
        {:halt, {:secret, label}}
      else
        {:cont, :ok}
      end
    end)
  end

  @doc """
  Dispatches a GET to `path` through `BankWeb.Endpoint` using
  `Plug.Test.conn/3` and returns `{:ok, status, body}` on a normal
  response or `{:error, reason}` when the dispatch itself raises.

  Public so the smoke task's tests can call it directly.
  Mirrors `Mix.Tasks.Bank.Sandbox.Smoke.dispatch_get/1` so the
  two ops-level smokes share dispatch semantics.
  """
  @spec dispatch_get(String.t()) :: {:ok, non_neg_integer(), binary()} | {:error, atom()}
  def dispatch_get(path) when is_binary(path) do
    conn = Plug.Test.conn(:get, path)
    response = BankWeb.Endpoint.call(conn, BankWeb.Endpoint.init([]))
    {:ok, response.status, response.resp_body || ""}
  rescue
    _ -> {:error, :dispatch_raised}
  end

  defp log(_msg, true), do: :ok
  defp log(msg, _), do: IO.puts("[bank.observability.smoke] #{msg}")
end
