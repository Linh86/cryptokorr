defmodule BankWeb.OpenApi.Parameters do
  @moduledoc """
  Reusable OpenAPI request parameter components for the external
  `/v1` API (issue #87, epic #85).

  Each function here returns a single `%OpenApiSpex.Parameter{}`
  value that the top-level `BankWeb.ApiSpec` registers under
  `components.parameters` with the name documented next to the
  function. Later issues cite parameters by that component name:

      %OpenApiSpex.Reference{"$ref": "#/components/parameters/IdempotencyKey"}

  rather than redefining header shapes ad-hoc.

  ## Components exposed

    * `IdempotencyKey` — required `Idempotency-Key` request header
      on every write. Pairs with the intent body's own
      `idempotency_key` field on `POST /v1/intents` (both must
      agree; see the `/v1` contract doc).
    * `RequestIdIn` — optional `X-Request-Id` request header. The
      Phoenix endpoint generates one when absent; when present,
      responses echo it unchanged via the
      `BankWeb.OpenApi.Headers.RequestIdOut` response header.

  ## Conventions

    * Header parameters use `in: :header` and pick `required:`
      from the runtime contract (writes require idempotency;
      request-id is always optional).
    * Schemas reference `BankWeb.OpenApi.Schemas.*` where a
      primitive fits, so format / length rules stay in one place.
    * Parameters deliberately do not carry `example` when their
      schema already carries one — avoids example drift.
  """

  alias OpenApiSpex.{Parameter, Schema}

  @doc """
  `Idempotency-Key` request header, required on all `/v1` writes.

  The runtime uses the value to deduplicate retries: a duplicate
  key with an identical body is a successful replay; a duplicate
  key with a mismatched body is a `409` per the contract.
  """
  @spec idempotency_key() :: Parameter.t()
  def idempotency_key do
    %Parameter{
      name: "Idempotency-Key",
      in: :header,
      required: true,
      description: """
      Client-supplied idempotency key. Required on every `/v1`
      write. The runtime dedupes retries by `(key, payload)`:
      a duplicate key with a matching body replays the original
      result, a duplicate key with a mismatched body returns
      `409 Conflict`.
      """,
      schema: %Schema{
        type: :string,
        minLength: 1,
        maxLength: 255,
        example: "8f0b3c82-2e6e-4f80-bb35-4a0f02d9d5d9"
      }
    }
  end

  @doc """
  `X-Request-Id` request header, optional. The Phoenix endpoint
  generates a new id when absent and echoes the presented value
  back in the response header of the same name.
  """
  @spec request_id_in() :: Parameter.t()
  def request_id_in do
    %Parameter{
      name: "X-Request-Id",
      in: :header,
      required: false,
      description: """
      Optional client-supplied request correlation id. The
      Phoenix endpoint generates a fresh id when this header is
      absent. Whether client-supplied or server-generated, the
      value is echoed back on the response as `X-Request-Id`
      and written into the audit trail for this request.
      """,
      schema: %Schema{
        type: :string,
        minLength: 1,
        maxLength: 255,
        example: "GKd2jN1eZDCQUvIAACHD"
      }
    }
  end
end
