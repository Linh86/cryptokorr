defmodule BankWeb.OpenApi.Schemas.Connect do
  @moduledoc """
  Per-domain schemas for `POST /v1/connect/smart_account` (issue #89).

  Server-side end-to-end as of PR #132 (#58 grant flow): the
  controller hands off to `Bank.Delegations.request_connect/1`,
  which enqueues `Bank.Runtime.Workers.GrantDelegation`; the
  worker dispatches to the adapter's
  `POST /dispatch/grant_delegation`, which builds + installs a
  ZeroDev `PermissionPlugin` and emits a `granted` callback with
  the artifact set Phoenix persists. The browser-side hook in
  `assets/js/hooks/wallet_connect.js` is still scaffolded — it
  does not yet sign a delegation payload, so operator-driven
  flows pass `delegation_payload: null` (see
  `docs/wallet-connect.md`). The synchronous response says
  `accepted` with a `note` flagging that the granted artifact
  rides on the callback.
  """
end

defmodule BankWeb.OpenApi.Schemas.ConnectSmartAccountRequest do
  @moduledoc "Body for `POST /v1/connect/smart_account`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

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
      smart_account_id: %Schema{type: :string, minLength: 1, example: "sa_primary"},
      account: %Schema{
        type: :string,
        minLength: 1,
        description: """
        Signer account address. The controller currently accepts any
        non-empty string — format validation is intentionally loose
        because `assets/js/hooks/wallet_connect.js` forwards
        `accounts[0]` directly from the wallet, which is typically
        an EIP-55 mixed-case EVM address (`0x` followed by 40 hex
        chars with case-encoded checksum). The shared `EvmAddress`
        schema's lowercase-only pattern would reject those payloads,
        so this field intentionally does NOT `$ref` it. A future
        issue may tighten this to a checksum-aware pattern once the
        browser flow is fully signed.
        """,
        example: "0xAbCdEf0123456789aBcDeF0123456789AbCdEf01"
      },
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
    Synchronous receipt for the connect request. The runtime
    audits the request and enqueues
    `Bank.Runtime.Workers.GrantDelegation` to dispatch the grant
    to the adapter (#58 grant flow). The actual delegation row is
    created asynchronously via the
    `delegation.state_changed{state: "granted"}` callback path,
    so a 202 here does NOT yet imply an active row — observe the
    callback to confirm. The `note` field states this truthfully.
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
        example:
          "Grant request audited and enqueued. Observe the delegation.state_changed callback path for the granted artifact."
      }
    }
  })
end
