# Staging environment

This document describes what the Bank staging environment looks like,
how to bring up a staging-like stack locally, and what still needs to
land in a cloud provider before real partner sessions can run against
it. The in-repo scaffolding (Dockerfile, docker-compose, release
helpers) is complete; the remaining work is credentials + infra
provisioning in whichever cloud we pick.

## Service topology

```
  ┌──────────────┐   HTTPS / mTLS   ┌──────────────┐
  │  operator    │ ───────────────▶ │  ingress      │
  │  browser     │                  │  (cloud LB)   │
  └──────────────┘                  └───────┬──────┘
                                             │
                              ┌──────────────┴──────────────┐
                              ▼                             ▼
                     ┌────────────────┐            ┌────────────────┐
                     │  Phoenix       │◀─ bearer ─▶│  Adapter       │
                     │  (bank.ex)     │  callback  │  (TS repo)     │
                     └──────┬─────────┘            └────────┬───────┘
                            │                               │
                            ▼                               ▼
                     ┌────────────────┐            ┌────────────────┐
                     │  Postgres      │            │  Bundler /     │
                     │  (managed)     │            │  Paymaster     │
                     └────────────────┘            └────────────────┘
```

Phoenix is the control plane. The adapter is a separate artifact
published out of its own repo and owns all chain-facing concerns
(bundler calls, signing, on-chain event tailing). Communication is
bidirectional:

- **Phoenix → adapter**: outbound dispatch (`POST /dispatch/transfer`,
  `/dispatch/revoke_delegation`). Authenticated with
  `ADAPTER_DISPATCH_SECRET`; enforced by the adapter's Fastify
  preHandler.
- **Adapter → Phoenix**: callbacks (`POST /internal/adapter/callback`).
  Authenticated with `ADAPTER_CALLBACK_SECRET`; enforced by
  [`BankWeb.Plugs.VerifyAdapterAuth`](../lib/bank_web/plugs/verify_adapter_auth.ex).

The two secrets gate the two directions independently. Transport
encryption (TLS / mTLS) is operator-supplied at the ingress. See
[docs/security.md](security.md) for the full auth model.

## Service inventory

| Service    | Image / source              | Port  | Notes                                      |
| ---------- | --------------------------- | ----- | ------------------------------------------ |
| `phoenix`  | this repo, `Dockerfile`     | 4000  | Phoenix 1.8 + Ecto + Oban + LiveView       |
| `db`       | `postgres:16`               | 5432  | Managed Postgres in cloud staging          |
| `adapter`  | TS adapter repo (separate)  | 3000  | Published under `ghcr.io/cryptobank/adapter` |
| `bundler`  | 3rd-party (Alchemy, Pimlico)| —     | Consumed by the adapter, not by Phoenix    |

## Environment variables

Required for Phoenix in staging/prod:

| Var                     | Purpose                                                    |
| ----------------------- | ---------------------------------------------------------- |
| `DATABASE_URL`          | Postgres DSN (`ecto://user:pass@host/db`)                  |
| `SECRET_KEY_BASE`       | Phoenix session signing key; `mix phx.gen.secret`          |
| `PHX_HOST`              | External hostname, used for URL generation                 |
| `PHX_SERVER`            | `true` to start the HTTP server on boot                    |
| `PORT`                  | HTTP listen port (default 4000)                            |
| `ADAPTER_BASE_URL`      | URL where Phoenix dispatches to the adapter (prod boot fails if unset) |
| `ADAPTER_DISPATCH_SECRET` | Bearer Phoenix sends on outbound `/dispatch/*`; must match the adapter's expected value (prod boot fails if unset) |
| `ADAPTER_CALLBACK_SECRET` | Bearer the adapter sends on inbound `/internal/adapter/callback`; must match the value the adapter is configured with (prod boot fails if unset) |
| `DNS_CLUSTER_QUERY`     | Optional `dns_cluster` query for clustering                |
| `POOL_SIZE`             | Ecto pool size (default 10)                                |
| `ECTO_IPV6`             | `true`/`1` to add `:inet6` to socket options               |

