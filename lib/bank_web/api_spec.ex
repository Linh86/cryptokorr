defmodule BankWeb.ApiSpec do
  @moduledoc """
  Top-level OpenAPI 3.0 document for the external CryptoBank `/v1`
  API (epic #85, issue #86).

  This module is the **foundation**: it pins the title, version,
  servers, tags, and security-scheme placeholder, and plugs an empty
  `paths` skeleton that subsequent issues fill in endpoint-by-endpoint.

  ## Scope

    * Describes only the external `/v1/...` surface. The private
      `/internal/adapter/callback` contract, `/health`, `/dev/*`,
      and the LiveView control tower are intentionally excluded —
      `paths/0` post-filters `OpenApiSpex.Paths.from_router/1` to
      `/v1/` prefixes, so even if a future edit adds operation specs
      to a non-`/v1` controller it will not leak into the external
      document.

  ## Current auth truth

  `/v1/` endpoints are **not** currently bearer-protected at runtime;
  they rely on the operator-console / network-boundary posture
  documented in `docs/security.md`. A reusable placeholder security
  scheme (`operator_bearer`, HTTP bearer) is declared in
  `components.securitySchemes` so individual operations in later
  issues can opt into it explicitly when the auth layer actually
  ships — but no operation is marked as requiring it here, and the
  top-level `security` array is empty.

  ## Layout convention for later issues

    * Per-domain schema modules live under
      `lib/bank_web/open_api/schemas/<domain>.ex`
      (e.g. `BankWeb.OpenApi.Schemas.Intents`).
    * Shared error / envelope / header schemas live under
      `lib/bank_web/open_api/` and land with issue #87.
    * Tag name constants go in `BankWeb.OpenApi.Tags` when #87
      needs them. For #86 the ten domain tags are inline in
      `tags/0` below — the authoritative list matching the
      `/v1/...` router surface.
    * Controllers stay at `lib/bank_web/controllers/api/v1/*.ex`;
      they adopt `use OpenApiSpex.ControllerSpecs` and declare
      `operation :action, ...` alongside their actions. The
      controller tree does not move.

  ## Non-goals for #86

    * Endpoint-by-endpoint operation coverage — #88 and #89.
    * Shared response / error envelope schemas — #87.
    * Generated `openapi.json` artifact + drift checks — #90.
    * Any depiction of `/internal/adapter/callback`.

  ## Inspection

  When `dev_routes` is on (dev only), the live spec is served at
  `GET /dev/openapi.json` via `OpenApiSpex.Plug.RenderSpec`. There is
  no production-facing spec endpoint — the artifact path lands with
  issue #90.
  """

  alias OpenApiSpex.{
    Components,
    Info,
    OpenApi,
    Paths,
    SecurityScheme,
    Server,
    ServerVariable,
    Tag
  }

  @behaviour OpenApi

  @v1_prefix "/v1/"

  @domain_tags [
    {"Intents", "Agent intent lifecycle (submit, inspect, simulate, cancel, replay)."},
    {"Decisions", "Decision envelopes and operator-initiated execution."},
    {"Approvals", "Human approval queue for decisions flagged by policy."},
    {"Counterparties", "Known counterparties, their evidence, and address book entries."},
    {"AddressLabels", "Chain addresses attributed to counterparties."},
    {"TrustAssertions", "Operator-issued trust statements that feed the trust engine."},
    {"Policies", "Policy catalog, revisions, and archival."},
    {"Audit", "Append-only runtime audit event stream."},
    {"Security", "Runtime pause, resume, and delegation revoke."},
    {"Connect", "Browser-wallet / smart-account connection scaffolding."}
  ]

  @impl OpenApi
  def spec do
    %OpenApi{
      info: info(),
      servers: servers(),
      tags: tags(),
      paths: paths(),
      components: components(),
      security: []
    }
  end

  @doc "The ten external-domain tag names. Canonical, used by tests and later issues."
  @spec domain_tag_names() :: [String.t()]
  def domain_tag_names, do: Enum.map(@domain_tags, fn {name, _} -> name end)

  defp info do
    %Info{
      title: "CryptoBank /v1 API",
      version: app_version(),
      description: """
      External control-plane API for the CryptoBank non-custodial
      treasury runtime. Scoped to the public `/v1/...` surface; the
      private `/internal/adapter/callback` contract is intentionally
      out of scope. The authoritative prose contract for this API
      lives at `docs/bank-v0.1-runtime-flow-and-api.md`.
      """
    }
  end

  defp servers do
    # The server URL is the Phoenix endpoint root — NOT `/v1` — so
    # operation paths (which start with `/v1/...` per the router) do
    # not double-prefix as `/v1/v1/...` once #88/#89 attach them.
    [
      %Server{
        url: "{scheme}://{host}",
        description: "Phoenix endpoint; external API lives under `/v1/`.",
        variables: %{
          "scheme" => %ServerVariable{
            default: "http",
            enum: ["http", "https"],
            description: "Transport scheme (https in prod)."
          },
          "host" => %ServerVariable{
            default: "localhost:4000",
            description: "Host:port of the Phoenix endpoint."
          }
        }
      }
    ]
  end

  defp tags do
    for {name, description} <- @domain_tags do
      %Tag{name: name, description: description}
    end
  end

  # #86 ships with an empty `paths` skeleton. Later issues (#88, #89)
  # annotate each `/v1/*` controller with `use OpenApiSpex.ControllerSpecs`
  # and declare `operation/2` specs; `Paths.from_router/1` then picks
  # them up automatically. The post-filter below hard-enforces the
  # scope invariant regardless of what future edits do elsewhere.
  defp paths do
    BankWeb.Router
    |> Paths.from_router()
    |> Enum.filter(fn {path, _item} -> String.starts_with?(path, @v1_prefix) end)
    |> Map.new()
  end

  defp components do
    %Components{
      schemas: %{},
      securitySchemes: %{
        "operator_bearer" => %SecurityScheme{
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
      }
    }
  end

  defp app_version do
    case Application.spec(:bank, :vsn) do
      nil -> "0.0.0-unknown"
      vsn -> to_string(vsn)
    end
  end
end
