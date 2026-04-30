# `/v1` API Key Auth + RBAC — Operator Smoke Runbook

Operator-side smoke for the API key authentication and role gates
that landed in the #218 + #159 series. Walks an operator through
bootstrap → mint → exercise → revoke against a local `mix
phx.server`. Every step is reproducible against a fresh dev DB
and does NOT require chain, adapter, Base Sepolia, or any `.env`
secret beyond Postgres + Phoenix.

Pairs with:

- [`lib/bank_web/router.ex`](../../lib/bank_web/router.ex) — canonical role-tier matrix for `/v1`.
- [`lib/bank_web/plugs/verify_api_key.ex`](../../lib/bank_web/plugs/verify_api_key.ex) — Bearer parsing, 401 collapse, `last_used_at` touch.
- [`lib/bank_web/plugs/require_role.ex`](../../lib/bank_web/plugs/require_role.ex) — HTTP role gate.
- [`lib/bank/api_keys.ex`](../../lib/bank/api_keys.ex) — context (mint, revoke, verify, list).
- [`lib/bank/runtime/workers/aggregate_api_key_usage.ex`](../../lib/bank/runtime/workers/aggregate_api_key_usage.ex) — daily `api_key.used` aggregator.

Unrelated blocker (referenced once for orientation only):
[`docs/runbooks/workspace-backfill.md`](workspace-backfill.md) gates `#158e`,
which is independent of this smoke.

## Operator hygiene — read first

- **Never paste a real API key into an issue comment, Slack
  message, log message, or PR body.** The raw key is the
  credential; logs are not. The audit trail records the prefix
  (public, indexed) and never the secret.
- **The raw key is shown EXACTLY ONCE** — in the body of `POST
  /v1/api_keys`. If you lose it, mint a fresh key and revoke
  the lost one.
- All curl examples below use the placeholder
  `cb_<…redacted…>`. Substitute your real key at the terminal,
  never in committed text.
- The `Authorization` header value is sensitive. Don't `cat`
  shell history into a ticket without redacting; don't leave a
  `curl -v` transcript in a paste bin.

## Prereqs

- Phoenix running on `:4000`: `mix phx.server` from the repo
  root, with the dev DB migrated (`mix ecto.setup`).
- `curl` and `jq` available locally.
- A clean dev DB. Step 0 creates its own workspace and user from
  IEx — it does NOT depend on `mix bank.demo.seed` or any
  pre-existing operator. If you've already run a previous
  iteration of this runbook on the same DB, see "Recovery"
  below before starting Step 0 (the `slug` columns are unique
  and a re-run with the same slug values will fail).

## Step 0 — bootstrap a management API key

`/v1/api_keys` is admin-tier-gated. To mint the first key in a
workspace you need an existing admin key — chicken-and-egg.
For the local smoke, bootstrap from IEx:

```sh
iex -S mix phx.server
```

```elixir
{:ok, ws} = Bank.Workspaces.create_workspace(%{slug: "smoke", name: "Smoke"})

{:ok, alice} =
  Bank.Accounts.find_or_create_from_oauth(%{
    provider: :google,
    subject: "alice-smoke",
    email: "alice-smoke@example.com",
    name: "Alice Smoke"
  })

{:ok, _} =
  Bank.Workspaces.create_membership(%{
    user_id: alice.id, workspace_id: ws.id, role: :admin
  })

{:ok, key, raw_secret} =
  Bank.APIKeys.create_key(ws, alice, :admin, "smoke-bootstrap")

IO.puts("Bootstrap admin key: #{raw_secret}")
```

Copy the printed `cb_<…>` string into a shell variable. Use this
variable in every subsequent step. Do NOT echo it back to the
terminal; do NOT paste it into documentation.

```sh
export ADMIN_KEY="cb_<paste-raw-secret-here>"
```

In real environments the bootstrap step is a one-shot done by an
operator with database / IEx access; thereafter every key is
minted via `POST /v1/api_keys`.

## Step 1 — mint per-role keys via the API

```sh
curl -sS -X POST http://localhost:4000/v1/api_keys \
  -H "Authorization: Bearer $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{"role": "viewer", "name": "smoke-viewer"}' \
  | jq

curl -sS -X POST http://localhost:4000/v1/api_keys \
  -H "Authorization: Bearer $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{"role": "operator", "name": "smoke-operator"}' \
  | jq
```

Each response (HTTP `201`) carries the **raw key in the response
body** under `raw_key`. Persist it immediately; the server
will never return it again.

Capture the two raw keys into shell variables for the next steps:

```sh
export VIEWER_KEY="cb_<…>"
export OPERATOR_KEY="cb_<…>"
```

If you try to mint a stronger key than the caller's role, you get
`403 forbidden_role_above_creator`:

```sh
# Admin caller attempts to mint owner — must be refused.
curl -sS -o /dev/null -w "%{http_code}\n" -X POST http://localhost:4000/v1/api_keys \
  -H "Authorization: Bearer $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{"role": "owner", "name": "should-fail"}'
# → 403
```

