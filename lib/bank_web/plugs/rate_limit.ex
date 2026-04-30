defmodule BankWeb.Plugs.RateLimit do
  @moduledoc """
  Per-key rate limit for `/v1` (#221, first slice).

  Sits AFTER `BankWeb.Plugs.VerifyAPIKey` in the
  `:api_authenticated` router pipeline so the bucket is keyed by the
  authenticated `api_key.id`. Health endpoints ride the bare `:api`
  pipeline and are NOT rate-limited.

  ## Configuration

      config :bank, Bank.RateLimit,
        requests_per_window: 60,
        window_seconds: 60

  Defaults are deliberately permissive (1 RPS sustained per key).
  Operators can tune downward via runtime config; the next slice will
  add per-workspace and chain-action stricter caps.

  ## 429 wire format

      HTTP/1.1 429 Too Many Requests
      Retry-After: 17
      Content-Type: application/json

      { "error": { "code": "rate_limited" } }

  Mirrors the existing `401`/`403` shapes from `VerifyAPIKey` and
  `RequireRole` so SDKs can dispatch on the same `error.code` envelope.

  ## Audit emission

  Limit-trip emits ONE `api_key.rate_limited` audit event per
  (api_key, window) — see `Bank.RateLimit.claim_audit/2`. The event
  carries the calling key's `id` / `prefix` / `role` plus window
  metadata; it does NOT carry the raw key, `secret_hash`, or any
  Authorization header bytes. A bursty bot cannot flood the audit log.

  ## What this plug does NOT do (deferred slices)

    * Per-workspace caps — first slice is per-key only.
    * Chain-action stricter caps — defer to a chain-aware plug or to
      a check inside the controller.
    * Auth-failure lockout — separate concern. The `VerifyAPIKey`
      plug already 401s; rate-limiting unauthenticated traffic is a
      different threat model (DDoS at the edge, not runaway agent).

  ## Failure modes

  If the upstream `VerifyAPIKey` was bypassed for some reason and
  there is no `current_scope.api_key`, this plug is a no-op — the
  rate-limit predicate has nothing to bucket against. That is also
  the correct behavior on routes the plug is misconfigured onto
  (e.g. `/health` if it ever gets re-piped); rate-limiting cannot
  silently 429 routes the operator did not intend to gate.
  """

  import Plug.Conn

  require Logger

  alias Bank.APIKeys.APIKey
  alias Bank.Audit
  alias Bank.RateLimit

  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_scope] do
      %{api_key: %APIKey{} = api_key} ->
        {max_req, window} = config()

        case RateLimit.check(api_key.id, max_req, window) do
          :ok ->
            conn

          {:error, :rate_limited, retry_after} ->
            maybe_emit_audit(api_key, retry_after, max_req, window)

            conn
            |> put_resp_header("retry-after", Integer.to_string(retry_after))
            |> put_resp_content_type("application/json")
            |> send_resp(:too_many_requests, Jason.encode!(%{error: %{code: "rate_limited"}}))
            |> halt()
        end

      _ ->
        conn
    end
  end

  defp config do
    cfg = Application.get_env(:bank, Bank.RateLimit, [])
    {Keyword.fetch!(cfg, :requests_per_window), Keyword.fetch!(cfg, :window_seconds)}
  end

  defp maybe_emit_audit(api_key, retry_after, max_req, window) do
    now = System.system_time(:second)
    window_start = div(now, window) * window

    if RateLimit.claim_audit(api_key.id, window_start) do
      attrs =
        Audit.Events.api_key_rate_limited(api_key, %{
          window_start: window_start,
          window_end: window_start + window,
          limit: max_req,
          retry_after_seconds: retry_after
        })

      case Audit.append_event(attrs) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          # Audit is observability — a transient append failure must
          # not block the 429 response. Log and continue.
          Logger.warning(
            "BankWeb.Plugs.RateLimit: api_key.rate_limited audit append failed: #{inspect(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  end
end
