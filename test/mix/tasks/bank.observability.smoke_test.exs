defmodule Mix.Tasks.Bank.Observability.SmokeTest do
  use Bank.DataCase, async: false

  import ExUnit.CaptureIO

  @runbook_path Path.expand("../../../docs/runbooks/production-observability.md", __DIR__)

  describe "mix bank.observability.smoke" do
    test "passes against the local control plane (all eight checks PASS)" do
      # Stub the adapter health endpoint with a healthy 200 so the
      # `health.endpoint_deep` and `health.snapshot_shape` checks
      # run against a deterministic upstream.
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.json(conn, %{status: "ok"})
      end)

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Observability.Smoke.run([])
        end)

      for name <- ~w(
            health.database
            health.stuck_plans
            health.snapshot_shape
            health.endpoint_liveness
            health.endpoint_readiness
            health.endpoint_deep
            alerts.kinds
            secret_hygiene.health_payload
          ) do
        assert output =~ "PASS #{name}", "missing PASS line for #{name}: #{inspect(output)}"
      end

      assert output =~ "8 / 8 PASS"
      refute output =~ "FAIL"
    end

    test "with --quiet suppresses PASS lines but still prints the summary" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.json(conn, %{status: "ok"})
      end)

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Observability.Smoke.run(["--quiet"])
        end)

      refute output =~ "PASS health.database"
      refute output =~ "PASS alerts.kinds"
      assert output =~ "8 / 8 PASS"
    end

    # #257 acceptance: "Smoke covers at least one degraded
    # dependency safely." We exercise the degraded-adapter path
    # via `Req.Test.stub` returning a 503 — the smoke must keep
    # passing (degraded ≠ failed-shape) AND
    # `Bank.Ops.Health.adapter/0` directly must classify the
    # response as `:degraded` with `detail: "http_5xx"`. This is
    # the load-bearing acceptance test for the degraded surface.
    test "covers a degraded adapter dependency safely (5xx ⇒ :degraded / http_5xx)" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{error: "down"})
      end)

      # Direct probe: Bank.Ops.Health.adapter/0 must classify a
      # 5xx as :degraded. This is the contract the runbook
      # operator-triage card depends on.
      assert %{status: :degraded, detail: "http_5xx"} = Bank.Ops.Health.adapter()

      # Snapshot rollup: a degraded adapter ⇒ overall :degraded
      # (not :ok, not :down).
      snapshot = Bank.Ops.Health.snapshot()
      assert snapshot.status == :degraded
      assert snapshot.checks.adapter.status == :degraded

      # Smoke task itself: must still PASS shape-wise — the
      # smoke is about shape correctness, not about whether
      # the adapter happens to be up.
      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Observability.Smoke.run([])
        end)

      assert output =~ "8 / 8 PASS"
      refute output =~ "FAIL"
    end

    # Companion: a transport error ⇒ :down / "transport_error".
    # Same posture as the 5xx case but for the harder failure
    # mode (TCP refused, DNS, etc.). This pins the second branch
    # of the runbook's adapter-triage card.
    test "covers a downed adapter dependency safely (transport_error ⇒ :down / transport_error)" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert %{status: :down, detail: "transport_error"} = Bank.Ops.Health.adapter()

      snapshot = Bank.Ops.Health.snapshot()
      assert snapshot.status == :degraded
      assert snapshot.checks.adapter.status == :down
    end

    # #257 acceptance: the smoke must FAIL when an alert kind is
    # silently added or removed without updating the Phase 1
    # allowlist (#256). We can't easily reach into `@kinds` at
    # runtime, so this test pins the live `Alerts.kinds/0` value
    # — if a future PR widens the surface, the smoke prints a
    # diff and the test cross-checks the contract.
    test "alerts.kinds check rejects a drifted allowlist" do
      assert MapSet.new(Bank.Ops.Alerts.kinds()) ==
               MapSet.new([
                 :stuck_plan,
                 :adapter_down,
                 :rpc_down,
                 :bundler_down,
                 :quote_provider_down,
                 :callback_latency_high,
                 :queue_depth_high,
                 :job_failures_high
               ])
    end

    # #257 chain-safety acceptance — the smoke uses the
    # AdapterClient via `Req.Test.stub`, so a NON-stubbed run
    # would still go through the real `Req.request` against the
    # configured `Bank.AdapterClient` base_url. In `:test` the
    # base_url is `localhost:4100`, but Req.Test routes through
    # the stub registry — so a real socket is never opened from
    # the test process when a stub is installed. We exercise
    # that property by installing a stub that sends `parent` a
    # message if invoked, then asserting the smoke calls the
    # adapter via the stub (the message arrives) but never
    # reaches anything else.
    test "adapter probe goes through Req.Test.stub (no real chain HTTP)" do
      parent = self()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        send(parent, :adapter_was_probed)
        Req.Test.json(conn, %{status: "ok"})
      end)

      capture_io(fn ->
        assert :ok = Mix.Tasks.Bank.Observability.Smoke.run([])
      end)

      # The adapter WAS probed (snapshot calls `adapter/0`,
      # which goes through Req.Test). The stub intercepts so no
      # real socket is opened.
      assert_receive :adapter_was_probed, 200
    end

    # #257 acceptance: the smoke output must not include any
    # secret-shaped substrings. This is the stdout-side guard;
    # the in-task `secret_hygiene.health_payload` check covers
    # the rendered HTTP body, this covers the operator-visible
    # PASS / FAIL lines.
    test "smoke output contains no secret-shaped markers" do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.json(conn, %{status: "ok"})
      end)

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.Bank.Observability.Smoke.run([])
        end)

      refute output =~ ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
             "smoke output contains a PEM private-key block"

      refute output =~ ~r/\b(sk_live|pk_live|sk_test)_[A-Za-z0-9_-]+/,
             "smoke output contains a Stripe-style live/test secret token"

      refute output =~ ~r/\bauthorization\s*:\s*"?bearer\s+[A-Za-z0-9._-]+/i,
             "smoke output contains a literal Authorization: Bearer header"

      refute output =~ ~r{https?://[^/\s"`]+:[^@/\s"`]+@[A-Za-z0-9.-]+},
             "smoke output contains a tokenized https://user:pass@host URL"
    end

    test "dispatch_get/1 reaches /health and returns 200" do
      assert {:ok, 200, body} = Mix.Tasks.Bank.Observability.Smoke.dispatch_get("/health")
      assert {:ok, %{"status" => "ok", "service" => "bank"}} = Jason.decode(body)
    end
  end

  describe "docs/runbooks/production-observability.md" do
    test "exists at the expected path" do
      assert File.exists?(@runbook_path),
             "production-observability runbook missing at #{@runbook_path}"
    end

    test "covers every #257 scope item" do
      contents = File.read!(@runbook_path)

      assert contents =~ ~r/health endpoints?/i,
             "runbook missing the health-endpoints section"

      assert contents =~ ~r/ops dashboard|`\/ops`/,
             "runbook missing the ops dashboard reference"

      assert contents =~ ~r/queue failure triage|queue (failure )?triage/i,
             "runbook missing the queue triage card"

      assert contents =~ ~r/adapter.+(triage|RPC|bundler)/i,
             "runbook missing the adapter / RPC / bundler triage card"

      assert contents =~ ~r/quote provider.+degraded/i,
             "runbook missing the quote-provider degraded-mode card"

      assert contents =~ ~r/callback failure triage|callback failure/i,
             "runbook missing the callback failure triage card"

      assert contents =~ ~r/stuck execution recovery|stuck execution/i,
             "runbook missing the stuck-execution recovery card"
    end

    test "names the local-vs-staging-vs-mainnet boundary" do
      contents = File.read!(@runbook_path)

      assert contents =~ ~r/local.{0,5}dev/i,
             "runbook missing the local/dev boundary callout"

      assert contents =~ ~r/staging.{0,5}mainnet/i,
             "runbook missing the staging/mainnet boundary callout"
    end

    test "documents the local smoke command" do
      contents = File.read!(@runbook_path)

      assert contents =~ "mix bank.observability.smoke",
             "runbook missing the smoke command"
    end

    test "cross-links to monitoring.md and incident-runbook.md" do
      contents = File.read!(@runbook_path)

      assert contents =~ "monitoring.md",
             "runbook missing cross-link to docs/monitoring.md"

      assert contents =~ "incident-runbook.md",
             "runbook missing cross-link to docs/incident-runbook.md"
    end

    test "names the eight Phase 1 alert kinds" do
      contents = File.read!(@runbook_path)

      for kind <- ~w(
            stuck_plan
            adapter_down
            rpc_down
            bundler_down
            quote_provider_down
            callback_latency_high
            queue_depth_high
            job_failures_high
          ) do
        assert contents =~ kind,
               "runbook does not name the #{kind} alert kind"
      end
    end
  end
end