## Step 2 — viewer endpoint succeeds (200)

Viewer-tier routes accept any valid key:

```sh
curl -sS -o /dev/null -w "%{http_code}\n" \
  http://localhost:4000/v1/policies \
  -H "Authorization: Bearer $VIEWER_KEY"
# → 200
```

Run with `OPERATOR_KEY` and `ADMIN_KEY` and confirm both also
return `200`. The role hierarchy `viewer < operator < admin <
owner` admits every higher tier to viewer routes.

## Step 3 — operator endpoint with viewer key → 403

Operator-tier routes refuse a viewer key with `403
insufficient_role`:

```sh
curl -sS -X GET http://localhost:4000/v1/audit \
  -H "Authorization: Bearer $VIEWER_KEY" \
  | jq
# → {"error": {"code": "insufficient_role"}, "required_role": "operator"}
```

Confirm the same call with `OPERATOR_KEY` returns `200`:

```sh
curl -sS -o /dev/null -w "%{http_code}\n" \
  http://localhost:4000/v1/audit \
  -H "Authorization: Bearer $OPERATOR_KEY"
# → 200
```

## Step 4 — admin-tier endpoint with operator key → 403

```sh
curl -sS -X POST http://localhost:4000/v1/security/pause \
  -H "Authorization: Bearer $OPERATOR_KEY" \
  -H "Content-Type: application/json" \
  -d '{}' | jq
# → {"error": {"code": "insufficient_role"}, "required_role": "admin"}
```

`ADMIN_KEY` succeeds on the same call (`200`).

## Step 5 — missing / invalid auth → 401

```sh
# No Authorization header.
curl -sS -X GET http://localhost:4000/v1/policies | jq
# → {"error": {"code": "missing_authorization"}}

# Wrong scheme.
curl -sS -X GET http://localhost:4000/v1/policies \
  -H "Authorization: Basic abc123" | jq
# → {"error": {"code": "invalid_authorization_scheme"}}

# Right scheme, malformed bearer.
curl -sS -X GET http://localhost:4000/v1/policies \
  -H "Authorization: Bearer not-a-cb-key" | jq
# → {"error": {"code": "invalid_credentials"}}

# Plausible shape but no matching prefix.
curl -sS -X GET http://localhost:4000/v1/policies \
  -H "Authorization: Bearer cb_aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee" | jq
# → {"error": {"code": "invalid_credentials"}}
```

`invalid_credentials` is deliberately the **same error code**
for "no such prefix", "wrong secret", "revoked", and "expired".
The plug collapses internal reasons so a client cannot probe
for valid prefixes by status code.

## Step 6 — cross-workspace resource id → 404

Mint a counterparty in a second workspace, then try to fetch it
with the smoke workspace's key. Cross-workspace ids return `404
not_found` — not 403 — so the response cannot confirm a row
exists in a sibling tenant.

In IEx:

```elixir
{:ok, other_ws} = Bank.Workspaces.create_workspace(%{slug: "other", name: "Other"})

{:ok, bob} =
  Bank.Accounts.find_or_create_from_oauth(%{
    provider: :google,
    subject: "bob-smoke",
    email: "bob-smoke@example.com",
    name: "Bob"
  })

{:ok, _} =
  Bank.Workspaces.create_membership(%{
    user_id: bob.id, workspace_id: other_ws.id, role: :admin
  })

{:ok, foreign_cp} =
  Bank.Counterparties.create_counterparty(
    %{name: "Foreign Corp", created_by: "user"},
    workspace_id: other_ws.id
  )

IO.puts("Foreign counterparty id: #{foreign_cp.id}")
```

Then in the shell:

```sh
export FOREIGN_CP_ID="<paste-uuid>"

curl -sS -X PATCH http://localhost:4000/v1/counterparties/$FOREIGN_CP_ID \
  -H "Authorization: Bearer $OPERATOR_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name": "Hijacked"}' | jq
# → {"error": {"code": "not_found", "message": "no counterparty with id=<…>"}}
```

The row in the other workspace stays unchanged. Verify in IEx:

```elixir
%{name: "Foreign Corp"} = Bank.Repo.get!(Bank.Counterparties.Counterparty, foreign_cp.id)
```

## Step 7 — revoke + verify future requests → 401

```sh
# Pull the viewer key's id out of the list.
VIEWER_KEY_ID=$(curl -sS -X GET http://localhost:4000/v1/api_keys \
  -H "Authorization: Bearer $ADMIN_KEY" \
  | jq -r '.data[] | select(.name == "smoke-viewer") | .id')

# Revoke it.
curl -sS -X DELETE http://localhost:4000/v1/api_keys/$VIEWER_KEY_ID \
  -H "Authorization: Bearer $ADMIN_KEY" \
  | jq
# → {"data": {"id": "...", "revoked_at": "2026-..."}}

