defmodule BankWeb.OpenApi.Schemas.APIKeys do
  @moduledoc """
  Per-domain schemas for `/v1/api_keys*` (#218c).

  Mirrors `BankWeb.API.V1.APIKeyJSON`. The `Created` shape is the
  ONLY response that includes the raw secret — it is shown once
  on creation and never re-fetchable. List + entity shapes carry
  only the public prefix and metadata.
  """
end

defmodule BankWeb.OpenApi.Schemas.APIKeyEntity do
  @moduledoc """
  API key as rendered by `APIKeyJSON.key/1` for list and singular
  responses. NEVER includes the raw secret or `secret_hash`.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "APIKeyEntity",
    description: """
    Public-facing API key metadata. The raw secret is shown ONCE
    on creation in `APIKeyCreatedResponse`; this entity shape
    deliberately omits it.
    """,
    type: :object,
    required: [:id, :prefix, :role, :name, :created_at],
    properties: %{
      id: %Reference{"$ref": "#/components/schemas/Id"},
      prefix: %Schema{
        type: :string,
        description: "Public lookup prefix — first 8 chars after `cb_`.",
        example: "abcdefgh"
      },
      role: %Schema{
        type: :string,
        enum: ["viewer", "operator", "admin", "owner"],
        example: "operator"
      },
      name: %Schema{
        type: :string,
        description: "Operator-supplied label.",
        example: "ci-runner"
      },
      created_by_user_id: %Reference{"$ref": "#/components/schemas/Id"},
      created_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
      expires_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
      revoked_at: %Reference{"$ref": "#/components/schemas/Timestamp"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.APIKeyListResponse do
  @moduledoc """
  `GET /v1/api_keys` response — workspace-scoped list of keys
  (active + revoked, newest first).
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "APIKeyListResponse",
    type: :object,
    required: [:data],
    properties: %{
      data: %Schema{
        type: :array,
        items: %Reference{"$ref": "#/components/schemas/APIKeyEntity"}
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.APIKeyCreateRequest do
  @moduledoc """
  `POST /v1/api_keys` request body.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "APIKeyCreateRequest",
    type: :object,
    required: [:role, :name],
    properties: %{
      role: %Schema{
        type: :string,
        enum: ["viewer", "operator", "admin", "owner"],
        description: """
        Role assigned to the new key. The caller MUST hold a role
        equal to or stronger than this; e.g. an `:admin` cannot
        mint an `:owner` key.
        """,
        example: "operator"
      },
      name: %Schema{
        type: :string,
        minLength: 1,
        maxLength: 255,
        description: "Operator-supplied label, free-form.",
        example: "ci-runner"
      },
      expires_at: %Reference{"$ref": "#/components/schemas/Timestamp"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.APIKeyCreatedResponse do
  @moduledoc """
  `POST /v1/api_keys` 201 response — includes the raw secret
  ONCE. Calling code MUST persist `raw_key` on the spot; it is
  never returned again.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "APIKeyCreatedResponse",
    description: """
    The newly minted API key, including the raw secret in
    `raw_key`. The raw secret is shown EXACTLY ONCE — losing it
    means rotating the key. The same key metadata is also
    available without the raw secret via the list endpoint.
    """,
    type: :object,
    required: [:data, :raw_key],
    properties: %{
      data: %Reference{"$ref": "#/components/schemas/APIKeyEntity"},
      raw_key: %Schema{
        type: :string,
        description: """
        The on-the-wire credential, of the form `cb_<base32>`. Must
        be supplied as `Authorization: Bearer <raw_key>` on every
        subsequent request. Shown once.
        """,
        example: "cb_abcdefgh1234567890abcdefgh1234567890abcdefgh"
      }
    }
  })
end
