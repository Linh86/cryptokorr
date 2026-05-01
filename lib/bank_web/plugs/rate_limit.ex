defmodule BankWeb.Plugs.RateLimit do
  @moduledoc """
  Success-path rate limit for `/v1` (#221, first + third slices).

  Sits AFTER `BankWeb.Plugs.VerifyAPIKey` in the
  `:api_authenticated` router pipeline so buckets are keyed by the
  authenticated `current_scope` (api_key id and workspace id).
  Health endpoints ride the bare `:api` pipeline and are NOT
  rate-limited.

  ## Two-stage check (per-key first, per-workspace second)

  Every authenticated request runs through both checks in this
  order:

    1. **Per-key bucket** keyed by `api_key.id`. If exceeded, the
       request 429s and the workspace bucket is NOT incremented.
       This is deliberate: a single noisy key MUST trip its own
       bucket first, otherwise it would burn the workspace's
       collective budget and starve quiet keys in the same
       workspace.
    2. **Per-workspace bucket** keyed by `"workspace:" <>
       workspace.id`. Catches the case where many keys collectively
       (or a misconfigured workspace) flood the API even though
       each individual key stays under its per-key cap.

  Both buckets share the same `Bank.RateLimit` ETS table. Distinct
  key prefixes (`<uuid>` vs `"workspace:" <> <uuid>`) prevent
  collision.

  ## Configuration

      config :bank, Bank.RateLimit,
        requests_per_window: 60,                # per-key
        window_seconds: 60,
        workspace_requests_per_window: 600,     # per-workspace
        workspace_window_seconds: 60

  Defaults: per-key 1 RPS sustained (60/60s); per-workspace 10×
  the per-key cap (600/60s) so a workspace with up to 10 quietly-
  busy keys is uncapped while malicious workspaces with many
  runaway keys hit a deterministic ceiling.

  Workspace check is OPTIONAL: if `workspace_requests_per_window`
  is absent (legacy test configs that overwrite the env), the
  per-workspace stage short-circuits to `:ok`. The per-key check
  remains active.

  ## 429 wire format

      HTTP/1.1 429 Too Many Requests
      Retry-After: 17
      Content-Type: application/json

      { "error": { "code": "rate_limited" } }

  Identical envelope for both per-key and per-workspace trips —
  SDK consumers dispatch on the same `error.code`. The
  `api_key.rate_limited` audit row carries `after_ref.scope`
  ("key" | "workspace") so operators can tell which bucket fired.

  ## Audit emission

  Limit-trip emits ONE `api_key.rate_limited` audit event per
  `(bucket, window)`:

    * Per-key trip → deduped on `api_key.id`.
    * Per-workspace trip → deduped on `"workspace:" <>
      workspace.id`.

  Both use `Bank.RateLimit.claim_audit/2`. A bursty bot cannot
  flood the audit log under either bucket.

  ## What this plug does NOT do (deferred slices)

    * **Chain-action stricter caps** — high-risk routes
      (`/v1/security/*`, future on-chain dispatch) are still
      governed only by the per-key + per-workspace caps. A
      stricter cap is the next #221 slice.
    * **Auth-failure lockout** — separate concern. The
      `VerifyAPIKey` plug handles that (#221, second slice).

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
      %{api_key: %APIKey{} = api_key, workspace: %{id: workspace_id}} ->
        with :ok <- check_key(api_key),
             :ok <- check_workspace(workspace_id, api_key) do
          conn
        else
          {:error, :rate_limited, retry_after, scope} ->
            maybe_emit_audit(api_key, scope, retry_after)

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

  # --- Per-key bucket (#286) ---------------------------------------

  defp check_key(api_key) do
    {max_req, window} = key_config()

    case RateLimit.check(api_key.id, max_req, window) do
      :ok ->
        :ok

      {:error, :rate_limited, retry_after} ->
        {:error, :rate_limited, retry_after, :key}
    end
  end

  defp key_config do
    cfg = Application.get_env(:bank, Bank.RateLimit, [])
    {Keyword.fetch!(cfg, :requests_per_window), Keyword.fetch!(cfg, :window_seconds)}
  end

  # --- Per-workspace bucket (#221, third slice) --------------------

  defp check_workspace(workspace_id, _api_key) when is_binary(workspace_id) do
    case workspace_config() do
      :disabled ->
        :ok

      {max_req, window} ->
        case RateLimit.check("workspace:" <> workspace_id, max_req, window) do
          :ok ->
            :ok

          {:error, :rate_limited, retry_after} ->
            {:error, :rate_limited, retry_after, :workspace}
        end
    end
  end

  # Workspace config is OPTIONAL: legacy or focused tests that
  # `Application.put_env/3`-replace the entire rate-limit config
  # with only the per-key keys must not crash here. Treat absence
  # as "feature disabled for this run" and continue with per-key
  # only.
  defp workspace_config do
    cfg = Application.get_env(:bank, Bank.RateLimit, [])

    case Keyword.get(cfg, :workspace_requests_per_window) do
      nil ->
        :disabled

      max_req when is_integer(max_req) and max_req > 0 ->
        window = Keyword.fetch!(cfg, :workspace_window_seconds)
        {max_req, window}
    end
  end

  # --- Audit emission ----------------------------------------------

  defp maybe_emit_audit(api_key, scope, retry_after) do
    {max_req, window} =
      case scope do
        :key -> key_config()
        :workspace -> workspace_config_or_raise()
      end

    now = System.system_time(:second)
    window_start = div(now, window) * window

    dedupe_id =
      case scope do
        :key -> api_key.id
        :workspace -> "workspace:" <> api_key.workspace_id
      end

    if RateLimit.claim_audit(dedupe_id, window_start) do
      attrs =
        Audit.Events.api_key_rate_limited(
          api_key,
          %{
            window_start: window_start,
            window_end: window_start + window,
            limit: max_req,
            retry_after_seconds: retry_after
          },
          scope: scope
        )

      case Audit.append_event(attrs) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          # Audit is observability — a transient append failure
          # must not block the 429 response. Log and continue.
          Logger.warning(
            "BankWeb.Plugs.RateLimit: api_key.rate_limited audit append failed: #{inspect(reason)}"
          )

          :ok
      end
    else
      :ok
    end
  end

  # Used by the audit emit path only — at this point we already
  # know the workspace bucket fired, so its config MUST be
  # present. If a misconfiguration nukes the keys mid-flight, raise
  # a clear error rather than silently emitting a bad audit row.
  defp workspace_config_or_raise do
    case workspace_config() do
      {max_req, window} ->
        {max_req, window}

      :disabled ->
        raise "BankWeb.Plugs.RateLimit: workspace bucket fired but workspace_requests_per_window is missing"
    end
  end
end
