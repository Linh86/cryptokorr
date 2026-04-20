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
               security: []
             } = ApiSpec.spec()

      assert is_map(paths)
    end

    test "serializes to JSON without raising" do
      json = ApiSpec.spec() |> Jason.encode!()
      assert is_binary(json)
      decoded = Jason.decode!(json)
      assert is_map(decoded)
      assert decoded["info"]["title"] == "CryptoBank /v1 API"
    end
  end

  describe "info" do
    test "title is the pinned CryptoBank /v1 API" do
      assert ApiSpec.spec().info.title == "CryptoBank /v1 API"
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

  describe "tags — canonical domain list" do
    test "exactly matches the ten planned external /v1 domains" do
      expected = ~w(
        Intents Decisions Approvals Counterparties AddressLabels
        TrustAssertions Policies Audit Security Connect
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

  describe "components.securitySchemes — placeholder only" do
    test "declares operator_bearer as HTTP bearer" do
      assert %SecurityScheme{type: "http", scheme: "bearer", description: description} =
               ApiSpec.spec().components.securitySchemes["operator_bearer"]

      # The wording is load-bearing: the spec must not imply that /v1
      # endpoints are currently bearer-protected. Later issues will
      # remove the "not currently enforced" caveat when auth actually
      # ships.
      assert description =~ "Not currently enforced"
    end

    test "does not attach any security requirement at the top level" do
      # `security: []` is the only truthful stance today: no endpoint
      # requires auth at runtime, so the top-level array stays empty
      # rather than defaulting into the placeholder scheme.
      assert ApiSpec.spec().security == []
    end
  end

  describe "components.schemas — populated by #87" do
    test "includes the full shared primitive / enum / envelope set" do
      # These are the shapes #88/#89 will $ref by name; a rename or
      # drop must surface as a test failure here. `ErrorEnvelope`
      # is the outer `{error: ErrorDetail}` wrapper that matches
      # what `/v1` controllers actually emit; `ErrorDetail` is the
      # inner object, registered so later issues can $ref either
      # layer.
      expected_schema_keys = ~w(
        Id Timestamp AmountString EvmAddress
        Chain Asset IntentState DecisionOutcome
        TrustLevel TrustConfidence
        Links ErrorDetail ErrorEnvelope
      )

      actual_keys = ApiSpec.spec().components.schemas |> Map.keys() |> Enum.sort()
      assert actual_keys == Enum.sort(expected_schema_keys)
    end
  end
end