See [`.env.staging.example`](../.env.staging.example) for the local
stack; the cloud staging values live in the operator's secret store.

## Local staging-like stack

```sh
cp .env.staging.example .env.staging
# fill in SECRET_KEY_BASE (mix phx.gen.secret) + ADAPTER_DISPATCH_SECRET
# + ADAPTER_CALLBACK_SECRET (each `openssl rand -hex 32`)
docker compose --env-file .env.staging up --build
```

This brings up Postgres + Phoenix + an adapter stub. The adapter stub
is a placeholder image — the real adapter artifact is published from
the separate TypeScript repo. Override `ADAPTER_IMAGE` in
`.env.staging` once that repo publishes a tagged image.

Phoenix runs migrations on boot via `bin/migrate`, then starts the
server via `bin/server`. Control tower is reachable at
<http://localhost:4000>.

## Cloud staging (TODO — blocked on credentials)

The in-repo artifacts are ready. What's left is:

1. **Pick a cloud target.** Candidates: Fly.io (simplest, has managed
   Postgres), Render, or AWS (App Runner + RDS).
2. **Provision Postgres.** Minimum spec for alpha: 1 vCPU, 2 GB RAM,
   20 GB storage, backups enabled, restricted to the Phoenix service
   network.
3. **Provision Phoenix.** Deploy the image from this repo's Dockerfile.
   Two instances behind a load balancer for zero-downtime deploys.
4. **Provision the adapter.** Deploy from the TS adapter repo (see
   that repo's deploy doc). Must be reachable from Phoenix over an
   internal network and vice versa.
5. **Provision the on-chain smart account.** A Kernel v3 modular
   account on Base, with a Permission Validator module installed
   against it. This is a one-shot operator procedure — see
   [`docs/provisioning-kernel-v3.md`](provisioning-kernel-v3.md) for
   the runbook. The output addresses (`SMART_ACCOUNT_ADDRESS`,
   `PERMISSION_VALIDATOR_ADDRESS`) feed the adapter's env in step 6.
   Tracked in #84 (provisioning) and #83 (validator ABI verification);
   the cryptographic revoke that consumes the validator is #58. Until
   #58 ships, leaving `PERMISSION_VALIDATOR_ADDRESS` unset is
   intentional and selects the sentinel revoke path.
6. **Issue and distribute secrets.** `SECRET_KEY_BASE`,
   `ADAPTER_DISPATCH_SECRET`, `ADAPTER_CALLBACK_SECRET`, bundler API
   keys, paymaster API keys. See [docs/security.md](security.md) for
   the rotation policy.
7. **Terminate TLS at the ingress.** A standard TLS-terminating load
   balancer in front of each service is sufficient for v0.1; the
   bearer secrets are what authenticate each request. Operators who
   want client-side mTLS as well can wire `req_options.transport_opts`
   on the Phoenix side and a Fastify HTTPS listen on the adapter side
   — both are documented in `docs/security.md`.
8. **Point a DNS record** at the LB (e.g. `bank-staging.internal`).
9. **Smoke test end-to-end.** `mix bank.smoke.transfer` +
   `mix bank.smoke.revoke` from the operator host; see
   [docs/smoke-tests.md](smoke-tests.md). Run
   `cryptobank-ts-adapter/scripts/check-env.sh` on the adapter host
   first to confirm whether the deploy is in `SENTINEL-ERA` or
   `KERNEL-PROVISIONED` mode — the smoke result must be interpreted
   in light of that mode.

## Blocker note for issue #35

The code-side of staging is complete and mergeable:

- Multi-stage `Dockerfile` that builds a `mix release`.
- `rel/overlays/bin/server` + `rel/overlays/bin/migrate` entry points.
- `Bank.Release` module with `migrate/0` + `rollback/2`.
- `docker-compose.yml` + `.env.staging.example` for a local stack.
- This doc describing topology, env vars, and the provisioning checklist.

**What's blocked**: actual cloud provisioning — picking a provider,
paying for it, issuing the bundler + paymaster API keys. That work
belongs to an operator with credentials and is tracked as the
remaining open items in #35.
