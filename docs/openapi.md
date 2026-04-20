# OpenAPI artifact

The `/v1` API is described in code via OpenApiSpex in
`BankWeb.ApiSpec` (foundation in epic #85, issues #86–#89). A
checked-in derived artifact lives at:

    priv/openapi/openapi.json

Everything downstream — SDK generators, Postman collections, CI
clients, ReDoc / Swagger UI renderers, doc tooling — should read
from this one file rather than scraping the controllers or
regenerating ad-hoc.

## Commands

- `mix openapi.gen` — regenerate `priv/openapi/openapi.json` from
  the current code-first spec. Run this after any change to
  `BankWeb.ApiSpec`, shared components under
  `lib/bank_web/open_api/`, or endpoint `operation/2` declarations.
  Commit the updated artifact alongside your spec change.
- `mix openapi.check` — fail if the checked-in artifact has drifted
  from the current spec. This task is part of the `mix precommit`
  alias, so CI (`.github/workflows/ci.yml`) and local precommit
  runs both catch drift automatically.

Both tasks are thin wrappers over `Bank.OpenApiArtifact`.

## Determinism

`mix openapi.gen` produces byte-identical output across runs, hosts,
and Elixir / OTP versions. It achieves this by round-tripping the
spec through Jason and sorting every map's keys alphabetically
before pretty-printing. The file is a normal unix text file with a
trailing newline; diffs should be clean and reviewable in PRs.

## Rules

- **Do not hand-edit** `priv/openapi/openapi.json`. The file is a
  pure derived output. Every consumer of it assumes so.
- **Never bypass drift.** If `mix openapi.check` fails, run
  `mix openapi.gen` and commit the regenerated file — do not mark
  the check itself as non-blocking.
- **The code-first spec is authoritative.** If the checked-in JSON
  and `BankWeb.ApiSpec` disagree, the code wins and the JSON is
  regenerated. The prose contract in
  `docs/bank-v0.1-runtime-flow-and-api.md` is the product-level
  source of truth the OpenAPI document implements against.

## Tooling hooks

Consumers of the artifact:

- **SDK generation.** Point `openapi-generator`, `openapi-typescript`,
  or similar at `priv/openapi/openapi.json`. No runtime spec-server
  round-trip is needed.
- **Postman.** Import `priv/openapi/openapi.json` directly; Postman
  reads OpenAPI 3.0 natively.
- **ReDoc / Swagger UI.** Both can render the artifact statically.
  Dev-only live inspection is still served at `GET /dev/openapi.json`
  via `OpenApiSpex.Plug.RenderSpec` when `dev_routes` is on (see
  `BankWeb.ApiSpec` moduledoc).
- **CI-time contract tests.** Downstream services that want to
  assert the shape of the `/v1` API in their own tests should pin
  against this file.

## Scope

This artifact covers **only** the external `/v1/...` surface. The
private `/internal/adapter/callback` contract, `/health` (non-v1
liveness), `/dev/*` routes, and the LiveView control tower are
intentionally excluded — `BankWeb.ApiSpec` post-filters
`OpenApiSpex.Paths.from_router/1` to `/v1/` prefixes, and the
generator inherits that scope.
