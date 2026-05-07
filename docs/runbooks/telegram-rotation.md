# Telegram Bot Rotation Runbook

Operational procedure for rotating the operator Telegram bot's secrets and
detecting webhook tampering. Audit reference: finding **H10**.

**Cross-reference:** general secrets rotation lives in
[`secrets-rotation.md`](secrets-rotation.md). This runbook covers Telegram-only
nuance — particularly the `setWebhook` ceremony and the monitoring posture
needed because Telegram doesn't sign payloads.

---

## Why this is a special case

Unlike Stripe / GitHub / our own adapter, **Telegram does not cryptographically
sign webhook payloads**. The Bot API authenticates inbound updates by echoing
the value of `secret_token` (registered via `setWebhook`) back to us in the
`X-Telegram-Bot-Api-Secret-Token` header on every request.

Implication: `TELEGRAM_WEBHOOK_SECRET` is the only thing standing between the
public internet and our `/internal/telegram/webhook` handler. A leak gives the
attacker full bot control — they can post arbitrary updates that the bot
treats as authentic operator messages.

The plug at [`BankWeb.Plugs.VerifyTelegramWebhook`](../../lib/bank_web/plugs/verify_telegram_webhook.ex)
already does the right thing: constant-time compare via
`Plug.Crypto.secure_compare/2`, telemetry on every outcome
(`Bank.Telegram.Telemetry.webhook_auth/1`), structured rejection codes
(`missing_secret_token`, `invalid_secret_token`, `bot_disabled`,
`server_misconfigured`). The remaining work is **operational**: rotation
discipline + monitoring on the telemetry signals so a leak gets noticed.

---

## Vault layout (1Password)

```
1Password vault: cryptobank-prod
├── phoenix/telegram-bot-token
│     fields: token, bot_id, generated_at
├── phoenix/telegram-webhook-secret
│     fields: token, registered_at, rotated_at
└── phoenix/telegram-operators
      fields: list (pipe-separated USER_ID:CHAT_ID:ROLE:AUDIT_ACTOR)
```

`TELEGRAM_OPERATORS` is data, not a secret in the cryptographic sense, but we
keep it in 1Password so role/identity changes are audit-tracked.

---

## Routine rotation (quarterly + on staff change)

```sh
# 1. Generate a new webhook secret.
NEW=$(openssl rand -hex 32)

# 2. Update vault (1Password keeps version history → audit trail of past secrets).
op item edit "phoenix/telegram-webhook-secret" \
  "token=$NEW" \
  "rotated_at=$(date -u +%FT%TZ)"

# 3. Deploy Phoenix with the new value (so the plug expects $NEW going forward).
#    Until step 4 lands, Telegram still echoes the OLD secret → all webhooks
#    will 401 with `invalid_secret_token`. Plan the deploy so step 4 follows
#    immediately.
op run --env-file=.env.prod -- ./deploy.sh phoenix

# 4. Re-register the webhook with Telegram so it echoes $NEW.
op run --env-file=.env.prod -- bash -c '
  curl -fsS -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
    -d "url=https://prod.bank/internal/telegram/webhook" \
    -d "secret_token=${TELEGRAM_WEBHOOK_SECRET}" \
    -d "drop_pending_updates=true"
'

# 5. Verify Telegram has the new webhook registered:
op run --env-file=.env.prod -- bash -c '
  curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getWebhookInfo" |
    jq "{url, has_custom_certificate, pending_update_count, last_error_message, last_error_date, ip_address}"
'

# 6. Send a smoke message via the operator chat — bot should respond normally.
```

Total wall time: ~2 min. The 401 window between deploy and `setWebhook` is
brief; Telegram retries with exponential backoff so missed updates re-arrive
naturally.

**Rollback:** `op item get phoenix/telegram-webhook-secret --include-version
<n>` to fetch the previous value, redeploy, re-`setWebhook` with the old
value. Audit log will show one `webhook.rotated` row with the failed deploy
ticket.

---

