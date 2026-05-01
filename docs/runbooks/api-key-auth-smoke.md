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

## Step 10 — rotate + `api_key.rotated` audit

Mint a key earmarked for rotation, then exercise the atomic
rotate flow. The old `raw_key` MUST stop working at the moment
the rotate completes (no grace period in v0.1).

```sh
# Mint a fresh operator key.
ROTATE_RESPONSE=$(curl -sS -X POST http://localhost:4000/v1/api_keys \
  -H "Authorization: Bearer $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{"role": "operator", "name": "smoke-rotate"}')

OLD_ID=$(echo "$ROTATE_RESPONSE" | jq -r '.data.id')
OLD_KEY=$(echo "$ROTATE_RESPONSE" | jq -r '.raw_key')

# Rotate it. The response carries a fresh raw_key shown ONCE.
ROTATED=$(curl -sS -X POST http://localhost:4000/v1/api_keys/$OLD_ID/rotate \
  -H "Authorization: Bearer $ADMIN_KEY")

NEW_KEY=$(echo "$ROTATED" | jq -r '.raw_key')
echo "$ROTATED" | jq '.data | {id, prefix, role, name}'
# → { "id": "<new uuid>", "prefix": "<new prefix>", ... }

# Old key fails IMMEDIATELY.
curl -sS -o /dev/null -w "%{http_code}\n" \
  http://localhost:4000/v1/policies \
  -H "Authorization: Bearer $OLD_KEY"
# → 401

# New key works.
curl -sS -o /dev/null -w "%{http_code}\n" \
  http://localhost:4000/v1/policies \
  -H "Authorization: Bearer $NEW_KEY"
# → 200
```

Confirm the audit row:

```sh
curl -sS "http://localhost:4000/v1/audit?event_type=api_key.rotated" \
  -H "Authorization: Bearer $ADMIN_KEY" | jq '.data[0]'
```

The `before_ref` carries the old key's `id` / `prefix` /
`revoked_at`; the `after_ref` carries the new key's `id` /
`prefix` / `role` / `name`. The raw secret appears in NEITHER —
hygiene confirmed by tests in
[`test/bank/api_keys_test.exs`](../../test/bank/api_keys_test.exs)
under `describe "rotate_key/3 (#220)"`.

Trying to rotate a key that has already been revoked is a
deterministic 422 — verifies the race-safety contract:

```sh
# Re-rotating the OLD id (already revoked by the rotate above).
curl -sS -o /dev/null -w "%{http_code}\n" \
  -X POST http://localhost:4000/v1/api_keys/$OLD_ID/rotate \
  -H "Authorization: Bearer $ADMIN_KEY"
# → 422

# Body: {"error": {"code": "already_revoked"}}
```

