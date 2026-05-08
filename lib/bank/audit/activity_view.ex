defmodule Bank.Audit.ActivityView do
  @moduledoc """
  Transforms `%Bank.Audit.AuditEvent{}` rows into the design's
  ActivityRow shape used by `BankWeb.AgentLive`'s strip and
  `BankWeb.AgentActivityLive`.

  Centralised so both screens render identically. The output map is
  consumed by `BankWeb.AgentComponents.activity_row/1`, which only
  reads `:id`, `:t`, `:status`, `:title`, `:reason`, `:amount` — but
  this module also stamps a `:kind` field that the activity-screen
  filters group by.

  Field semantics:

    * `:id`     — audit event id (UUID string)
    * `:t`      — relative humanised timestamp (e.g. "2 min ago")
    * `:kind`   — one of `"wallet"`, `"permission"`, `"intent"`,
                  `"execution"`, `"security"`, `"system"`. Strings
                  to match the existing seed shape and the
                  `BankWeb.AgentActivityLive` filter logic.
    * `:status` — pill kind string accepted by
                  `BankWeb.AgentComponents.status_pill/1`
                  (`"executed"`, `"blocked"`, `"pending"`,
                  `"needs-approval"`, `"note"`, `"revoked"`,
                  `"expired"`, `"installed"`, `"installing"`,
                  `"failed"`).
    * `:title`  — short headline shown next to the pill.
    * `:reason` — optional one-liner under the title (or `nil`).
    * `:amount` — optional signed USDC amount string (or `nil`).
    * `:tx_hash` — optional onchain tx hash for execution rows.
  """

  alias Bank.Audit.AuditEvent

  @type entry :: %{
          id: String.t(),
          t: String.t(),
          kind: String.t(),
          status: String.t(),
          title: String.t(),
          reason: String.t() | nil,
          amount: String.t() | nil,
          tx_hash: String.t() | nil
        }

  @doc """
  Render one audit event or a list of events into the activity-row
  shape consumed by the agent screens.
  """
  @spec render(AuditEvent.t() | [AuditEvent.t()]) :: entry() | [entry()]
  def render(events) when is_list(events), do: Enum.map(events, &render_one/1)
  def render(%AuditEvent{} = event), do: render_one(event)

  # --- per-event-type formatters ---------------------------------------

  defp render_one(%AuditEvent{event_type: type} = e)
       when type in ["wallet_binding.verified", "wallet_binding.confirmed"] do
    base(e, "wallet", "note", "Wallet connected", wallet_reason(e))
  end

  defp render_one(%AuditEvent{event_type: "wallet_binding.revoked"} = e) do
    base(e, "wallet", "revoked", "Wallet disconnected", reason_field(e))
  end

  defp render_one(%AuditEvent{event_type: "wallet_binding.failed"} = e) do
    base(e, "wallet", "failed", "Wallet connect failed", reason_field(e))
  end

  defp render_one(%AuditEvent{event_type: "delegation.install_envelope_issued"} = e) do
    base(e, "permission", "pending", "Install requested", "Awaiting your signature")
  end

  defp render_one(%AuditEvent{event_type: "delegation.install_signed_by_user"} = e) do
    base(e, "permission", "installing", "Install signed", "Submitting userop")
  end

  defp render_one(%AuditEvent{event_type: "delegation.install_confirmed_onchain"} = e) do
    base(e, "permission", "installed", "Permission installed", "Ready to use")
  end

  defp render_one(%AuditEvent{event_type: "delegation.install_failed"} = e) do
    base(e, "permission", "failed", "Install failed", reason_field(e))
  end

  defp render_one(%AuditEvent{event_type: "delegation.state_changed"} = e) do
    case state_field(e) do
      "revoked" ->
        base(e, "permission", "revoked", "Permission revoked", reason_field(e))

      "expired" ->
        base(e, "permission", "expired", "Permission expired", nil)

      _ ->
        fallback(e)
    end
  end

  defp render_one(%AuditEvent{event_type: "intent.submitted"} = e) do
    %{
      id: e.id,
      t: humanize(e.ts),
      kind: "intent",
      status: "pending",
      title: "Intent submitted",
      reason: intent_reason(e),
      amount: amount_field(e),
      tx_hash: nil
    }
  end

  defp render_one(%AuditEvent{event_type: "intent.state_changed"} = e) do
    case state_field(e) do
      "executed" ->
        %{
          id: e.id,
          t: humanize(e.ts),
          kind: "intent",
          status: "executed",
          title: "Intent executed",
          reason: intent_reason(e),
          amount: amount_field(e),
          tx_hash: tx_hash_field(e)
        }

      "blocked" ->
        base(e, "intent", "blocked", "Intent blocked", reason_field(e))

      _ ->
        fallback(e)
    end
  end

  defp render_one(%AuditEvent{event_type: "decision.decided"} = e) do
    case outcome_field(e) do
      "approval_required" ->
        base(e, "intent", "needs-approval", "Approval needed", reason_field(e))

      _ ->
        fallback(e)
    end
  end

  defp render_one(%AuditEvent{event_type: "execution.confirmed"} = e) do
    %{
      id: e.id,
      t: humanize(e.ts),
      kind: "execution",
      status: "executed",
      title: "Transaction confirmed",
      reason: execution_reason(e),
      amount: nil,
      tx_hash: tx_hash_field(e)
    }
  end

  defp render_one(%AuditEvent{event_type: "execution.reverted"} = e) do
    base(e, "execution", "failed", "Transaction reverted", reason_field(e))
  end

  defp render_one(%AuditEvent{event_type: "approval.granted"} = e) do
    actor =
      case e.actor_id do
        nil -> "operator"
        id when is_binary(id) -> id
      end

    base(e, "intent", "executed", "Approval granted", "by " <> actor)
  end

  defp render_one(%AuditEvent{event_type: "security.scope_paused"} = e) do
    base(e, "security", "blocked", "Runtime paused", reason_field(e))
  end

  defp render_one(%AuditEvent{} = e), do: fallback(e)

  # --- common builders --------------------------------------------------

  defp base(%AuditEvent{} = e, kind, status, title, reason) do
    %{
      id: e.id,
      t: humanize(e.ts),
      kind: kind,
      status: status,
      title: title,
      reason: reason,
      amount: nil,
      tx_hash: nil
    }
  end

  defp fallback(%AuditEvent{event_type: type} = e) do
    %{
      id: e.id,
      t: humanize(e.ts),
      kind: "system",
      status: "note",
      title: type,
      reason: nil,
      amount: nil,
      tx_hash: nil
    }
  end

  # --- field extractors -------------------------------------------------

  # `after_ref` / `before_ref` round-trip through jsonb, so keys are
  # strings on read regardless of how the writer authored them.
  defp reason_field(%AuditEvent{after_ref: %{"reason" => r}}) when is_binary(r), do: r
  defp reason_field(_), do: nil

  defp state_field(%AuditEvent{after_ref: %{"state" => s}}) when is_binary(s), do: s
  defp state_field(_), do: nil

  defp outcome_field(%AuditEvent{after_ref: %{"outcome" => o}}) when is_binary(o), do: o
  defp outcome_field(_), do: nil

  defp amount_field(%AuditEvent{after_ref: %{"amount" => a}}) when is_binary(a), do: format_amount(a)
  defp amount_field(%AuditEvent{after_ref: %{"amount" => a}}) when is_number(a),
    do: format_amount(to_string(a))
  defp amount_field(_), do: nil

  defp format_amount(amount) when is_binary(amount) do
    # Default to outflow ("− 10.00 USDC") since the dominant case is
    # an agent-side debit. Receivers (faucet, refunds) are out-of-scope
    # for the agent screen's seed coverage.
    "− #{amount} USDC"
  end

  defp tx_hash_field(%AuditEvent{after_ref: %{"tx_hash" => h}}) when is_binary(h), do: h

  defp tx_hash_field(%AuditEvent{after_ref: %{"receipt" => %{"txHash" => h}}})
       when is_binary(h),
       do: h

  defp tx_hash_field(_), do: nil

  defp wallet_reason(%AuditEvent{after_ref: %{"address" => addr}}) when is_binary(addr) do
    "Base Sepolia · " <> short_addr(addr)
  end

  defp wallet_reason(_), do: "Base Sepolia"

  defp intent_reason(%AuditEvent{after_ref: %{"kind" => kind}}) when is_binary(kind) do
    "Kind: " <> kind
  end

  defp intent_reason(_), do: nil

  defp execution_reason(%AuditEvent{after_ref: ref}) when is_map(ref) do
    network = Map.get(ref, "network") || Map.get(ref, "chain")
    tx = tx_hash_field(%AuditEvent{after_ref: ref})

    case {network, tx} do
      {nil, nil} -> nil
      {network, nil} when is_binary(network) -> network
      {nil, tx} -> short_tx(tx)
      {network, tx} -> "#{network} · #{short_tx(tx)}"
    end
  end

  defp execution_reason(_), do: nil

  # --- formatting helpers ----------------------------------------------

  defp short_addr("0x" <> _ = addr) when byte_size(addr) > 12 do
    head = String.slice(addr, 0, 6)
    tail = String.slice(addr, -4, 4)
    head <> "…" <> tail
  end

  defp short_addr(addr), do: addr

  defp short_tx("0x" <> _ = tx) when byte_size(tx) > 10 do
    head = String.slice(tx, 0, 6)
    tail = String.slice(tx, -4, 4)
    head <> "…" <> tail
  end

  defp short_tx(tx), do: tx

  @doc """
  Render a `DateTime` as a coarse human-friendly relative time
  ("just now", "2 min ago", "3 hr ago", "5 d ago"), falling back to
  an ISO date past one week.
  """
  @spec humanize(DateTime.t()) :: String.t()
  def humanize(%DateTime{} = ts) do
    diff = DateTime.diff(DateTime.utc_now(), ts, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86_400 -> "#{div(diff, 3600)} hr ago"
      diff < 7 * 86_400 -> "#{div(diff, 86_400)} d ago"
      true -> Calendar.strftime(ts, "%Y-%m-%d")
    end
  end
end
