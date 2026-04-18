defmodule BankWeb.OpenApi.Schemas.Counterparties do
  @moduledoc """
  Per-domain schemas for `/v1/counterparties*` and the two routes that
  live next to it — `PATCH /v1/address_labels/{id}` and
  `POST /v1/counterparties/{id}/evidence` (issue #89, epic #85).

  Shapes mirror `BankWeb.API.V1.CounterpartyJSON` and
  `BankWeb.API.V1.AddressLabelController` exactly as they render
  today. Reuses shared primitives from #87 (`Id`, `Timestamp`,
  `AmountString`, `EvmAddress`, `Chain`, `TrustLevel`, `Links`) via
  `$ref`.
  """
end

defmodule BankWeb.OpenApi.Schemas.CounterpartySummary do
  @moduledoc """
  Bare counterparty object returned by the list endpoint.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "CounterpartySummary",
    description: """
    Counterparty fields projected by `CounterpartyJSON.counterparty/1`.
    The list endpoint emits this bare object; single-counterparty
    responses also carry preloaded associations (see
    `CounterpartyDetail`).
    """,
    type: :object,
    required: [:id, :name, :active],
    properties: %{
      id: %Reference{"$ref": "#/components/schemas/Id"},
      name: %Schema{type: :string, example: "Acme Payments"},
      ownership_context: %Schema{
        type: :string,
        nullable: true,
        example: "Treasury counterparty"
      },
      notes: %Schema{type: :string, nullable: true},
      active: %Schema{type: :boolean, example: true},
      current_trust_level: %Schema{
        allOf: [%Reference{"$ref": "#/components/schemas/TrustLevel"}],
        nullable: true
      },
      created_by: %Schema{type: :string, nullable: true, example: "user"},
      inserted_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
      updated_at: %Reference{"$ref": "#/components/schemas/Timestamp"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.AddressLabelEntity do
  @moduledoc """
  Address label entity returned inside counterparty detail responses
  and as the top-level `data` of attach / update label responses.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "AddressLabelEntity",
    description: """
    Address label projected by
    `CounterpartyJSON.address_label/1`. `retired_at` is non-null when
    the label has been retired; retired labels are immutable.
    """,
    type: :object,
    required: [:id, :counterparty_id, :chain, :address, :verified],
    properties: %{
      id: %Reference{"$ref": "#/components/schemas/Id"},
      counterparty_id: %Reference{"$ref": "#/components/schemas/Id"},
      chain: %Reference{"$ref": "#/components/schemas/Chain"},
      address: %Reference{"$ref": "#/components/schemas/EvmAddress"},
      alias: %Schema{type: :string, nullable: true, example: "treasury-ops"},
      role: %Schema{
        type: :string,
        nullable: true,
        example: "recipient",
        description: "Operator-chosen role label (free text)."
      },
      verified: %Schema{type: :boolean, example: true},
      retired_at: %Schema{
        allOf: [%Reference{"$ref": "#/components/schemas/Timestamp"}],
        nullable: true
      },
      inserted_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
      updated_at: %Reference{"$ref": "#/components/schemas/Timestamp"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.EvidenceArtifactEntity do
  @moduledoc """
  Evidence artifact entity returned by the add-evidence response.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "EvidenceArtifactEntity",
    description: """
    Evidence artifact projected by
    `CounterpartyJSON.evidence_artifact/1`. Evidence is append-only;
    this endpoint never edits prior artifacts.
    """,
    type: :object,
    required: [:id, :kind, :source, :captured_at],
    properties: %{
      id: %Reference{"$ref": "#/components/schemas/Id"},
      subject_type: %Schema{type: :string, example: "counterparty"},
      subject_id: %Reference{"$ref": "#/components/schemas/Id"},
      kind: %Schema{type: :string, example: "manual_note"},
      source: %Schema{type: :string, example: "operator"},
      content_uri: %Schema{type: :string, nullable: true, example: "https://..."},
      payload_hash: %Schema{type: :string, nullable: true},
      weight: %Schema{
        type: :number,
        nullable: true,
        example: 1.0,
        description: "Operator-assigned weight; interpretation is context-specific."
      },
      captured_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
      captured_by: %Schema{type: :string, nullable: true, example: "user"},
      supersedes_id: %Schema{
        allOf: [%Reference{"$ref": "#/components/schemas/Id"}],
        nullable: true
      },
      inserted_at: %Reference{"$ref": "#/components/schemas/Timestamp"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.TrustAssertionEntity do
  @moduledoc """
  Trust assertion entity embedded in counterparty detail responses
  and returned as `data` by `POST /v1/trust_assertions`.
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "TrustAssertionEntity",
    description: """
    Trust assertion projected by
    `CounterpartyJSON.trust_assertion/1`. `coarse` is `true` when the
    assertion is `trusted` and unscoped — a hint for the operator
    console to ask for a tighter scope.
    """,
    type: :object,
    required: [:id, :subject, :level, :coarse],
    properties: %{
      id: %Reference{"$ref": "#/components/schemas/Id"},
      subject: %Schema{
        type: :object,
        required: [:type, :id],
        properties: %{
          type: %Schema{type: :string, enum: ["counterparty", "address_label"]},
          id: %Reference{"$ref": "#/components/schemas/Id"}
        }
      },
      level: %Reference{"$ref": "#/components/schemas/TrustLevel"},
      scope: %Schema{
        type: :object,
        description:
          "Free-form scope object (asset / chain / amount_ceiling / time_window). " <>
            "Unscoped `trusted` is accepted but flagged as `coarse: true`.",
        additionalProperties: true,
        example: %{"asset" => "USDC", "chain" => "base"}
      },
      rationale: %Schema{type: :string, nullable: true},
      evidence_ids: %Schema{
        type: :array,
        items: %Reference{"$ref": "#/components/schemas/Id"}
      },
      issued_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
      issued_by: %Schema{
        type: :string,
        description: "`\"user\"` for operator-issued; `\"trust_engine\"` for derived.",
        example: "user"
      },
      expires_at: %Schema{
        allOf: [%Reference{"$ref": "#/components/schemas/Timestamp"}],
        nullable: true
      },
      superseded_at: %Schema{
        allOf: [%Reference{"$ref": "#/components/schemas/Timestamp"}],
        nullable: true
      },
      supersedes_id: %Schema{
        allOf: [%Reference{"$ref": "#/components/schemas/Id"}],
        nullable: true
      },
      coarse: %Schema{type: :boolean, example: false}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.CounterpartyDetail do
  @moduledoc """
  Counterparty object with its preloaded associations, returned by
  create / update (and single-counterparty GETs once wired).
  """

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "CounterpartyDetail",
    description: """
    Counterparty with preloaded active address labels, effective
    trust assertions, and evidence artifacts. Produced by
    `CounterpartyJSON.counterparty_with_preloads/1` on create /
    update responses.
    """,
    type: :object,
    required: [:id, :name, :active],
    properties: %{
      id: %Reference{"$ref": "#/components/schemas/Id"},
      name: %Schema{type: :string},
      ownership_context: %Schema{type: :string, nullable: true},
      notes: %Schema{type: :string, nullable: true},
      active: %Schema{type: :boolean},
      current_trust_level: %Schema{
        allOf: [%Reference{"$ref": "#/components/schemas/TrustLevel"}],
        nullable: true
      },
      created_by: %Schema{type: :string, nullable: true},
      inserted_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
      updated_at: %Reference{"$ref": "#/components/schemas/Timestamp"},
      active_address_labels: %Schema{
        type: :array,
        nullable: true,
        items: %Reference{"$ref": "#/components/schemas/AddressLabelEntity"}
      },
      effective_trust_assertions: %Schema{
        type: :array,
        nullable: true,
        items: %Reference{"$ref": "#/components/schemas/TrustAssertionEntity"}
      },
      evidence: %Schema{
        type: :array,
        nullable: true,
        items: %Reference{"$ref": "#/components/schemas/EvidenceArtifactEntity"}
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.CounterpartyListResponse do
  @moduledoc "`GET /v1/counterparties` response body."

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "CounterpartyListResponse",
    description: "Paged list of counterparty summaries.",
    type: :object,
    required: [:data, :page],
    properties: %{
      data: %Schema{
        type: :array,
        items: %Reference{"$ref": "#/components/schemas/CounterpartySummary"}
      },
      page: %Schema{
        type: :object,
        required: [:next_cursor],
        properties: %{
          next_cursor: %Schema{type: :string, nullable: true}
        }
      }
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.CounterpartyResponse do
  @moduledoc "Create / update counterparty response body."

  require OpenApiSpex
  alias OpenApiSpex.Reference

  OpenApiSpex.schema(%{
    title: "CounterpartyResponse",
    type: :object,
    required: [:data],
    properties: %{
      data: %Reference{"$ref": "#/components/schemas/CounterpartyDetail"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.CreateCounterpartyRequest do
  @moduledoc "Body for `POST /v1/counterparties`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "CreateCounterpartyRequest",
    type: :object,
    required: [:name],
    properties: %{
      name: %Schema{type: :string, example: "Acme Payments"},
      ownership_context: %Schema{type: :string, nullable: true},
      notes: %Schema{type: :string, nullable: true}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.UpdateCounterpartyRequest do
  @moduledoc "Body for `PATCH /v1/counterparties/{id}`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "UpdateCounterpartyRequest",
    description:
      "Patch body. Every field is optional; `active: false` soft-archives " <>
        "the counterparty. Attaching to an archived counterparty is rejected.",
    type: :object,
    properties: %{
      name: %Schema{type: :string},
      ownership_context: %Schema{type: :string, nullable: true},
      notes: %Schema{type: :string, nullable: true},
      active: %Schema{type: :boolean}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.AttachAddressRequest do
  @moduledoc "Body for `POST /v1/counterparties/{id}/addresses`."

  require OpenApiSpex
  alias OpenApiSpex.{Reference, Schema}

  OpenApiSpex.schema(%{
    title: "AttachAddressRequest",
    type: :object,
    required: [:chain, :address],
    properties: %{
      chain: %Reference{"$ref": "#/components/schemas/Chain"},
      address: %Reference{"$ref": "#/components/schemas/EvmAddress"},
      alias: %Schema{type: :string, nullable: true, example: "treasury-ops"},
      role: %Schema{type: :string, nullable: true, example: "recipient"},
      verified: %Schema{type: :boolean, example: false}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.AddressLabelResponse do
  @moduledoc "Response body for attach + update address label."

  require OpenApiSpex
  alias OpenApiSpex.Reference

  OpenApiSpex.schema(%{
    title: "AddressLabelResponse",
    type: :object,
    required: [:data],
    properties: %{
      data: %Reference{"$ref": "#/components/schemas/AddressLabelEntity"}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.UpdateAddressLabelRequest do
  @moduledoc "Body for `PATCH /v1/address_labels/{id}`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "UpdateAddressLabelRequest",
    description: """
    Patch body. The address value itself is immutable — correcting a
    wrong address requires retiring this label (`retired: true`) and
    attaching a new one.
    """,
    type: :object,
    properties: %{
      alias: %Schema{type: :string, nullable: true},
      role: %Schema{type: :string, nullable: true},
      verified: %Schema{type: :boolean},
      retired: %Schema{type: :boolean}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.AddEvidenceRequest do
  @moduledoc "Body for `POST /v1/counterparties/{id}/evidence`."

  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "AddEvidenceRequest",
    description:
      "Pin a new evidence artifact to a counterparty. Append-only: this " <>
        "endpoint never edits prior artifacts.",
    type: :object,
    required: [:kind, :content_uri, :source],
    properties: %{
      kind: %Schema{type: :string, example: "manual_note"},
      source: %Schema{type: :string, example: "operator"},
      content_uri: %Schema{type: :string, example: "https://..."},
      weight: %Schema{type: :number, nullable: true, example: 1.0},
      payload_hash: %Schema{type: :string, nullable: true}
    }
  })
end

defmodule BankWeb.OpenApi.Schemas.EvidenceResponse do
  @moduledoc "Response body for `POST /v1/counterparties/{id}/evidence`."

  require OpenApiSpex
  alias OpenApiSpex.Reference

  OpenApiSpex.schema(%{
    title: "EvidenceResponse",
    type: :object,
    required: [:data],
    properties: %{
      data: %Reference{"$ref": "#/components/schemas/EvidenceArtifactEntity"}
    }
  })
end