## Bot token rotation (on suspected token leak)

The bot token is much more sensitive than the webhook secret — it's the
credential to send messages AS the bot, and is independent of the webhook
mechanism.

Procedure:

1. **Revoke at BotFather first:** `/revoke` against `@BotFather`. This
   invalidates the old token immediately at Telegram's side. **The bot stops
   working until step 2.**

2. **Issue new token:** BotFather replies with a fresh `<bot_id>:<token>`.

3. **Update vault:**
   ```sh
   op item edit "phoenix/telegram-bot-token" \
     "token=NEW_TOKEN" "rotated_at=$(date -u +%FT%TZ)"
   ```

4. **Redeploy Phoenix.**

5. **Re-register webhook** (the URL is tied to the bot, but the token in the
   URL changed):
   ```sh
   op run --env-file=.env.prod -- bash -c '
     curl -fsS -X POST \
       "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
       -d "url=https://prod.bank/internal/telegram/webhook" \
       -d "secret_token=${TELEGRAM_WEBHOOK_SECRET}"
   '
   ```

6. **Smoke test** with an operator chat.

The webhook secret does NOT need to rotate alongside the bot token (they are
independent). But if the leak is "I lost my laptop" rather than "the token
specifically", rotate both — see emergency procedure below.

---

## Operator allowlist updates (`TELEGRAM_OPERATORS`)

Adding or removing an operator is a config change, not a secret rotation. The
allowlist is parsed by `Bank.Telegram.Config.parse_operators_env!/1`.

```sh
# Pipe-separated records: USER_ID:CHAT_ID:ROLE:AUDIT_ACTOR
NEW='100200300:100200300:approver:ops-alice|100200301:-1001234567890:security_operator:ops-bob'

op item edit "phoenix/telegram-operators" "list=$NEW"
op run --env-file=.env.prod -- ./deploy.sh phoenix
```

Removed operators are immediately blocked; they cannot send authenticated
commands even if their Telegram identity is intact.

---

## Monitoring & alerting

The plug emits a telemetry event on every webhook attempt — auth outcome
included. Operators MUST wire alerts on the abnormal outcomes; they are the
canary for a leaked or attacked secret.

### Telemetry signal

`Bank.Telegram.Telemetry.webhook_auth/1` is called with one of:

| Outcome | What it means | Alert? |
|---|---|---|
| `:ok` | Valid secret, valid header | no — baseline volume |
| `:missing_secret_token` | Header absent | **yes** — port-scan / probe |
| `:invalid_secret_token` | Header present but mismatched | **yes** — leaked-secret canary |
| `:bot_disabled` | Bot was disabled but webhook still pointed here | **yes** — config drift |
| `:server_misconfigured` | Internal config error | **yes** — page oncall |

### Recommended alert thresholds

Add to your monitoring backend (whatever consumes the
`bank.telegram.webhook_auth` event — Datadog, Honeycomb, Grafana via
telemetry-metrics). Suggested rules:

```
# Anything unusual is an event worth a Slack ping.
alert: telegram_webhook_invalid_secret
expr: rate(bank_telegram_webhook_auth{outcome="invalid_secret_token"}[5m]) > 0
for: 1m
severity: high
runbook: docs/runbooks/telegram-rotation.md#emergency-leaked-secret

alert: telegram_webhook_missing_secret_burst
expr: rate(bank_telegram_webhook_auth{outcome="missing_secret_token"}[5m]) > 0.1
for: 5m
severity: medium
runbook: docs/runbooks/telegram-rotation.md#emergency-leaked-secret

alert: telegram_webhook_misconfigured
expr: bank_telegram_webhook_auth{outcome="server_misconfigured"} > 0
for: 0m
severity: page-oncall
runbook: docs/runbooks/telegram-rotation.md#config-drift
```

### Webhook integrity check (cron)

A cron job that calls `getWebhookInfo` every 5 minutes and compares the
returned URL + `pending_update_count` against expected values catches:

- **Webhook tampering at Telegram's side** — someone called `setWebhook` with a
  different URL.
