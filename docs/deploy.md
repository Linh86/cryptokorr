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

## Smart-account provisioning prerequisite

The adapter binds to an on-chain smart account (`SMART_ACCOUNT_ADDRESS`
in the adapter's env) and, once #58 ships, to a Permission Validator
module installed against that account
(`PERMISSION_VALIDATOR_ADDRESS`). Both must exist on the target chain
**before** any deploy can run end-to-end smokes.

Provisioning is a one-shot operator procedure, not part of the
release-time release flow. It is documented in
[`docs/provisioning-kernel-v3.md`](provisioning-kernel-v3.md), with
operator templates under
[`chain_adapter/scripts/`](../chain_adapter/scripts/).
That runbook is the source of truth; this section is just a deploy-
time pointer at it. For a tight time-ordered checklist that sequences
the provisioning day against the no-secret preflights and the
smoke-test runbook, see
[`docs/base-sepolia-execution-day.md`](base-sepolia-execution-day.md).
Tracked in #84 (provisioning) and #83 (validator ABI verification).

### Adapter env strictness by mode

The adapter has three operational modes for the revoke path. Which
mode a deploy lands in is a function of
`PERMISSION_VALIDATOR_ADDRESS` and the state of
`KERNEL_PERMISSION_VALIDATOR_PIN` in
`chain_adapter/src/chains/base/permission_validator.ts`:

| Mode                 | `PERMISSION_VALIDATOR_ADDRESS` | `KERNEL_PERMISSION_VALIDATOR_PIN` | What revoke does |
| -------------------- | ------------------------------ | --------------------------------- | ---------------- |
| `sentinel-era`       | unset                          | `null`                            | Sentinel UserOp: on-chain anchor, no cryptographic disable. Correct for v0.1. |
| `straddle`           | set (real address)             | `null`                            | Still sentinel. Runtime logs a warn-level line at revoke time; `check-env.sh` reports this as a WARN, not a failure. Expected during the rollout window between #84 and #83. |
| `kernel-provisioned` | set (real address)             | populated (`VerifiedPermissionValidator`) | Cryptographic ERC-7579 disable (once #58 lands). Startup bytecode tripwire enforces that `keccak256(eth_getCode(pin.address))` equals `pin.deployedBytecodeKeccak256`. |

For the deploy-time check, `sentinel-era` and `straddle` are both
acceptable. `BROKEN` (env set but placeholder or malformed) fails
deploy.

### Env vars the adapter reads

`chain_adapter/.env.example` is the authoritative template. Required
at startup regardless of mode:

- `ADAPTER_DISPATCH_SECRET`, `ADAPTER_CALLBACK_SECRET`
- `PHOENIX_BASE_URL`, `BASE_RPC_URL`, `BUNDLER_RPC_URL`
- `SMART_ACCOUNT_ADDRESS`, `DELEGATION_SIGNER_KEY`
- `USDC_CONTRACT_ADDRESS`

Required ONLY once #58 has shipped against a Kernel-provisioned
smart account:

- `PERMISSION_VALIDATOR_ADDRESS` — must be the address `#83` pinned a
  verified ABI fragment against. Leaving it unset on a sentinel-era
  host is correct and will NOT fail startup. Setting it without a
  matching pin is a warn-only straddle — see `check-env.sh`.

### Deploy-time check

Run `chain_adapter/scripts/check-env.sh` on the adapter host after
setting secrets and before declaring the deploy healthy. The script
is no-secret and makes no network calls; it reports `mode:
sentinel-era`, `mode: straddle`, `mode: kernel-provisioned`, or
`mode: BROKEN`, and exits 1 only on the last. See
`chain_adapter/scripts/README.md` for the full output contract and
the list of checks it performs (placeholder detection, trailing-
whitespace detection, address shape, pin-state from the sibling
source file).

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

> **Note on the revoke smoke.** Until #58 ships, `bank.smoke.revoke`
> exercises the adapter's sentinel revoke path (real on-chain anchor,
> AA callback plumbing, `delegation_id` threaded through the dispatch
> payload per the contract in `priv/adapter/contract.md`). A
> successful smoke in `sentinel-era` or `straddle` mode means
> `state: revoked` has been reached via an on-chain anchor, trust has
> been downgraded, and the full callback chain is healthy — it does
> NOT imply the delegation is cryptographically unable to sign. The
> same caveat applies in `straddle` mode, because the runtime
> continues to use the sentinel body while `KERNEL_PERMISSION_VALIDATOR_PIN`
> is null. See
> [docs/smart-account-and-revoke-design.md](smart-account-and-revoke-design.md),
> the "What `state: revoked` means" callout in
> [docs/smoke-tests.md](smoke-tests.md), and the `mode:` line from
> `chain_adapter/scripts/check-env.sh` on the adapter host.

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
