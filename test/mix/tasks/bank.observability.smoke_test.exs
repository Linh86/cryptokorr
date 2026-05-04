defmodule Mix.Tasks.Bank.Observability.SmokeTest do
  use Bank.DataCase, async: false

  import ExUnit.CaptureIO

  alias Bank.Notifications

  @runbook_path Path.expand("../../../docs/runbooks/production-observability.md", __DIR__)

  describe "mix bank.observability.smoke" do
    test "passes against a clean DB and prints PASS for every check" do
      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Observability.Smoke.run([])
        end)

      for label <- ~w(
            health_snapshot
            health_database
            health_adapter
            adapter_snapshot
            problem_jobs_shape
            stuck_plan_details
            alert_kinds
            provider_health
            alert_pipeline
          ) do
        assert output =~ "PASS #{label}",
               "missing PASS line for #{label}: #{inspect(output)}"
      end

      assert output =~ "9 / 9 PASS"
      refute output =~ "FAIL"
    end

    test "with --quiet suppresses PASS lines but still prints the summary" do
      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Observability.Smoke.run(["--quiet"])
        end)

      refute output =~ "PASS health_snapshot"
      refute output =~ "PASS alert_pipeline"
      assert output =~ "9 / 9 PASS"
    end

    test "alert pipeline check rolls back its temp workspace on the way out" do
      ws_count_before =
        Bank.Workspaces.Workspace
        |> Bank.Repo.aggregate(:count, :id)

      capture_io(fn ->
        assert :ok = Mix.Tasks.Bank.Observability.Smoke.run([])
      end)

      ws_count_after =
        Bank.Workspaces.Workspace
        |> Bank.Repo.aggregate(:count, :id)

      assert ws_count_before == ws_count_after,
             "alert pipeline check leaked a workspace (#{ws_count_before} → #{ws_count_after})"
    end

    test "alert pipeline check leaves no notifications behind globally" do
      notif_count_before =
        Notifications.Notification
        |> Bank.Repo.aggregate(:count, :id)

      capture_io(fn ->
        assert :ok = Mix.Tasks.Bank.Observability.Smoke.run([])
      end)

      notif_count_after =
        Notifications.Notification
        |> Bank.Repo.aggregate(:count, :id)

      assert notif_count_before == notif_count_after,
             "alert pipeline check leaked notifications (#{notif_count_before} → #{notif_count_after})"
    end

    test "smoke output never contains a secret-looking substring" do
      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Observability.Smoke.run([])
        end)

      for needle <- [
            "Bearer ",
            "sk_live_",
            "sk_test_",
            "Authorization:",
            "BEGIN PRIVATE KEY",
            "BEGIN RSA PRIVATE KEY",
            "private_key",
            "https://user:"
          ] do
        refute output =~ needle,
               "smoke leaked secret marker #{inspect(needle)}: #{inspect(output)}"
      end
    end
  end

  describe "runbook" do
    test "docs/runbooks/production-observability.md exists and references the smoke task" do
      assert File.exists?(@runbook_path),
             "expected runbook at #{@runbook_path}"

      body = File.read!(@runbook_path)

      # The runbook must point operators at the smoke task and at
      # the operational alert / health surfaces it covers.
      assert body =~ "mix bank.observability.smoke"
      assert body =~ "/v1/health/deep"
      assert body =~ "/ops"
      assert body =~ "Bank.Ops.Alerts"
      assert body =~ "Stuck execution recovery"
    end

    test "runbook calls out the local/dev vs staging/mainnet distinction" do
      body = File.read!(@runbook_path)

      # Acceptance criterion: "Docs identify local/dev vs
      # staging/mainnet behavior". The runbook must keep the
      # environment matrix.
      assert body =~ "local / dev"
      assert body =~ ~r/staging|mainnet/i
      assert body =~ ":not_configured"
      assert body =~ ":degraded"
    end

    test "runbook documents the secret-hygiene posture" do
      body = File.read!(@runbook_path)

      assert body =~ ~r/secret[-\s]hygiene/i,
             "expected runbook to mention `secret hygiene` / `secret-hygiene`"

      assert body =~ "Bearer" or body =~ "sk_live" or body =~ "redact"
    end
  end
end
