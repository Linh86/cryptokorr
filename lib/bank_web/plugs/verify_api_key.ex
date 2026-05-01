defmodule BankWeb.Plugs.VerifyAPIKey do
  @moduledoc """
  Bearer-token authentication for `/v1` (#218b).

  Pulls `Authorization: Bearer cb_<body>` off the request, verifies
  it via `Bank.APIKeys.verify_key/1`, and populates
  `conn.assigns.current_scope` so downstream `Plugs.RequireRole`
  and controllers can authorize without re-querying.

  ## current_scope shape

      %{
        user: nil,
        workspace: %Workspace{},
        membership: nil,
        role: api_key.role,
        api_key: %APIKey{}
      }

  Mirrors the LiveView session shape from #157 / #159a in every
  field that authorization reads (`workspace`, `role`), and
  diverges where the request is machine-, not user-, attributable
  (`user: nil`, `membership: nil`, `api_key: %APIKey{}`).

  ## Failure modes

  All map to a generic 401 with a single error code on the wire so
  an attacker cannot distinguish "no such prefix" from "bad
  secret" by response shape:

    * No `authorization` header → `missing_authorization`.
    * Header present but not `Bearer ...` → `invalid_authorization_scheme`.
    * Bearer token does not match `cb_<body>` shape → `invalid_credentials`.
    * Prefix lookup misses, hash mismatches, key is revoked or
      expired → `invalid_credentials`.

  All four `verify_key` error reasons (`:not_found`,
  `:hash_mismatch`, `:revoked`, `:expired`) collapse to
  `invalid_credentials` on the wire. Distinct internal reasons are
  preserved in `Logger.warning` for operator triage.

  ## Workspace scoping handoff

  This plug populates `current_scope.workspace` so downstream code
  CAN scope queries to the key's workspace. Whether each
  controller actually uses that to add a `workspace_id` filter is
  a separate retrofit (#218b's router carries the deferral note —
  see `lib/bank_web/router.ex`). The plug's contract here is
  identity, not query enforcement.
  """

  import Plug.Conn

  require Logger

  alias Bank.APIKeys
  alias Bank.Audit

  # Dedupe window for `api_key.denied` emission (#222). 60s
  # collapses brute-force probes to one row per minute per
  # (prefix-or-id, reason) pair while still surfacing distinct
  # incidents on the audit timeline.
  @denied_dedupe_window_seconds 60

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, presented} <- extract_bearer(conn),
         {:ok, api_key, workspace} <- APIKeys.verify_key(presented) do
      # Best-effort `last_used_at` update on the success path
      # only (#218d). Failed / revoked / expired keys never reach
      # this branch. The throttle inside `touch_last_used/2`
      # keeps the per-request DB write to at most once per
      # active-key per throttle window. Errors here are logged
      # and swallowed so a transient DB hiccup cannot block an
      # otherwise-valid request.
      api_key = maybe_touch_used(api_key)

      assign(conn, :current_scope, %{
        user: nil,
        workspace: workspace,
        membership: nil,
        role: api_key.role,
        api_key: api_key
      })
    else
      {:error, scheme_error}
      when scheme_error in [:missing_authorization, :invalid_authorization_scheme] ->
        emit_denied(:missing, presented_or_nil(conn))
        halt_with(conn, Atom.to_string(scheme_error))

      {:error, verify_error}
      when verify_error in [:malformed, :not_found, :hash_mismatch, :revoked, :expired] ->
        Logger.warning(
          "BankWeb.Plugs.VerifyAPIKey: rejecting from #{peer_for_log(conn)} (#{verify_error})"
        )

        emit_denied(audit_reason(verify_error), presented_or_nil(conn))
        halt_with(conn, "invalid_credentials")
    end
  end

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      [] ->
        {:error, :missing_authorization}

      ["Bearer " <> token] when byte_size(token) > 0 ->
        {:ok, token}

      [_other] ->
        {:error, :invalid_authorization_scheme}

      _multiple ->
        {:error, :invalid_authorization_scheme}
    end
  end

  defp halt_with(conn, code) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(:unauthorized, Jason.encode!(%{error: %{code: code}}))
    |> halt()
  end

  defp peer_for_log(conn) do
    case conn.remote_ip do
      {a, b, c, d} -> "#{a}.#{b}.#{c}.#{d}"
      other -> inspect(other)
    end
  end

  defp maybe_touch_used(api_key) do
    case APIKeys.touch_last_used(api_key) do
      {:ok, refreshed} ->
        refreshed

      {:error, reason} ->
        Logger.warning(
          "BankWeb.Plugs.VerifyAPIKey: touch_last_used failed for prefix=#{api_key.prefix}: " <>
            inspect(reason)
        )

        api_key
    end
  end

  # Map the seven internal reject reasons onto the five public
  # audit reasons. Mirrors the wire-side collapse from `:not_found`
  # / `:hash_mismatch` → `invalid_credentials` so an attacker
  # comparing audit-driven dashboards against probe responses sees
  # the same granularity.
  defp audit_reason(:malformed), do: :malformed
  defp audit_reason(:not_found), do: :invalid_credentials
  defp audit_reason(:hash_mismatch), do: :invalid_credentials
  defp audit_reason(:revoked), do: :revoked
  defp audit_reason(:expired), do: :expired

  # Returns the bearer token body if it could be extracted from
  # the request, else nil. Used by the denied-event path to
  # populate prefix/api_key context when possible. Header parsing
  # ran (or failed) earlier in `extract_bearer/1`; we re-read it
  # here cheaply rather than threading the value through the with-
  # chain.
  defp presented_or_nil(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] when byte_size(token) > 0 -> token
      _ -> nil
    end
  end

  # Emit `api_key.denied` with the strongest identifying context we
  # have, deduped per (prefix-or-id, reason, minute). A bursty
  # probe collapses to one row per pattern per minute, keeping the
  # audit log readable.
  defp emit_denied(reason, presented) do
    {prefix, api_key} = APIKeys.lookup_for_audit(presented)

    dedupe_key =
      case api_key do
        %APIKeys.APIKey{id: id} -> {:denied, {:id, id}, reason}
        _ when is_binary(prefix) -> {:denied, {:prefix, prefix}, reason}
        _ -> {:denied, :anonymous, reason}
      end

    if Bank.Audit.DedupeWindow.claim(dedupe_key, @denied_dedupe_window_seconds) do
      attrs = Audit.Events.api_key_denied(reason, prefix: prefix, api_key: api_key)

      case Audit.append_event(attrs) do
        {:ok, _} ->
          :ok

        {:error, audit_reason} ->
          # Audit is observability — a transient append failure
          # must not block the 401 response or the request flow.
          Logger.warning(
            "BankWeb.Plugs.VerifyAPIKey: api_key.denied audit append failed: " <>
              inspect(audit_reason)
          )

          :ok
      end
    else
      :ok
    end
  rescue
    error ->
      # Defense in depth: NEVER let an audit emit error change the
      # response. Log and continue to the 401.
      Logger.warning("BankWeb.Plugs.VerifyAPIKey: emit_denied raised: #{inspect(error)}")

      :ok
  end
end
