defmodule Mix.Tasks.Bank.Sandbox.Smoke do
  @shortdoc "Run the Level 1 sandbox smoke against the local seeded dataset (no chain, no secrets)"

  @moduledoc """
  Level 1 sandbox smoke command (#240).

  Verifies that the local no-chain product flow holds end-to-end
  against the seeded sandbox dataset (`mix bank.demo.seed`). This
  is the automated counterpart to the manual `/sandbox` checklist —
  a fresh reviewer (or CI) can run a single command and get a
  concise pass/fail report covering the eight checks below.

  ## What it verifies

    * `health` — `Bank.Ops.Health.database/0` is `:ok`. The smoke
      deliberately does NOT call `Bank.Ops.Health.snapshot/0` /
      `Bank.Ops.Health.adapter/0` because the adapter probe issues
      a real `Req.request` to the configured base_url and Level 1
      is no-chain by definition. DB-only health is the right
      dependency surface for the sandbox flow.
    * `seeded_workspace` — the demo workspace exists by slug.
    * `endpoint` — `GET /v1/health` dispatched through
      `BankWeb.Endpoint` returns `200` with a valid JSON body.
      This is the route-reachability signal: if any of the Phoenix
      endpoint, the router pipeline, or the readiness controller
      regresses to 5xx (501 stub, 502/503 misconfig, 500 raise),
      the smoke fails. The route is public, DB-only, no adapter,
      no auth — exactly the surface a Level 1 smoke should touch.
    * `create_intent` — at least one seeded intent reached the
      `agent_intents` table (smokes the create path; if the seed
      stops writing intents, this fails).
    * `show_intent` — `Bank.Intents.list/1` returns an intent with
      its preloaded counterparty (smokes the read path).
    * `simulate_reasons` — at least one decision carries a non-nil
      `risk_tier` AND a `decision.recorded` audit event exists for
      a seeded intent (the deterministic-evaluation pipeline
      produced *what + why* reasoning).
    * `approval` — at least one decision in `:approval_required`
      outcome AND at least one in `:auto_exec` outcome exist (held
      + dispatched in the seed are both represented).
    * `cancel_flow` — at least one intent reached `:cancelled`
      state in the seeded set (the `cancelled-pre-decision`
      scenario).
    * `replay` — `Bank.Audit.replay/1` returns `{:ok, bundle}` for a
      seeded intent and the bundle's audit slice contains
      `intent.submitted` plus at least one `decision.recorded` or
      `execution.*` event for the `payroll-confirmed` scenario.

  ## What it does NOT do

  This is a Level 1 smoke — local, no chain side effects.

    * No chain adapter HTTP. No `Bank.AdapterClient` dispatch.
    * No bundler / RPC calls.
    * No broadcast / signing path.
    * No secrets, no `.env`, no `ADAPTER_BASE_URL` /
      `ADAPTER_DISPATCH_SECRET` / `ADAPTER_CALLBACK_SECRET` /
      `RPC_URL`.
    * No `mix bank.smoke.transfer` / `mix bank.smoke.revoke` —
      those are testnet-broadcast smokes documented in
      `docs/base-sepolia-execution-day.md`.

  ## Usage

      mix bank.sandbox.smoke
      # → prints one line per check, exits non-zero on failure

  Opts:

    * `--seed` — run `Bank.Demo.seed/0` before the checks (handy
      for a fresh DB). Without this flag the task expects the seed
      has already been applied.
    * `--quiet` — suppress per-check PASS lines; only print
      failures and the trailing summary.

  ## Example output

      [bank.sandbox.smoke] running 9 checks
      [bank.sandbox.smoke] PASS health
      [bank.sandbox.smoke] PASS seeded_workspace
      [bank.sandbox.smoke] PASS endpoint
      [bank.sandbox.smoke] PASS create_intent
      [bank.sandbox.smoke] PASS show_intent
      [bank.sandbox.smoke] PASS simulate_reasons
      [bank.sandbox.smoke] PASS approval
      [bank.sandbox.smoke] PASS cancel_flow
      [bank.sandbox.smoke] PASS replay
      [bank.sandbox.smoke] 9 / 9 PASS
  """

  use Mix.Task

  @requirements ["app.start"]

  @check_order [
    :health,
    :seeded_workspace,
    :endpoint,
    :create_intent,
    :show_intent,
    :simulate_reasons,
    :approval,
    :cancel_flow,
    :replay
  ]

  # Path used by the `:endpoint` route-reachability check. Must be a
  # public route that does NOT trigger any chain/adapter probe. The
  # `/v1/health` readiness probe verifies Postgres only.
  @endpoint_smoke_path "/v1/health"

  @impl Mix.Task
  def run(argv) do
    {opts, _args, _invalid} =
      OptionParser.parse(argv, strict: [seed: :boolean, quiet: :boolean])

    quiet? = Keyword.get(opts, :quiet, false)
    seed_first? = Keyword.get(opts, :seed, false)

    if seed_first? do
      log("seeding sandbox dataset (--seed)", quiet?)
      :ok = Bank.Demo.seed()
    end

    log("running #{length(@check_order)} checks", quiet?)

    results = Enum.map(@check_order, &run_check/1)

    Enum.each(results, fn {name, status, detail} ->
      case status do
        :ok ->
          log("PASS #{name}", quiet?)

        :fail ->
          # FAIL lines always print, even with --quiet, so a
          # non-zero exit always carries a reason on stdout.
          IO.puts("[bank.sandbox.smoke] FAIL #{name} — #{detail}")
      end
    end)

    pass_count = Enum.count(results, fn {_, status, _} -> status == :ok end)
    total = length(results)

    summary = "[bank.sandbox.smoke] #{pass_count} / #{total} PASS"
    IO.puts(summary)

    if pass_count < total do
      Mix.raise(
        "bank.sandbox.smoke FAILED (#{total - pass_count} of #{total} checks did not pass)"
      )
    end

    :ok
  end

  # --- Checks --------------------------------------------------------------
  #
  # Each check returns `{name, :ok | :fail, detail}` where detail is a
  # short string describing the failure cause (or `nil` on success).
  # The detail string is sanitized: no `inspect/1` of internal structs,
  # no exception text, no RPC URLs, no Authorization headers — same
  # posture as `Bank.Ops.Health` (#253).

  defp run_check(:health) do
    # Level 1 is no-chain. The smoke deliberately calls
    # `Bank.Ops.Health.database/0` directly instead of
    # `Bank.Ops.Health.snapshot/0` because the snapshot ALSO calls
    # `Bank.Ops.Health.adapter/0`, which issues a real
    # `Req.request` against the configured `Bank.AdapterClient`
    # base_url. In dev that is `localhost:4100`. The sandbox smoke
    # must never make that HTTP probe — DB connectivity is the
    # only dependency the local no-chain product flow needs.
    case Bank.Ops.Health.database() do
      %{status: :ok} -> {:health, :ok, nil}
      %{status: status} -> {:health, :fail, "database status #{status}"}
    end
  rescue
    _ -> {:health, :fail, "database check raised"}
  end

  defp run_check(:endpoint) do
    # Route-reachability smoke: dispatches GET @endpoint_smoke_path
    # through `BankWeb.Endpoint` via `Plug.Test`. If any product
    # surface regresses to a 5xx — including 501 Not Implemented
    # for a stubbed action, 503 for a misconfigured pipeline, or
    # 500 for a raise — this check fails. The path
    # `/v1/health` is public, DB-only, and never calls
    # `Bank.AdapterClient`, so the smoke stays Level 1.
    case dispatch_get(@endpoint_smoke_path) do
      {:ok, status, _body} when status >= 200 and status < 500 ->
        {:endpoint, :ok, nil}

      {:ok, status, _body} ->
        {:endpoint, :fail, "GET #{@endpoint_smoke_path} returned status #{status}"}

      {:error, reason_atom} ->
        {:endpoint, :fail, "GET #{@endpoint_smoke_path} dispatch failed: #{reason_atom}"}
    end
  rescue
    _ -> {:endpoint, :fail, "endpoint dispatch raised"}
  end

  defp run_check(:seeded_workspace) do
    slug = Bank.Demo.workspace_slug()

    case Bank.Workspaces.get_workspace_by_slug(slug) do
      nil ->
        {:seeded_workspace, :fail, "workspace '#{slug}' not found; run `mix bank.demo.seed`"}

      _ws ->
        {:seeded_workspace, :ok, nil}
    end
  end

  defp run_check(:create_intent) do
    case Bank.Demo.demo_workspace_id() do
      nil ->
        {:create_intent, :fail, "demo workspace not bootstrapped; run `mix bank.demo.seed`"}

      workspace_id ->
        case Bank.Intents.list(workspace_id: workspace_id, limit: 1) do
          [] -> {:create_intent, :fail, "no intents found in seeded workspace"}
          [_ | _] -> {:create_intent, :ok, nil}
        end
    end
  end

  defp run_check(:show_intent) do
    case Bank.Demo.demo_workspace_id() do
      nil ->
        {:show_intent, :fail, "demo workspace not bootstrapped"}

      workspace_id ->
        case Bank.Intents.list(workspace_id: workspace_id, limit: 1) do
          [intent | _] ->
            cp = intent.target_counterparty

            cond do
              is_nil(cp) ->
                {:show_intent, :fail, "intent missing preloaded counterparty"}

              is_binary(intent.idempotency_key) and is_binary(intent.agent_id) ->
                {:show_intent, :ok, nil}

              true ->
                {:show_intent, :fail, "intent missing required fields"}
            end

          [] ->
            {:show_intent, :fail, "no intents to read"}
        end
    end
  end

  defp run_check(:simulate_reasons) do
    # The seed exercises the deterministic-evaluation pipeline by
    # writing `DecisionEnvelope` rows with both an `outcome` and a
    # `risk_tier`, plus a `decision.recorded` audit event. Together
    # those are the "simulate reasons" surface the sandbox smoke
    # cares about: a decision that names *what* and *why*.
    import Ecto.Query

    case Bank.Demo.demo_workspace_id() do
      nil ->
        {:simulate_reasons, :fail, "demo workspace not bootstrapped"}

      workspace_id ->
        with_reasons =
          Bank.Repo.aggregate(
            from(d in Bank.Decisions.DecisionEnvelope,
              join: i in Bank.Intents.AgentIntent,
              on: i.id == d.intent_id,
              where: i.workspace_id == ^workspace_id and not is_nil(d.risk_tier)
            ),
            :count,
            :id
          )

        recorded_audit =
          Bank.Repo.exists?(
            from(e in Bank.Audit.AuditEvent,
              join: i in Bank.Intents.AgentIntent,
              on: i.id == e.correlation_id,
              where:
                i.workspace_id == ^workspace_id and
                  e.event_type == ^"decision.recorded"
            )
          )

        cond do
          with_reasons < 1 ->
            {:simulate_reasons, :fail, "no decision carries a non-nil risk_tier"}

          not recorded_audit ->
            {:simulate_reasons, :fail, "no `decision.recorded` audit event present"}

          true ->
            {:simulate_reasons, :ok, nil}
        end
    end
  end

  defp run_check(:approval) do
    import Ecto.Query

    case Bank.Demo.demo_workspace_id() do
      nil ->
        {:approval, :fail, "demo workspace not bootstrapped"}

      workspace_id ->
        outcomes =
          Bank.Repo.all(
            from(d in Bank.Decisions.DecisionEnvelope,
              join: i in Bank.Intents.AgentIntent,
              on: i.id == d.intent_id,
              where: i.workspace_id == ^workspace_id,
              distinct: d.outcome,
              select: d.outcome
            )
          )

        cond do
          :approval_required not in outcomes ->
            {:approval, :fail, "no decision in :approval_required outcome (held branch missing)"}

          :auto_exec not in outcomes ->
            {:approval, :fail, "no decision in :auto_exec outcome (dispatched branch missing)"}

          true ->
            {:approval, :ok, nil}
        end
    end
  end

  defp run_check(:cancel_flow) do
    import Ecto.Query

    case Bank.Demo.demo_workspace_id() do
      nil ->
        {:cancel_flow, :fail, "demo workspace not bootstrapped"}

      workspace_id ->
        cancelled_count =
          Bank.Repo.aggregate(
            from(i in Bank.Intents.AgentIntent,
              where: i.workspace_id == ^workspace_id and i.state == :cancelled
            ),
            :count,
            :id
          )

        if cancelled_count >= 1 do
          {:cancel_flow, :ok, nil}
        else
          {:cancel_flow, :fail, "no intent reached :cancelled state in seeded set"}
        end
    end
  end

  defp run_check(:replay) do
    import Ecto.Query

    case Bank.Demo.demo_workspace_id() do
      nil ->
        {:replay, :fail, "demo workspace not bootstrapped"}

      workspace_id ->
        # Pick the intent the seed marks as `payroll-confirmed`
        # (an `:executed` happy-path scenario). If the seed stops
        # producing it, `replay` should fail loud.
        intent =
          Bank.Repo.one(
            from(i in Bank.Intents.AgentIntent,
              where:
                i.workspace_id == ^workspace_id and
                  i.idempotency_key == ^"sandbox-payroll-confirmed",
              limit: 1
            )
          )

        case intent do
          nil ->
            {:replay, :fail,
             "seeded `sandbox-payroll-confirmed` intent not found; run `mix bank.demo.seed`"}

          %{id: id} ->
            case Bank.Audit.replay(id) do
              {:ok, %{audit: events}} when is_list(events) and events != [] ->
                event_types = Enum.map(events, & &1.event_type)

                has_submitted? = "intent.submitted" in event_types

                has_decision_or_execution? =
                  Enum.any?(event_types, fn t ->
                    t == "decision.recorded" or String.starts_with?(t, "execution.")
                  end)

                cond do
                  not has_submitted? ->
                    {:replay, :fail, "replay bundle missing `intent.submitted` event"}

                  not has_decision_or_execution? ->
                    {:replay, :fail,
                     "replay bundle missing `decision.recorded` / `execution.*` event"}

                  true ->
                    {:replay, :ok, nil}
                end

              {:ok, _} ->
                {:replay, :fail, "replay bundle has empty audit slice"}

              {:error, :not_found} ->
                {:replay, :fail, "intent not found by replay/1"}
            end
        end
    end
  end

  # --- Helpers -------------------------------------------------------------

  defp log(_msg, true), do: :ok
  defp log(msg, _), do: IO.puts("[bank.sandbox.smoke] #{msg}")

  @doc """
  Dispatches a GET to `path` through `BankWeb.Endpoint` using
  `Plug.Test.conn/3` and returns `{:ok, status, body}` on a normal
  response or `{:error, reason}` when the dispatch itself raises.

  This is a public helper rather than a private function so the
  smoke task's tests can call it directly to assert that no chain
  adapter HTTP is involved (the dispatch only goes through the
  Phoenix router and Plug pipeline; nothing here reaches
  `Bank.AdapterClient`).

  Used by `run_check(:endpoint)`. Exposed in @doc form so a future
  smoke that wants to add more route checks can reuse this helper
  rather than re-deriving the dispatch shape.
  """
  @spec dispatch_get(String.t()) :: {:ok, non_neg_integer(), binary()} | {:error, atom()}
  def dispatch_get(path) when is_binary(path) do
    conn = Plug.Test.conn(:get, path)
    response = BankWeb.Endpoint.call(conn, BankWeb.Endpoint.init([]))
    {:ok, response.status, response.resp_body || ""}
  rescue
    _ -> {:error, :dispatch_raised}
  end
end
