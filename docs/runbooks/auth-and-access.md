# Auth and access — operator runbook

This runbook is the operator-facing reference for the **private-alpha auth/workspace gate** (epic #153, issues #154–#162). It tells a fresh reviewer what is implemented today on `main`, how to bring up a local instance from an empty database to an approved workspace user, and what the gate refuses by design.

> **Audience.** Operators, alpha reviewers, and anyone wiring the auth path into a new environment.
>
> **Posture.** This is **invite-only private alpha**. There is no public sign-up. Google login is **identity only**; an admin must approve a pending user into a workspace before they can use the product. Chain actions are refused unless the workspace is approved and the chain capability is enabled. Mainnet stays disabled until a separate explicit issue flips the workspace flag.

## What this gate is and isn't

| Concern | Today on `main` |
|---|---|
| Identity | Google OAuth (real) or `Bank.Accounts.OAuthProvider.Stub` (dev/test). CSRF state verified either way. |
| First-login user state | `users.status = :pending_access`, no membership. Lands on `/pending`. |
| Allowlist | `access_invites` table — `:exact_email` or `:domain` rows scoped per workspace. Auto-applied on login by `Bank.Access.apply_invites_for_user/1`. |
| Admin approval | `Bank.Access.approve_pending_user/3` / `reject_pending_user/3`. Bootstrap admins gated by `BANK_ADMIN_EMAILS`. |
| Browser scope | `BankWeb.Plugs.FetchCurrentUser` resolves `current_scope = %{user, workspace, membership, role}` per request. No-membership / ambiguous → `/pending`. |
| `/v1` API scope | `BankWeb.Plugs.VerifyAPIKey` extracts `Authorization: Bearer cb_<body>`, populates the same `current_scope` shape with the API key's role. |
| Roles | Closed enum `[:viewer, :operator, :admin, :owner]` (authority order). Enforced via `BankWeb.Plugs.RequireRole`. |
| Pause | `agent_keys_paused_at` on `workspaces` rejects API keys with `:workspace_paused`. |
| Mainnet | `mainnet_enabled boolean default false null: false` on `workspaces`. `Bank.Chains.mainnet_allowed_for?/2` gates dispatch. |

What the gate is **not**:

- **Not a public signup surface.** The login button starts an OAuth flow that always lands at `/pending` for fresh users. Crossing into a workspace requires an existing invite OR explicit admin approval.
- **Not a substitute for transport security.** Phoenix does not terminate TLS; production deployments sit behind an operator-supplied TLS ingress (see [`docs/security.md`](../security.md)).
- **Not a paid onboarding flow.** No billing, no email delivery, no SSO beyond Google.
- **Not a cross-workspace data isolator at the query layer.** Today isolation is identity-level (the resolver picks a single workspace per request); query-layer enforcement is tracked in #158 and pinned by RBAC tests.

## Identity and access architecture

```
            Browser                              /v1 API client
               │                                       │
   Authorization: cookie                Authorization: Bearer cb_…
               ▼                                       ▼
  ┌──────────────────────────────┐       ┌──────────────────────────────┐
  │ AuthController + OAuth       │       │ VerifyAPIKey plug            │
  │ provider (Google or Stub)    │       │  + APIKeys.verify_key/1      │
  │  → users.status :pending /   │       │  rejects :workspace_paused / │
  │    :active / :disabled       │       │  :revoked / :expired         │
  └──────────────────────────────┘       └──────────────────────────────┘
               │                                       │
               ▼                                       ▼
       Bank.Access.apply_invites_for_user/1   (membership preloaded)
               │                                       │
               ▼                                       ▼
        Bank.Workspaces.resolve_scope/1         single workspace per
        → :single | :no_membership |             API key (XOR with user)
          {:ambiguous, [...]}
               │
               ▼
   conn.assigns.current_scope = %{user, workspace, membership, role}
               │
               ▼
       RequireRole plug (browser + /v1) → 403 if role insufficient
               │
               ▼
   Domain code (Decisions / Chain / Notifications) reads current_scope
   and refuses cross-workspace writes
```

## Local development setup

### 1. Pick an OAuth provider

The OAuth provider is selected by config — one of:

```elixir
# config/dev.exs (or config/test.exs)
config :bank, Bank.Accounts.OAuthProvider,
  provider: Bank.Accounts.OAuthProvider.Stub
```

The **Stub provider** ([`lib/bank/accounts/oauth_provider/stub.ex`](../../lib/bank/accounts/oauth_provider/stub.ex)) never calls Google. Tests inject canned identity claims via `Application.put_env/3`; the controller round-trips them as if Google had returned them. CSRF state is still verified — that is a real property the tests want to pin. Default outcome is `:ok` with a deterministic stub identity (`google-stub-1` / `alice@example.com`).

For real Google OAuth in `:dev`, set `provider: Bank.Accounts.OAuthProvider.Google` and provide the env vars below before booting.

### 2. Required env vars (real Google)

`config/runtime.exs` raises on boot in `:prod` if any of these are missing. In `:dev` they are still required if the Google provider is selected; the auth controller surfaces `Set GOOGLE_OAUTH_CLIENT_ID / SECRET / REDIRECT_URI and try again.` if a real call is attempted without them.

| Env var | Purpose | Rotation trigger |
|---|---|---|
| `GOOGLE_OAUTH_CLIENT_ID` | OAuth 2.0 web-application client id from Google Cloud Console. | When the project's client is rotated. |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Paired client secret. | On any staff change with access to the secret store. |
| `GOOGLE_OAUTH_REDIRECT_URI` | Must match the redirect URI registered in the Google Cloud Console. Defaults are not provided. | On hostname change. |
| `BANK_ADMIN_EMAILS` | Comma-separated allowlist of bootstrap-admin emails. Read by `Bank.Access.can_admin_access?/1` and surfaced as a `:require_admin` plug guard. **Different set from the workspace `:admin` role** — bootstrap admin gates the access-admin LiveViews, not the per-workspace admin operations. | On staff turnover. |

### 3. What must never be logged or committed

- Raw OAuth tokens, refresh tokens, access tokens, or `id_token` claims with PII.
- `GOOGLE_OAUTH_CLIENT_SECRET` in any form (no `.env` checked in, no `Logger.info` on config).
- `Authorization` headers, full API keys (`cb_<body>` strings), or any prefix long enough to brute-force.
- Email addresses in audit summaries beyond what the access-audit emit explicitly redacts.

The notification inbox layer enforces this at the row level (see [`docs/runbooks/notifications.md`](notifications.md) — the `Bank.Notifications.create/1` secret-marker gate), but the same posture applies to logs and metrics.

### 4. Boot

```sh
mix deps.get
mix ecto.create
mix ecto.migrate

# pick one (dev defaults to Stub provider unless you change config/dev.exs)
GOOGLE_OAUTH_CLIENT_ID=… GOOGLE_OAUTH_CLIENT_SECRET=… GOOGLE_OAUTH_REDIRECT_URI=http://localhost:4000/auth/google/callback \
BANK_ADMIN_EMAILS=you@example.com \
mix phx.server
```

A fresh DB has zero workspaces, zero users, zero memberships. Every `/dashboard` hit redirects to `/auth/google`. After login, the user is `:pending_access` until an admin approves them (operator runbook below).

## Operator runbook

### Add the first admin / bootstrap user

1. Set `BANK_ADMIN_EMAILS=you@example.com` before boot. This makes `Bank.Access.can_admin_access?(%User{email: "you@example.com"})` return `true` and unlocks the `/admin/access` LiveViews.
2. Sign in through `/auth/google`. The first login creates a `:pending_access` user with no membership. You'll land on `/pending`.
3. Hit `/admin/access` directly (the link is rendered in the layout once `BANK_ADMIN_EMAILS` matches your email). The pending list shows your own account classified as `:exact_match_pending` / `:domain_match` / `:allowlist_missed`.
4. Create the first workspace via the IEx console or a follow-up admin tool — `Bank.Workspaces.create_workspace(%{slug: "your-workspace", name: "Your Workspace", mainnet_enabled: false})`. **Mainnet stays off**; flipping the flag is a separate explicit issue (#178).
5. Approve yourself: `Bank.Access.approve_pending_user(admin_user, target_user, %{workspace_id: ws.id, role: :owner})`. The membership upsert runs through the same path the LiveView uses; `:owner` is the highest role.
6. Refresh `/dashboard`. `current_scope` now resolves a single workspace and the app loads.

> The bootstrap-admin allowlist (`BANK_ADMIN_EMAILS`) and the workspace `:admin` role are **different sets**. The first gates the access-admin LiveViews and the bootstrap path. The second gates per-workspace admin operations (membership management, API key issuance, etc.). A user can be one without the other.

### Invite a user

Add a row to `access_invites` scoped to the workspace:

```elixir
Bank.Access.create_invite(%{
  workspace_id: ws.id,
  type: :exact_email,           # or :domain
  email: "alice@example.com",   # for :exact_email
  domain: nil,                  # for :domain, set domain: "example.com" instead
  role: :operator,
  expires_at: ~U[2026-12-31 00:00:00Z]
})
```

Matching rules:

- **Exact-email** wins over **domain** for the same workspace.
- `:revoked`, `:expired`, and past-`expires_at` invites are ignored.
- `Bank.Access.apply_invites_for_user/1` runs on every login; a returning login does **not** double-create a membership (idempotent).
- A `:disabled` user is never admitted, regardless of invite.
- A user with no matching invite stays `:pending_access` until a bootstrap admin explicitly approves.

### Approve or reject a pending user

From the access-admin LiveView (`/admin/access`) or directly:

```elixir
# Approve into a workspace as :operator
Bank.Access.approve_pending_user(admin_user, target_user, %{
  workspace_id: ws.id,
  role: :operator
})
# Outcomes: {:ok, :membership_created} | {:ok, :already_member}
#         | {:ok, :membership_reactivated}

# Reject — flips the user to :disabled
Bank.Access.reject_pending_user(admin_user, target_user, %{reason: "not on team"})
# The user remains in the DB but `Bank.Accounts.session_allowed?/1` returns false,
# the next login is refused, and any active session expires on the next request.
```

`reject_pending_user/3` also emits a workspace-scoped `access.rejected` operator notification when an active invite matches the rejected user's email — the inbox row is the audit-visible artifact of the rejection (see [`docs/runbooks/notifications.md`](notifications.md)).

### Switch workspace

`Bank.Workspaces.resolve_scope/1` returns one of:

- `{:single, %Workspace{}}` — user has exactly one active membership; auto-selected.
- `:no_membership` — user has zero active memberships; controller redirects to `/pending`.
- `{:ambiguous, [%Workspace{}, ...]}` — user has multiple memberships. The browser session honors a user-selected workspace (cookie / session key); the workspace switcher UI sets it.

A user with two memberships sees the switcher; a user with one does not.

### Submit an intent as an approved operator

- Browser: `/queue` and the existing intent/approval LiveViews carry `current_scope` from `BankWeb.Plugs.FetchCurrentUser`. Decisions write `workspace_id = current_scope.workspace.id`.
- `/v1` API: include the workspace's API key as `Authorization: Bearer cb_<body>`. `BankWeb.Plugs.VerifyAPIKey` resolves `current_scope` from the key (the `:user` slot is `nil` on the API path; the workspace + role come from the `api_keys` row).

The `RequireRole` plug refuses with `403` (`/v1`) or a flash redirect (browser) when the resolved `role` is below the action's minimum.

### Confirm a pending user cannot access the app or chain actions

- Pending user hitting `/dashboard` is redirected to `/pending` — the `current_scope` carries `workspace: nil`, and the controller short-circuits.
- Pending user hitting `/v1/intents` with a stolen / unintended API key is refused at `BankWeb.Plugs.VerifyAPIKey` — the key is workspace-scoped, not user-scoped, so a pending user cannot mint or carry one.
- Chain dispatch refuses for any workspace where `mainnet_enabled: false` AND the request targets mainnet — `Bank.Chains.mainnet_allowed_for?/2` returns `false` and the dispatch path returns `{:error, :mainnet_not_enabled}` before it touches the adapter.
- A workspace with `agent_keys_paused_at` set rejects every API key tied to that workspace with `:workspace_paused`. The browser path keeps reading (the pause is dispatch-side), but every chain-action attempt is refused.

## Run the auth/access smoke

There is **no** dedicated `mix bank.access.smoke` Mix task today (call out as a follow-up if one is wanted). The pinning signal for the gate is the focused test set below; running them on a fresh checkout is the smoke recipe.

```sh
mix test \
  test/bank_web/controllers/auth_controller_test.exs \
  test/bank/access_test.exs \
  test/bank/access_admin_test.exs \
  test/bank/access_audit_test.exs \
  test/bank_web/live_auth_rbac_test.exs \
  test/bank_web/api_v1_auth_rbac_test.exs
```

Together these pin:

- Unauthenticated browser request → 302 to `/auth/google`.
- OAuth callback (Stub provider) creates a `:pending_access` user.
- Pending user lands on `/pending`; cannot reach `/dashboard`, `/queue`, `/admin/*`, or any action route.
- Bootstrap admin (`BANK_ADMIN_EMAILS`) can list / approve / reject pending users.
- Approve creates a membership; the next request resolves `current_scope` and the app loads.
- Reject flips the user to `:disabled`; the next session is refused.
- Workspace switcher works for a user with two memberships.
- Role-gating: `:viewer` cannot mutate, `:operator` cannot reach admin surfaces, `:admin` cannot reach owner-only operations.
- `/v1/intents` refuses missing / unauthorized workspace scope; succeeds for an approved operator workspace.
- Chain action is blocked for pending / unapproved / paused workspace.
- Audit emission: `auth.login`, `access.invite_applied`, `access.approved`, `access.rejected`, role transitions all land in the audit log with actor, subject, correlation id, and `workspace_id`.

For a manual browser pass on a fresh DB, follow the operator runbook above end-to-end: boot empty, sign in, land on `/pending`, approve via IEx, refresh, submit an intent, observe the access-audit rows in `/audit`.

## Verification (what `mix precommit` covers)

The shipped gate is pinned by:

- `test/bank_web/controllers/auth_controller_test.exs` — OAuth request + callback + logout + Stub-provider failure modes; CSRF state.
- `test/bank/access_test.exs` — invite matching (exact-email beats domain; revoked / expired / past-expiry ignored; idempotent re-login; cross-workspace isolation; `:disabled` always refused).
- `test/bank/access_admin_test.exs` — approve / reject / pending-list classification.
- `test/bank/access_audit_test.exs` — audit emission for every transition.
- `test/bank_web/live_auth_rbac_test.exs` — LiveView role gating (`/admin/*`, `/queue`, etc.).
- `test/bank_web/api_v1_auth_rbac_test.exs` — `/v1` API role gating + paused-workspace + missing-key.

Run them as part of the pre-merge gate:

```sh
mix precommit
```

A green `mix precommit` is the success signal for this runbook.

## Limitations and follow-ups

- **No dedicated `mix bank.access.smoke` task today.** The focused test set above is the smoke. A Mix task that drives a fresh DB through the full pending → approve → submit-intent flow without a live OAuth call would be a clean follow-up; it can lean on the Stub provider the way [`Bank.Notifications.Smoke`](../../lib/bank/notifications/smoke.ex) leans on its channel stub.
- **No real email invite delivery.** Invite rows are written by an admin; there is no outbound email today. Operators communicate the access path out-of-band.
- **No SSO beyond Google.** Other identity providers (Microsoft, Okta, custom SAML) are not implemented; the `Bank.Accounts.OAuthProvider` behaviour is the foundation that future providers attach to.
- **Cross-workspace isolation is identity-level only today.** Query-layer enforcement is tracked in #158; the RBAC tests cover the surfaces that matter for operator behaviour.
- **Mainnet is off.** Every workspace ships with `mainnet_enabled: false`. Flipping the flag is a separate explicit issue (#178); chain dispatch refuses mainnet routes until it lands.
- **Public signup is not on the roadmap for alpha.** Every door into the product is invite + admin approval.
