defmodule Bank.Ops.Alerts do
  @moduledoc """
  Operational alert hooks (#256).

  Domain code emits typed operational alerts via `emit/1`. Each
  alert is recorded as a workspace-scoped notification through
  `Bank.Notifications.create/1`. Repeated `emit/1` calls with the
  same `(workspace_id, dedupe_key)` collapse to one row — that is
  the "duplicate alerts deduped/throttled" acceptance bullet from
  the issue body.

  A subsequent `resolve/1` call records a paired
  `ops.<kind>.resolved` notification so operators see recovery —
  also deduped per `(workspace_id, resolve dedupe_key)`. That is
  the "clear resolved state or recovery note" acceptance bullet.

  ## Alert kinds (Phase 1 allowlist)

  Maps 1:1 to the issue body's `## Scope > Alert sources`:

    * `:stuck_plan` — execution pending too long
    * `:adapter_down` — chain adapter unreachable
    * `:rpc_down` — JSON-RPC source unreachable
    * `:bundler_down` — UserOp bundler unreachable
    * `:quote_provider_down` — quote provider unreachable / stale
    * `:callback_latency_high` — adapter callback latency over
      threshold
    * `:queue_depth_high` — Oban queue backlog over threshold
    * `:job_failures_high` — Oban job failures over threshold

  An unknown kind returns `{:error, :unknown_kind}` instead of
  silently widening the projection surface — same hard-allowlist
  pattern the smart-account chain sync uses for projection kinds.

  ## Read-only / no chain side effects

  This module never:

    * broadcasts a transaction,
    * signs a payload,
    * calls `Bank.AdapterClient` / the chain adapter,
    * creates an `ExecutionPlan`,
    * enqueues an Oban dispatch job.

  It only inserts workspace-scoped inbox rows. The
  `Bank.Notifications` context itself is contractually side-effect
  free (no PubSub, no Oban) — see its moduledoc — so emitting an
  alert from inside a transaction is safe.

  ## Workspace boundary

  Every emit takes a `:workspace_id`. There is no global
  cross-workspace alert surface here — siblings cannot observe
  each other's alerts. Callers that detect a global ops signal
  (e.g. adapter down affects every tenant) are responsible for
  fanning the emit out per workspace.

  ## Secret hygiene

  Callers MUST keep `:summary` and `:details` free of secret-
  bearing content (Authorization headers, Bearer tokens,
  `sk_(test|live)_…`, PEM private-key markers, tokenized RPC
  URLs). The downstream `Bank.Notifications.Notification`
  changeset rejects those at the `:unsafe_text` gate, so a
  regression surfaces as `{:error, %Ecto.Changeset{}}` instead of
  a leak. The body builder also caps benign `:summary` text at
  240 chars to keep notification bodies bounded.

  ## Dedupe key

  By default `emit/1` derives `dedupe_key` from
  `"<event_type>:<subject>"`. Pass `:dedupe_window` to add a time
  bucket (e.g. an ISO date or hour) so the same kind+subject can
  re-fire across windows — useful for periodic alerts like
  `:queue_depth_high`. `resolve/1` derives a different
  `dedupe_key` (with `.resolved` suffix) so the resolve event
  cannot collide with the open alert.

  ## Example

      Bank.Ops.Alerts.emit(%{
        workspace_id: ws.id,
        kind: :stuck_plan,
        subject: plan.id,
        severity: :warning,
        details: %{stuck_for_seconds: 900, status: "pending_confirmation"}
      })

      # Later, when the plan finally lands:
      Bank.Ops.Alerts.resolve(%{
        workspace_id: ws.id,
        kind: :stuck_plan,
        subject: plan.id
      })
  """

  alias Bank.Notifications

  @kinds ~w(
    stuck_plan
    adapter_down
    rpc_down
    bundler_down
    quote_provider_down
    callback_latency_high
    queue_depth_high
    job_failures_high
  )a

  @severities ~w(info warning critical)a

  @summary_max_length 240

  @typedoc "Allowlisted alert kind."
  @type kind ::
          :stuck_plan
          | :adapter_down
          | :rpc_down
          | :bundler_down
          | :quote_provider_down
          | :callback_latency_high
          | :queue_depth_high
          | :job_failures_high

  @typedoc "Alert severity, mirrors `Bank.Notifications.Notification`."
  @type severity :: :info | :warning | :critical

  @typedoc "Alert input attrs."
  @type alert_attrs :: %{
          required(:workspace_id) => String.t(),
          required(:kind) => kind(),
          required(:subject) => String.t(),
          optional(:severity) => severity(),
          optional(:role_target) => :viewer | :operator | :admin | :owner,
          optional(:summary) => String.t(),
          optional(:details) => map(),
          optional(:dedupe_window) => String.t(),
          optional(:subject_type) => String.t(),
          optional(:subject_id) => String.t(),
          optional(:correlation_id) => String.t()
        }

  @typedoc "Result of `emit/1` / `resolve/1`."
  @type emit_result ::
          {:ok, :emitted, Notifications.Notification.t()}
          | {:ok, :deduped, Notifications.Notification.t()}
          | {:error,
             :unknown_kind
             | :missing_workspace
             | :missing_subject
             | :invalid_attrs
             | Ecto.Changeset.t()}

  @doc """
  Emit a typed operational alert.

  Returns:

    * `{:ok, :emitted, notification}` — fresh row inserted
    * `{:ok, :deduped, existing}` — `(workspace_id, dedupe_key)`
      already existed; no second row inserted, the existing one
      is returned for caller convenience
    * `{:error, :unknown_kind}` / `{:error, :missing_workspace}` /
      `{:error, :missing_subject}` / `{:error, :invalid_attrs}`
      for shape-level failures
    * `{:error, %Ecto.Changeset{}}` for downstream notification
      validation failures (including secret-hygiene rejections)
  """
  @spec emit(alert_attrs()) :: emit_result()
  def emit(attrs), do: do_create(attrs, :open)

  @doc """
  Record a recovery / resolved notification for a previously-
  emitted alert. Idempotent on `(workspace_id, resolve dedupe_key)`.

  The resolution event_type is `ops.<kind>.resolved` and the
  default severity is `:info` (recoveries are informational, not
  warnings).
  """
  @spec resolve(alert_attrs()) :: emit_result()
  def resolve(attrs), do: do_create(attrs, :resolved)

  @doc "Allowlisted alert kinds."
  @spec kinds() :: [kind()]
  def kinds, do: @kinds

  # --- internals --------------------------------------------------------

  defp do_create(attrs, mode) when is_map(attrs) and mode in [:open, :resolved] do
    with :ok <- validate_kind(attrs),
         :ok <- validate_workspace(attrs),
         :ok <- validate_subject(attrs) do
      attrs
      |> build_notification_attrs(mode)
      |> Notifications.create()
      |> wrap_result()
    end
  end

  defp do_create(_attrs, _mode), do: {:error, :invalid_attrs}

  defp validate_kind(%{kind: kind}) when kind in @kinds, do: :ok
  defp validate_kind(_), do: {:error, :unknown_kind}

  defp validate_workspace(%{workspace_id: ws}) when is_binary(ws) and ws != "", do: :ok
  defp validate_workspace(_), do: {:error, :missing_workspace}

  defp validate_subject(%{subject: s}) when is_binary(s) and s != "", do: :ok
  defp validate_subject(_), do: {:error, :missing_subject}

  defp build_notification_attrs(attrs, mode) do
    kind = attrs.kind
    workspace_id = attrs.workspace_id
    subject = attrs.subject
    event_type = event_type_for(kind, mode)
    dedupe_key = dedupe_key_for(event_type, subject, attrs)

    %{
      workspace_id: workspace_id,
      event_type: event_type,
      severity: severity_for(attrs, mode),
      role_target: Map.get(attrs, :role_target, :operator),
      subject_type: Map.get(attrs, :subject_type, "ops_alert"),
      subject_id: Map.get(attrs, :subject_id),
      correlation_id: Map.get(attrs, :correlation_id),
      title: title_for(kind, mode),
      body: body_for(kind, mode, attrs),
      dedupe_key: dedupe_key
    }
  end

  defp event_type_for(kind, :open), do: "ops." <> Atom.to_string(kind)
  defp event_type_for(kind, :resolved), do: "ops." <> Atom.to_string(kind) <> ".resolved"

  defp dedupe_key_for(event_type, subject, attrs) do
    [event_type, subject, Map.get(attrs, :dedupe_window)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(":")
  end

  defp severity_for(_attrs, :resolved), do: :info

  defp severity_for(%{severity: s}, :open) when s in @severities, do: s
  defp severity_for(_, :open), do: :warning

  defp title_for(kind, mode) do
    base =
      case kind do
        :stuck_plan -> "Execution plan stuck"
        :adapter_down -> "Chain adapter unreachable"
        :rpc_down -> "RPC source unreachable"
        :bundler_down -> "Bundler unreachable"
        :quote_provider_down -> "Quote provider unavailable"
        :callback_latency_high -> "Adapter callback latency high"
        :queue_depth_high -> "Job queue backlog high"
        :job_failures_high -> "Job failures over threshold"
      end

    case mode do
      :open -> base
      :resolved -> base <> " — resolved"
    end
  end

  defp body_for(kind, mode, attrs) do
    summary =
      attrs
      |> Map.get(:summary)
      |> bound_summary()

    details = format_details(Map.get(attrs, :details, %{}))

    base =
      case mode do
        :open ->
          "Operational alert " <>
            Atom.to_string(kind) <> " fired for subject " <> attrs.subject <> "."

        :resolved ->
          "Operational alert " <>
            Atom.to_string(kind) <> " for subject " <> attrs.subject <> " has cleared."
      end

    [base, summary, details]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end

  defp bound_summary(nil), do: nil
  defp bound_summary(""), do: nil

  defp bound_summary(s) when is_binary(s),
    do: String.slice(s, 0, @summary_max_length)

  defp bound_summary(_), do: nil

  defp format_details(map) when is_map(map) and map_size(map) > 0 do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> to_string(k) <> "=" <> format_value(v) end)
    |> Enum.join(", ")
  end

  defp format_details(_), do: ""

  defp format_value(v) when is_binary(v), do: v
  defp format_value(v) when is_integer(v), do: Integer.to_string(v)
  defp format_value(v) when is_atom(v), do: Atom.to_string(v)
  defp format_value(v) when is_float(v), do: Float.to_string(v)
  defp format_value(v), do: inspect(v)

  defp wrap_result({:ok, %Notifications.Notification{} = n}), do: {:ok, :emitted, n}
  defp wrap_result({:duplicate, %Notifications.Notification{} = n}), do: {:ok, :deduped, n}
  defp wrap_result({:error, %Ecto.Changeset{} = cs}), do: {:error, cs}
end
