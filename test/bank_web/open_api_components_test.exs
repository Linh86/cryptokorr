defmodule BankWeb.OpenApiComponentsTest do
  @moduledoc """
  Shape tests for the shared OpenAPI components introduced in
  issue #87.

  These tests pin the exact component names and error-body shape
  that #88 and #89 will `$ref` by name. They are deliberately
  narrow — they do not try to cover endpoint-level operations
  (that is #88 / #89), and they avoid whole-document snapshots.
  """

  use ExUnit.Case, async: true

  alias BankWeb.ApiSpec
  alias OpenApiSpex.{Components, Header, Parameter, Reference, Response, Schema, SecurityScheme}

  defp components, do: ApiSpec.spec().components

  describe "top-level components wiring" do
    test "spec().components is populated with every shared bucket" do
      assert %Components{
               schemas: schemas,
               parameters: parameters,
               headers: headers,
               responses: responses,
               securitySchemes: security_schemes
             } = components()

      refute schemas == %{}
      refute parameters == %{}
      refute headers == %{}
      refute responses == %{}
      refute security_schemes == %{}
    end
  end

  describe "shared schemas — primitives" do
    test "Id is a UUID-formatted string" do
      assert %Schema{title: "Id", type: :string, format: :uuid} = components().schemas["Id"]
    end

    test "Timestamp is an ISO-8601 date-time string" do
      assert %Schema{title: "Timestamp", type: :string, format: :"date-time"} =
               components().schemas["Timestamp"]
    end

    test "AmountString is a string with a decimal-pattern" do
      assert %Schema{title: "AmountString", type: :string, pattern: pattern} =
               components().schemas["AmountString"]

      assert is_binary(pattern)
      assert Regex.match?(Regex.compile!(pattern), "250.00")
      assert Regex.match?(Regex.compile!(pattern), "0")
      refute Regex.match?(Regex.compile!(pattern), "abc")
    end

    test "EvmAddress enforces lowercase 0x-prefixed 20-byte hex" do
      assert %Schema{title: "EvmAddress", type: :string, pattern: pattern} =
               components().schemas["EvmAddress"]

      assert Regex.match?(Regex.compile!(pattern), "0x" <> String.duplicate("a", 40))
      refute Regex.match?(Regex.compile!(pattern), "0x" <> String.duplicate("A", 40))
      refute Regex.match?(Regex.compile!(pattern), "0xdead")
    end
  end

  describe "shared schemas — enums" do
    test "Chain enum is the single-value /v1 list" do
      assert %Schema{title: "Chain", enum: ["base"]} = components().schemas["Chain"]
    end

    test "IntentState enum matches the documented lifecycle states" do
      assert %Schema{title: "IntentState", enum: enum} = components().schemas["IntentState"]

      assert Enum.sort(enum) ==
               Enum.sort(~w(submitted evaluating decided executing executed blocked cancelled))
    end

    test "DecisionOutcome enum is the four outcomes pinned by the /v1 contract" do
      assert %Schema{title: "DecisionOutcome", enum: enum} =
               components().schemas["DecisionOutcome"]

      assert Enum.sort(enum) == Enum.sort(~w(auto_exec hold approval_required block))
    end

    test "TrustLevel enum is the four derived-trust levels" do
      assert %Schema{title: "TrustLevel", enum: enum} = components().schemas["TrustLevel"]
      assert Enum.sort(enum) == Enum.sort(~w(trusted sensitive unknown conflicted))
    end

    test "TrustConfidence enum is low/medium/high" do
      assert %Schema{title: "TrustConfidence", enum: enum} =
               components().schemas["TrustConfidence"]

      assert Enum.sort(enum) == Enum.sort(~w(low medium high))
    end
  end

  describe "shared schemas — envelopes" do
    test "ErrorEnvelope is the outer {error: ErrorDetail} wrapper" do
      # Matches what every /v1 controller actually emits today:
      # `{ "error": { ... } }`. The `error` property references the
      # inner `ErrorDetail` schema by $ref.
      assert %Schema{
               title: "ErrorEnvelope",
               type: :object,
               required: [:error],
               properties: %{error: error_property}
             } = components().schemas["ErrorEnvelope"]

      assert %Reference{"$ref": "#/components/schemas/ErrorDetail"} = error_property
    end

    test "ErrorDetail requires only code + message (truthful floor)" do
      # Only `code` and `message` are required because every /v1
      # error path sets both. `hint`, `retryable`, and `details`
      # are deliberately optional — #87 does not pin a stricter
      # contract than the runtime actually delivers.
      assert %Schema{
               title: "ErrorDetail",
               type: :object,
               required: required,
               properties: props
             } = components().schemas["ErrorDetail"]

      assert Enum.sort(required) == Enum.sort([:code, :message])
      assert :hint not in required
      assert :retryable not in required
      assert :details not in required

      expected_props = [:code, :message, :hint, :retryable, :details]
      assert Map.keys(props) |> Enum.sort() == Enum.sort(expected_props)

      assert %Schema{type: :string} = props[:code]
      assert %Schema{type: :string} = props[:message]
      assert %Schema{type: :string, nullable: true} = props[:hint]
      assert %Schema{type: :boolean} = props[:retryable]
      assert %Schema{type: :object, additionalProperties: details_inner} = props[:details]
      assert %Schema{type: :array, items: %Schema{type: :string}} = details_inner
    end

    test "Links is an open object of string values" do
      assert %Schema{title: "Links", type: :object, additionalProperties: inner} =
               components().schemas["Links"]

      assert %Schema{type: :string} = inner
    end
  end

  describe "shared parameters" do
    test "IdempotencyKey is a required header parameter" do
      assert %Parameter{
               name: "Idempotency-Key",
               in: :header,
               required: true,
               schema: %Schema{type: :string}
             } = components().parameters["IdempotencyKey"]
    end

    test "RequestIdIn is an optional X-Request-Id header parameter" do
      assert %Parameter{
               name: "X-Request-Id",
               in: :header,
               required: false,
               schema: %Schema{type: :string}
             } = components().parameters["RequestIdIn"]
    end
  end

  describe "shared headers" do
    test "RequestIdOut is a required response header" do
      assert %Header{
               required: true,
               schema: %Schema{type: :string}
             } = components().headers["RequestIdOut"]
    end
  end

  describe "shared responses" do
    test "declares the full error-response family under stable names" do
      # `NotImplemented` was added in #88 for the intent stubs.
      # `Unauthorized` was added in #218c so authenticated `/v1`
      # operations can $ref a consistent 401 body shape.
      # `TooManyRequests` was added in #221 once all four
      # rate-limit slices (per-key, auth-failure, per-workspace,
      # chain-action) were in `main` so authenticated `/v1`
      # operations can $ref the 429 body shape and `Retry-After`
      # header.
      expected =
        ~w(BadRequest Unauthorized Forbidden NotFound Conflict UnprocessableEntity
           TooManyRequests NotImplemented ServiceUnavailable BadGateway GatewayTimeout)

      actual = components().responses |> Map.keys() |> Enum.sort()
      assert actual == Enum.sort(expected)
    end

    test "every error response carries a JSON ErrorEnvelope body and the request-id header" do
      for {name, %Response{content: content, headers: headers}} <- components().responses do
        assert %{"application/json" => %OpenApiSpex.MediaType{schema: schema_ref}} = content,
               "response #{name} missing application/json body"

        assert %Reference{"$ref": "#/components/schemas/ErrorEnvelope"} = schema_ref,
               "response #{name} body does not $ref ErrorEnvelope"

        assert %Reference{"$ref": "#/components/headers/RequestIdOut"} = headers["X-Request-Id"],
               "response #{name} missing X-Request-Id header ref"
      end
    end

    test "each response has a human-readable description" do
      for {name, %Response{description: description}} <- components().responses do
        assert is_binary(description) and description != "",
               "response #{name} is missing a description"
      end
    end
  end

  describe "security schemes — workspace_api_key is the active scheme (#218b)" do
    test "workspace_api_key is an HTTP bearer scheme with the cb_<base32> bearerFormat" do
      assert %SecurityScheme{
               type: "http",
               scheme: "bearer",
               bearerFormat: "cb_<base32>",
               description: description
             } = components().securitySchemes["workspace_api_key"]

      assert description =~ "Workspace-scoped"
      assert description =~ "Bearer"
    end

    test "operator_bearer is retained as a backwards-compat alias" do
      assert components().securitySchemes["operator_bearer"] ==
               components().securitySchemes["workspace_api_key"]
    end

    test "agent_api_key is reserved as a future scheme placeholder" do
      assert %SecurityScheme{
               type: "apiKey",
               in: "header",
               name: "X-Agent-Key"
             } = components().securitySchemes["agent_api_key"]
    end

    test "top-level security requires workspace_api_key by default" do
      assert ApiSpec.spec().security == [%{"workspace_api_key" => []}]
    end
  end

  describe "document serializability" do
    test "the full spec still encodes to JSON after components wiring" do
      json = ApiSpec.spec() |> Jason.encode!()
      decoded = Jason.decode!(json)

      assert decoded["components"]["schemas"]["ErrorEnvelope"]["title"] == "ErrorEnvelope"
      assert decoded["components"]["schemas"]["ErrorDetail"]["title"] == "ErrorDetail"
      assert decoded["components"]["responses"]["Conflict"]["description"] =~ "Idempotency"

      assert decoded["components"]["securitySchemes"]["operator_bearer"]["type"] == "http"
      assert decoded["components"]["securitySchemes"]["agent_api_key"]["type"] == "apiKey"
    end

    test "ErrorEnvelope's error property serializes as a $ref to ErrorDetail" do
      # End-to-end JSON check: the outer envelope's `error` property
      # must land as `{"$ref": "#/components/schemas/ErrorDetail"}`
      # in the final document, not as an inlined schema.
      json = ApiSpec.spec() |> Jason.encode!()
      decoded = Jason.decode!(json)

      envelope = decoded["components"]["schemas"]["ErrorEnvelope"]
      assert envelope["required"] == ["error"]
      assert envelope["properties"]["error"]["$ref"] == "#/components/schemas/ErrorDetail"
    end

    test "ErrorDetail's required-field set is exactly [code, message] in JSON" do
      json = ApiSpec.spec() |> Jason.encode!()
      decoded = Jason.decode!(json)

      detail = decoded["components"]["schemas"]["ErrorDetail"]
      assert Enum.sort(detail["required"]) == ["code", "message"]
      # Opportunistic fields exist as optional properties.
      for key <- ~w(code message hint retryable details) do
        assert Map.has_key?(detail["properties"], key), "ErrorDetail missing property #{key}"
      end
    end
  end
end
