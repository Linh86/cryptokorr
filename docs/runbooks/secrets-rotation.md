# Secrets Rotation Runbook

Operational procedure for rotating production secrets and managing them through
1Password CLI (`op`). Incident-driven version of this runbook is at the bottom
("Emergency: secret exposed").

**Status:** Authoritative for v0.1. Audit reference: finding **C1**.

---

## Scope

Secrets covered:

| Secret | Owner | Rotation cadence | Where it lands |
|---|---|---|---|
| `DELEGATION_SIGNER_KEY` | chain_adapter | On staff change, on suspected compromise, quarterly | adapter env |
| `OPERATOR_PRIVATE_KEY` | chain_adapter | On staff change, on suspected compromise, quarterly | adapter env |
| `ADAPTER_DISPATCH_SECRET` | both | Quarterly, or on Phoenix/adapter staff change | both Phoenix + adapter env |
| `ADAPTER_CALLBACK_SECRET` | both | Quarterly, or on Phoenix/adapter staff change | both Phoenix + adapter env |
| `SECRET_KEY_BASE` | Phoenix | On Phoenix host change, on suspected compromise | Phoenix env |
| `TELEGRAM_BOT_TOKEN` | Phoenix | On staff change, on bot leak | Phoenix env |
| `TELEGRAM_WEBHOOK_SECRET` | Phoenix | On staff change, after `setWebhook` | Phoenix env |
| `GOOGLE_OAUTH_CLIENT_SECRET` | Phoenix | On staff change | Phoenix env |
| `TENDERLY_API_KEY` | Phoenix | When Tenderly rotates | Phoenix env |
| `BUNDLER_URL` (with API key) | chain_adapter | When provider rotates | adapter env |

Out of scope: TLS certs (handled at ingress), database passwords (handled by
managed Postgres provider).

---

## Vault layout (1Password)

We use a single shared vault `cryptobank-prod` with one **Secure Note** or
**API Credential** item per secret. The convention below lets `op run` resolve
secret references (`op://vault/item/field`) directly into env vars without
embedding secrets in any file on disk.

```
1Password vault: cryptobank-prod
├── adapter/delegation-signer-key       (Secure Note)
│     fields: private_key, address, deployed_at, rotated_at
├── adapter/operator-private-key
│     fields: private_key, address, deployed_at, rotated_at
├── adapter/dispatch-secret
│     fields: token, generated_at
├── adapter/callback-secret
│     fields: token, generated_at
├── phoenix/secret-key-base
│     fields: token, generated_at
├── phoenix/telegram-bot-token
│     fields: token, bot_id, generated_at
├── phoenix/telegram-webhook-secret
│     fields: token, registered_at
├── phoenix/google-oauth                 (single item, two fields)
│     fields: client_id, client_secret
├── phoenix/tenderly-api-key
│     fields: api_key
└── adapter/bundler                      (single item, all bundler config)
      fields: url, api_key
```

**Naming convention:** `<service>/<purpose>` for the item title, kebab-case.
Each rotation **adds a new field `rotated_at: <ISO8601>`** rather than removing
the previous value — so we keep a rotation timeline within the item itself.
1Password's "version history" is the audit log.

Operators with access:

- `admin@` (full r/w) — does rotations
- `oncall@` (read-only) — can deploy and read for incident response

---

## Local dev setup

### One-time

1. Install 1Password CLI:
   ```sh
   brew install 1password-cli
   op signin
   ```

2. Verify access to the vault:
   ```sh
   op vault list
   op item list --vault cryptobank-prod
   ```

3. Replace literal values in `chain_adapter/.env` with `op://` references:
   ```
   # chain_adapter/.env (committed shape; literal values forbidden)
   DELEGATION_SIGNER_KEY=op://cryptobank-prod/adapter/delegation-signer-key/private_key
   OPERATOR_PRIVATE_KEY=op://cryptobank-prod/adapter/operator-private-key/private_key
   ADAPTER_DISPATCH_SECRET=op://cryptobank-prod/adapter/dispatch-secret/token
   ADAPTER_CALLBACK_SECRET=op://cryptobank-prod/adapter/callback-secret/token
   ```

   Phoenix `.env.staging` likewise gets `op://` refs.

4. **Delete** any local `.env` containing literal secrets after the rotation
   completes (see C1 closing step below).

### Per-shell

Run services through `op run`:

```sh
# Phoenix dev
op run --env-file=.env.dev -- mix phx.server

# Adapter dev
op run --env-file=chain_adapter/.env -- npm --prefix chain_adapter run dev

# One-off mix task
op run --env-file=.env.dev -- mix bank.demo.seed
```

**Why `op run` and not the SDK:** the operator decision (2026-05-07) is to keep
the Phoenix runtime SDK-free so application code stays ignorant of secret
storage. `op run` injects resolved env vars at process start; the app reads
plain env vars as before. Rotation is a redeploy, not a config push.

---

## Rotation procedures

Each procedure assumes you are the on-call admin with vault r/w. All steps log
to the runbook deployment ticket; copy the ticket number into each `rotated_at`
field.

