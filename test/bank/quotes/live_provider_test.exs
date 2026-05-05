defmodule Bank.Quotes.LiveProviderTest do
  # async: false — these tests stub `Req.Test` and several mutate
  # `:bank, Bank.Quotes.LiveProvider` config (deleting `api_key` to
  # exercise the not-configured branch). Running them async would
  # let those mutations race against the parallel-running cases in
  # `test/bank/quotes_test.exs` that also touch the LiveProvider.
  use Bank.DataCase, async: false

  import ExUnit.CaptureLog

  alias Bank.Fixtures
  alias Bank.Quotes.{LiveProvider, Persistence, Preview}

  @api_key_under_test "test-tenderly-api-key"
  @base_url_under_test "http://tenderly.test"

  defp intent! do
    Fixtures.agent_intent(chain: "base", asset: "USDC", amount: Decimal.new("10.5"))
  end

  defp success_body(overrides \\ %{}) do
    Map.merge(
      %{
        "success" => true,
        "trace_id" => "tenderly-trace-#{System.unique_integer([:positive])}",
        "estimated_gas" => 120_000,
        "estimated_fee" => "0.00015",
        "fee_asset" => "ETH",
        "balance_changes" => %{"USDC" => "-10.5"},
        "expected_output" => nil,
        "slippage_bps" => nil,
        "route" => %{"type" => "erc20_transfer", "asset" => "USDC"},
        "failure_conditions" => ["wallet balance falls below requested amount"],
        "risk_flags" => [],
        "freshness_ttl_seconds" => 30
      },
      overrides
    )
  end

  describe "happy path" do
    test "returns a populated %Preview{source: :live, provider: \"tenderly\"}" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %Preview{} = preview} = LiveProvider.preview(intent!())

      assert preview.source == :live
      assert preview.provider == "tenderly"
      assert is_binary(preview.provider_trace_ref)
      assert preview.provider_trace_ref != ""
      assert %DateTime{} = preview.generated_at
      assert preview.freshness_ttl_seconds == 30
      assert preview.estimated_gas == 120_000
      assert %Decimal{} = preview.estimated_fee
      assert preview.fee_asset == "ETH"
      assert preview.balance_impact["USDC"] |> Decimal.equal?(Decimal.new("-10.5"))
      assert preview.failure_conditions == ["wallet balance falls below requested amount"]
      assert preview.risk_flags == []
      assert preview.failure_reason == nil
    end

    test "request body carries chain_id, kind, asset, amount, intent_id" do
      parent = self()

      Req.Test.stub(LiveProvider, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        {:ok, body} = Jason.decode(raw)
        send(parent, {:upstream_payload, body})

        Req.Test.json(conn, success_body())
      end)

      intent = intent!()
      assert {:ok, %Preview{}} = LiveProvider.preview(intent)

      assert_receive {:upstream_payload, payload}
      assert payload["chain_id"] == 8453
      assert payload["kind"] == "transfer"
      assert payload["asset"] == "USDC"
      assert payload["amount"] == "10.5"
      assert payload["intent_id"] == intent.id
    end

    test "request carries the X-Access-Key header from config (never Authorization: Bearer)" do
      parent = self()

      Req.Test.stub(LiveProvider, fn conn ->
        send(parent, {:headers, conn.req_headers})
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %Preview{}} = LiveProvider.preview(intent!())

      assert_receive {:headers, headers}
      headers_map = Map.new(headers)
      assert Map.fetch!(headers_map, "x-access-key") == @api_key_under_test
      refute Map.has_key?(headers_map, "authorization")
    end

    test "risk_flags from upstream are filtered to the allowlist" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{
            "risk_flags" => [
              "wide_slippage_band",
              "low_liquidity_pool",
              "totally_made_up_flag",
              # An attempted injection of an Authorization-shaped string.
              # The allowlist filter rejects it.
              "Authorization: Bearer evil"
            ]
          })
        )
      end)

      assert {:ok, %Preview{risk_flags: flags}} = LiveProvider.preview(intent!())
      assert "wide_slippage_band" in flags
      assert "low_liquidity_pool" in flags
      refute Enum.any?(flags, &(&1 == "totally_made_up_flag"))
      refute Enum.any?(flags, &String.contains?(&1, "Bearer"))
    end

    test "missing freshness_ttl_seconds defaults to 30" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(conn, success_body() |> Map.delete("freshness_ttl_seconds"))
      end)

      assert {:ok, %Preview{freshness_ttl_seconds: 30}} = LiveProvider.preview(intent!())
    end

    test "provider_trace_ref is forwarded from upstream's trace id (not from URL)" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(conn, success_body(%{"trace_id" => "tenderly-abc-123"}))
      end)

      assert {:ok, %Preview{provider_trace_ref: ref}} = LiveProvider.preview(intent!())
      assert ref == "tenderly-abc-123"
      refute ref =~ ~r{https?://}
      refute ref =~ ~r/authorization|bearer/i
      refute ref =~ @api_key_under_test
    end

    test "long upstream trace_id is clamped to 128 chars" do
      long = String.duplicate("a", 500)

      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(conn, success_body(%{"trace_id" => long}))
      end)

      assert {:ok, %Preview{provider_trace_ref: ref}} = LiveProvider.preview(intent!())
      assert byte_size(ref) == 128
    end
  end

  describe "failure paths" do
    test "5xx maps to {:error, :provider_unavailable}" do
      Req.Test.stub(LiveProvider, fn conn ->
        Plug.Conn.send_resp(conn, 502, "")
      end)

      assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
    end

    test "503 maps to {:error, :provider_unavailable}" do
      Req.Test.stub(LiveProvider, fn conn ->
        Plug.Conn.send_resp(conn, 503, "")
      end)

      assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
    end

    test "transport error maps to {:error, :provider_unavailable}" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
    end

    test "transport timeout maps to {:error, :provider_unavailable}" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
    end

    test "malformed JSON / unexpected 2xx body maps to {:error, :provider_unavailable}" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(conn, %{"unexpected" => "shape"})
      end)

      assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
    end

    test "2xx with success: true but missing balance_changes shape maps to :provider_unavailable" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{"balance_changes" => %{"USDC" => "not-a-number"}})
        )
      end)

      assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
    end

    test "string body (HTML / plain text) maps to {:error, :provider_unavailable}" do
      Req.Test.stub(LiveProvider, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.send_resp(200, "<html>maintenance</html>")
      end)

      assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
    end
  end

  describe "simulation_failed branch" do
    test "4xx with top-level code: \"simulation_failed\" maps to {:simulation_failed, reason}" do
      Req.Test.stub(LiveProvider, fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{
          "success" => false,
          "code" => "simulation_failed",
          "reason" => "insufficient_balance"
        })
      end)

      assert {:error, {:simulation_failed, "insufficient_balance"}} =
               LiveProvider.preview(intent!())
    end

    test "4xx with nested error.code: \"simulation_failed\" maps to {:simulation_failed, reason}" do
      Req.Test.stub(LiveProvider, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "success" => false,
          "error" => %{
            "code" => "simulation_failed",
            "reason" => "revert"
          }
        })
      end)

      assert {:error, {:simulation_failed, "revert"}} = LiveProvider.preview(intent!())
    end

    test "simulation_failed with reason outside the allowlist collapses to upstream_dry_run_rejected" do
      Req.Test.stub(LiveProvider, fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{
          "success" => false,
          "code" => "simulation_failed",
          # Free-form upstream string — must not reach the error tuple.
          "reason" => "Authorization: Bearer leaked"
        })
      end)

      assert {:error, {:simulation_failed, "upstream_dry_run_rejected"}} =
               LiveProvider.preview(intent!())
    end

    test "4xx WITHOUT simulation_failed code maps to {:error, :provider_unavailable}" do
      # An opaque 4xx (rate limit, bad request) is treated as
      # transport state, not a deterministic dry-run rejection.
      Req.Test.stub(LiveProvider, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"reason" => "rate_limited"})
      end)

      assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
    end
  end

  describe "configuration / fail-closed" do
    test "no api_key configured maps to {:error, :provider_unavailable} without HTTP" do
      previous = Application.get_env(:bank, LiveProvider, [])

      Application.put_env(
        :bank,
        LiveProvider,
        Keyword.delete(previous, :api_key)
      )

      on_exit(fn -> Application.put_env(:bank, LiveProvider, previous) end)

      parent = self()

      # Even with a stub installed, the provider MUST short-circuit
      # before issuing the HTTP call when api_key is unset.
      Req.Test.stub(LiveProvider, fn conn ->
        send(parent, :stub_invoked)
        Req.Test.json(conn, success_body())
      end)

      assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
      refute_receive :stub_invoked, 50
    end

    test "no base_url configured maps to {:error, :provider_unavailable} without HTTP" do
      previous = Application.get_env(:bank, LiveProvider, [])

      Application.put_env(
        :bank,
        LiveProvider,
        Keyword.delete(previous, :base_url)
      )

      on_exit(fn -> Application.put_env(:bank, LiveProvider, previous) end)

      parent = self()

      Req.Test.stub(LiveProvider, fn conn ->
        send(parent, :stub_invoked)
        Req.Test.json(conn, success_body())
      end)

      assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
      refute_receive :stub_invoked, 50
    end

    test "config entry entirely absent maps to {:error, :provider_unavailable}" do
      previous = Application.get_env(:bank, LiveProvider, [])
      Application.delete_env(:bank, LiveProvider)
      on_exit(fn -> Application.put_env(:bank, LiveProvider, previous) end)

      assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
    end
  end

  describe "secret hygiene — Logger output never leaks api_key / base_url / Authorization" do
    # The brief is explicit: logs MUST NEVER include API keys,
    # tokenized URLs, or Authorization headers. We pin this with
    # regex assertions across every failure path so a future
    # refactor that swaps `Logger.warning("...category=#{cat}")`
    # for an `inspect/1`-based log line trips the test suite.

    test "transport error log carries only the category — no api_key, base_url, or headers" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      log =
        capture_log(fn ->
          assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
        end)

      assert log =~ "Bank.Quotes.LiveProvider"
      assert log =~ "category=econnrefused"

      refute log =~ @api_key_under_test
      refute log =~ @base_url_under_test
      refute log =~ ~r/authorization|bearer/i
      refute log =~ "Req.TransportError"
      refute log =~ "Req.Request"
    end

    test "5xx log carries only the http_5xx category — no api_key, base_url, or body" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn |> Plug.Conn.put_status(500),
          %{
            # Adversarial body — even if a future regression
            # `inspect/1`-ed it, the log assertions catch it.
            "Authorization" => "Bearer leaked-#{@api_key_under_test}",
            "leaked_url" => @base_url_under_test
          }
        )
      end)

      log =
        capture_log(fn ->
          assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
        end)

      assert log =~ "category=http_5xx"
      refute log =~ @api_key_under_test
      refute log =~ @base_url_under_test
      refute log =~ ~r/authorization|bearer/i
      refute log =~ "leaked"
    end

    test "4xx (non-simulation_failed) log carries only the http_4xx category" do
      Req.Test.stub(LiveProvider, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{
          "Authorization" => "Bearer leaked-#{@api_key_under_test}"
        })
      end)

      log =
        capture_log(fn ->
          assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
        end)

      assert log =~ "category=http_4xx"
      refute log =~ @api_key_under_test
      refute log =~ ~r/authorization|bearer/i
    end

    test "simulation_failed log carries only the controlled reason tag" do
      Req.Test.stub(LiveProvider, fn conn ->
        conn
        |> Plug.Conn.put_status(422)
        |> Req.Test.json(%{
          "success" => false,
          "code" => "simulation_failed",
          # Adversarial reason — must collapse to the allowlist tag.
          "reason" => "Authorization: Bearer #{@api_key_under_test}"
        })
      end)

      log =
        capture_log(fn ->
          assert {:error, {:simulation_failed, "upstream_dry_run_rejected"}} =
                   LiveProvider.preview(intent!())
        end)

      assert log =~ "category=simulation_failed"
      assert log =~ "reason=upstream_dry_run_rejected"
      refute log =~ @api_key_under_test
      refute log =~ ~r/bearer/i
    end

    test "invalid 2xx body log carries only the invalid_response category" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(conn, %{
          "Authorization" => "Bearer leaked-#{@api_key_under_test}",
          "url" => @base_url_under_test
        })
      end)

      log =
        capture_log(fn ->
          assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
        end)

      assert log =~ "category=invalid_response"
      refute log =~ @api_key_under_test
      refute log =~ @base_url_under_test
      refute log =~ ~r/authorization|bearer/i
    end

    test "not-configured log carries only the not_configured category" do
      previous = Application.get_env(:bank, LiveProvider, [])
      Application.delete_env(:bank, LiveProvider)
      on_exit(fn -> Application.put_env(:bank, LiveProvider, previous) end)

      log =
        capture_log(fn ->
          assert {:error, :provider_unavailable} = LiveProvider.preview(intent!())
        end)

      assert log =~ "category=not_configured"
      refute log =~ @api_key_under_test
      refute log =~ @base_url_under_test
    end

    test "returned %Preview{} carries no api_key / base_url / Authorization in any field" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(conn, success_body())
      end)

      assert {:ok, %Preview{} = preview} = LiveProvider.preview(intent!())

      # Inspect every visible field to be confident the secret never
      # rides the preview to downstream consumers (decision engine,
      # operator UI, simulation_reports table).
      blob = inspect(preview)
      refute blob =~ @api_key_under_test
      refute blob =~ @base_url_under_test
      refute blob =~ ~r/authorization|bearer/i
    end
  end

  describe "secret hygiene — upstream-supplied trace_id / route / failure_conditions are sanitized (#174 P2)" do
    # Backstop for #174 P2: the upstream provider response is
    # untrusted. Even though log redaction (above) already prevents
    # secret leakage to stderr, a malicious or buggy upstream can
    # still smuggle markers through `trace_id` / `route` /
    # `failure_conditions` into the `%Preview{}` and onto the
    # persisted `simulation_reports` row. These cases prove the
    # provider drops or redacts each marker before it reaches the
    # Preview struct or the persistence attrs.

    test "trace_id carrying Authorization: Bearer is dropped (provider_trace_ref nil)" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{"trace_id" => "Authorization: Bearer sk_live_abcdef"})
        )
      end)

      assert {:ok, %Preview{provider_trace_ref: nil}} = LiveProvider.preview(intent!())
    end

    test "trace_id carrying sk_live_ key marker is dropped" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(conn, success_body(%{"trace_id" => "trace-sk_live_abc"}))
      end)

      assert {:ok, %Preview{provider_trace_ref: nil}} = LiveProvider.preview(intent!())
    end

    test "trace_id carrying sk_test_ / pk_live_ / pk_test_ markers is dropped" do
      for marker <- ["sk_test_abc", "pk_live_abc", "pk_test_abc"] do
        Req.Test.stub(LiveProvider, fn conn ->
          Req.Test.json(conn, success_body(%{"trace_id" => "trace-#{marker}"}))
        end)

        assert {:ok, %Preview{provider_trace_ref: nil}} = LiveProvider.preview(intent!()),
               "expected trace_id carrying #{marker} to be dropped"
      end
    end

    test "trace_id carrying credentialed URL is dropped" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{"trace_id" => "trace-https://user:pass@example.com"})
        )
      end)

      assert {:ok, %Preview{provider_trace_ref: nil}} = LiveProvider.preview(intent!())
    end

    test "trace_id carrying PEM private-key marker is dropped" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{"trace_id" => "-----BEGIN RSA PRIVATE KEY-----abc"})
        )
      end)

      assert {:ok, %Preview{provider_trace_ref: nil}} = LiveProvider.preview(intent!())
    end

    test "route map's nested string values matching secret patterns are redacted in place" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{
            "route" => %{
              "type" => "erc20_transfer",
              "asset" => "USDC",
              "leaked_header" => "Authorization: Bearer sk_live_abc",
              "nested" => %{
                "deep_url" => "https://user:pass@host/path",
                "ok_field" => "fine"
              },
              "items" => ["sk_test_xyz", "harmless"]
            }
          })
        )
      end)

      assert {:ok, %Preview{route: route}} = LiveProvider.preview(intent!())
      assert route["type"] == "erc20_transfer"
      assert route["asset"] == "USDC"
      assert route["leaked_header"] == "[REDACTED]"
      assert route["nested"]["deep_url"] == "[REDACTED]"
      assert route["nested"]["ok_field"] == "fine"
      assert "[REDACTED]" in route["items"]
      assert "harmless" in route["items"]

      blob = inspect(route)
      refute blob =~ ~r/sk_live_|sk_test_|pk_live_|pk_test_/
      refute blob =~ ~r/authorization|bearer/i
      refute blob =~ ~r{://[^\s/@]+:[^\s/@]+@}
    end

    test "route carrying PEM private-key text in a nested field is redacted" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{
            "route" => %{
              "type" => "v3_swap",
              "key_dump" =>
                "-----BEGIN RSA PRIVATE KEY-----\nMIIEv...etc\n-----END RSA PRIVATE KEY-----"
            }
          })
        )
      end)

      assert {:ok, %Preview{route: route}} = LiveProvider.preview(intent!())
      assert route["type"] == "v3_swap"
      assert route["key_dump"] == "[REDACTED]"
      refute inspect(route) =~ "PRIVATE KEY"
    end

    test "failure_conditions entries matching secret patterns are dropped" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{
            "failure_conditions" => [
              "wallet balance falls below requested amount",
              "Authorization: Bearer leaked",
              "see -----BEGIN RSA PRIVATE KEY----- in upstream",
              "https://user:pass@host failure",
              "use pk_live_xyz to bypass",
              "router liquidity drops below threshold"
            ]
          })
        )
      end)

      assert {:ok, %Preview{failure_conditions: conds}} = LiveProvider.preview(intent!())
      assert "wallet balance falls below requested amount" in conds
      assert "router liquidity drops below threshold" in conds
      assert length(conds) == 2
      refute Enum.any?(conds, &String.contains?(&1, "Bearer"))
      refute Enum.any?(conds, &String.contains?(&1, "PRIVATE KEY"))
      refute Enum.any?(conds, &String.contains?(&1, "pk_live_"))
    end

    test "Bank.Quotes.Persistence.to_simulation_attrs/3 carries no secret markers when upstream injects them" do
      # End-to-end backstop: even if a future regression skipped one
      # of the per-field redactions above, the persisted attrs (which
      # become a `simulation_reports` row) must not carry the markers.
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{
            "trace_id" => "Authorization: Bearer sk_live_leaked",
            "route" => %{
              "type" => "erc20_transfer",
              "leaked" => "sk_test_secret",
              "url" => "https://user:pass@host"
            },
            "failure_conditions" => [
              "Authorization: Bearer leaked",
              "real condition"
            ]
          })
        )
      end)

      assert {:ok, %Preview{} = preview} = LiveProvider.preview(intent!())
      attrs = Persistence.to_simulation_attrs(preview, Ecto.UUID.generate(), :completed)

      blob = inspect(attrs)
      refute blob =~ ~r/sk_(live|test)_/
      refute blob =~ ~r/pk_(live|test)_/
      refute blob =~ ~r/authorization|bearer/i
      refute blob =~ ~r{://[^\s/@]+:[^\s/@]+@}
      refute blob =~ "PRIVATE KEY"
    end

    test "benign route map passes through unchanged" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{
            "route" => %{
              "type" => "v3_swap",
              "pool" => "0xabc",
              "fee_bps" => 30,
              "hops" => [%{"asset" => "USDC"}, %{"asset" => "WETH"}]
            }
          })
        )
      end)

      assert {:ok, %Preview{route: route}} = LiveProvider.preview(intent!())
      assert route["type"] == "v3_swap"
      assert route["pool"] == "0xabc"
      assert route["fee_bps"] == 30
      assert route["hops"] == [%{"asset" => "USDC"}, %{"asset" => "WETH"}]
    end

    test "benign failure_conditions pass through unchanged" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{
            "failure_conditions" => [
              "wallet balance falls below requested amount",
              "router liquidity drops below threshold"
            ]
          })
        )
      end)

      assert {:ok, %Preview{failure_conditions: conds}} = LiveProvider.preview(intent!())
      assert "wallet balance falls below requested amount" in conds
      assert "router liquidity drops below threshold" in conds
      assert length(conds) == 2
    end

    test "route map entries whose KEY carries a secret marker are dropped entirely" do
      # PR #442 sanitised route values but left keys untouched, so
      # `%{"Authorization: Bearer sk_live_x" => "ok"}` would persist
      # the secret key through `inspect(route)` and into the
      # `simulation_reports.routing_path` jsonb column.
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{
            "route" => %{
              "type" => "erc20_transfer",
              "Authorization: Bearer sk_live_abc" => "ok",
              "sk_test_smuggled" => %{"nested" => "value"},
              "https://user:pass@evil/" => "credentialed",
              "-----BEGIN RSA PRIVATE KEY-----" => "pem dump",
              "asset" => "USDC"
            }
          })
        )
      end)

      assert {:ok, %Preview{route: route}} = LiveProvider.preview(intent!())
      assert route["type"] == "erc20_transfer"
      assert route["asset"] == "USDC"
      refute Map.has_key?(route, "Authorization: Bearer sk_live_abc")
      refute Map.has_key?(route, "sk_test_smuggled")
      refute Map.has_key?(route, "https://user:pass@evil/")
      refute Map.has_key?(route, "-----BEGIN RSA PRIVATE KEY-----")

      blob = inspect(route)
      refute blob =~ ~r/authorization|bearer/i
      refute blob =~ ~r/sk_(live|test)_/
      refute blob =~ ~r{://[^\s/@]+:[^\s/@]+@}
      refute blob =~ "PRIVATE KEY"
    end

    test "secret-bearing keys nested deep in the route map are dropped at every level" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{
            "route" => %{
              "type" => "v3_swap",
              "hops" => [
                %{"asset" => "USDC", "Bearer sk_live_x" => "leaked-1"},
                %{"asset" => "WETH", "pk_live_y" => %{"deep" => "leaked-2"}}
              ],
              "meta" => %{
                "Authorization: Bearer leaked-3" => "outer",
                "ok" => %{"sk_test_z" => "inner-leak", "fine" => "kept"}
              }
            }
          })
        )
      end)

      assert {:ok, %Preview{route: route}} = LiveProvider.preview(intent!())
      assert route["type"] == "v3_swap"
      assert [%{"asset" => "USDC"}, %{"asset" => "WETH"}] = route["hops"]
      assert route["meta"]["ok"]["fine"] == "kept"
      refute Map.has_key?(route["meta"]["ok"], "sk_test_z")

      blob = inspect(route)
      refute blob =~ ~r/authorization|bearer/i
      refute blob =~ ~r/sk_(live|test)_/
      refute blob =~ ~r/pk_(live|test)_/
      refute blob =~ "leaked-1"
      refute blob =~ "leaked-2"
      refute blob =~ "leaked-3"
      refute blob =~ "inner-leak"
    end

    test "Persistence.to_simulation_attrs/3 backstop covers secret-bearing keys" do
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{
            "route" => %{
              "type" => "erc20_transfer",
              "Authorization: Bearer sk_live_persisted" => "v",
              "nested" => %{"pk_test_persisted" => "v"}
            }
          })
        )
      end)

      assert {:ok, %Preview{} = preview} = LiveProvider.preview(intent!())
      attrs = Persistence.to_simulation_attrs(preview, Ecto.UUID.generate(), :completed)
      blob = inspect(attrs)

      refute blob =~ ~r/authorization|bearer/i
      refute blob =~ ~r/sk_(live|test)_/
      refute blob =~ ~r/pk_(live|test)_/
    end

    test "benign route keys with mixed shapes survive unchanged" do
      # The pattern guards must not over-match on plausibly named
      # benign keys (e.g. "asset", "pool", "type", numeric strings).
      Req.Test.stub(LiveProvider, fn conn ->
        Req.Test.json(
          conn,
          success_body(%{
            "route" => %{
              "type" => "v3_swap",
              "fee_bps" => 30,
              "0xabc" => "pool-address",
              "asset_in" => "USDC",
              "asset_out" => "WETH",
              "hops" => [%{"asset" => "USDC"}, %{"asset" => "WETH"}]
            }
          })
        )
      end)

      assert {:ok, %Preview{route: route}} = LiveProvider.preview(intent!())
      assert route["type"] == "v3_swap"
      assert route["fee_bps"] == 30
      assert route["0xabc"] == "pool-address"
      assert route["asset_in"] == "USDC"
      assert route["asset_out"] == "WETH"
      assert route["hops"] == [%{"asset" => "USDC"}, %{"asset" => "WETH"}]
    end
  end
end
