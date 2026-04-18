# Deployment & release procedure

Operational runbook for deploying the Bank control plane to staging
and (once it exists) production. Pairs with
[docs/staging.md](staging.md) (topology), [docs/security.md](security.md)
(secrets), and [docs/smoke-tests.md](smoke-tests.md) (post-deploy gate).

## Build artifacts

Two flavors of the same artifact:

- **Local release**: `make release` → `_build/prod/rel/bank`.
- **Docker image**: `make image` or CI → `ghcr.io/<owner>/bank:<tag>`.

CI publishes an image on every pushed tag `v*`, plus a manual
`workflow_dispatch` with a custom tag (e.g. `staging`). See
[`.github/workflows/release.yml`](../.github/workflows/release.yml).

## Environment variable inventory

The single source of truth. If you add a new `System.get_env` call,
update this table and the `.env.staging.example` template.

| Var                    | Required | Where read                         | Purpose                                               |
| ---------------------- | -------- | ---------------------------------- | ----------------------------------------------------- |
| `DATABASE_URL`         | prod     | `config/runtime.exs`               | Postgres DSN for `Bank.Repo`.                         |
| `SECRET_KEY_BASE`      | prod     | `config/runtime.exs`               | Phoenix session signing key.                          |
| `PHX_HOST`             | prod     | `config/runtime.exs`               | External hostname for URL generation.                 |
| `PHX_SERVER`           | release  | `config/runtime.exs`, `bin/server` | `true` starts the HTTP listener.                      |
| `PORT`                 | no       | `config/runtime.exs`               | HTTP listen port. Default 4000.                       |
| `ADAPTER_BASE_URL`         | prod     | `config/runtime.exs`               | URL where Phoenix dispatches to the adapter. Boot fails if missing in `:prod`. |
| `ADAPTER_DISPATCH_SECRET`  | prod     | `config/runtime.exs`               | Bearer Phoenix sends on outbound `/dispatch/*`. Boot fails if missing in `:prod`. |
| `ADAPTER_CALLBACK_SECRET`  | prod     | `config/runtime.exs`               | Bearer the adapter sends on inbound `/internal/adapter/callback`. Boot fails if missing in `:prod`. |
| `POOL_SIZE`            | no       | `config/runtime.exs`               | Ecto pool size. Default 10.                           |
| `ECTO_IPV6`            | no       | `config/runtime.exs`               | `true`/`1` to bind Ecto sockets over IPv6.            |
| `DNS_CLUSTER_QUERY`    | no       | `config/runtime.exs`               | DNS query for node clustering via `dns_cluster`.      |

## Secrets handling

- Secrets live in the cloud provider's secret manager (AWS Secrets
  Manager, Fly secrets, Render env groups). Never in repo, never in
  a `.env` committed anywhere.
- The repo ships `.env.staging.example` with placeholders — the real
  `.env.staging` is git-ignored.
- Rotation procedure for `ADAPTER_DISPATCH_SECRET` /
  `ADAPTER_CALLBACK_SECRET`: see
  [docs/security.md](security.md#shared-secret-management). Each
  rotates independently.
- `SECRET_KEY_BASE` rotation is disruptive (invalidates sessions). Roll
  it only when compromised; generate with `mix phx.gen.secret`.

## Release / update procedure

The happy path:

1. **Merge to main** with a green CI. `.github/workflows/ci.yml` runs
   `mix precommit` against a throwaway Postgres.
2. **Tag a release** locally: `git tag -s v0.1.<n> -m "<summary>" && git push --tags`.
   CI builds and pushes `ghcr.io/<owner>/bank:v0.1.<n>`.
3. **Roll staging forward.** On the staging host:
   ```sh
   docker pull ghcr.io/<owner>/bank:v0.1.<n>
   docker compose --env-file .env.staging up -d phoenix
   ```
   Compose replaces the `phoenix` container; `bin/migrate` runs on boot,
   then `bin/server` starts. If migrations fail the container exits
   non-zero and compose keeps the old one up (pinned image digest).
4. **Run the smoke checks** from the operator host:
   ```sh
   ADAPTER_BASE_URL=... ADAPTER_DISPATCH_SECRET=... ADAPTER_CALLBACK_SECRET=... \
   SMART_ACCOUNT_ID=... DELEGATION_ID=... TARGET_ADDRESS=... \
   mix bank.smoke.transfer

   ADAPTER_BASE_URL=... ADAPTER_DISPATCH_SECRET=... ADAPTER_CALLBACK_SECRET=... \
   SMART_ACCOUNT_ID=... mix bank.smoke.revoke
   ```
   Both must PASS (exit 0) before declaring the deploy healthy.
5. **Monitor for 10 minutes.** Watch logs, Oban retry counts, and the
   `/internal/adapter/callback` 4xx rate (see
   [docs/monitoring.md](monitoring.md) once #37 lands).

## Rollback

If the smoke checks fail or the deploy misbehaves:

1. **Re-tag the previous container.** On the staging host:
   ```sh
   docker tag ghcr.io/<owner>/bank:v0.1.<n-1> ghcr.io/<owner>/bank:staging
   docker compose --env-file .env.staging up -d phoenix
   ```
   Compose pulls the previous image and restarts `phoenix`.
2. **Decide about migrations.** If the failed deploy ran a migration,
   determine whether it can stay (forward-compatible) or must be
   rolled back:
   ```sh
   docker compose exec phoenix /app/bin/bank eval \
     'Bank.Release.rollback(Bank.Repo, <version>)'
   ```
   Prefer forward-only migrations whenever possible. Schema changes
   that would require a rollback should be gated behind a feature flag
   or split into additive steps.
3. **File an incident.** See [docs/incident-runbook.md](incident-runbook.md)
   once #38 lands.

## CI matrix

| Workflow          | Trigger                            | Steps                                      |
| ----------------- | ---------------------------------- | ------------------------------------------ |
| `ci.yml`          | push/PR on main                    | `mix deps.get`, `mix precommit`            |
| `release.yml`     | tag `v*`, or `workflow_dispatch`   | Docker build + push to GHCR                |

Both workflows are required checks before a merge can promote.

## Blocker note for issue #36

The repo-side automation is complete and mergeable:

- CI workflow running `mix precommit` with a Postgres service.
- Release workflow building and pushing a Docker image to GHCR on tag.
- `Makefile` with standard targets (`setup`, `test`, `precommit`, `run`,
  `release`, `image`, `staging-up/down/logs`, `migrate`, `seed`).
- `.env.staging.example` as the env template; `.gitignore` excludes
  `.env*` files except `*.example`.
- This doc consolidating the env var inventory, release procedure, and
  rollback procedure.

**What's blocked**: the cloud-side plumbing (secret manager wiring,
deploy hooks against a real host, feeding a staging URL into the CI
release workflow as a promote step) — all of which needs operator
credentials and a chosen provider. Tracked against the open items in
[docs/staging.md](staging.md) and picked up in #37 onwards.
