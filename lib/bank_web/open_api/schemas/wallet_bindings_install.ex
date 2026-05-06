defmodule BankWeb.OpenApi.Schemas.WalletBindingsInstall do
  @moduledoc """
  OpenAPI schemas for the browser-signed install endpoints (#474):

    * `GET  /v1/wallet_bindings/:id/install_envelope`
    * `POST /v1/wallet_bindings/:id/install_attestation`
    * `GET  /v1/wallet_bindings/:id/install_status`

  See `docs/design/browser-signed-install.md` for the architectural
  rationale and `Bank.SessionPermissions.BrowserInstall` for the
  Phoenix-side state machine.
  """
end

defmodule BankWeb.OpenApi.Schemas.InstallEnvelopeResponse do
  @moduledoc "Response body for `GET /v1/wallet_bindings/:id/install_envelope`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "InstallEnvelopeResponse",
    description: """
    Canonical browser-install envelope. Phoenix is the source of
    truth for the scope; the browser relays the bytes byte-for-byte
    to the ZeroDev SDK. `scope_hash` is the SHA-256 of the
    canonical-JSON-encoded `scope` and is the audit anchor for
    "this is the exact scope the operator was shown."
    """,
    type: :object,
    required: [
      :binding_id,
      :smart_account_id,
      :chain_id,
      :entry_point_address,
      :kernel_version,
      :permissions_package_version,
      :scope,
      :scope_hash,
      :human_readable_summary
    ],
    properties: %{
      binding_id: %Schema{type: :string, format: :uuid},
      smart_account_id: %Schema{type: :string, minLength: 1},
      chain_id: %Schema{type: :integer, enum: [84_532]},
      entry_point_address: %Schema{
        type: :string,
        example: "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
      },
      kernel_version: %Schema{type: :string, example: "v3.1"},
      permissions_package_version: %Schema{type: :string, example: "5.6.3"},
      session_signer_address: %Schema{type: :string, nullable: true},
      scope: %Schema{
        type: :object,
        description: "Canonical scope payload. Browser relays bytes verbatim to ZeroDev SDK.",
        additionalProperties: true
      },
      scope_hash: %Schema{
        type: :string,
        description: "`sha256:` + lowercase hex of canonical scope JSON.",
        example: "sha256:abcd1234..."
      },
      bundler_rpc_url: %Schema{
        type: :string,
        nullable: true,
        description:
          "Browser-tier bundler RPC URL with a public-tier API key. Operator-rotated, distinct from the adapter bundler URL."
      },
      human_readable_summary: %Schema{type: :string, minLength: 1}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.InstallAttestationRequest do
  @moduledoc "Body for `POST /v1/wallet_bindings/:id/install_attestation`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "InstallAttestationRequest",
    description: """
    Browser report of an install lifecycle step. `status` is one
    of `submitted | confirmed | user_rejected | bundler_rejected
    | reverted`. Status-specific fields:

      * `submitted` — `install_userop_hash`, `permission_id` (4
        bytes hex), `validation_id` (21 bytes hex).
      * `confirmed` — `install_userop_hash`, `tx_hash`,
        `block_number`.
      * `user_rejected` / `bundler_rejected` / `reverted` —
        `reason` from the
        `Bank.SessionPermissions.BrowserInstall.failure_categories/0`
        allowlist; anything else collapses to `unknown`.
    """,
    type: :object,
    required: [:status],
    properties: %{
      status: %Schema{
        type: :string,
        enum: ["submitted", "confirmed", "user_rejected", "bundler_rejected", "reverted"]
      },
      install_userop_hash: %Schema{type: :string, nullable: true},
      tx_hash: %Schema{type: :string, nullable: true},
      block_number: %Schema{type: :integer, nullable: true},
      permission_id: %Schema{
        type: :string,
        nullable: true,
        description: "0x + 8 hex chars (4 bytes)"
      },
      validation_id: %Schema{
        type: :string,
        nullable: true,
        description: "0x + 42 hex chars (21 bytes)"
      },
      reason: %Schema{
        type: :string,
        nullable: true,
        enum: [
          "user_rejected",
          "bundler_rejected",
          "bundler_unavailable",
          "chain_id_mismatch",
          "insufficient_funds",
          "userop_reverted",
          "attestation_timeout",
          "unknown"
        ]
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.InstallAttestationResponse do
  @moduledoc "Response body for `POST /v1/wallet_bindings/:id/install_attestation`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "InstallAttestationResponse",
    description: """
    Synchronous acknowledgement of the attestation. `state` is the
    new server-side install state (`submitted | verifying | failed`).
    A `confirmed` attestation surfaces here as `verifying` because
    Phoenix has only enqueued the on-chain verifier worker; the
    delegation row flips to `:active` only after
    `Bank.Runtime.Workers.VerifyInstallOnchain` confirms the
    permission validator is installed.
    """,
    type: :object,
    required: [:state],
    properties: %{
      state: %Schema{
        type: :string,
        enum: ["submitted", "verifying", "failed"]
      },
      delegation_id: %Schema{type: :string, format: :uuid, nullable: true}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.InstallStatusResponse do
  @moduledoc "Response body for `GET /v1/wallet_bindings/:id/install_status`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "InstallStatusResponse",
    description: """
    Current install state for the binding. `state` is one of
    `awaiting | submitted | verifying | active | failed`.
    `awaiting` means no attestation has landed yet; `active` means
    the on-chain verifier passed and the delegation row is
    `:active`; `failed` means a terminal failure with a category
    atom on the row's `last_reason`.
    """,
    type: :object,
    required: [:state],
    properties: %{
      state: %Schema{
        type: :string,
        enum: ["awaiting", "submitted", "verifying", "active", "failed"]
      },
      delegation_id: %Schema{type: :string, format: :uuid, nullable: true},
      last_reason: %Schema{type: :string, nullable: true}
    }
  })
end
