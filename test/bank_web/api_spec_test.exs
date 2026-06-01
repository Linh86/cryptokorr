defmodule BankWeb.ApiSpecTest do
  @moduledoc """
  Tests for the OpenAPI foundation (issue #86, epic #85).

  Pins the invariants this foundation is supposed to guarantee before
  subsequent issues (#87 components, #88-#89 operations, #90
  artifact) build on top:

    * the document builds and serializes cleanly;
    * its paths never leak outside the external `/v1/...` surface —
      `/health`, `/internal/*`, `/dev/*`, and the LiveView tree must
      stay excluded even when later issues add operation specs
      elsewhere in the router by accident;
    * the ten domain tag names are stable (renames should fail this
      test loudly so downstream SDK consumers don't silently drift);
    * the security placeholder is declared but not attached to any
      operation — the spec must not overclaim current runtime auth.
  """

  use ExUnit.Case, async: true

  alias BankWeb.ApiSpec
  alias OpenApiSpex.{Components, Info, OpenApi, SecurityScheme, Server, Tag}

  describe "spec/0 — structural invariants" do
    test "returns a well-formed OpenApiSpex.OpenApi struct" do
      assert %OpenApi{
               info: %Info{},
               servers: [%Server{} | _],
               tags: [%Tag{} | _],
               paths: paths,
               components: %Components{},
               security: [%{"workspace_api_key" => []}]
             } = ApiSpec.spec()

      assert is_map(paths)
    end

    test "serializes to JSON without raising" do
      json = ApiSpec.spec() |> Jason.encode!()
      assert is_binary(json)
      decoded = Jason.decode!(json)
      assert is_map(decoded)
      assert decoded["info"]["title"] == "CryptoKorr /v1 API"
    end
  end

  describe "info" do
    test "title is the pinned CryptoKorr /v1 API" do
      assert ApiSpec.spec().info.title == "CryptoKorr /v1 API"
    end

    test "version tracks the loaded :bank app version" do
      expected = Application.spec(:bank, :vsn) |> to_string()
      assert ApiSpec.spec().info.version == expected
      assert expected != ""
    end
  end

  describe "servers" do
    test "declares a single templated server at the endpoint root (NOT /v1)" do
      # The server URL must end at the host so operation paths like
      # `/v1/intents` compose to `{scheme}://{host}/v1/intents` rather
      # than `{scheme}://{host}/v1/v1/intents`. This is the #86
      # variant-1 base-path fix.
      assert [%Server{url: url, variables: vars}] = ApiSpec.spec().servers
      assert url == "{scheme}://{host}"
      refute String.ends_with?(url, "/v1")
      assert Map.has_key?(vars, "scheme")
      assert Map.has_key?(vars, "host")
    end
  end

  describe "tags — canonical top-level list" do
    test "exactly matches the eleven business domains plus Health and APIKeys" do
      # Ten business-domain tags were pinned in #86; `Health` was
      # added in #88 alongside the operation specs on
      # `BankWeb.HealthController`; `APIKeys` was added in #218c
      # alongside `BankWeb.API.V1.APIKeyController`. Every
      # operation tag the spec references is also declared at the
      # top level.
      expected = ~w(
        Intents Decisions Approvals Counterparties AddressLabels
        TrustAssertions Policies Audit Security Connect Health APIKeys
      )

      actual = Enum.map(ApiSpec.spec().tags, & &1.name)
      assert actual == expected
      assert ApiSpec.domain_tag_names() == expected
    end

    test "every tag carries a non-empty description" do
      for %Tag{name: name, description: description} <- ApiSpec.spec().tags do
        assert is_binary(description) and description != "",
               "tag #{inspect(name)} is missing a description"
      end
    end
  end

  describe "paths — scope invariant" do
    test "never contain non-/v1 routes" do
      for {path, _item} <- ApiSpec.spec().paths do
        assert String.starts_with?(path, "/v1/"),
               "path #{inspect(path)} leaked into the external /v1 spec"
      end
    end

    test "contain no /internal/, /health, /dev, or LiveView paths" do
      for {path, _item} <- ApiSpec.spec().paths do
        refute String.starts_with?(path, "/internal/"), "internal path leaked: #{path}"
        refute String.starts_with?(path, "/dev"), "dev path leaked: #{path}"
        refute path in ["/health", "/"], "non-/v1 path leaked: #{path}"
      end
    end
  end

  describe "components.securitySchemes — workspace_api_key is the active scheme (#218b)" do
    test "declares workspace_api_key as HTTP bearer with the cb_<base32> bearerFormat" do
      assert %SecurityScheme{
               type: "http",
               scheme: "bearer",
               bearerFormat: "cb_<base32>",
               description: description
             } = ApiSpec.spec().components.securitySchemes["workspace_api_key"]

      # The wording must reflect the actual enforcement shape so
      # SDK / tooling consumers don't have to read the docs to
      # discover the auth scheme.
      assert description =~ "Workspace-scoped"
      assert description =~ "Bearer"
      assert description =~ "401 invalid_credentials"
    end

    test "operator_bearer is retained as a backwards-compat alias of workspace_api_key" do
      # Existing tooling that referenced the historical
      # `operator_bearer` name should keep working — `operator_bearer`
      # now resolves to the same scheme as `workspace_api_key`.
      bearer = ApiSpec.spec().components.securitySchemes["operator_bearer"]
      ws_key = ApiSpec.spec().components.securitySchemes["workspace_api_key"]
      assert bearer == ws_key
    end

    test "attaches workspace_api_key as the default at the top level" do
      # Top-level `security` requires `workspace_api_key` on every
      # operation by default. Public health operations override
      # with `security: []` to opt out.
      assert ApiSpec.spec().security == [%{"workspace_api_key" => []}]
    end
  end

  describe "components.schemas — populated by #87 + #88" do
    test "includes the shared #87 primitives / enums / envelopes" do
      # These are the #87 shapes #88/#89 $ref by name. `ErrorEnvelope`
      # is the outer `{error: ErrorDetail}` wrapper; `ErrorDetail` is
      # the inner object.
      expected_shared = ~w(
        Id Timestamp AmountString EvmAddress
        Chain Asset IntentState DecisionOutcome
        TrustLevel TrustConfidence
        Links ErrorDetail ErrorEnvelope
      )

      actual = ApiSpec.spec().components.schemas |> Map.keys()

      for title <- expected_shared do
        assert title in actual, "shared schema #{inspect(title)} missing from components.schemas"
      end
    end

    test "includes the per-domain schemas added in #88" do
      # Health + Intents + Decisions + Approvals domain shapes. Later
      # issues cover remaining operator / configuration endpoints.
      expected_domain = ~w(
        HealthReadinessResponse HealthDeepResponse
        IntentTarget IntentSubmissionRequest SimulationRequest
        CancelRequest IntentReplayResponse
        ExecutionPlanSummary DecisionEnvelopeDetail DecisionShowResponse
        ExecuteDecisionRequest ExecuteDecisionResponse
        ApprovalDecisionSummary ApprovalQueueResponse
        ApprovalActionRequest ApprovalNextStep ApprovalActionResponse
      )

      actual = ApiSpec.spec().components.schemas |> Map.keys()

      for title <- expected_domain do
        assert title in actual, "#88 schema #{inspect(title)} missing from components.schemas"
      end
    end
  end
end
