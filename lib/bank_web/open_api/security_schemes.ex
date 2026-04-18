defmodule BankWeb.OpenApi.SecuritySchemes do
  @moduledoc """
  Reusable OpenAPI security scheme components for the external
  `/v1` API (issue #87, epic #85).

  The `/v1` runtime **does not** enforce bearer or API-key auth
  today. The `/v1` contract doc states the target posture:
  session + operator scope for humans, API-key + agent scope for
  agents. This module declares those two schemes as contract
  building blocks so individual operations in later issues can
  attach them via `security:` without a second components-level
  change when the auth layer actually ships.

  ## Components exposed

    * `operator_bearer` — HTTP bearer. For operator (human) calls.
    * `agent_api_key` — API key in the `X-Agent-Key` request
      header. For agent calls.

  ## Truthfulness

  Both descriptions are explicit that the scheme is NOT currently
  enforced at runtime and that the document declares them as
  building blocks, not as a current enforcement contract.
  """

  alias OpenApiSpex.SecurityScheme

  @doc """
  Operator (human) bearer-auth placeholder. Target posture per
  the `/v1` contract is session + operator scope; this scheme
  stands in for the future enforcement and is not currently
  enforced at runtime.
  """
  @spec operator_bearer() :: SecurityScheme.t()
  def operator_bearer do
    %SecurityScheme{
      type: "http",
      scheme: "bearer",
      description:
        "Placeholder for future operator bearer auth. Not currently " <>
          "enforced on `/v1/` at runtime — today the API relies on the " <>
          "operator-console and network-boundary posture described in " <>
          "`docs/security.md`. Declared here so later issues can attach " <>
          "`security: [%{\"operator_bearer\" => []}]` to specific " <>
          "operations without a second components-level change when " <>
          "the auth layer ships."
    }
  end

  @doc """
  Agent API-key placeholder. Target posture per the `/v1`
  contract is API-key + agent scope; this scheme stands in for
  the future enforcement and is not currently enforced at
  runtime.
  """
  @spec agent_api_key() :: SecurityScheme.t()
  def agent_api_key do
    %SecurityScheme{
      type: "apiKey",
      in: "header",
      name: "X-Agent-Key",
      description:
        "Placeholder for future agent API-key auth on agent-facing " <>
          "endpoints (`POST /v1/intents`, `GET /v1/intents/{id}`, " <>
          "`POST /v1/intents/{id}/simulate`). Not currently enforced on " <>
          "`/v1/` at runtime — declared here so later issues can attach " <>
          "`security: [%{\"agent_api_key\" => []}]` to agent operations " <>
          "without a second components-level change when the auth layer " <>
          "ships."
    }
  end
end
