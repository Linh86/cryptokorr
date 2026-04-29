defmodule BankWeb.OpenApiCoreEndpointsTest do
  @moduledoc """
  Tests for the core-endpoint operation coverage added in issue #88:
  `/v1/health`, `/v1/health/deep`, and the full intents / decisions /
  approvals surfaces.

  These tests pin presence and wiring — the core contract operations
  exist, carry the right tag, and reuse the shared components from
  #87 — without turning into a brittle whole-document snapshot. They
  also assert that `/internal/*` never leaks into the spec, matching
  the scope invariant established in #86 / #87.
  """

  use ExUnit.Case, async: true

  alias BankWeb.ApiSpec

  defp spec, do: ApiSpec.spec()
  defp paths, do: spec().paths

  describe "paths coverage for #88 in-scope endpoints" do
    test "every in-scope path appears in the spec" do
      expected = [
        "/v1/health",
        "/v1/health/deep",
        "/v1/intents",
        "/v1/intents/{id}",
        "/v1/intents/{id}/simulate",
        "/v1/intents/{id}/cancel",
        "/v1/intents/{id}/replay",
        "/v1/decisions/{id}",
        "/v1/decisions/{id}/execute",
        "/v1/approvals",
        "/v1/approvals/{decision_id}/approve",
        "/v1/approvals/{decision_id}/reject"
      ]

      for path <- expected do
        assert Map.has_key?(paths(), path), "path #{inspect(path)} missing from /v1 spec"
      end
    end

    test "no /internal/, /health (non-v1), or /dev path leaks into the spec" do
      for {path, _item} <- paths() do
        assert String.starts_with?(path, "/v1/"),
               "path #{inspect(path)} leaked outside /v1"

        refute path == "/health", "non-v1 /health leaked"
      end
    end
  end

  describe "tags wiring" do
    test "health endpoints carry the Health tag" do
      assert get_in(paths(), ["/v1/health", Access.key(:get), Access.key(:tags)]) == ["Health"]

      assert get_in(paths(), ["/v1/health/deep", Access.key(:get), Access.key(:tags)]) ==
               ["Health"]
    end

    test "intent endpoints carry the Intents tag" do
      for {path, method} <- [
            {"/v1/intents", :post},
            {"/v1/intents/{id}", :get},
            {"/v1/intents/{id}/simulate", :post},
            {"/v1/intents/{id}/cancel", :post},
            {"/v1/intents/{id}/replay", :get}
          ] do
        tags = get_in(paths(), [path, Access.key(method), Access.key(:tags)])
        assert tags == ["Intents"], "#{method} #{path} missing Intents tag (got #{inspect(tags)})"
      end
    end

    test "decision endpoints carry the Decisions tag" do
      assert get_in(paths(), ["/v1/decisions/{id}", Access.key(:get), Access.key(:tags)]) ==
               ["Decisions"]

      assert get_in(paths(), [
               "/v1/decisions/{id}/execute",
               Access.key(:post),
               Access.key(:tags)
             ]) == ["Decisions"]
    end

    test "approval endpoints carry the Approvals tag" do
      for path <- [
            "/v1/approvals",
            "/v1/approvals/{decision_id}/approve",
            "/v1/approvals/{decision_id}/reject"
          ] do
        method = if path == "/v1/approvals", do: :get, else: :post
        tags = get_in(paths(), [path, Access.key(method), Access.key(:tags)])
        assert tags == ["Approvals"], "#{method} #{path} missing Approvals tag"
      end
    end
  end

  describe "intent stubs are documented as 501 Not Implemented" do
    for {path, method} <- [
          {"/v1/intents/{id}/simulate", :post},
          {"/v1/intents/{id}/cancel", :post}
        ] do
      @path path
      @method method

      test "#{String.upcase(to_string(method))} #{path} documents 501 + ErrorEnvelope" do
        responses = get_in(paths(), [@path, Access.key(@method), Access.key(:responses)])
        assert is_map(responses)
        assert Map.has_key?(responses, 501)

        # The 501 response is the shared NotImplemented component.
        assert %OpenApiSpex.Reference{"$ref": "#/components/responses/NotImplemented"} =
                 responses[501]
      end
    end
  end

  describe "intent create / show are documented live (issue #135)" do
    test "POST /v1/intents documents 202 + IntentSubmitResponse, plus 409 / 422" do
      op = get_in(paths(), ["/v1/intents", Access.key(:post)])
      assert op

      responses = op.responses
      refute Map.has_key?(responses, 501), "POST /v1/intents must no longer document 501"

      %{content: content} = responses[202]
      assert %{"application/json" => media} = content
      assert media.schema == BankWeb.OpenApi.Schemas.IntentSubmitResponse

      assert %OpenApiSpex.Reference{"$ref": "#/components/responses/Conflict"} = responses[409]

      assert %OpenApiSpex.Reference{"$ref": "#/components/responses/UnprocessableEntity"} =
               responses[422]
    end

    test "GET /v1/intents/{id} documents 200 + IntentShowResponse and 404" do
      op = get_in(paths(), ["/v1/intents/{id}", Access.key(:get)])
      assert op

      responses = op.responses
      refute Map.has_key?(responses, 501), "GET /v1/intents/{id} must no longer document 501"

      %{content: content} = responses[200]
      assert %{"application/json" => media} = content
      assert media.schema == BankWeb.OpenApi.Schemas.IntentShowResponse

      assert %OpenApiSpex.Reference{"$ref": "#/components/responses/NotFound"} = responses[404]
    end
  end

  describe "intent replay references IntentReplayResponse + NotFound" do
    test "GET /v1/intents/{id}/replay returns IntentReplayResponse on 200 and NotFound on 404" do
      op = get_in(paths(), ["/v1/intents/{id}/replay", Access.key(:get)])
      assert op

      responses = op.responses
      assert %OpenApiSpex.Reference{"$ref": "#/components/responses/NotFound"} = responses[404]

      # The 200 body references the IntentReplayResponse schema module
      # either as a Reference or via resolve_schema_modules. Assert the
      # JSON content type exists and points at a schema with title
      # "IntentReplayResponse".
      %{content: content} = responses[200]
      assert %{"application/json" => media} = content
      assert media.schema == BankWeb.OpenApi.Schemas.IntentReplayResponse
    end
  end

  describe "decision execute references the expected request / response pair" do
    test "POST /v1/decisions/{id}/execute carries ExecuteDecisionRequest and ExecuteDecisionResponse" do
      op = get_in(paths(), ["/v1/decisions/{id}/execute", Access.key(:post)])
      assert op

      assert %OpenApiSpex.RequestBody{content: req_content} = op.requestBody
      assert %{"application/json" => req_media} = req_content
      assert req_media.schema == BankWeb.OpenApi.Schemas.ExecuteDecisionRequest

      %{content: resp_content} = op.responses[202]
      assert %{"application/json" => resp_media} = resp_content
      assert resp_media.schema == BankWeb.OpenApi.Schemas.ExecuteDecisionResponse
    end

    test "GET /v1/decisions/{id} references DecisionShowResponse body + NotFound" do
      op = get_in(paths(), ["/v1/decisions/{id}", Access.key(:get)])
      assert op

      %{content: resp_content} = op.responses[200]
      assert %{"application/json" => resp_media} = resp_content
      assert resp_media.schema == BankWeb.OpenApi.Schemas.DecisionShowResponse

      assert %OpenApiSpex.Reference{"$ref": "#/components/responses/NotFound"} = op.responses[404]
    end
  end

  describe "approvals reference the unified action request / response pair" do
    test "POST /v1/approvals/{decision_id}/approve uses ApprovalActionRequest + ApprovalActionResponse" do
      op = get_in(paths(), ["/v1/approvals/{decision_id}/approve", Access.key(:post)])
      assert op

      assert %{"application/json" => req_media} = op.requestBody.content
      assert req_media.schema == BankWeb.OpenApi.Schemas.ApprovalActionRequest

      %{content: resp_content} = op.responses[200]
      assert %{"application/json" => resp_media} = resp_content
      assert resp_media.schema == BankWeb.OpenApi.Schemas.ApprovalActionResponse
    end

    test "POST /v1/approvals/{decision_id}/reject carries the same request / response pair" do
      op = get_in(paths(), ["/v1/approvals/{decision_id}/reject", Access.key(:post)])
      assert op

      assert op.requestBody.content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.ApprovalActionRequest

      assert op.responses[200].content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.ApprovalActionResponse
    end

    test "GET /v1/approvals returns ApprovalQueueResponse" do
      op = get_in(paths(), ["/v1/approvals", Access.key(:get)])
      assert op

      assert op.responses[200].content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.ApprovalQueueResponse
    end
  end

  describe "health endpoints reference their dedicated schemas" do
    test "GET /v1/health returns HealthReadinessResponse on 200 and 503" do
      op = get_in(paths(), ["/v1/health", Access.key(:get)])
      assert op

      assert op.responses[200].content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.HealthReadinessResponse

      assert op.responses[503].content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.HealthReadinessResponse
    end

    test "GET /v1/health/deep returns HealthDeepResponse on 200 and 503" do
      op = get_in(paths(), ["/v1/health/deep", Access.key(:get)])
      assert op

      assert op.responses[200].content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.HealthDeepResponse

      assert op.responses[503].content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.HealthDeepResponse
    end
  end

  describe "shared header / parameter wiring" do
    test "write endpoints reuse the IdempotencyKey shared parameter" do
      for {path, method} <- [
            {"/v1/intents", :post},
            {"/v1/intents/{id}/simulate", :post},
            {"/v1/intents/{id}/cancel", :post},
            {"/v1/decisions/{id}/execute", :post},
            {"/v1/approvals/{decision_id}/approve", :post},
            {"/v1/approvals/{decision_id}/reject", :post}
          ] do
        params = get_in(paths(), [path, Access.key(method), Access.key(:parameters)])
        assert params != nil and params != []

        idempotency =
          Enum.find(params, fn p ->
            match?(
              %OpenApiSpex.Reference{"$ref": "#/components/parameters/IdempotencyKey"},
              p
            )
          end)

        assert idempotency,
               "#{method} #{path} is missing the IdempotencyKey shared parameter ref"
      end
    end
  end

  describe "top-level components added by #88" do
    test "NotImplemented is now a registered reusable response" do
      assert %OpenApiSpex.Response{content: content} =
               spec().components.responses["NotImplemented"]

      assert %{"application/json" => media} = content

      assert %OpenApiSpex.Reference{"$ref": "#/components/schemas/ErrorEnvelope"} = media.schema
    end

    test "every per-domain schema added in #88 is registered under its title" do
      expected = ~w(
        HealthReadinessResponse HealthDeepResponse
        IntentTarget IntentSubmissionRequest SimulationRequest
        CancelRequest IntentReplayResponse
        ExecutionPlanSummary DecisionEnvelopeDetail DecisionShowResponse
        ExecuteDecisionRequest ExecuteDecisionResponse
        ApprovalDecisionSummary ApprovalQueueResponse
        ApprovalActionRequest ApprovalNextStep ApprovalActionResponse
      )

      schemas = spec().components.schemas

      for title <- expected do
        assert Map.has_key?(schemas, title), "schema #{inspect(title)} missing"
        assert schemas[title].title == title
      end
    end
  end

  describe "document serializability after #88" do
    test "the full spec still encodes to JSON cleanly" do
      json = spec() |> Jason.encode!()
      decoded = Jason.decode!(json)

      assert Map.has_key?(decoded, "paths")
      assert Map.has_key?(decoded["paths"], "/v1/intents/{id}/replay")

      assert decoded["paths"]["/v1/intents/{id}/simulate"]["post"]["responses"]["501"]["$ref"] =~
               "NotImplemented"
    end
  end
end
