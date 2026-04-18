defmodule BankWeb.OpenApi.Schemas.Connect do
  @moduledoc """
  Per-domain schemas for `POST /v1/connect/smart_account` (issue #89).

  The v0.1 delegation path flows through the adapter callback. This
  endpoint is the v1.1 scaffolding for the browser-native flow
  described in `docs/wallet-connect.md`. The controller hands off to
  `Bank.Delegations.request_connect/1`, which is a stub until the
  adapter exposes `POST /dispatch/grant_delegation`. The synchronous
  response says `accepted` with a `note` flagging the adapter stub.
  """
end

defmodule BankWeb.OpenApi.Schemas.ConnectSmartAccountRequest do
  @moduledoc "Body for `POST /v1/connect/smart_account`."

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "ConnectSmartAccountRequest",
    description: """
    Browser-built smart-account connect payload. The three required
    fields identify the smart account, the signer, and the chain;
    `delegation_payload` is the signed delegation object from the JS
    hook (see `assets/js/hooks/wallet_connect.js` and
    `docs/wallet-connect.md`).
    """,
    type: :object,
    required: [:smart_account_id, :account, :chain_id],
    properties: %{
      smart_account_id: %Schema{type: :string, example: "sa_primary"},
      account: %Reference{"$ref": "#/components/schemas/EvmAddress"},
      chain_id: %Schema{
        type: :integer,
        description:
          "EIP-155 chain id. Currently accepted: `8453` (Base) and " <>
            "`84532` (Base Sepolia); other values are rejected with " <>
            "`422 unsupported_chain`.",
        example: 8453
      },
      delegation_payload: %Schema{
        type: :object,
        nullable: true,
        description:
          "Signed delegation payload from the JS hook. Left as an open " <>
            "object; the shape is defined in `docs/wallet-connect.md`.",
        additionalProperties: true
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.ConnectSmartAccountResponse do
  @moduledoc "Response body for `POST /v1/connect/smart_account`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "ConnectSmartAccountResponse",
    description: """
    Synchronous receipt for the connect request. Until the adapter's
    `POST /dispatch/grant_delegation` route lands, the runtime
    persists the connect intent and emits an audit event but does
    NOT actually grant a delegation on-chain. The `note` field
    states this truthfully.
    """,
    type: :object,
    required: [:status, :smart_account_id, :note],
    properties: %{
      status: %Schema{
        type: :string,
        enum: ["accepted"],
        example: "accepted"
      },
      smart_account_id: %Schema{type: :string, example: "sa_primary"},
      note: %Schema{
        type: :string,
        example: "Adapter dispatch is stubbed in v1.1 — see docs/wallet-connect.md."
      }
    }
  })
end