An `:admin` caller cannot rotate an `:owner` key — the same
`forbidden_role_above_creator` gate that protects `create`
applies (mint an owner key in IEx first if you need to exercise
this in smoke; it's not part of the default flow).

## Step 11 — over-limit 429 + `api_key.rate_limited` audit

The plug refuses requests once a key exceeds its per-window
budget. Default is `60 requests / 60 seconds per key`. Lower
the threshold at runtime to exercise the trip without firing
60+ requests:

```elixir
# In IEx
Application.put_env(:bank, Bank.RateLimit,
  requests_per_window: 3,
  window_seconds: 60
)

# Reset any in-flight buckets so the new threshold applies cleanly.
Bank.RateLimit.reset()
```

Now fire four requests in rapid succession:

```sh
for i in 1 2 3 4; do
  curl -sS -o /dev/null -w "Request $i: %{http_code}\n" \
    http://localhost:4000/v1/policies \
    -H "Authorization: Bearer $NEW_KEY"
done
# Request 1: 200
# Request 2: 200
# Request 3: 200
# Request 4: 429
```

Inspect the `Retry-After` header on the 429:

```sh
curl -sS -i http://localhost:4000/v1/policies \
  -H "Authorization: Bearer $NEW_KEY" \
  | head -20
# HTTP/1.1 429 Too Many Requests
# retry-after: <seconds>
# content-type: application/json
# ...
# {"error":{"code":"rate_limited"}}
```

Confirm the audit row — exactly ONE row per (key, window),
even after a long burst of refused requests:

```sh
curl -sS "http://localhost:4000/v1/audit?event_type=api_key.rate_limited" \
  -H "Authorization: Bearer $ADMIN_KEY" | jq '.data[0]'
```

The `after_ref` carries `id` / `prefix` / `role` / `window_start`
/ `window_end` / `limit` / `retry_after_seconds`. NEVER the raw
key, `secret_hash`, or Authorization header — hygiene tests in
[`test/bank_web/plugs/rate_limit_test.exs`](../../test/bank_web/plugs/rate_limit_test.exs)
JSON-scan the audit row for those substrings on every run.

Restore the dev threshold before continuing:

```elixir
# In IEx
Application.put_env(:bank, Bank.RateLimit,
  requests_per_window: 60,
  window_seconds: 60
)

Bank.RateLimit.reset()
```

Auth failures and revoked keys still 401 — they never reach
the rate-limit plug, so a 429 cannot mask a 401. Step 12 covers
the auth-failure side.

## Step 12 — failed auth + `api_key.denied` audit

Every reject path of `BankWeb.Plugs.VerifyAPIKey` emits a
`api_key.denied` audit row, deduped per (prefix-or-id, reason,
minute) so a brute-force probe cannot flood storage. Each of
the five audit reasons is observable by sending a request that
trips the corresponding internal verify_key/1 path:

```sh
# 1. Missing header → reason="missing".
curl -sS -o /dev/null -w "%{http_code}\n" \
  http://localhost:4000/v1/policies
# → 401

# 2. Wrong scheme → reason="missing".
curl -sS -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Basic abc" \
  http://localhost:4000/v1/policies
# → 401

# 3. Garbage non-`cb_` token → reason="malformed".
curl -sS -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer not-a-cb-token" \
  http://localhost:4000/v1/policies
# → 401

# 4. Unknown prefix → reason="invalid_credentials".
curl -sS -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer cb_aaaaaaaabbbbbbbbccccccccddddddd" \
  http://localhost:4000/v1/policies
# → 401

# 5. Revoked key (re-using the viewer key revoked in Step 7) →
#    reason="revoked".
curl -sS -o /dev/null -w "%{http_code}\n" \
  -H "Authorization: Bearer $VIEWER_KEY" \
  http://localhost:4000/v1/policies
# → 401
```

For `expired`, mint a key with `expires_at` set to the past via
the API, then attempt to use it:

```sh
PAST_TTL_KEY=$(curl -sS -X POST http://localhost:4000/v1/api_keys \
  -H "Authorization: Bearer $ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{"role": "viewer", "name": "smoke-expired", "expires_at": "2000-01-01T00:00:00Z"}')
```

> The controller now refuses past-expires_at on create with a 422
> (`invalid_expires_at`). To exercise the `expired` reject in
> smoke, set `expires_at` to a few seconds in the future, wait,
> then send a request — or stamp the column to a past time
> directly via `Bank.Repo.update_all` in IEx.

Inspect the audit rows:

```sh
curl -sS "http://localhost:4000/v1/audit?event_type=api_key.denied" \
  -H "Authorization: Bearer $ADMIN_KEY" | jq '.data[] | {reason: .after_ref.reason, prefix: .after_ref.prefix, subject_id, workspace_id}'
```

Each row's `after_ref` allowlists `reason` / `prefix` /
`api_key_id` only. NEVER raw bearer tokens, `secret_hash`, or
Authorization header bytes — hygiene tests in
[`test/bank_web/plugs/verify_api_key_test.exs`](../../test/bank_web/plugs/verify_api_key_test.exs)
under `describe "api_key.denied audit event"` JSON-scan each
denial class.

Subject identity:

  * Known key (`hash_mismatch` / `revoked` / `expired`):
    `subject_id` = key UUID, `workspace_id` stamped.
  * Prefix parsed but no row (`invalid_credentials` via
    `:not_found`): `subject_id` = `"prefix:" <> prefix`,
    `workspace_id` = `null`.
  * No parseable prefix (`missing` / `malformed`):
    `subject_id` = `"anonymous"`, `workspace_id` = `null`.

Repeated rejects of the SAME (prefix-or-id, reason) within a
minute collapse to ONE audit row — verified by burst tests.
This is intentional: a misconfigured client retrying for an
hour produces 60 rows, not thousands.

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