- **Stale config** — Telegram thinks the webhook is gone (`last_error_message`).

Sketch:

```sh
EXPECTED_URL="https://prod.bank/internal/telegram/webhook"
INFO=$(op run --env-file=.env.prod -- bash -c '
  curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getWebhookInfo"
')

URL=$(echo "$INFO" | jq -r .result.url)
LAST_ERR=$(echo "$INFO" | jq -r '.result.last_error_message // ""')

if [ "$URL" != "$EXPECTED_URL" ]; then
  page_oncall "Telegram webhook URL drift: $URL"
fi

if [ -n "$LAST_ERR" ]; then
  warn_oncall "Telegram webhook error: $LAST_ERR"
fi
```

---

## Emergency: leaked secret

You see a burst of `invalid_secret_token` events, or you have a confirmed
leak (chat screenshot, repo push, etc.).

**Time targets:** detect → rotate < 5 min.

```sh
# 1. Rotate immediately. Don't wait for batching with other secrets.
NEW=$(openssl rand -hex 32)
op item edit "phoenix/telegram-webhook-secret" \
  "token=$NEW" "rotated_at=$(date -u +%FT%TZ)"

# 2. Deploy Phoenix.
op run --env-file=.env.prod -- ./deploy.sh phoenix

# 3. Re-register webhook with drop_pending_updates=true to discard any
#    in-flight messages the attacker may have queued.
op run --env-file=.env.prod -- bash -c '
  curl -fsS -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/setWebhook" \
    -d "url=https://prod.bank/internal/telegram/webhook" \
    -d "secret_token=${TELEGRAM_WEBHOOK_SECRET}" \
    -d "drop_pending_updates=true"
'

# 4. Audit-log the incident.
mix bank.audit.write_incident \
  --reason="telegram_secret_leak" \
  --actor=oncall

# 5. Forensic — what did the attacker post during the window? Check audit
#    rows since the suspected leak time, looking for `telegram.command` with
#    unusual user_ids (NOT in TELEGRAM_OPERATORS allowlist) or unexpected
#    times-of-day. Anything they tried to approve / reject?
mix bank.audit.list \
  --kind=telegram.command \
  --since="<suspected-leak-time>"
```

If audit shows the attacker **succeeded** in posting a command (e.g., they had
an allowed user_id too — chat session hijack), escalate to the
`telegram_session_hijack` playbook in `docs/incident-runbook.md`.

---

## Config drift

`server_misconfigured` outcomes mean the plug can't load `webhook_secret`
from `Bank.Telegram.Config`. Causes:

- env var missing on a freshly-deployed Phoenix host
- 1Password CLI session expired in the deploy environment
- vault item renamed without updating the env file

Recovery: re-run the deploy with `op run --env-file=.env.prod`. If the issue
persists, manually verify `op item get phoenix/telegram-webhook-secret`
returns the expected value with the deploy user's session.

---

## Operator checklist before merging Telegram-touching code

When changing the webhook plug, the bot logic, or the operator allowlist:

- [ ] No literal token/secret in the diff (run `make secret-guard` against
      staged changes).
- [ ] Telemetry signals still emitted (don't drop `Bank.Telegram.Telemetry`
      calls under any branch).
- [ ] Test cases cover all 5 outcome codes (the existing
      `test/bank_web/plugs/verify_telegram_webhook_test.exs` is the template).
- [ ] If allowlist parsing changes, add a unit test demonstrating malformed
      records get rejected at boot, not at runtime.

---

## Cross-references

- [`docs/runbooks/secrets-rotation.md`](secrets-rotation.md) — generic rotation runbook.
- [`docs/security.md`](../security.md) — overall security posture.
- [`docs/telegram-ops.md`](../telegram-ops.md) — operator-facing bot UX.
- [`docs/incident-runbook.md`](../incident-runbook.md) — incident response.
- `cryptobank-security-audit-2026-05-07.md` (outside repo) — origin of finding H10.