# Subsequent use of the revoked key fails.
curl -sS http://localhost:4000/v1/policies \
  -H "Authorization: Bearer $VIEWER_KEY" | jq
# → {"error": {"code": "invalid_credentials"}}
```

Re-revoking is idempotent (returns `200` and does not emit a
duplicate `api_key.revoked` audit event):

```sh
curl -sS -o /dev/null -w "%{http_code}\n" -X DELETE \
  http://localhost:4000/v1/api_keys/$VIEWER_KEY_ID \
  -H "Authorization: Bearer $ADMIN_KEY"
# → 200
```

## Step 8 — `last_used_at` advances on success

The plug bumps `last_used_at` on every successful auth, throttled
to at most once per active-key per hour. After Step 2's first
viewer call, the row should carry a fresh timestamp:

```elixir
# In IEx
key = Bank.Repo.get_by!(Bank.APIKeys.APIKey, name: "smoke-operator")
key.last_used_at
# → ~U[2026-04-30 …]   (post-curl timestamp)
```

A second curl within the throttle window is a no-op — the
column does not advance again until the throttle window passes.
This is the intended throttle behavior, not a bug.

Failed auths (revoked, malformed, etc.) do NOT update
`last_used_at` — verified by the Step 7 revoke flow.

## Step 9 — `api_key.used` daily aggregate audit

The runtime emits ONE `api_key.used` audit event per key per
24-hour window. The cron schedule fires daily at `00:30 UTC`
(`Bank.Runtime.Workers.AggregateAPIKeyUsage`). Per-request
emission is intentionally NOT supported — see the worker
moduledoc for the rationale.

For local smoke, fire the worker manually with a one-day window
that covers the smoke's traffic:

```elixir
# In IEx
window_start = ~U[2026-04-30 00:00:00.000000Z]
window_end   = ~U[2026-05-01 00:00:00.000000Z]

{:ok, _job} =
  Oban.insert(
    Bank.Runtime.Workers.AggregateAPIKeyUsage.new(%{
      "window_start" => DateTime.to_iso8601(window_start),
      "window_end"   => DateTime.to_iso8601(window_end)
    })
  )
```

Once the job runs, query the audit trail:

```sh
curl -sS "http://localhost:4000/v1/audit?event_type=api_key.used" \
  -H "Authorization: Bearer $ADMIN_KEY" | jq '.data[]'
```

Each event includes `id`, `prefix`, `role`, `window_start`,
`window_end`, and `last_used_at`. The audit shape NEVER includes
the raw key or the `secret_hash` — confirmed by hygiene tests in
[`test/bank/runtime/workers/aggregate_api_key_usage_test.exs`](../../test/bank/runtime/workers/aggregate_api_key_usage_test.exs).

Re-running the job for the same window is a no-op (Oban
`unique:` plus `Bank.APIKeys.used_event_exists?/2` guard). Bumping
the queue concurrency above 1 without first adding a SQL-level
unique constraint would silently regress that idempotency — see
the worker's moduledoc.

## What this smoke does NOT exercise

- **Chain / adapter / Base Sepolia / `.env` secrets.** None of
  the steps require the TypeScript adapter to be running, an
  on-chain RPC URL, an operator EOA, or any Bank chain
  credential. The smoke is Phoenix + Postgres only.
- **Workspace backfill (`#158e`).** The
  [`workspace-backfill`](workspace-backfill.md) runbook is a
  separate concern and is the prerequisite for `#158e`. None of
  the API auth contracts in this smoke depend on backfill being
  run.
- **Browser RBAC (`#159a`).** The browser path uses
  `BankWeb.LiveAuth.{:require_role, role}` against a session
  cookie, NOT a bearer token. This smoke covers the `/v1`
  surface only.
- **OpenAPI impact: none.** This runbook documents existing
  contract; no schema changes.

## Recovery

- **Re-running Step 0 on the same DB.** `workspaces.slug` is
  unique (`workspaces_lower_slug_idx`). Running Step 0 a second
  time with `slug: "smoke"` will fail at
  `Bank.Workspaces.create_workspace(...)` with a changeset
  error. Either:
    1. `mix ecto.reset` to start from a clean DB (smoke runs
       non-production data; this is the simplest path), or
    2. Substitute a unique suffix in the slug each run, e.g.
       `slug: "smoke-#{System.os_time()}"`. Same goes for the
       `slug: "other"` workspace in Step 6.
- **Bootstrap key lost.** Re-run Step 0 in IEx with a fresh
  key name. Manually revoke the lost key by id in IEx if you
  can identify it from the prefix + audit trail.
- **Workspace got polluted with smoke data.** Drop and recreate
  the dev DB: `mix ecto.reset`. The smoke is non-production;
  no recovery is needed beyond a fresh DB.
- **Curl exit code is non-zero on a 4xx.** That's expected;
  curl returns 0 unless the network errored. Inspect the body
  with `jq`.
