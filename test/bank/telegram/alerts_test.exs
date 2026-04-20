defmodule Bank.Telegram.AlertsTest do
  @moduledoc """
  Tests for the outbound alert surface introduced in issue #68.

  Pins:

    * the render path (text output is operator-readable, deterministic,
      and includes the minimum required context per alert type);
    * the inline-button boundary (only `:pending_approval` emits
      buttons, and only as signed callback tokens; #68 does NOT
      stand up the callback handlers, so no other alert type gets
      tappable controls);
    * the dispatch path (fan-out via `Bank.Telegram.Transport` with
      per-recipient buttons, no raw HTTP or env access outside the
      #69 boundary);
    * fail-closed behavior (disabled bot, missing token, empty
      allowlist, unknown alert, missing required field, every
      operator-side failure all take distinct error atoms).

  Transport is routed to `Req.Test` so no test ever talks to the
  real Telegram Bot API.
  """

  use ExUnit.Case, async: false

  alias Bank.Telegram.Alerts
  alias Bank.Telegram.CallbackToken
  alias Bank.Telegram.Operator

  @target_id "b6a10f53-8c6e-4d79-9bb9-3e1e5b1f1a11"
  @intent_id "2b2b2b2b-2b2b-2b2b-2b2b-2b2b2b2b2b2b"

  @approver_a %{user_id: 10_001, chat_id: 50, role: :approver, audit_actor: "ops-alice"}
  @approver_b %{user_id: 10_002, chat_id: 60, role: :approver, audit_actor: "ops-bob"}

  setup do
    original = Application.get_env(:bank, Bank.Telegram.Config)

    on_exit(fn ->
      if original do
        Application.put_env(:bank, Bank.Telegram.Config, original)
      else
        Application.delete_env(:bank, Bank.Telegram.Config)
      end
    end)

    :ok
  end

  defp configure(opts) do
    defaults = [
      enabled: true,
      bot_token: "test-bot-token",
      webhook_secret: "test-webhook-secret",
      operators: [@approver_a, @approver_b]
    ]

    Application.put_env(:bank, Bank.Telegram.Config, Keyword.merge(defaults, opts))
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

  defp op(attrs), do: struct!(Operator, attrs)

  describe "alert_types/0" do
    test "enumerates exactly the nine MVP alert classes from #68" do
      assert Enum.sort(Alerts.alert_types()) ==
               Enum.sort(~w(
                 pending_approval runtime_paused runtime_resumed
                 revoke_incident execution_confirmed execution_reverted
                 execution_aborted sanctions_hit scam_challenge
               )a)
    end
  end

  describe "render/1 — pending_approval" do
    test "includes intent id, amount, target, risk tier, and deep links" do
      assert {:ok, text} =
               Alerts.render(
                 {:pending_approval,
                  %{
                    intent_id: @intent_id,
                    decision_id: @target_id,
                    amount: "250.00",
                    asset: "USDC",
                    chain: "base",
                    target_label: "Acme Ops",
                    risk_tier: "elevated",
                    reasons: ["trust_sensitive", "amount_threshold"]
                  }}
               )

      assert text =~ "Pending approval"
      assert text =~ "Intent: #{@intent_id}"
      assert text =~ "250.00 USDC on base"
      assert text =~ "Acme Ops"
      assert text =~ "Risk tier: elevated"
      assert text =~ "Reasons: trust_sensitive, amount_threshold"
      assert text =~ "/queue"
      assert text =~ "/audit/replay/#{@intent_id}"
    end

    test "minimum-viable render requires intent_id + decision_id" do
      assert {:error, {:missing_field, :intent_id, :pending_approval}} =
               Alerts.render({:pending_approval, %{decision_id: @target_id}})

      assert {:error, {:missing_field, :decision_id, :pending_approval}} =
               Alerts.render({:pending_approval, %{intent_id: @intent_id}})
    end
  end

  describe "render/1 — runtime_paused / runtime_resumed" do
    test "runtime_paused includes scope, reason, actor, and security-console link" do
      assert {:ok, text} =
               Alerts.render(
                 {:runtime_paused,
                  %{scope: "global", reason: "operator_requested", actor_id: "ops-alice"}}
               )

      assert text =~ "Runtime paused"
      assert text =~ "Scope: global"
      assert text =~ "Reason: operator_requested"
      assert text =~ "By: ops-alice"
      assert text =~ "/security"
    end

    test "runtime_resumed includes scope, actor, and security-console link" do
      assert {:ok, text} =
               Alerts.render({:runtime_resumed, %{scope: "global", actor_id: "ops-bob"}})

      assert text =~ "Runtime resumed"
      assert text =~ "Scope: global"
      assert text =~ "By: ops-bob"
      assert text =~ "/security"
    end

    test "both require the scope field" do
      assert {:error, {:missing_field, :scope, :runtime_paused}} =
               Alerts.render({:runtime_paused, %{}})

      assert {:error, {:missing_field, :scope, :runtime_resumed}} =
               Alerts.render({:runtime_resumed, %{}})
    end
  end

  describe "render/1 — revoke_incident" do
    test "includes smart_account_id, state, and reason" do
      assert {:ok, text} =
               Alerts.render(
                 {:revoke_incident,
                  %{
                    smart_account_id: "sa_primary",
                    state: "revoke_failed",
                    reason: "bundler_error"
                  }}
               )

      assert text =~ "Delegation revoke incident"
      assert text =~ "Smart account: sa_primary"
      assert text =~ "State: revoke_failed"
      assert text =~ "Reason: bundler_error"
      assert text =~ "/security"
    end

    test "requires smart_account_id + state" do
      assert {:error, {:missing_field, :smart_account_id, :revoke_incident}} =
               Alerts.render({:revoke_incident, %{state: "revoked"}})

      assert {:error, {:missing_field, :state, :revoke_incident}} =
               Alerts.render({:revoke_incident, %{smart_account_id: "sa_1"}})
    end
  end

  describe "render/1 — execution outcomes" do
    for {type, header} <- [
          {:execution_confirmed, "Execution confirmed"},
          {:execution_reverted, "Execution reverted"},
          {:execution_aborted, "Execution aborted"}
        ] do
      @type_ type
      @header header

      test "#{type} renders with intent id, amount, plan, and replay link" do
        assert {:ok, text} =
                 Alerts.render(
                   {@type_,
                    %{
                      intent_id: @intent_id,
                      amount: "250.00",
                      asset: "USDC",
                      chain: "base",
                      plan_id: "plan-xyz",
                      final_reason: :adapter_aborted
                    }}
                 )

        assert text =~ @header
        assert text =~ "Intent: #{@intent_id}"
        assert text =~ "250.00 USDC on base"
        assert text =~ "Plan: plan-xyz"
        assert text =~ "Reason: adapter_aborted"
        assert text =~ "/audit/replay/#{@intent_id}"
      end

      test "#{type} requires intent_id" do
        assert {:error, {:missing_field, :intent_id, @type_}} = Alerts.render({@type_, %{}})
      end
    end
  end

  describe "render/1 — sanctions_hit / scam_challenge" do
    test "sanctions_hit states the block in the header" do
      assert {:ok, text} =
               Alerts.render(
                 {:sanctions_hit,
                  %{
                    intent_id: @intent_id,
                    address: "0xdeadbeef",
                    source_list: "OFAC-2024-09",
                    amount: "100",
                    asset: "USDC",
                    chain: "base"
                  }}
               )

      assert text =~ "Sanctions hit"
      assert text =~ "intent blocked"
      assert text =~ "Address: 0xdeadbeef"
      assert text =~ "List: OFAC-2024-09"
      assert text =~ "100 USDC on base"
      assert text =~ "/audit/replay/#{@intent_id}"
    end

    test "scam_challenge routes to the queue (approval-required wording)" do
      assert {:ok, text} =
               Alerts.render(
                 {:scam_challenge,
                  %{
                    intent_id: @intent_id,
                    address: "0xbad",
                    source_list: "scamsniffer",
                    amount: "10",
                    asset: "USDC",
                    chain: "base"
                  }}
               )

      assert text =~ "Scam / phishing challenge"
      assert text =~ "approval required"
      assert text =~ "/queue"
      assert text =~ "/audit/replay/#{@intent_id}"
    end

    test "both require intent_id + address" do
      for type <- [:sanctions_hit, :scam_challenge] do
        assert {:error, {:missing_field, :intent_id, ^type}} = Alerts.render({type, %{}})

        assert {:error, {:missing_field, :address, ^type}} =
                 Alerts.render({type, %{intent_id: @intent_id}})
      end
    end
  end

  describe "render/1 — edge cases" do
    test "rejects unknown alert types" do
      assert {:error, :unknown_alert} = Alerts.render({:not_a_real_alert, %{}})
    end

    test "rejects non-map contexts" do
      assert {:error, :unknown_alert} = Alerts.render({:pending_approval, "not a map"})
    end
  end

  describe "buttons_for/2" do
    test "pending_approval emits exactly approve + reject with signed callback tokens" do
      op_a = op(@approver_a)

      buttons =
        Alerts.buttons_for({:pending_approval, %{decision_id: @target_id}}, op_a)

      assert [
               %{label: "Approve", callback_data: approve_token},
               %{label: "Reject", callback_data: reject_token}
             ] =
               buttons

      assert {:ok, approve} = CallbackToken.verify(approve_token, op_a.user_id, op_a.chat_id)
      assert approve.action == :approve
      assert approve.target_id == @target_id

      assert {:ok, reject} = CallbackToken.verify(reject_token, op_a.user_id, op_a.chat_id)
      assert reject.action == :reject
    end

    test "tokens are actor-bound per recipient — token for operator A is rejected for operator B" do
      op_a = op(@approver_a)
      op_b = op(@approver_b)

      [%{callback_data: token_for_a} | _] =
        Alerts.buttons_for({:pending_approval, %{decision_id: @target_id}}, op_a)

      assert {:error, :actor_mismatch} =
               CallbackToken.verify(token_for_a, op_b.user_id, op_b.chat_id)
    end

    test "every non-approval alert emits zero buttons" do
      op_a = op(@approver_a)

      for type <- Alerts.alert_types(), type != :pending_approval do
        assert [] = Alerts.buttons_for({type, %{}}, op_a)
      end
    end
  end

  describe "dispatch/1 — happy path" do
    test "fans out one send_message per operator with per-recipient buttons on pending_approval" do
      configure([])
      stub_transport_ok(self())

      alert =
        {:pending_approval,
         %{
           intent_id: @intent_id,
           decision_id: @target_id,
           amount: "250.00",
           asset: "USDC",
           chain: "base"
         }}

      assert :ok = Alerts.dispatch(alert)

      payloads = collect_payloads(2)

      chat_ids = Enum.map(payloads, & &1["chat_id"])
      assert Enum.sort(chat_ids) == Enum.sort([@approver_a.chat_id, @approver_b.chat_id])

      for payload <- payloads do
        # Each recipient gets both approve + reject buttons.
        [[approve, reject]] =
          get_in(payload, ["reply_markup", "inline_keyboard"])

        assert approve["text"] == "Approve"
        assert reject["text"] == "Reject"

        # Tokens are bound to this recipient.
        matching_op = Enum.find([@approver_a, @approver_b], &(&1.chat_id == payload["chat_id"]))

        assert {:ok, %{action: :approve}} =
                 CallbackToken.verify(
                   approve["callback_data"],
                   matching_op.user_id,
                   matching_op.chat_id
                 )
      end
    end

    test "non-approval alerts send text without reply_markup" do
      configure([])
      stub_transport_ok(self())

      alert = {:runtime_paused, %{scope: "global", reason: "operator_requested"}}
      assert :ok = Alerts.dispatch(alert)

      payloads = collect_payloads(2)

      for payload <- payloads do
        assert payload["text"] =~ "Runtime paused"
        refute Map.has_key?(payload, "reply_markup")
      end
    end
  end

  describe "dispatch/1 — fail-closed surface" do
    test "bot disabled short-circuits before any transport call" do
      configure(enabled: false)
      # No transport stub installed — any HTTP attempt would raise.

      alert = {:runtime_paused, %{scope: "global"}}
      assert {:error, :bot_disabled} = Alerts.dispatch(alert)
    end

    test "bot enabled but token missing returns :bot_not_configured (no transport call)" do
      configure(bot_token: nil)
      alert = {:runtime_paused, %{scope: "global"}}
      assert {:error, :bot_not_configured} = Alerts.dispatch(alert)
    end

    test "malformed config shape returns :invalid_config" do
      Application.put_env(:bank, Bank.Telegram.Config,
        enabled: true,
        bot_token: "t",
        webhook_secret: "w",
        operators: [%{user_id: 1, chat_id: 1, role: :god_mode, audit_actor: "x"}]
      )

      alert = {:runtime_paused, %{scope: "global"}}
      assert {:error, :invalid_config} = Alerts.dispatch(alert)
    end

    test "empty allowlist returns :no_operators (misconfig surface, not a silent no-op)" do
      configure(operators: [])
      alert = {:runtime_paused, %{scope: "global"}}
      assert {:error, :no_operators} = Alerts.dispatch(alert)
    end

    test "render errors propagate through dispatch without calling transport" do
      configure([])
      # Missing required fields; no transport stub means any HTTP call would raise.
      assert {:error, {:missing_field, :scope, :runtime_paused}} =
               Alerts.dispatch({:runtime_paused, %{}})
    end

    test "every operator failing returns {:all_failed, [...]}" do
      configure([])

      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        Req.Test.transport_error(conn, :econnrefused)
      end)

      assert {:error, {:all_failed, failures}} =
               Alerts.dispatch({:runtime_paused, %{scope: "global"}})

      assert Enum.sort(Enum.map(failures, fn {chat_id, _} -> chat_id end)) ==
               Enum.sort([@approver_a.chat_id, @approver_b.chat_id])

      for {_chat_id, {:error, reason}} <- failures do
        assert reason == :telegram_unavailable
      end
    end

    test "partial failures still return :ok (best-effort delivery) and log the loser" do
      configure([])

      test_pid = self()

      Req.Test.stub(Bank.Telegram.Transport, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)
        send(test_pid, {:sent, payload})

        # Fail only the second operator's chat.
        if payload["chat_id"] == @approver_b.chat_id do
          Req.Test.transport_error(conn, :econnrefused)
        else
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 1}}))
        end
      end)

      # The stub is per-process and alerts run synchronously, so the
      # result is deterministic: one success + one failure → :ok.
      assert :ok = Alerts.dispatch({:runtime_paused, %{scope: "global"}})
    end
  end

  # --- test helpers ---

  defp collect_payloads(n) do
    for _ <- 1..n do
      assert_receive {:sent, payload}, 500
      payload
    end
  end
end
