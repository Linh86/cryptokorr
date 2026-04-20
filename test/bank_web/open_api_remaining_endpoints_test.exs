defmodule BankWeb.OpenApiRemainingEndpointsTest do
  @moduledoc """
  Tests for the operator / configuration endpoint coverage added in
  issue #89: counterparties, address labels, trust assertions,
  policies, audit, security, and connect.

  Pins path presence, tag attachment, and major request/response
  `$ref`s without turning into a brittle whole-document snapshot.
  Also re-asserts the scope invariant from #86/#87/#88 — no
  `/internal/*`, `/health` (non-v1), or `/dev` leaks — now that the
  full external `/v1` surface is documented.
  """

  use ExUnit.Case, async: true

  alias BankWeb.ApiSpec

  defp spec, do: ApiSpec.spec()
  defp paths, do: spec().paths

  describe "paths coverage for #89 in-scope endpoints" do
    test "every in-scope path appears in the spec" do
      expected = [
        "/v1/counterparties",
        "/v1/counterparties/{id}",
        "/v1/counterparties/{id}/addresses",
        "/v1/counterparties/{id}/evidence",
        "/v1/address_labels/{id}",
        "/v1/trust_assertions",
        "/v1/policies",
        "/v1/policies/{id}/revise",
        "/v1/policies/{id}/archive",
        "/v1/audit",
        "/v1/security/pause",
        "/v1/security/resume",
        "/v1/security/revoke_delegation",
        "/v1/connect/smart_account"
      ]

      for path <- expected do
        assert Map.has_key?(paths(), path), "path #{inspect(path)} missing from /v1 spec"
      end
    end

    test "combined /v1 surface is inside the /v1 prefix — nothing leaks" do
      for {path, _item} <- paths() do
        assert String.starts_with?(path, "/v1/"),
               "path #{inspect(path)} leaked outside /v1"

        refute String.starts_with?(path, "/v1/internal"), "internal leaked: #{path}"
      end
    end
  end

  describe "tags wiring" do
    test "counterparty endpoints carry the Counterparties tag" do
      for {path, method} <- [
            {"/v1/counterparties", :get},
            {"/v1/counterparties", :post},
            {"/v1/counterparties/{id}", :patch},
            {"/v1/counterparties/{id}/addresses", :post},
            {"/v1/counterparties/{id}/evidence", :post}
          ] do
        tags = get_in(paths(), [path, Access.key(method), Access.key(:tags)])
        assert tags == ["Counterparties"], "#{method} #{path} not tagged Counterparties"
      end
    end

    test "address label patch carries the AddressLabels tag" do
      assert get_in(paths(), ["/v1/address_labels/{id}", Access.key(:patch), Access.key(:tags)]) ==
               ["AddressLabels"]
    end

    test "trust assertion create carries the TrustAssertions tag" do
      assert get_in(paths(), ["/v1/trust_assertions", Access.key(:post), Access.key(:tags)]) ==
               ["TrustAssertions"]
    end

    test "policy endpoints carry the Policies tag" do
      for {path, method} <- [
            {"/v1/policies", :get},
            {"/v1/policies", :post},
            {"/v1/policies/{id}/revise", :post},
            {"/v1/policies/{id}/archive", :post}
          ] do
        tags = get_in(paths(), [path, Access.key(method), Access.key(:tags)])
        assert tags == ["Policies"], "#{method} #{path} not tagged Policies"
      end
    end

    test "audit index carries the Audit tag" do
      assert get_in(paths(), ["/v1/audit", Access.key(:get), Access.key(:tags)]) == ["Audit"]
    end

    test "security endpoints carry the Security tag" do
      for action <- ["pause", "resume", "revoke_delegation"] do
        path = "/v1/security/#{action}"
        tags = get_in(paths(), [path, Access.key(:post), Access.key(:tags)])
        assert tags == ["Security"], "POST #{path} not tagged Security"
      end
    end

    test "connect carries the Connect tag" do
      assert get_in(paths(), ["/v1/connect/smart_account", Access.key(:post), Access.key(:tags)]) ==
               ["Connect"]
    end
  end

  describe "representative request / response refs" do
    test "POST /v1/counterparties uses CreateCounterpartyRequest + CounterpartyResponse" do
      op = get_in(paths(), ["/v1/counterparties", Access.key(:post)])

      assert op.requestBody.content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.CreateCounterpartyRequest

      assert op.responses[201].content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.CounterpartyResponse
    end

    test "GET /v1/counterparties returns CounterpartyListResponse" do
      op = get_in(paths(), ["/v1/counterparties", Access.key(:get)])

      assert op.responses[200].content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.CounterpartyListResponse
    end

    test "PATCH /v1/address_labels/{id} references UpdateAddressLabelRequest + AddressLabelResponse" do
      op = get_in(paths(), ["/v1/address_labels/{id}", Access.key(:patch)])

      assert op.requestBody.content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.UpdateAddressLabelRequest

      assert op.responses[200].content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.AddressLabelResponse
    end

    test "POST /v1/trust_assertions uses IssueTrustAssertionRequest + IssueTrustAssertionResponse" do
      op = get_in(paths(), ["/v1/trust_assertions", Access.key(:post)])

      assert op.requestBody.content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.IssueTrustAssertionRequest

      assert op.responses[201].content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.IssueTrustAssertionResponse
    end

    test "POST /v1/policies uses CreatePolicyRequest + PolicyResponse" do
      op = get_in(paths(), ["/v1/policies", Access.key(:post)])

      assert op.requestBody.content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.CreatePolicyRequest

      assert op.responses[201].content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.PolicyResponse
    end

    test "GET /v1/audit returns AuditListResponse" do
      op = get_in(paths(), ["/v1/audit", Access.key(:get)])

      assert op.responses[200].content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.AuditListResponse
    end
  end

  describe "security — truthful revoke semantics" do
    test "POST /v1/security/revoke_delegation returns 202 revoke_enqueued, not a synchronous chain result" do
      op = get_in(paths(), ["/v1/security/revoke_delegation", Access.key(:post)])

      assert op.requestBody.content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.RevokeDelegationRequest

      # Response is 202 (receipt), not 200 — the chain-side state
      # change is delivered async via security:events + audit.
      assert op.responses[202].content["application/json"].schema ==
               BankWeb.OpenApi.Schemas.RevokeDelegationResponse

      refute Map.has_key?(op.responses, 200),
             "revoke response must not claim synchronous success — it is one-way + async"

      # Description must not overclaim a cryptographic revoke — it
      # must surface the receipt-plus-async semantics.
      description = op.description
      assert description =~ "receipt"
      assert description =~ "async"
      assert description =~ "one-way"
    end

    test "pause / resume return SecurityStateResponse with the already-in-state idempotent branches" do
      pause_response =
        get_in(
          paths(),
          [
            "/v1/security/pause",
            Access.key(:post),
            Access.key(:responses),
            200,
            Access.key(:content),
            "application/json",
            Access.key(:schema)
          ]
        )

      assert pause_response == BankWeb.OpenApi.Schemas.SecurityStateResponse

      # The response schema itself includes both successful-transition
      # and already-in-state values in the `status` enum — asserting
      # the enum is truthful to the controller.
      status_enum =
        BankWeb.OpenApi.Schemas.SecurityStateResponse.schema().properties.status.enum

      assert Enum.sort(status_enum) ==
               Enum.sort(["paused", "already_paused", "resumed", "already_running"])
    end

    test "pause / resume scope is documented truthfully as a loose string (runtime does not reject unknown values)" do
      for mod <- [
            BankWeb.OpenApi.Schemas.SecurityPauseRequest,
            BankWeb.OpenApi.Schemas.SecurityResumeRequest
          ] do
        schema = mod.schema()

        # `scope` must not be an enum — the runtime silently falls
        # back to `:global` on unrecognised values, so an OpenAPI
        # enum would reject requests the server currently accepts.
        assert schema.properties.scope.type == :string

        refute schema.properties.scope.enum,
               "#{inspect(mod)}.scope must not be an enum — runtime accepts any string"

        # Description must state the truthful parse behavior rather
        # than overclaiming validation.
        description = schema.properties.scope.description
        assert description =~ "counterparty:"

        assert description =~ "NOT",
               "#{inspect(mod)}.scope description must explicitly state the runtime " <>
                 "parse is NOT strict (unknown values fall back to global)"
      end
    end
  end

  describe "connect — truthful adapter-stub note" do
    test "POST /v1/connect/smart_account response schema carries the adapter-stub note field" do
      response_schema = BankWeb.OpenApi.Schemas.ConnectSmartAccountResponse.schema()
      assert :note in response_schema.required
      assert response_schema.properties.note.example =~ "stubbed"
    end

    test "account is documented as a loose non-empty string, NOT as EvmAddress" do
      # The controller only checks `account` is a non-empty string. The
      # browser hook forwards `accounts[0]` directly from the wallet,
      # which is typically an EIP-55 mixed-case EVM address — the
      # shared `EvmAddress` schema's lowercase-only pattern would
      # reject those requests.
      account = BankWeb.OpenApi.Schemas.ConnectSmartAccountRequest.schema().properties.account

      # Regression guard for the prior `$ref: EvmAddress` form: must
      # be a concrete Schema, not a Reference.
      assert match?(%OpenApiSpex.Schema{}, account),
             "account must be a concrete Schema, not a $ref to EvmAddress"

      assert account.type == :string
      assert account.minLength == 1

      # No pattern constraint — runtime accepts any non-empty string.
      assert is_nil(account.pattern),
             "account must not carry a format pattern — runtime accepts any non-empty string"

      # An EIP-55 mixed-case example is honest about what the wallet
      # sends today; a lowercase-only pattern would reject it.
      assert account.example =~ ~r/^0x[0-9A-Fa-f]+$/

      assert account.example != String.downcase(account.example),
             "account example should be mixed-case to match what the wallet hook forwards"
    end
  end

  describe "shared component reuse (#87)" do
    test "every write endpoint in #89 references IdempotencyKey" do
      writes = [
        {"/v1/counterparties", :post},
        {"/v1/counterparties/{id}", :patch},
        {"/v1/counterparties/{id}/addresses", :post},
        {"/v1/counterparties/{id}/evidence", :post},
        {"/v1/address_labels/{id}", :patch},
        {"/v1/trust_assertions", :post},
        {"/v1/policies", :post},
        {"/v1/policies/{id}/revise", :post},
        {"/v1/policies/{id}/archive", :post},
        {"/v1/security/pause", :post},
        {"/v1/security/resume", :post},
        {"/v1/security/revoke_delegation", :post},
        {"/v1/connect/smart_account", :post}
      ]

      for {path, method} <- writes do
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

  describe "top-level components added by #89" do
    test "every per-domain schema added in #89 is registered under its title" do
      expected = ~w(
        CounterpartySummary CounterpartyDetail
        CounterpartyListResponse CounterpartyResponse
        CreateCounterpartyRequest UpdateCounterpartyRequest
        AddressLabelEntity AddressLabelResponse
        AttachAddressRequest UpdateAddressLabelRequest
        EvidenceArtifactEntity EvidenceResponse AddEvidenceRequest
        TrustAssertionEntity
        IssueTrustAssertionRequest IssueTrustAssertionResponse
        PolicyRuleEntity PolicyListResponse PolicyResponse
        CreatePolicyRequest RevisePolicyRequest
        AuditEventEntity AuditListResponse
        SecurityPauseRequest SecurityResumeRequest SecurityStateResponse
        RevokeDelegationRequest RevokeDelegationResponse
        ConnectSmartAccountRequest ConnectSmartAccountResponse
      )

      schemas = spec().components.schemas

      for title <- expected do
        assert Map.has_key?(schemas, title), "schema #{inspect(title)} missing"
        assert schemas[title].title == title
      end
    end
  end

  describe "document serializability after #89" do
    test "the full spec still encodes to JSON cleanly" do
      json = spec() |> Jason.encode!()
      decoded = Jason.decode!(json)

      assert Map.has_key?(decoded["paths"], "/v1/counterparties")
      assert Map.has_key?(decoded["paths"], "/v1/security/revoke_delegation")
      # revoke is 202 (receipt), never 200.
      assert decoded["paths"]["/v1/security/revoke_delegation"]["post"]["responses"]["202"]
      refute decoded["paths"]["/v1/security/revoke_delegation"]["post"]["responses"]["200"]
    end
  end
end
