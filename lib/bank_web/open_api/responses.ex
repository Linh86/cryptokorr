defmodule BankWeb.OpenApi.Responses do
  @moduledoc """
  Reusable OpenAPI response components for the external `/v1` API
  (issue #87, epic #85).

  Every non-2xx `/v1` response shares the `ErrorEnvelope` body
  shape pinned in `docs/bank-v0.1-runtime-flow-and-api.md`
  (`{ code, message, hint, retryable }`). Rather than redefining
  that shape per-endpoint, later issues cite reusable responses
  by name:

      %OpenApiSpex.Reference{"$ref": "#/components/responses/Conflict"}

  ## Components exposed

    * `BadRequest` — 400, schema validation failure.
    * `Unauthorized` — 401, missing / malformed / revoked / expired
      API key. Added in #218c alongside the management endpoints
      so every authenticated `/v1` operation can `$ref` the 401
      response body shape consistently.
    * `Forbidden` — 403, caller scope does not cover the subject.
    * `NotFound` — 404, subject does not exist.
    * `Conflict` — 409, idempotency key replay mismatch or
      state-machine conflict (e.g. approving an already-resolved
      decision).
    * `UnprocessableEntity` — 422, request shape is valid but a
      semantic guard rejected it (unsupported chain, asset,
      decision outcome not `auto_exec`, …).
    * `NotImplemented` — 501, endpoint is scaffolded but its owning
      engine has not landed yet. Added in #88 for the intent
      endpoints that currently route through
      `BankWeb.API.V1.FallbackController.not_implemented/3`.
    * `ServiceUnavailable` — 503, runtime is paused or otherwise
      refusing to advance execution at the door.
    * `BadGateway` — 502, adapter / upstream provider failure
      treated as caution-widening (`retryable: false`).
    * `GatewayTimeout` — 504, adapter / upstream provider timeout.
    * `TooManyRequests` — 429, rate-limit refusal from any of the
      `/v1` rate-limit buckets (per-key, per-workspace,
      chain-action stricter cap, or auth-failure lockout). Body
      shape is the standard `ErrorEnvelope` with
      `code: "rate_limited"`. The response carries a `Retry-After`
      header (integer seconds until window rollover). Added by
      #221 once all four rate-limit slices were in `main`.

  Every response references `components.headers.RequestIdOut` so
  `X-Request-Id` correlation is documented once. The
  `TooManyRequests` response additionally references
  `components.headers.RetryAfter`.
  """

  alias OpenApiSpex.{MediaType, Reference, Response}

  @error_envelope_ref %Reference{"$ref": "#/components/schemas/ErrorEnvelope"}
  @request_id_header_ref %Reference{"$ref": "#/components/headers/RequestIdOut"}
  @retry_after_header_ref %Reference{"$ref": "#/components/headers/RetryAfter"}

  @doc "400 — request body failed schema validation."
  @spec bad_request() :: Response.t()
  def bad_request, do: error_response("Malformed request body or missing required field.")

  @doc """
  401 — missing, malformed, revoked, or expired API key.

  Body codes (collapsed by `BankWeb.Plugs.VerifyAPIKey` so the
  client cannot distinguish internal reasons):

    * `missing_authorization` — no `Authorization` header.
    * `invalid_authorization_scheme` — header present but not
      `Bearer ...`.
    * `invalid_credentials` — bearer body did not authenticate
      (unknown prefix, wrong secret, revoked, expired).
  """
  @spec unauthorized() :: Response.t()
  def unauthorized,
    do:
      error_response(
        "Missing, malformed, revoked, or expired API key. The body's `code` is one of " <>
          "`missing_authorization`, `invalid_authorization_scheme`, or `invalid_credentials` " <>
          "— internal verify reasons are deliberately collapsed to a single wire shape."
      )

  @doc "403 — caller scope does not cover the subject."
  @spec forbidden() :: Response.t()
  def forbidden,
    do:
      error_response(
        "Caller scope does not cover the subject (e.g. agent trying to read another agent's intent)."
      )

  @doc "404 — subject does not exist or is not visible to the caller."
  @spec not_found() :: Response.t()
  def not_found, do: error_response("Subject does not exist or is not visible to the caller.")

  @doc "409 — idempotency conflict or state-machine conflict."
  @spec conflict() :: Response.t()
  def conflict,
    do:
      error_response(
        "Idempotency-Key replay with a mismatched payload, or a state-machine conflict " <>
          "(e.g. approving an already-resolved decision, cancelling an executing intent)."
      )

  @doc "422 — semantic guard rejection."
  @spec unprocessable_entity() :: Response.t()
  def unprocessable_entity,
    do:
      error_response(
        "Request was structurally valid but a semantic guard rejected it (unsupported chain, " <>
          "asset not whitelisted by active policy, decision not currently `auto_exec`, …)."
      )

  @doc "501 — endpoint scaffolded, owning engine not yet landed."
  @spec not_implemented() :: Response.t()
  def not_implemented,
    do:
      error_response(
        "Endpoint is scaffolded but its owning engine has not landed yet. The body is the " <>
          "standard `ErrorEnvelope` with `code: \"not_implemented\"`."
      )

  @doc "503 — runtime paused or refusing to advance at the door."
  @spec service_unavailable() :: Response.t()
  def service_unavailable,
    do:
      error_response(
        "Runtime is paused (global or scoped) and is refusing to advance execution. Callers " <>
          "must not retry into autonomy — the pause is lifted only by operator action."
      )

  @doc "502 — adapter / upstream provider failure."
  @spec bad_gateway() :: Response.t()
  def bad_gateway,
    do:
      error_response(
        "Adapter or upstream provider returned a failure response. Treated as a " <>
          "caution-widening input (`retryable: false`); callers must not loop."
      )

  @doc "504 — adapter / upstream provider timeout."
  @spec gateway_timeout() :: Response.t()
  def gateway_timeout,
    do:
      error_response(
        "Adapter or upstream provider did not respond in time. Treated as a caution-widening " <>
          "input (`retryable: false`); callers must not loop."
      )

  @doc """
  429 — rate-limit refusal (#221).

  Emitted from one of four buckets:

    * **Per-key bucket** (`BankWeb.Plugs.RateLimit`) — calling
      key exceeded its sustained request rate. Audit
      `api_key.rate_limited` with `after_ref.scope = "key"`.
    * **Per-workspace bucket** (same plug) — workspace's
      collective request rate across all its keys exceeded the
      cap. Audit `api_key.rate_limited` with
      `after_ref.scope = "workspace"`.
    * **Chain-action stricter cap**
      (`BankWeb.Plugs.RateLimit.ChainAction`) — refused on
      `/v1/security/{pause,resume,revoke_delegation}`. Audit
      `api_key.rate_limited` with
      `after_ref.scope = "chain_action"`.
    * **Auth-failure lockout** (`BankWeb.Plugs.VerifyAPIKey`) —
      bucket of failed-auth attempts (per `api_key.id`,
      per-prefix, or per-IP) exceeded the lockout threshold.
      Audit `api_key.auth_failure_limited`.

  Body is the standard `ErrorEnvelope` with `code:
  "rate_limited"`. The `Retry-After` response header carries
  the integer seconds until the window rolls over.
  """
  @spec too_many_requests() :: Response.t()
  def too_many_requests do
    %Response{
      description:
        "Rate-limit refusal. The body is the standard `ErrorEnvelope` with " <>
          "`code: \"rate_limited\"`. `Retry-After` carries integer seconds until the bucket's " <>
          "window rolls over. See `BankWeb.Plugs.RateLimit` and " <>
          "`BankWeb.Plugs.RateLimit.ChainAction` for the four bucket flavors.",
      headers: %{
        "X-Request-Id" => @request_id_header_ref,
        "Retry-After" => @retry_after_header_ref
      },
      content: %{
        "application/json" => %MediaType{schema: @error_envelope_ref}
      }
    }
  end

  # --- internals ---

  defp error_response(description) do
    %Response{
      description: description,
      headers: %{"X-Request-Id" => @request_id_header_ref},
      content: %{
        "application/json" => %MediaType{schema: @error_envelope_ref}
      }
    }
  end
end
