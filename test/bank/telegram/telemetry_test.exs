defmodule Bank.Telegram.TelemetryTest do
  @moduledoc """
  Tests for the Telegram observability surface introduced in
  issue #74.

  Two concerns:

    * `Bank.Telegram.Transport.retriable?/1` is the authoritative
      retry classification — dashboards, tests, and any future
      retry policy consult it. The truth table is pinned here.
    * `Bank.Telegram.Telemetry` events fire at the three boundary
      points (transport, alert, webhook-auth) with the expected
      result atoms and measurements, so dashboards and alerting
      pipelines can observe them without parsing log lines.

  Telemetry attachment is per-test and cleaned up in `on_exit/1`.
  No telemetry is left hanging off shared handlers after a test
  finishes.
  """

  use Bank.DataCase, async: false

  alias Bank.Telegram.Alerts
  alias Bank.Telegram.Transport
  alias BankWeb.Plugs.VerifyTelegramWebhook

  @webhook_header "x-telegram-bot-api-secret-token"

  @approver %{user_id: 10_001, chat_id: 50, role: :approver, audit_actor: "ops-alice"}

  setup do
    original = Application.get_env(:bank, Bank.Telegram.Config)

    Application.put_env(:bank, Bank.Telegram.Config,
      enabled: true,
      bot_token: "test-bot-token",
      webhook_secret: "test-webhook-secret",
      operators: [@approver]
    )

    on_exit(fn ->
      if original do
        Application.put_env(:bank, Bank.Telegram.Config, original)
      else
        Application.delete_env(:bank, Bank.Telegram.Config)
      end
    end)

    :ok
  end

  defp attach(event, test_pid, id \\ nil) do
    id = id || make_ref()

    :telemetry.attach(
      id,
      event,
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp stub_transport_ok(test_pid) do
    Req.Test.stub(Bank.Telegram.Transport, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:sent, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 1}}))
    end)
  end

  describe "Transport.retriable?/1" do
    test "network / DNS / timeout is retriable" do
      assert Transport.retriable?(:telegram_unavailable) == true
    end

    test "Telegram 5xx and 429 are retriable; other 4xx are not" do
      assert Transport.retriable?({:telegram_rejected, 503, %{}}) == true
      assert Transport.retriable?({:telegram_rejected, 502, ""}) == true

      assert Transport.retriable?(
               {:telegram_rejected, 429, %{"parameters" => %{"retry_after" => 3}}}
             ) ==
               true

      assert Transport.retriable?({:telegram_rejected, 400, %{}}) == false
      assert Transport.retriable?({:telegram_rejected, 404, %{}}) == false
    end

    test "invalid 2xx body is treated as a contract bug, not retriable" do
      assert Transport.retriable?(:invalid_response) == false
    end

    test "config-side errors are not retriable — operator must change config" do
      assert Transport.retriable?(:bot_disabled) == false
      assert Transport.retriable?(:bot_not_configured) == false
      assert Transport.retriable?(:invalid_config) == false
    end

    test "unknown reasons return :unknown — callers can log and fail closed" do
      assert Transport.retriable?(:something_new) == :unknown
      assert Transport.retriable?({:weird_shape, :here}) == :unknown
    end
  end

  describe "Bank.Telegram.Telemetry — transport events" do
    test "emits :ok with retriable=false on a successful sendMessage" do
      attach([:bank, :telegram, :transport], self())
      stub_transport_ok(self())

      assert {:ok, _} = Transport.send_message(123, "hi")

      assert_receive {:telemetry, [:bank, :telegram, :transport], %{count: 1},
                      %{method: "sendMessage", result: :ok, retriable: false}}
    end

    test "emits :telegram_unavailable with retriable=true on a transport failure" do
      attach([:bank, :telegram, :transport], self())

      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, :telegram_unavailable} = Transport.send_message(123, "hi")

      assert_receive {:telemetry, [:bank, :telegram, :transport], _,
                      %{method: "sendMessage", result: :telegram_unavailable, retriable: true}}
    end

    test "emits :telegram_rejected with retriable=false on a 4xx" do
      attach([:bank, :telegram, :transport], self())

      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{"ok" => false, "description" => "bad chat"}))
      end)

      assert {:error, {:telegram_rejected, 400, _}} = Transport.send_message(123, "hi")

      assert_receive {:telemetry, [:bank, :telegram, :transport], _,
                      %{method: "sendMessage", result: :telegram_rejected, retriable: false}}
    end

    test "emits :bot_disabled without making any HTTP call" do
      Application.put_env(:bank, Bank.Telegram.Config,
        enabled: false,
        bot_token: "t",
        webhook_secret: "s",
        operators: []
      )

      attach([:bank, :telegram, :transport], self())
      # No stub installed. Any HTTP attempt would raise.

      assert {:error, :bot_disabled} = Transport.send_message(123, "hi")

      assert_receive {:telemetry, [:bank, :telegram, :transport], _,
                      %{method: "sendMessage", result: :bot_disabled, retriable: false}}
    end
  end

  describe "Bank.Telegram.Telemetry — alert events" do
    test "emits :ok with full targeted count on happy-path dispatch" do
      attach([:bank, :telegram, :alert], self())
      stub_transport_ok(self())

      assert :ok = Alerts.dispatch({:runtime_paused, %{scope: "global"}})

      assert_receive {:telemetry, [:bank, :telegram, :alert], %{count: 1, targeted: 1, failed: 0},
                      %{alert_type: :runtime_paused, result: :ok}}
    end

    test "emits :all_failed with the failure count when every operator fails" do
      attach([:bank, :telegram, :alert], self())

      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:all_failed, _}} =
               Alerts.dispatch({:runtime_paused, %{scope: "global"}})

      assert_receive {:telemetry, [:bank, :telegram, :alert], %{count: 1, targeted: 1, failed: 1},
                      %{alert_type: :runtime_paused, result: :all_failed}}
    end

    test "emits :ok with a non-zero failed count on partial delivery" do
      approver_b = %{user_id: 10_002, chat_id: 60, role: :approver, audit_actor: "ops-bob"}

      Application.put_env(:bank, Bank.Telegram.Config,
        enabled: true,
        bot_token: "test-bot-token",
        webhook_secret: "test-webhook-secret",
        operators: [@approver, approver_b]
      )

      attach([:bank, :telegram, :alert], self())

      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        if payload["chat_id"] == approver_b.chat_id do
          Req.Test.transport_error(conn, :econnrefused)
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 1}}))
        end
      end)

      assert :ok = Alerts.dispatch({:runtime_paused, %{scope: "global"}})

      assert_receive {:telemetry, [:bank, :telegram, :alert], %{count: 1, targeted: 2, failed: 1},
                      %{alert_type: :runtime_paused, result: :ok}}
    end

    test "emits :bot_disabled without any transport call when the bot is off" do
      Application.put_env(:bank, Bank.Telegram.Config,
        enabled: false,
        bot_token: "t",
        webhook_secret: "s",
        operators: []
      )

      attach([:bank, :telegram, :alert], self())

      assert {:error, :bot_disabled} =
               Alerts.dispatch({:runtime_paused, %{scope: "global"}})

      assert_receive {:telemetry, [:bank, :telegram, :alert], %{count: 1, targeted: 0, failed: 0},
                      %{alert_type: :runtime_paused, result: :bot_disabled}}
    end

    test "emits :render_error on a missing-field dispatch" do
      attach([:bank, :telegram, :alert], self())

      assert {:error, {:missing_field, :scope, :runtime_paused}} =
               Alerts.dispatch({:runtime_paused, %{}})

      assert_receive {:telemetry, [:bank, :telegram, :alert], _,
                      %{alert_type: :runtime_paused, result: :render_error}}
    end
  end

  describe "Bank.Telegram.Telemetry — webhook_auth events" do
    test "emits :ok on a matching X-Telegram-Bot-Api-Secret-Token header" do
      attach([:bank, :telegram, :webhook_auth], self())

      call_webhook_plug(fn conn ->
        Plug.Conn.put_req_header(conn, @webhook_header, "test-webhook-secret")
      end)

      assert_receive {:telemetry, [:bank, :telegram, :webhook_auth], %{count: 1}, %{result: :ok}}
    end

    test "emits :missing_secret_token when the header is absent" do
      attach([:bank, :telegram, :webhook_auth], self())

      call_webhook_plug(& &1)

      assert_receive {:telemetry, [:bank, :telegram, :webhook_auth], _,
                      %{result: :missing_secret_token}}
    end

    test "emits :invalid_secret_token when the header does not match" do
      attach([:bank, :telegram, :webhook_auth], self())

      call_webhook_plug(fn conn ->
        Plug.Conn.put_req_header(conn, @webhook_header, "definitely-not-the-secret")
      end)

      assert_receive {:telemetry, [:bank, :telegram, :webhook_auth], _,
                      %{result: :invalid_secret_token}}
    end

    test "emits :bot_disabled when the bot is off" do
      Application.put_env(:bank, Bank.Telegram.Config,
        enabled: false,
        bot_token: "t",
        webhook_secret: "test-webhook-secret",
        operators: []
      )

      attach([:bank, :telegram, :webhook_auth], self())

      call_webhook_plug(fn conn ->
        Plug.Conn.put_req_header(conn, @webhook_header, "test-webhook-secret")
      end)

      assert_receive {:telemetry, [:bank, :telegram, :webhook_auth], _, %{result: :bot_disabled}}
    end

    test "emits :server_misconfigured when :webhook_secret is missing" do
      Application.put_env(:bank, Bank.Telegram.Config,
        enabled: true,
        bot_token: "t",
        operators: []
      )

      attach([:bank, :telegram, :webhook_auth], self())

      call_webhook_plug(fn conn ->
        Plug.Conn.put_req_header(conn, @webhook_header, "anything")
      end)

      assert_receive {:telemetry, [:bank, :telegram, :webhook_auth], _,
                      %{result: :server_misconfigured}}
    end

    test "emits :server_misconfigured when config shape is broken" do
      Application.put_env(:bank, Bank.Telegram.Config,
        enabled: true,
        bot_token: "t",
        webhook_secret: "test-webhook-secret",
        operators: :not_a_list
      )

      attach([:bank, :telegram, :webhook_auth], self())

      call_webhook_plug(fn conn ->
        Plug.Conn.put_req_header(conn, @webhook_header, "test-webhook-secret")
      end)

      assert_receive {:telemetry, [:bank, :telegram, :webhook_auth], _,
                      %{result: :server_misconfigured}}
    end
  end

  describe "Bank.Telegram.Telemetry.events/0" do
    test "lists the three event families #74 stands up" do
      assert Bank.Telegram.Telemetry.events() == [
               [:bank, :telegram, :transport],
               [:bank, :telegram, :alert],
               [:bank, :telegram, :webhook_auth]
             ]
    end
  end

  defp call_webhook_plug(prepare) do
    :post
    |> Plug.Test.conn("/internal/telegram/webhook", "{}")
    |> prepare.()
    |> VerifyTelegramWebhook.call([])
  end
end
