defmodule BankWeb.HealthControllerTest do
  # async: false because the new #253 tests mutate
  # `Application.put_env(:bank, Bank.AdapterClient, ...)` to exercise
  # the unconfigured / credentialed-URL paths. Concurrent tests that
  # read the same config (revoke / grant / transfer dispatch) would
  # otherwise see partial overrides and fail with `:adapter_unavailable`.
  use BankWeb.ConnCase, async: false

  setup do
    # `Bank.Quotes.ProviderHealth` is a singleton ETS table shared
    # across the test process tree (#176). Reset it before each
    # health-controller test so deep-probe assertions start with a
    # known-empty state regardless of which provider tests ran first.
    Bank.Quotes.ProviderHealth.reset()
    :ok
  end

  describe "GET /health" do
    test "returns 200 with liveness payload", %{conn: conn} do
      conn = get(conn, ~p"/health")
      body = json_response(conn, 200)
      assert body["status"] == "ok"
      assert body["service"] == "bank"
      assert is_binary(body["version"])
    end
  end

  describe "GET /v1/health" do
    test "returns 200 with ok checks when the database is reachable", %{conn: conn} do
      conn = get(conn, ~p"/v1/health")
      body = json_response(conn, 200)
      assert body["status"] == "ok"
      assert body["checks"]["database"] == "ok"
    end
  end

  describe "GET /v1/health/deep" do
    test "returns ok when every check passes", %{conn: conn} do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.json(conn, %{status: "ok"})
      end)

      conn = get(conn, ~p"/v1/health/deep")
      body = json_response(conn, 200)
      assert body["status"] == "ok"
      assert body["checks"]["database"]["status"] == "ok"
      assert body["checks"]["adapter"]["status"] == "ok"
      assert body["checks"]["stuck_plans"]["status"] == "ok"
      assert body["checks"]["stuck_plans"]["count"] == 0
    end

    test "returns 503 when the adapter is unreachable (transport error → :down)", %{conn: conn} do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      conn = get(conn, ~p"/v1/health/deep")
      body = json_response(conn, 503)
      assert body["status"] == "degraded"
      assert body["checks"]["adapter"]["status"] == "down"
      assert body["checks"]["adapter"]["detail"] == "transport_error"
    end

    test "renders adapter 5xx as degraded (#253)", %{conn: conn} do
      Req.Test.stub(Bank.AdapterClient, fn conn ->
        conn
        |> Plug.Conn.put_status(502)
        |> Req.Test.json(%{error: "bad_gateway"})
      end)

      conn = get(conn, ~p"/v1/health/deep")
      body = json_response(conn, 503)
      assert body["status"] == "degraded"
      assert body["checks"]["adapter"]["status"] == "degraded"
      assert body["checks"]["adapter"]["detail"] == "http_5xx"
    end

    test "renders unconfigured adapter as not_configured AND keeps overall ok (#253)", %{
      conn: conn
    } do
      original = Application.get_env(:bank, Bank.AdapterClient)

      try do
        Application.put_env(
          :bank,
          Bank.AdapterClient,
          Keyword.delete(original || [], :base_url)
        )

        conn = get(conn, ~p"/v1/health/deep")
        body = json_response(conn, 200)
        assert body["status"] == "ok"
        assert body["checks"]["adapter"]["status"] == "not_configured"
        assert body["checks"]["adapter"]["detail"] == "adapter_base_url_not_configured"
      after
        if original do
          Application.put_env(:bank, Bank.AdapterClient, original)
        else
          Application.delete_env(:bank, Bank.AdapterClient)
        end
      end
    end

    test "redaction: response body never carries raw exception text, RPC URL, Authorization header, or struct names (#253)",
         %{conn: conn} do
      original = Application.get_env(:bank, Bank.AdapterClient, [])

      try do
        # Wire a credentialed RPC URL into the adapter config to prove
        # nothing in the response body leaks it. The actual probe will
        # fail with transport_error (no test plug); the response detail
        # must collapse to the enum string.
        secret_url = "https://user:supersecret@adapter.example.invalid/path?token=abc123"

        Application.put_env(
          :bank,
          Bank.AdapterClient,
          original
          |> Keyword.put(:base_url, secret_url)
          |> Keyword.put(:req_options, [])
        )

        conn = get(conn, ~p"/v1/health/deep")
        body = response(conn, 503)

        refute String.contains?(body, "supersecret"),
               "response leaked secret credential from RPC URL"

        refute String.contains?(body, "adapter.example.invalid"),
               "response leaked RPC host"

        refute String.contains?(body, "abc123"),
               "response leaked URL token"

        refute String.contains?(body, "Req.TransportError"),
               "response leaked internal struct module name"

        refute String.contains?(body, "Authorization"),
               "response carried an Authorization header label"
      after
        Application.put_env(:bank, Bank.AdapterClient, original)
      end
    end

    test "includes quotes_provider check (#176)", %{conn: conn} do
      Bank.Quotes.ProviderHealth.reset()

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.json(conn, %{status: "ok"})
      end)

      conn = get(conn, ~p"/v1/health/deep")
      body = json_response(conn, 200)

      assert body["checks"]["quotes_provider"]["status"] == "ok"
      # No providers observed yet → empty list, no detail string.
      assert body["checks"]["quotes_provider"]["providers"] == []
      assert is_nil(body["checks"]["quotes_provider"]["detail"])
    end

    test "quotes_provider check downgrades to :down when a provider is :failing (#176)",
         %{conn: conn} do
      Bank.Quotes.ProviderHealth.reset()

      for _ <- 1..5 do
        Bank.Quotes.ProviderHealth.record_failure("tenderly", :provider_unavailable)
      end

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.json(conn, %{status: "ok"})
      end)

      conn = get(conn, ~p"/v1/health/deep")
      body = json_response(conn, 503)
      assert body["status"] == "degraded"
      assert body["checks"]["quotes_provider"]["status"] == "down"
      assert body["checks"]["quotes_provider"]["detail"] == "provider_tenderly_failing"

      providers = body["checks"]["quotes_provider"]["providers"]
      assert is_list(providers)
      assert Enum.any?(providers, fn p -> p["provider"] == "tenderly" end)
    end

    test "quotes_provider providers carry only category-atom failure reasons (#176)", %{
      conn: conn
    } do
      Bank.Quotes.ProviderHealth.record_failure("tenderly", :provider_unavailable)

      Req.Test.stub(Bank.AdapterClient, fn conn ->
        Req.Test.json(conn, %{status: "ok"})
      end)

      conn = get(conn, ~p"/v1/health/deep")
      # One failure with zero successes → :failing → top-level 503.
      body = response(conn, 503)

      # Allowlist atom serialised as a string — no raw URLs / headers /
      # token markers in the readiness payload.
      assert String.contains?(body, "provider_unavailable")
      refute String.contains?(body, "Authorization")
      refute body =~ ~r/sk_(live|test)_/
      refute body =~ ~r/pk_(live|test)_/
      refute body =~ ~r{://[^\s/@]+:[^\s/@]+@}
      refute String.contains?(body, "PRIVATE KEY")
    end
  end
end
