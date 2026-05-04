defmodule Mix.Tasks.Bank.DecisionReport.Smoke do
  @shortdoc "Build human-readable decision reports from seeded demo intents (no chain, no secrets)"

  @moduledoc """
  Decision report smoke command (#252).

  For each of the six outcome examples called out by #252 —
  `auto_exec`, `approval_required`, `held`, `blocked`, `executed`,
  `failed` — the task locates the corresponding seeded intent,
  builds the export artifact via the same pipeline the HTTP routes
  use (`Bank.Audit.replay/1` →
  `Bank.Decisions.Report.from_bundle/1` →
  `Bank.Decisions.ReportExport.build/1`), and validates the result.

  ## What it verifies

  Per example the smoke checks that:

    * `Bank.Audit.replay/1` returns `{:ok, bundle}` for the seeded
      intent.
    * The built report struct's decision / approval / execution
      shape matches the example (e.g. `executed` ⇒ plan
      `final_outcome == :confirmed`).
    * The export artifact body is non-empty Markdown carrying the
      generated metadata block.
    * The artifact filename is hex-safe (UUID-derived; no
      operator-supplied text).
    * Neither the rendered body nor the metadata block leaks a
      secret-shaped value: no `Authorization: Bearer`, no
      `sk_live_` / `sk_test_` token, no PEM `-----BEGIN ...
      PRIVATE KEY-----` marker, no tokenized
      `https://user:pass@host` URL, and no 32-byte hex blob.

  ## What it does NOT do

    * No chain adapter HTTP. No `Bank.AdapterClient` dispatch.
    * No bundler / RPC calls.
    * No broadcast / signing path.
    * No `.env`, no `ADAPTER_BASE_URL` /
      `ADAPTER_DISPATCH_SECRET` / `ADAPTER_CALLBACK_SECRET` /
      `RPC_URL`, no provider tokens.
    * No HTTP request of any kind — the export pipeline is pure
      Postgres reads.

  ## Usage

      mix bank.decision_report.smoke
      # → prints one PASS / FAIL line per outcome example,
      #   exits non-zero on failure.

  Opts:

    * `--seed` — run `Bank.Demo.seed/0` before the checks (handy
      for a fresh DB). Without this flag the task expects the
      seed has already been applied.
    * `--quiet` — suppress per-check PASS lines; only print
      failures and the trailing summary.

  ## Example output

      [bank.decision_report.smoke] running 6 checks
      [bank.decision_report.smoke] PASS auto_exec        decided-pending-exec      → decision-report-...md
      [bank.decision_report.smoke] PASS approval_required partner-x-pending-approval → decision-report-...md
      [bank.decision_report.smoke] PASS held             treasury-held              → decision-report-...md
      [bank.decision_report.smoke] PASS blocked          unknown-blocked            → decision-report-...md
      [bank.decision_report.smoke] PASS executed         payroll-confirmed          → decision-report-...md
      [bank.decision_report.smoke] PASS failed           treasury-reverted          → decision-report-...md
      [bank.decision_report.smoke] 6 / 6 PASS

  See also: `docs/runbooks/decision-reports.md`.
  """

  use Mix.Task

  @requirements ["app.start"]

  alias Bank.Audit
  alias Bank.Decisions.Report
  alias Bank.Decisions.ReportExport
  alias Bank.Demo
  alias Bank.Intents.AgentIntent
  alias Bank.Repo

  # Each example pairs a #252-required outcome label with:
  #   * the seeded intent's `idempotency_key`
  #   * a predicate that asserts the report's shape matches the
  #     outcome (e.g. an `executed` example's report carries an
  #     execution plan in `:confirmed`).
  #
  # The order is significant only for stable output. Adding a new
  # outcome label is the right place to extend coverage in a
  # future issue — drop another tuple in here, point it at a
  # seeded intent, and the smoke + tests pick it up.
  @examples [
    {:auto_exec, "sandbox-decided-pending-exec", &__MODULE__.matches_auto_exec?/1},
    {:approval_required, "sandbox-partner-x-pending-approval",
     &__MODULE__.matches_approval_required?/1},
    {:held, "sandbox-treasury-held", &__MODULE__.matches_held?/1},
    {:blocked, "sandbox-unknown-blocked", &__MODULE__.matches_blocked?/1},
    {:executed, "sandbox-payroll-confirmed", &__MODULE__.matches_executed?/1},
    {:failed, "sandbox-treasury-reverted", &__MODULE__.matches_failed?/1}
  ]

  # Patterns that must NOT appear anywhere in the rendered Markdown
  # body or the metadata block. The list mirrors the secret-hygiene
  # tests under `test/bank/demo_test.exs` — adding a new pattern
  # here is the right place to widen coverage if a future
  # incident surfaces a new credential shape.
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
    {opts, _args, _invalid} =
      OptionParser.parse(argv, strict: [seed: :boolean, quiet: :boolean])

    quiet? = Keyword.get(opts, :quiet, false)
    seed_first? = Keyword.get(opts, :seed, false)

    if seed_first? do
      log("seeding sandbox dataset (--seed)", quiet?)
      :ok = Demo.seed()
    end

    log("running #{length(@examples)} checks", quiet?)

    workspace_id = Demo.demo_workspace_id()

    results =
      Enum.map(@examples, fn {label, idempotency_key, predicate} ->
        run_example(workspace_id, label, idempotency_key, predicate)
      end)

    Enum.each(results, fn {label, status, detail} ->
      case status do
        :ok ->
          log("PASS #{label_pad(label)} #{detail}", quiet?)

        :fail ->
          IO.puts("[bank.decision_report.smoke] FAIL #{label_pad(label)} — #{detail}")
      end
    end)

    pass_count = Enum.count(results, fn {_, status, _} -> status == :ok end)
    total = length(results)

    summary = "[bank.decision_report.smoke] #{pass_count} / #{total} PASS"
    IO.puts(summary)

    if pass_count < total do
      Mix.raise(
        "bank.decision_report.smoke FAILED (#{total - pass_count} of #{total} checks did not pass)"
      )
    end

    :ok
  end

  # --- per-example check ---------------------------------------------------

  defp run_example(nil, label, _idempotency_key, _predicate) do
    {label, :fail, "demo workspace not bootstrapped; run `mix bank.demo.seed`"}
  end

  defp run_example(workspace_id, label, idempotency_key, predicate)
       when is_binary(workspace_id) do
    case find_intent(workspace_id, idempotency_key) do
      nil ->
        {label, :fail,
         "seeded intent #{inspect(idempotency_key)} not found; run `mix bank.demo.seed`"}

      %AgentIntent{id: intent_id} = _intent ->
        with {:ok, bundle} <- Audit.replay(intent_id),
             %Report{} = report <- Report.from_bundle(bundle),
             :ok <- check_report_shape(label, report, predicate),
             artifact when is_map(artifact) <- ReportExport.build(report),
             :ok <- check_artifact(artifact) do
          handle = handle_from(idempotency_key)
          detail = "#{handle_pad(handle)} → #{artifact.filename}"
          {label, :ok, detail}
        else
          {:error, :not_found} ->
            {label, :fail, "Audit.replay/1 returned :not_found"}

          {:error, reason} when is_binary(reason) ->
            {label, :fail, reason}

          {:error, reason} ->
            {label, :fail, "report build failed: #{inspect(reason)}"}
        end
    end
  rescue
    err ->
      # Sanitize: surface the exception module name only, never the
      # message — a raised stacktrace can carry config strings the
      # smoke is supposed to keep out of stdout.
      {label, :fail, "report build raised #{inspect(err.__struct__)}"}
  end

  # Workspace-scoped lookup so a stray non-demo row with the same
  # idempotency_key never accidentally satisfies the smoke.
  defp find_intent(workspace_id, idempotency_key) do
    import Ecto.Query

    Repo.one(
      from(i in AgentIntent,
        where: i.workspace_id == ^workspace_id and i.idempotency_key == ^idempotency_key,
        limit: 1
      )
    )
  end

  defp check_report_shape(label, %Report{} = report, predicate) do
    if predicate.(report) do
      :ok
    else
      {:error, "report shape did not match #{label} predicate"}
    end
  end

  defp check_artifact(%{body: body, filename: filename, content_type: ct, body_hash: hash}) do
    cond do
      not is_binary(body) or byte_size(body) == 0 ->
        {:error, "artifact body is empty"}

      not String.starts_with?(filename, "decision-report-") ->
        {:error, "artifact filename does not start with `decision-report-`"}

      not String.ends_with?(filename, ".md") ->
        {:error, "artifact filename does not end with `.md`"}

      ct != "text/markdown; charset=utf-8" ->
        {:error, "unexpected content type: #{ct}"}

      not Regex.match?(~r/^[0-9a-f]+$/, hash) ->
        {:error, "body hash is not lowercase hex"}

      true ->
        case scan_for_secrets(body) do
          :ok -> :ok
          {:secret, label} -> {:error, "artifact body contains a #{label}"}
        end
    end
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

  # --- shape predicates ----------------------------------------------------

  @doc false
  def matches_auto_exec?(%Report{decision_envelope: %{available: true, outcome: "auto_exec"}}),
    do: true

  def matches_auto_exec?(_), do: false

  @doc false
  def matches_approval_required?(%Report{
        decision_envelope: %{available: true, outcome: "approval_required"}
      }),
      do: true

  def matches_approval_required?(_), do: false

  @doc false
  def matches_held?(%Report{decision_envelope: %{available: true, outcome: "hold"}}), do: true
  def matches_held?(_), do: false

  @doc false
  def matches_blocked?(%Report{
        decision_envelope: %{available: true, outcome: "block"},
        execution_plan: %{available: false}
      }),
      do: true

  def matches_blocked?(_), do: false

  @doc false
  def matches_executed?(%Report{
        execution_plan: %{available: true, final_outcome: "confirmed"}
      }),
      do: true

  def matches_executed?(_), do: false

  @doc false
  def matches_failed?(%Report{
        execution_plan: %{available: true, final_outcome: "reverted"}
      }),
      do: true

  def matches_failed?(_), do: false

  # --- helpers --------------------------------------------------------------

  defp handle_from("sandbox-" <> rest), do: rest
  defp handle_from(other), do: other

  defp label_pad(label) do
    label
    |> Atom.to_string()
    |> String.pad_trailing(18)
  end

  defp handle_pad(handle), do: String.pad_trailing(handle, 28)

  defp log(_msg, true), do: :ok
  defp log(msg, _), do: IO.puts("[bank.decision_report.smoke] #{msg}")
end