### `ADAPTER_DISPATCH_SECRET` and `ADAPTER_CALLBACK_SECRET` (low risk)

These are bearer tokens between Phoenix and the adapter. No on-chain coupling.

```sh
# 1. Generate
NEW_DISPATCH=$(openssl rand -hex 32)
NEW_CALLBACK=$(openssl rand -hex 32)

# 2. Update vault (creates new version; previous value preserved in history)
op item edit "adapter/dispatch-secret" "token=$NEW_DISPATCH" "rotated_at=$(date -u +%FT%TZ)"
op item edit "adapter/callback-secret" "token=$NEW_CALLBACK" "rotated_at=$(date -u +%FT%TZ)"

# 3. Redeploy Phoenix and adapter together (atomic restart)
#    Both must come up with the new value before either accepts a request.
make staging-down
op run --env-file=.env.staging -- make staging-up

# 4. Verify
curl -fsS -H "Authorization: Bearer $NEW_DISPATCH" http://adapter:3000/healthz
curl -fsS http://phoenix:4000/v1/health/deep | jq '.adapter.status'
```

Rollback: redeploy with the previous version (1Password version history, `op
item get --include-version <n>`). Mismatch causes both directions to 401 — no
on-chain effect.

### `SECRET_KEY_BASE` (medium risk)

Phoenix cookie / session signing key. Rotation invalidates all active sessions.

```sh
NEW=$(mix phx.gen.secret)
op item edit "phoenix/secret-key-base" "token=$NEW" "rotated_at=$(date -u +%FT%TZ)"
# Redeploy Phoenix only.
# All operators get logged out and must re-auth via Google OAuth.
```

Rollback: redeploy previous version. Session cookies issued under the new key
become invalid; active operators reauth.

### `DELEGATION_SIGNER_KEY` (HIGH risk — on-chain rotation)

The delegation signer is the key whose signature the smart account's permission
validator authorizes. Rotating it requires an on-chain transaction.

> **Read first:** `docs/smart-account-and-revoke-design.md`,
> `docs/zerodev-permissions-integration.md`. The permission ID is computed from
> the signer address; new key = new permission ID = new install flow.

Procedure:

1. **Generate offline:**
   ```sh
   NEW_KEY=$(node -e 'console.log("0x" + require("crypto").randomBytes(32).toString("hex"))')
   NEW_ADDR=$(cd chain_adapter && node scripts/derive-address.ts "$NEW_KEY")
   echo "$NEW_KEY" > /tmp/new-delegation-key.txt   # tmpfs only — wiped on reboot
   chmod 600 /tmp/new-delegation-key.txt
   ```

2. **Pre-write to vault as a draft** (do not deploy yet):
   ```sh
   op item create --category="Secure Note" --vault=cryptobank-prod \
     --title="adapter/delegation-signer-key.draft" \
     "private_key=$NEW_KEY" "address=$NEW_ADDR" "drafted_at=$(date -u +%FT%TZ)"
   ```

3. **Pause the runtime** (workspace agent-key pause is sufficient; full pause
   if you want belt+braces):
   ```sh
   curl -fsS -X POST -H "Authorization: Bearer $ADMIN_KEY" \
     https://prod.bank/v1/security/pause_agent_keys
   ```

4. **Issue a fresh install attestation** for the new permission ID via the
   browser-signed install flow (see `docs/wallet-quickstart.md`). Operator
   browser signs the new envelope with the smart account's owner wallet.

5. **Wait for `verify_install_onchain`** to flip the new delegation to
   `:active`. Monitor:
   ```sh
   mix bank.delegations.show <smart_account_id>
   ```

6. **Revoke the old delegation** (synchronous DB write + async on-chain):
   ```sh
   curl -fsS -X POST -H "Authorization: Bearer $ADMIN_KEY" \
     -H "Content-Type: application/json" \
     -d '{"smart_account_id": "<id>"}' \
     https://prod.bank/v1/security/revoke_delegation
   ```

7. **Wait for revoke confirmation** (audit row `delegation.state_changed
   :revoked`).

8. **Promote the draft to canonical:**
   ```sh
   op item edit "adapter/delegation-signer-key" \
     "private_key=$NEW_KEY" "address=$NEW_ADDR" "rotated_at=$(date -u +%FT%TZ)"
   op item delete "adapter/delegation-signer-key.draft"
   ```

9. **Resume the runtime:**
   ```sh
   curl -fsS -X POST -H "Authorization: Bearer $ADMIN_KEY" \
     https://prod.bank/v1/security/resume_agent_keys
   ```

10. **Verify** with a small canary transfer (`docs/runbooks/base-mainnet-canary.md`).

11. **Wipe the tmp file** (and let `tmpfs` zero it on reboot):
    ```sh
    shred -u /tmp/new-delegation-key.txt
    ```

Rollback: if the new install fails verify or canary, the old delegation is
still `:active` (we revoke only after the new one is verified). Drop the draft,
keep the runtime paused, and triage.

### `OPERATOR_PRIVATE_KEY` (HIGH risk — on-chain rotation)

The operator key funds gas and (in some flows) signs as the smart account
owner. Rotation requires migrating any on-chain ownership.

