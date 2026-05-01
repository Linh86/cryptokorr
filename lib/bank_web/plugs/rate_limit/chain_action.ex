defmodule BankWeb.Plugs.RateLimit.ChainAction do
  @moduledoc """
  Stricter per-key rate limit for chain-affecting kill-switch
  routes (#221, fourth slice).

  Sits at the END of the pipeline for `/v1/security/*` so it runs
  AFTER `VerifyAPIKey` → standard `BankWeb.Plugs.RateLimit` (per-key
  + per-workspace) → `BankWeb.Plugs.RequireRole, :admin`. A request
  must pass all four gates: auth + per-key + per-workspace + role
  + chain-action. The chain-action ceiling is deliberately tighter
  than the standard caps so that a credential capable of moving
  funds (revoke_delegation) or pausing the runtime cannot be used
  at scale even if its workspace's collective budget is healthy.

  ## Routes covered (v0.1)

    * `POST /v1/security/pause` — deployment-wide pause toggle
    * `POST /v1/security/resume` — paired with pause
    * `POST /v1/security/revoke_delegation` — chain-affecting
      delegation revoke

  Other admin routes (policy CRUD, API key management) are NOT
  chain-affecting and ride only the standard per-key + per-
  workspace caps.

  `POST /v1/decisions/:id/execute` is an obvious follow-up
  candidate (the operator manually dispatches a chain action via
  Oban). v0.1 keeps execute on the standard caps until product
  calibration data informs a stricter ceiling — execute is part
  of the normal trading loop, not an emergency lever.

  ## Configuration

      config :bank, Bank.RateLimit,
        chain_action_per_window: 5,
        chain_action_window_seconds: 60

  Default: 5 requests per 60 seconds per calling key. Pausing the
  runtime 5 times in a minute is far above any legitimate operator
  pace and well below the rate a runaway agent could trip.

  Optional: if `chain_action_per_window` is missing from config,
  the plug short-circuits to `:ok`. Tests that
  `Application.put_env/3`-replace the rate-limit keyword without
  preserving the chain-action keys do not crash.

  ## Bucket key

  `"chain_action:" <> api_key.id` — distinct namespace from raw
  `api_key.id` (per-key bucket from #286), `"workspace:" <>
  workspace.id` (per-workspace bucket from #221 third slice), and
  `"auth_fail:..."` (auth-failure lockout from #221 second slice).
  All four share the same `Bank.RateLimit` ETS table; key prefixes
  prevent collision.

  ## 429 wire format

      HTTP/1.1 429 Too Many Requests
      Retry-After: 17
      Content-Type: application/json

      { "error": { "code": "rate_limited" } }

  Identical envelope to the per-key and per-workspace 429s. SDKs
  dispatch on `error.code` only — operators distinguish via the
  audit row's `after_ref.scope == "chain_action"`.

  ## Audit

  Limit-trip emits ONE `api_key.rate_limited` audit event per
  `(api_key.id, window)` via `Bank.RateLimit.claim_audit/2` with
  the chain-action dedupe key. `after_ref.scope` is `"chain_action"`.
  Same hygiene contract as the other rate-limit events: no raw
  bearer, no `secret_hash`, no Authorization bytes.

  ## Failure modes

  If `current_scope.api_key` is nil (no upstream auth) the plug is
  a no-op. The 401 from `VerifyAPIKey` already handled that case
  earlier in the pipeline; this plug only sees authenticated calls.
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
        case config() do
          :disabled ->
            conn

          {max_req, window} ->
            case RateLimit.check("chain_action:" <> api_key.id, max_req, window) do
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
        end

      _ ->
        conn
    end
  end

  defp config do
    cfg = Application.get_env(:bank, Bank.RateLimit, [])

    case Keyword.get(cfg, :chain_action_per_window) do
      nil ->
        :disabled

      max_req when is_integer(max_req) and max_req > 0 ->
        window = Keyword.fetch!(cfg, :chain_action_window_seconds)
        {max_req, window}
    end
  end

  defp maybe_emit_audit(api_key, retry_after, max_req, window) do
    now = System.system_time(:second)
    window_start = div(now, window) * window
    dedupe_id = "chain_action:" <> api_key.id

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
          scope: :chain_action
        )

      case Audit.append_event(attrs) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "BankWeb.Plugs.RateLimit.ChainAction: api_key.rate_limited audit append failed: " <>
              inspect(reason)
          )

          :ok
      end
    else
      :ok
    end
  end
end
