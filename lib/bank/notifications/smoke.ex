defmodule Bank.Notifications.Smoke do
  @moduledoc """
  Notifications smoke runner (#237).

  Drives every notification surface a fresh reviewer needs to
  inspect locally:

    * **Emitter → inbox row** via the seeded
      `partner-x-pending-approval` (`:approval_required`)
      and `treasury-held` (`:hold`) intents.
    * **Inbox state transitions** via
      `Bank.Notifications.mark_read/2` and
      `Bank.Notifications.archive/2`.
    * **Delivery preferences + state** via
      `Bank.Notifications.Deliveries.set_preference/1`,
      `enqueue_deliveries/1`, and `attempt_delivery/2` against
      the stub channel — including a deliberate transient
      failure to demonstrate the retry path.
    * **Secret hygiene** by scanning every emitted row's
      `title`, `body`, `action_link`, and `dedupe_key` for the
      same secret-marker family the inbox row's create
      changeset already rejects (#233).

  ## Side-effect contract

    * No `Bank.AdapterClient` calls.
    * No `.env` reads. No real SMTP / webhook / Telegram —
      every channel routes to `Bank.Notifications.Channel.Stub`.
    * No Oban jobs enqueued.
    * No chain network. No HTTP outside the BEAM process.
    * Within the demo workspace the smoke writes inbox rows
      and delivery rows. Re-runs are idempotent: the inbox
      row's `(workspace_id, dedupe_key)` unique constraint
      and the delivery row's `(notification_id, channel)`
      unique constraint collapse repeats. The
      `attempt_delivery/2` terminal-state guard from
      #236 P2 keeps a re-run from regressing a delivered
      row.
  """

  alias Bank.Decisions.DecisionEnvelope
  alias Bank.Demo
  alias Bank.Intents.AgentIntent
  alias Bank.Notifications
  alias Bank.Notifications.Deliveries
  alias Bank.Notifications.Delivery
  alias Bank.Notifications.Emitter
  alias Bank.Notifications.Notification
  alias Bank.Repo

  @approval_intent_idempotency "sandbox-partner-x-pending-approval"
  @hold_intent_idempotency "sandbox-treasury-held"

  @secret_markers [
    ~r/Authorization\s*:/i,
    ~r/Bearer\s+[^\s]+/i,
    ~r/sk_(test|live)_/i,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----/,
    ~r/private_key/i
  ]

  @type status :: :pass | :fail

  @type check :: %{name: String.t(), status: status(), detail: String.t()}

  @type report :: %{
          workspace_slug: String.t(),
          workspace_id: Ecto.UUID.t() | nil,
          status: status(),
          checks: [check()],
          passed: non_neg_integer(),
          total: non_neg_integer()
        }

  @doc """
  Run every smoke check. Always returns; never raises. The Mix
  task wraps this in a `case` to choose the exit code.
  """
  @spec run() :: {:ok, report()} | {:error, report()}
  def run do
    workspace_slug = Demo.workspace_slug()

    case Demo.demo_workspace_id() do
      nil ->
        finalize(workspace_slug, nil, [
          %{
            name: "seed",
            status: :fail,
            detail: "demo workspace #{workspace_slug} not found — run `mix bank.demo.seed`"
          }
        ])

      workspace_id ->
        finalize(workspace_slug, workspace_id, run_checks(workspace_id))
    end
  end

  defp run_checks(workspace_id) do
    pre_checks = [check_seed_intents()]

    case fetch_seed_intents() do
      {:ok, approval, hold} ->
        pre_checks ++ run_main_checks(workspace_id, approval, hold)

      :error ->
        pre_checks
    end
  end

  defp run_main_checks(workspace_id, approval_intent, hold_intent) do
    {approval_envelope, hold_envelope} = current_envelopes(approval_intent, hold_intent)

    # Set up the operator-tier email + webhook preferences
    # BEFORE emitting any notification so the post-create
    # `dispatch_after_create/1` hook lands the matching
    # delivery rows.
    [
      check_set_operator_preferences(workspace_id),
      check_emit_approval(approval_intent, approval_envelope),
      check_emit_hold(hold_intent, hold_envelope),
      check_mark_read(workspace_id, approval_intent),
      check_archive(workspace_id, hold_intent),
      check_delivery_preference_dispatch(workspace_id, approval_intent),
      check_delivery_attempt_success(workspace_id),
      check_delivery_attempt_transient_failure(workspace_id),
      check_secret_hygiene(workspace_id)
    ]
  end

  defp finalize(workspace_slug, workspace_id, checks) do
    passed = Enum.count(checks, &(&1.status == :pass))
    total = length(checks)
    overall = if passed == total, do: :pass, else: :fail

    report = %{
      workspace_slug: workspace_slug,
      workspace_id: workspace_id,
      status: overall,
      checks: checks,
      passed: passed,
      total: total
    }

    case overall do
      :pass -> {:ok, report}
      :fail -> {:error, report}
    end
  end

  # --- Checks ----------------------------------------------------------

  defp check_seed_intents do
    case fetch_seed_intents() do
      {:ok, _approval, _hold} ->
        pass(
          "seed_intents",
          "demo intents present (`#{@approval_intent_idempotency}` + `#{@hold_intent_idempotency}`)"
        )

      :error ->
        fail(
          "seed_intents",
          "missing demo intents — run `mix bank.demo.seed` to populate the sandbox-demo workspace"
        )
    end
  end

  defp check_set_operator_preferences(workspace_id) do
    email_result =
      Deliveries.set_preference(%{
        workspace_id: workspace_id,
        role_target: :operator,
        channel: :email,
        min_severity: :warning,
        enabled: true
      })

    webhook_result =
      Deliveries.set_preference(%{
        workspace_id: workspace_id,
        role_target: :operator,
        channel: :webhook,
        min_severity: :warning,
        enabled: true
      })

    case {email_result, webhook_result} do
      {{:ok, _}, {:ok, _}} ->
        pass(
          "operator_preferences",
          "operator preferences set for :email + :webhook (min_severity=:warning)"
        )

      {{:error, cs}, _} ->
        fail("operator_preferences", "email preference upsert failed: #{inspect(cs.errors)}")

      {_, {:error, cs}} ->
        fail("operator_preferences", "webhook preference upsert failed: #{inspect(cs.errors)}")
    end
  end

  defp check_emit_approval(intent, envelope) do
    case envelope do
      %DecisionEnvelope{} = env ->
        case Emitter.emit_decision_outcome(intent, env) do
          {:ok, %Notification{event_type: "decision.approval_required"} = n} ->
            pass(
              "emit_approval_required",
              "inbox row created (id=#{short(n.id)} severity=#{n.severity})"
            )

          {:duplicate, %Notification{} = n} ->
            pass(
              "emit_approval_required",
              "inbox row already present (idempotent re-run; id=#{short(n.id)})"
            )

          other ->
            fail("emit_approval_required", "unexpected emitter result: #{inspect(other)}")
        end

      _ ->
        fail("emit_approval_required", "no current decision envelope for the approval intent")
    end
  end

  defp check_emit_hold(intent, envelope) do
    case envelope do
      %DecisionEnvelope{} = env ->
        case Emitter.emit_decision_outcome(intent, env) do
          {:ok, %Notification{event_type: "decision.hold"} = n} ->
            pass("emit_hold", "inbox row created (id=#{short(n.id)} severity=#{n.severity})")

          {:duplicate, %Notification{} = n} ->
            pass("emit_hold", "inbox row already present (idempotent re-run; id=#{short(n.id)})")

          other ->
            fail("emit_hold", "unexpected emitter result: #{inspect(other)}")
        end

      _ ->
        fail("emit_hold", "no current decision envelope for the hold intent")
    end
  end

  defp check_mark_read(workspace_id, intent) do
    case find_inbox_row(workspace_id, intent.id, "decision.approval_required") do
      %Notification{} = n ->
        case Notifications.mark_read(n) do
          {:ok, %Notification{status: :read}} ->
            pass("mark_read", "approval notification flipped to :read")

          {:error, :archived} ->
            pass(
              "mark_read",
              "approval notification was already archived from a prior run (idempotent)"
            )

          other ->
            fail("mark_read", "unexpected mark_read result: #{inspect(other)}")
        end

      nil ->
        fail("mark_read", "could not locate the approval inbox row to mark read")
    end
  end

  defp check_archive(workspace_id, intent) do
    case find_inbox_row(workspace_id, intent.id, "decision.hold") do
      %Notification{} = n ->
        case Notifications.archive(n) do
          {:ok, %Notification{status: :archived}} ->
            pass("archive", "hold notification flipped to :archived")

          other ->
            fail("archive", "unexpected archive result: #{inspect(other)}")
        end

      nil ->
        fail("archive", "could not locate the hold inbox row to archive")
    end
  end

  defp check_delivery_preference_dispatch(workspace_id, intent) do
    case find_inbox_row(workspace_id, intent.id, "decision.approval_required") do
      %Notification{} = n ->
        case Deliveries.list_deliveries_for(n) do
          [] ->
            fail(
              "delivery_preference_dispatch",
              "no delivery rows created for the approval notification"
            )

          rows ->
            channels = rows |> Enum.map(& &1.channel) |> Enum.sort()

            pass(
              "delivery_preference_dispatch",
              "delivery rows queued for channel(s): #{inspect(channels)}"
            )
        end

      nil ->
        fail(
          "delivery_preference_dispatch",
          "approval inbox row missing — emit_approval_required check should have created it"
        )
    end
  end

  defp check_delivery_attempt_success(workspace_id) do
    Application.put_env(:bank, Bank.Notifications.Channel.Stub,
      result: {:ok, %{provider: "stub"}}
    )

    case oldest_queued_delivery(workspace_id) do
      %Delivery{} = d ->
        case Deliveries.attempt_delivery(d, DateTime.utc_now()) do
          {:ok, %Delivery{status: :delivered}} ->
            pass("delivery_attempt_success", "stub :ok → :delivered")

          {:ok, %Delivery{status: status}} ->
            pass(
              "delivery_attempt_success",
              "no queued row left to deliver; current status #{status} (idempotent re-run)"
            )

          other ->
            fail("delivery_attempt_success", "unexpected attempt result: #{inspect(other)}")
        end

      nil ->
        # All deliveries already terminal from a prior run —
        # the terminal-state guard means this is a safe no-op.
        pass(
          "delivery_attempt_success",
          "no queued delivery row remained (terminal-state guard exercised by prior run)"
        )
    end
  after
    Application.delete_env(:bank, Bank.Notifications.Channel.Stub)
  end

  defp check_delivery_attempt_transient_failure(workspace_id) do
    # Webhook preference is already set in
    # `check_set_operator_preferences/1`. Force the stub to a
    # transient error and attempt the queued webhook delivery.
    # The transient path increments `attempts`, schedules a
    # retry, and stays in `:failed` until the retry-cap is hit.
    case oldest_queued_delivery(workspace_id, :webhook) do
      %Delivery{} = d ->
        Application.put_env(:bank, Bank.Notifications.Channel.Stub,
          result: {:error, :transport_error}
        )

        try do
          case Deliveries.attempt_delivery(d, DateTime.utc_now()) do
            {:ok, %Delivery{status: :failed, attempts: a, last_error: :transport_error}}
            when a >= 1 ->
              pass(
                "delivery_attempt_transient_failure",
                "stub :transport_error → :failed (attempts=#{a}); next_attempt_at scheduled"
              )

            {:ok, %Delivery{status: :permanently_failed, attempts: a}} ->
              pass(
                "delivery_attempt_transient_failure",
                "row reached :permanently_failed after attempts=#{a}; retry cap demonstrated"
              )

            other ->
              fail(
                "delivery_attempt_transient_failure",
                "unexpected attempt result: #{inspect(other)}"
              )
          end
        after
          Application.delete_env(:bank, Bank.Notifications.Channel.Stub)
        end

      nil ->
        pass(
          "delivery_attempt_transient_failure",
          "no queued webhook delivery (already exercised in a prior run)"
        )
    end
  end

  defp check_secret_hygiene(workspace_id) do
    notifications = Notifications.list_for_workspace(workspace_id, status: :all, limit: 100)
    deliveries = Enum.flat_map(notifications, &Deliveries.list_deliveries_for/1)

    leaks =
      []
      |> collect_notification_leaks(notifications)
      |> collect_delivery_leaks(deliveries)

    case leaks do
      [] ->
        pass(
          "secret_hygiene",
          "scanned #{length(notifications)} inbox + #{length(deliveries)} delivery row(s); no secret markers"
        )

      _ ->
        fail("secret_hygiene", "secret marker(s) found: #{inspect(leaks)}")
    end
  end

  # --- Helpers ---------------------------------------------------------

  defp pass(name, detail), do: %{name: name, status: :pass, detail: detail}
  defp fail(name, detail), do: %{name: name, status: :fail, detail: detail}

  defp short(uuid) when is_binary(uuid), do: String.slice(uuid, 0, 8)

  defp fetch_seed_intents do
    approval = Repo.get_by(AgentIntent, idempotency_key: @approval_intent_idempotency)
    hold = Repo.get_by(AgentIntent, idempotency_key: @hold_intent_idempotency)

    case {approval, hold} do
      {%AgentIntent{} = a, %AgentIntent{} = h} -> {:ok, a, h}
      _ -> :error
    end
  end

  defp current_envelopes(approval_intent, hold_intent) do
    {
      Repo.get_by(DecisionEnvelope, intent_id: approval_intent.id, current: true),
      Repo.get_by(DecisionEnvelope, intent_id: hold_intent.id, current: true)
    }
  end

  defp find_inbox_row(workspace_id, intent_id, event_type) do
    workspace_id
    |> Notifications.list_for_workspace(status: :all, limit: 100, event_type: event_type)
    |> Enum.find(fn n -> n.correlation_id == intent_id end)
  end

  defp oldest_queued_delivery(workspace_id, channel \\ :email) do
    import Ecto.Query, only: [from: 2]

    Repo.one(
      from(d in Delivery,
        where: d.workspace_id == ^workspace_id and d.status == :queued and d.channel == ^channel,
        order_by: [asc: d.inserted_at],
        limit: 1
      )
    )
  end

  defp collect_notification_leaks(acc, notifications) do
    Enum.reduce(notifications, acc, fn n, leaks ->
      [n.title, n.body, n.action_link, n.dedupe_key]
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(leaks, fn value, inner ->
        case scan(value) do
          nil -> inner
          marker -> [{:notification, n.id, marker} | inner]
        end
      end)
    end)
  end

  defp collect_delivery_leaks(acc, deliveries) do
    Enum.reduce(deliveries, acc, fn d, leaks ->
      # Delivery rows do not carry user text, but
      # `last_error` could conceivably regress to a free-text
      # value if a future channel violates the closed enum.
      # Defensive scan.
      case d.last_error && to_string(d.last_error) do
        nil ->
          leaks

        value ->
          case scan(value) do
            nil -> leaks
            marker -> [{:delivery, d.id, marker} | leaks]
          end
      end
    end)
  end

  defp scan(nil), do: nil
  defp scan(value) when is_binary(value), do: Enum.find(@secret_markers, &Regex.match?(&1, value))
end