1. Generate new key (same offline ceremony as above).
2. **Fund the new address** from a treasury wallet (cover at least one month
   of gas headroom).
3. **Transfer smart account ownership** if the operator key is the kernel
   owner (check `KernelVerifier` on the affected smart accounts):
   ```sh
   cd chain_adapter
   op run --env-file=.env -- npm run scripts:transfer-owner -- \
     --smart-account=<addr> --new-owner=$NEW_ADDR
   ```
4. Pause the runtime, swap vault item, redeploy adapter, resume.
5. Verify with a smoke transfer.
6. **Decommission old wallet:** sweep any residual balance to treasury, leave
   the address in vault history for audit traceability.

### `TELEGRAM_WEBHOOK_SECRET` (low risk)

Cross-reference: see `docs/runbooks/telegram-rotation.md` (issued under
audit finding **H10**).

Short version:
```sh
NEW=$(openssl rand -hex 32)
op item edit "phoenix/telegram-webhook-secret" "token=$NEW" "rotated_at=$(date -u +%FT%TZ)"
op run --env-file=.env.prod -- curl -fsS -X POST \
  "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
  -d "url=https://prod.bank/internal/telegram/webhook" \
  -d "secret_token=${NEW}"
# Redeploy Phoenix.
```

### Other secrets

`GOOGLE_OAUTH_CLIENT_SECRET`, `TENDERLY_API_KEY`, `BUNDLER_URL` — follow the
"low risk" pattern: regenerate at provider, edit vault item, redeploy.

---

## Pre-commit guard

A guard script lives at `scripts/secret-guard.sh` and rejects commits that
introduce literal `0x` + 64 hex private-key shapes anywhere outside known-safe
test fixtures.

Install:

```sh
make hooks-install
```

This symlinks `scripts/secret-guard.sh` into `.git/hooks/pre-commit`. The
script is idempotent — running `make hooks-install` again is a no-op.

What it blocks:

- `^[A-Z_]+KEY[A-Z_]*=0x[0-9a-fA-F]{64}` (env var assignments)
- Bare `0x` + 64 hex outside `test/`, `chain_adapter/test/`, `priv/repo/seeds.exs`,
  `*.example` files, and `*.lock` files.

What it does **not** block:

- Address-shaped values (`0x` + 40 hex) — those are public.
- Hashed values, signatures, calldata — those are public on-chain artifacts.
- Anything inside the known-safe paths above.

Bypass (only for known-safe additions like new test fixtures):

```sh
git commit --no-verify   # AUDITED; document in commit message why.
```

CI verification: a server-side check in CI scans the same patterns. This is a
defense in depth — the local hook catches the problem early; CI catches it if
the local hook was skipped or never installed.

---

## Emergency: secret exposed

You suspect or know a secret was exposed (force-pushed, screenshare, HN
comment, lost laptop, etc.).

**Time targets:** detect→pause < 5 min, full rotation < 60 min.

1. **Pause the runtime first** (don't wait for rotation):
   ```sh
   curl -fsS -X POST -H "Authorization: Bearer $ADMIN_KEY" \
     https://prod.bank/v1/security/pause
   ```

2. **Invalidate the exposed credential** at the issuing layer:
   - Bearer token (`*_DISPATCH_SECRET`, `*_CALLBACK_SECRET`,
     `TELEGRAM_WEBHOOK_SECRET`, `SECRET_KEY_BASE`): rotation procedure above —
     redeploy invalidates.
   - On-chain key (`DELEGATION_SIGNER_KEY`, `OPERATOR_PRIVATE_KEY`): immediate
     revoke + sweep funds. The HIGH-risk procedure above is the playbook,
     compressed to "do it now."
   - Provider keys (Tenderly, OAuth, bundler): revoke at provider console
     first; vault edit second.

3. **Audit log** the incident: a `security.paused` audit row is written when
   you hit pause. Add a `security.incident_declared` audit row via:
   ```sh
   mix bank.audit.write_incident --reason="<short reason>" --actor=oncall
   ```

4. **Forensic:** record what was exposed, when, where (channel), who saw,
   estimated blast radius. File in security incidents log
   (`docs/incident-runbook.md`).

5. **Resume only after** the secret is confirmed-rotated and a canary check
   passes.

---

## Operator checklist before commit

When working with secret-touching code:

- [ ] No literal `0x[0-9a-f]{64}` in any source file.
- [ ] No literal `dev-*-secret`-style strings outside test config.
- [ ] `chain_adapter/.env` and `.env.staging` contain only `op://` references
      or empty values (filled by `op run`).
- [ ] `make hooks-install` has been run on this clone.
- [ ] If adding a new secret env var: add an `*.example` line, add a vault
      item, document here.

---

## Cross-references

- `docs/security.md` — overall security posture.
- `docs/incident-runbook.md` — incident response process.
- `docs/runbooks/telegram-rotation.md` — Telegram-specific rotation (H10).
- `cryptobank-security-audit-2026-05-07.md` (outside repo) — audit report
  origin of finding C1.
- `docs/operator-secrets-checklist.md` — operator onboarding for secret access.
