defmodule BankWeb.OpenApi.SecuritySchemes do
  @moduledoc """
  Reusable OpenAPI security scheme components for the external
  `/v1` API (issue #87, epic #85; refreshed in #218b).

  As of #218b, every `/v1` route except the public health endpoints
  (`GET /v1/health`, `GET /v1/health/deep`) is gated behind
  `BankWeb.Plugs.VerifyAPIKey`. A subset of operator-mutating
  routes is additionally gated behind `BankWeb.Plugs.RequireRole,
  :operator` and refuses a `:viewer` key with `403
  insufficient_role`.

  ## Components exposed

    * `workspace_api_key` — HTTP bearer using the wire format
      `cb_<base32_body>` minted by
      `Bank.APIKeys.create_key/4`. The active enforcement scheme.
    * `operator_bearer` (deprecated alias) — kept for spec
      stability while existing tooling that referenced the
      historical `operator_bearer` name catches up. Identical
      semantics to `workspace_api_key`.
  """

  alias OpenApiSpex.SecurityScheme

  @doc """
  Bearer auth backed by a workspace-scoped, role-bound API key
  (#218b).

  Wire format: `Authorization: Bearer cb_<base32_body>`. The token
  is minted via `Bank.APIKeys.create_key/4`; the raw secret is
  shown ONCE on creation and only the SHA-256 hash is persisted.
  Revoked or expired keys produce `401 invalid_credentials`.
  """
  @spec workspace_api_key() :: SecurityScheme.t()
  def workspace_api_key do
    %SecurityScheme{
      type: "http",
      scheme: "bearer",
      bearerFormat: "cb_<base32>",
      description:
        "Workspace-scoped, role-bound API key (#218b). Bearer token of " <>
          "the form `cb_<base32_body>` minted by " <>
          "`Bank.APIKeys.create_key/4`. The token is shown ONCE on " <>
          "creation; only the SHA-256 hash is persisted. Revoked or " <>
          "expired keys are refused with `401 invalid_credentials`. " <>
          "Required on every `/v1` operation except the public " <>
          "health endpoints."
    }
  end

  @doc """
  Backwards-compat alias for `workspace_api_key/0`. Same scheme,
  retained so existing tooling that referenced
  `operator_bearer` does not break on the OpenAPI side.
  """
  @spec operator_bearer() :: SecurityScheme.t()
  def operator_bearer, do: workspace_api_key()

  @doc """
  Agent API-key placeholder. Reserved for a future scheme that
  carries an agent-scoped credential alongside the workspace key.
  Not currently enforced — `workspace_api_key` is the active
  scheme.
  """
  @spec agent_api_key() :: SecurityScheme.t()
  def agent_api_key do
    %SecurityScheme{
      type: "apiKey",
      in: "header",
      name: "X-Agent-Key",
      description:
        "Placeholder for a future agent-scoped credential. Not " <>
          "currently enforced — the active scheme is " <>
          "`workspace_api_key`."
    }
  end
end
