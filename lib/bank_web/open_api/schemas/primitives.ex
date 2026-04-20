defmodule BankWeb.OpenApi.Schemas.Primitives do
  @moduledoc """
  Shared primitive schemas for the external `/v1` OpenAPI document
  (issue #87, epic #85).

  Each primitive is its own schema module so later issues can
  `$ref` it by title in request / response bodies:

    * `Id` — opaque runtime-assigned UUID string.
    * `Timestamp` — ISO-8601 UTC timestamp.
    * `AmountString` — decimal amount transmitted as a string,
      matching the `/v1/intents` contract ("250.00" shape).
    * `EvmAddress` — `0x`-prefixed 20-byte hex EVM address; used as
      the low-level fallback when no counterparty / label is known.

  None of these carry business semantics; they exist to stop later
  issues duplicating the format / regex / description in every
  schema that needs, say, a UUID id or an amount string.
  """
end

defmodule BankWeb.OpenApi.Schemas.Id do
  @moduledoc """
  Opaque runtime-assigned id. UUID v4 string, set by Phoenix at
  persistence time (never by callers).
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Id",
    description: """
    Opaque runtime-assigned identifier. Always a lowercase
    canonical UUID v4 string. Set by Phoenix at persistence time;
    callers never write it.
    """,
    type: :string,
    format: :uuid,
    example: "b6a10f53-8c6e-4d79-9bb9-3e1e5b1f1a11"
  })
end

defmodule BankWeb.OpenApi.Schemas.Timestamp do
  @moduledoc """
  ISO-8601 UTC timestamp. Runtime-authoritative per the
  `/v1` contract.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "Timestamp",
    description: """
    ISO-8601 UTC timestamp with microsecond precision. Timestamps
    are runtime-authoritative: caller-supplied timestamps are
    accepted only as notes metadata and never drive decisions.
    """,
    type: :string,
    format: :"date-time",
    example: "2026-04-18T13:33:50.123456Z"
  })
end

defmodule BankWeb.OpenApi.Schemas.AmountString do
  @moduledoc """
  Decimal amount transmitted as a string, preserving scale without
  losing precision to floating-point serialization.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "AmountString",
    description: """
    Decimal amount as a plain string (no scientific notation,
    no thousands separators). The `/v1` contract transmits amounts
    as strings so JavaScript clients and scale-sensitive asset
    math do not silently round through 64-bit floats. Example:
    `"250.00"`.
    """,
    type: :string,
    pattern: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?$",
    example: "250.00"
  })
end

defmodule BankWeb.OpenApi.Schemas.EvmAddress do
  @moduledoc """
  Lowercase `0x`-prefixed EVM address. 20 bytes → 40 hex chars.
  """

  require OpenApiSpex

  OpenApiSpex.schema(%{
    title: "EvmAddress",
    description: """
    EVM address as a lowercase `0x`-prefixed 40-hex-character
    string. Used on the `/v1` contract only as the `raw_address`
    fallback when no counterparty / label is known; raw addresses
    always evaluate at trust `unknown`.
    """,
    type: :string,
    pattern: "^0x[0-9a-f]{40}$",
    example: "0x1234567890abcdef1234567890abcdef12345678"
  })
end
