# Telegram operator-bot ops runbook

Rotation, allowlist changes, and failure playbooks for the operator
Telegram bot (epic #54). Pairs with [docs/monitoring.md](monitoring.md)
(what to watch) and [docs/incident-runbook.md](incident-runbook.md)
(broader Bank control-plane incidents).

The bot is a **convenience surface**, not a source of truth. Every
alert it emits also has a record in the audit trail / web control
tower. If the bot is wedged, operators can still approve, pause, or
revoke from the web console — nothing is gated on Telegram being up.

## Environment variables

Production reads Telegram configuration from four environment
variables (see [`config/runtime.exs`](../config/runtime.exs)). The
config loader is fail-closed: any missing required value with
`TELEGRAM_BOT_ENABLED=true` raises at boot.

| Variable                 | Required when enabled | Purpose                                                                 |
| ------------------------ | :-------------------: | ----------------------------------------------------------------------- |
| `TELEGRAM_BOT_ENABLED`   | always                | Literal string `"true"` turns the bot on. Anything else disables it.    |
| `TELEGRAM_BOT_TOKEN`     | yes                   | Bot token issued by BotFather. Used by `Bank.Telegram.Transport`.       |
| `TELEGRAM_WEBHOOK_SECRET`| yes                   | Shared secret Telegram echoes back in `X-Telegram-Bot-Api-Secret-Token`.|
| `TELEGRAM_OPERATORS`     | yes                   | Pipe-separated allowlist of `USER_ID:CHAT_ID:ROLE:AUDIT_ACTOR` records. |

`dev` and `test` use fixed values from their config files; the env
vars above are only consulted in `:prod`.

## Rotation: `TELEGRAM_BOT_TOKEN`

Rotate on staff change, on suspected leak, or at milestone end.

1. **Revoke the old token with BotFather.** In Telegram, open the chat
   with `@BotFather`, run `/revoke`, pick the bot. The old token stops
   working within seconds — plan the rest of the rotation for
   immediately after this step.
2. **Issue a new token.** Still in BotFather, `/token` → pick the bot
   → copy the new value. It is the only secret BotFather will hand out
   for that bot; there is no "show" command later.
3. **Update the env var in your secret store.** Replace
   `TELEGRAM_BOT_TOKEN` with the new value. Keep the old value in the
   rollback slot until the next step confirms success.
4. **Roll the Bank control-plane pods.** The token is read once at
   boot into `Bank.Telegram.Config`; a running node will keep trying
   the revoked token until it restarts.
5. **Re-register the webhook.** BotFather revocation drops any
   previously configured webhook. Run `setWebhook` with the current
   `TELEGRAM_WEBHOOK_SECRET` (do not rotate the webhook secret in the
   same change — one variable at a time):
   ```sh
   curl -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/setWebhook" \
        -d url="https://<host>/internal/telegram/webhook" \
        -d secret_token="$TELEGRAM_WEBHOOK_SECRET"
   ```
6. **Verify.** Have an allowlisted operator send `/status` in the
   operator chat. A reply within a few seconds confirms both outbound
   (token) and inbound (webhook) are healthy.

**Rollback.** If step 4 or 5 fails, put the previous token back in the
secret store and re-roll. The old token only works again if BotFather
has *not* been told to revoke it — if it has, the only path forward is
to finish the rotation with a working token.

## Rotation: `TELEGRAM_WEBHOOK_SECRET`

Rotate on suspected leak, on a control-plane host change, or on a
regular cadence. Unlike the bot token, this secret is something we
choose; BotFather is not involved.

1. **Generate a new secret.**
   ```sh
   openssl rand -hex 32
   ```
2. **Update `TELEGRAM_WEBHOOK_SECRET` in the secret store.** Keep the
   old value in the rollback slot.
3. **Roll the Bank control-plane pods.** The plug
   `BankWeb.Plugs.VerifyTelegramWebhook` reads the expected secret
   through `Bank.Telegram.Config.webhook_secret/0`, which re-reads env
   on every call — but the value in app env is only refreshed on
   restart, so a roll is still required.
4. **Re-register the webhook with the new secret.** Telegram will
   continue sending the **old** secret in the header until
   `setWebhook` is called again:
   ```sh
   curl -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/setWebhook" \
        -d url="https://<host>/internal/telegram/webhook" \
        -d secret_token="$TELEGRAM_WEBHOOK_SECRET"
   ```
   Between steps 3 and 4, inbound webhooks are rejected with
   `invalid_secret_token` — expect a short burst on the
   `[:bank, :telegram, :webhook_auth]` telemetry feed with
   `result: :invalid_secret_token`. This is load-bearing: the plug is
   fail-closed by design, so nothing in the runtime acts on an
   unverified payload during the gap.
5. **Verify.** Have an allowlisted operator tap any inline button
   (e.g. on a test `:pending_approval` alert) or send `/status`. A
   button callback going through confirms Telegram is sending the new
   secret and the plug accepts it.

**Rollback.** Put the previous secret back in env, re-roll pods, and
re-register the webhook with the old value. There is no BotFather
step; rollback is symmetric to rotation.

## Updating `TELEGRAM_OPERATORS`

The allowlist is a pipe-separated list of records, each record
colon-separated: `USER_ID:CHAT_ID:ROLE:AUDIT_ACTOR`. Roles are
`viewer`, `approver`, `security_operator`, `admin`. See
`Bank.Telegram.Config.parse_operators_env!/1` for the authoritative
parser and the per-field validation rules.

Example:

```
100200300:100200300:approver:ops-alice|100200301:-1001234567890:security_operator:ops-bob
```

### Adding an operator

1. Have the new operator message the bot once (any text). Ask them
   for the numeric `user_id` Telegram shows for their account (they
   can get it from `@userinfobot` or any similar helper) and the
   `chat_id` where alerts should land — either their own `user_id`
   for DMs, or a negative group-chat id if they want alerts in a
   shared operator channel.
2. Pick the narrowest role that lets them do their job:
   - `viewer` — can read `/status`, `/queue`. Cannot approve / reject,
     cannot pause / resume. Inline Approve / Reject buttons are
     **never** emitted to viewers (role boundary is enforced at
     alert emit time, not only on callback).
   - `approver` — everything a viewer can do, plus Approve / Reject
     on pending-approval alerts.
   - `security_operator` — approver plus pause / resume.
   - `admin` — everything.
3. Pick a stable `AUDIT_ACTOR` string. This is what shows up in the
   audit trail on every action the operator takes from Telegram.
   Match the convention already in use (`ops-<firstname>`).
4. Append the new record to `TELEGRAM_OPERATORS` in the secret
   store. Do not drop existing entries; the config loader accepts any
   order.
5. Roll the Bank control-plane pods. The allowlist is read once per
   `Bank.Telegram.Config.load/0` call, which means:
   - Alerts fan out to whatever operator set was in memory at the
     time `Alerts.dispatch/1` was called.
   - New operators start receiving alerts the moment pods finish
     rolling with the updated env.

### Removing an operator

1. Delete their record from `TELEGRAM_OPERATORS`.
2. Roll the pods. They stop receiving alerts immediately after the
   roll lands; any inline-button callbacks they still have in their
   chat history will fail verification because the `Bank.Telegram.Config`
   allowlist no longer contains their `user_id`.
3. There is no BotFather step. The bot has no concept of who its
   "subscribers" are — delivery is entirely driven by our allowlist.

### Changing a role

Replace the existing record in place with the new role. Roles do not
compose — the right-most value for a given `user_id` wins. Roll the
pods to pick up the change.

## Telemetry event reference

The bot emits three telemetry event families, all pinned in
`Bank.Telegram.Telemetry.events/0`:

| Event                              | Fires when                                                                 | Key metadata                                          |
| ---------------------------------- | -------------------------------------------------------------------------- | ----------------------------------------------------- |
| `[:bank, :telegram, :transport]`   | Every outbound Bot API call from `Bank.Telegram.Transport`.                | `method`, `result`, `retriable` (`true \| false \| :unknown`) |
| `[:bank, :telegram, :alert]`       | Every `Bank.Telegram.Alerts.dispatch/1` outcome.                           | `alert_type`, `result`, `targeted`, `failed`          |
| `[:bank, :telegram, :webhook_auth]`| Every `BankWeb.Plugs.VerifyTelegramWebhook` decision (accept or reject).   | `result`                                              |

Dashboards should split reject-class on `webhook_auth` (misconfigured
client vs brute-force) and split `retriable` on `transport` (transient
network vs hard 4xx contract mismatch).

## Retry classification

`Bank.Telegram.Transport.retriable?/1` is the authoritative truth
table; dashboards, tests, and any future retry policy consult it.
Summary:

| Error reason                             | Retriable? | Why                                                 |
| ---------------------------------------- | ---------- | --------------------------------------------------- |
| `:telegram_unavailable`                  | `true`     | Network / DNS / timeout. Retry with backoff.        |
| `{:telegram_rejected, 429, _}`           | `true`     | Flood control. Back off for Telegram's `retry_after`. |
| `{:telegram_rejected, status, _}` (5xx)  | `true`     | Telegram-side transient fault.                      |
| `{:telegram_rejected, status, _}` (other 4xx) | `false` | Request itself is wrong (bad chat id, malformed).   |
| `:invalid_response`                      | `false`    | 2xx with an unexpected body shape. Contract bug.    |
| `:bot_disabled`                          | `false`    | Config says the bot is off. Operator must toggle.   |
| `:bot_not_configured`                    | `false`    | Enabled but no token. Operator must fix env.        |
| `:invalid_config`                        | `false`    | Config shape broken. Operator must fix env.         |
| anything else                            | `:unknown` | Unrecognised. Log loudly, fail closed.              |

The transport itself **never retries on its own**. Higher layers pick
a retry policy using this classification; today no caller retries,
and the alert fan-out accepts per-operator failures as non-fatal so
long as at least one recipient lands.

## Failure playbooks

### Webhook auth failures

**Signal.** `[:bank, :telegram, :webhook_auth]` emits one of:

- `:missing_secret_token` — no `X-Telegram-Bot-Api-Secret-Token`
  header at all. Either something other than Telegram is POSTing to
  `/internal/telegram/webhook`, or the webhook was registered without
  a `secret_token`.
- `:invalid_secret_token` — header present but does not match. Either
  `TELEGRAM_WEBHOOK_SECRET` was rotated without re-registering the
  webhook, or someone is probing the endpoint.
- `:bot_disabled` — `TELEGRAM_BOT_ENABLED` is not `"true"` in env, but
  Telegram is still pointing at the webhook. Loud signal: change
  config or call `deleteWebhook`.
- `:server_misconfigured` — either `TELEGRAM_WEBHOOK_SECRET` is empty
  while the bot is enabled, or the `Bank.Telegram.Config` shape is
  broken. This should never occur in `:prod` because `runtime.exs`
  raises at boot — if it does, something other than `runtime.exs` is
  populating the key.

**Action.**

1. Check the current bot state: `TELEGRAM_BOT_ENABLED` and whether
   `setWebhook` currently points at this host.
2. If `:invalid_secret_token` persists beyond the expected gap during
   a webhook-secret rotation, re-run `setWebhook` with the value in
   env. The plug is fail-closed; the runtime is unaffected.
3. If `:bot_disabled` is seen in prod, either flip
   `TELEGRAM_BOT_ENABLED=true` (intended) or call `deleteWebhook`
   (intended-off) — whichever matches the decision that turned the
   bot off.
4. A low-rate background of `:missing_secret_token` /
   `:invalid_secret_token` from unknown peers is normal on a
   public-internet-reachable host and does not require action; alert
   only on sustained bursts.

### Telegram transport outages

**Signal.** `[:bank, :telegram, :transport]` with
`result: :telegram_unavailable` and `retriable: true` for more than a
couple of minutes. Typically coincides with a regional network blip
or a Telegram Bot API incident.

**Behaviour.**

- `Bank.Telegram.Transport` surfaces the error to its caller and does
  **not** retry. The Logger also emits a warning per failed call.
- `Bank.Telegram.Alerts.dispatch/1` fans out per-operator and treats
  individual failures as non-fatal; the whole dispatch returns
  `{:error, {:all_failed, _}}` only when **every** operator fails.
  Partial fan-out still returns `:ok`, and telemetry records the
  `failed` count on the alert event so dashboards can spot chronic
  partial failure without waiting for an all-fail.

**Action.**

1. Confirm the outage is Telegram-side, not a DNS or egress issue on
   your host. `curl -v https://api.telegram.org/` from a pod is the
   fastest check.
2. There is no operator action needed for a transient outage — the
   runtime keeps running; the web console remains the source of
   truth. Alerts that would have gone out during the window are still
   in the audit trail.
3. If the outage is long enough that operators are likely to miss an
   approval window, pause the runtime from the web console and work
   the approval queue there. See
   [docs/incident-runbook.md](incident-runbook.md#emergency-pause).

### Partial alert fan-out failure

**Signal.** `[:bank, :telegram, :alert]` with `result: :ok` but
`failed > 0` seen repeatedly for the same operator.

**Meaning.** The dispatch succeeded (at least one operator got the
alert), but one or more specific chats keep failing. Usually one of:

- The operator blocked the bot — Telegram returns 403 once the user
  taps "block". This shows up as a `{:telegram_rejected, 403, _}`
  transport event with `retriable: false`.
- The operator's `chat_id` is stale (they left a group chat, or the
  group was deleted). Usually 400 / 403, `retriable: false`.
- The operator sits behind a relay that is silently dropping outbound
  messages. This looks like `:telegram_unavailable` on that chat only.

**Action.**

1. Look at the preceding `[:bank, :telegram, :transport]` events for
   the specific `chat_id` to get the hard error class.
2. If the chat is permanently dead (403 / blocked / left), update
   `TELEGRAM_OPERATORS` (see above) and roll the pods.
3. Partial failure by itself does not degrade correctness — alerts
   still fan out to everyone else, and the audit trail records the
   underlying event regardless of Telegram.

### Alert `result: :all_failed`

Every operator failed on the same dispatch. Treat as a transport
outage (above) until proven otherwise. If it recurs and the transport
telemetry is clean for other traffic, check that
`TELEGRAM_OPERATORS` still contains at least one live chat — an
allowlist that was valid at boot can become effectively empty if the
only operator blocks the bot.

### Alert `result: :render_error`

One of `Bank.Telegram.Alerts.dispatch/1`'s required context fields
was missing. The caller passed an incomplete payload — a bug in the
emitting module, not an ops problem. File an issue; the audit trail
still captured the source event.

### Alert `result: :no_operators`

`TELEGRAM_OPERATORS` resolved to an empty list. Either the env var is
missing / empty, or the parser rejected every record. Re-run
`Bank.Telegram.Config.parse_operators_env!/1` in a console with the
current value to see which record is malformed; fix env and roll
pods.

## Common failure signals at a glance

| Signal                                                      | Likely cause                                        | Where to look next                                       |
| ----------------------------------------------------------- | --------------------------------------------------- | -------------------------------------------------------- |
| `webhook_auth.result = :invalid_secret_token` burst         | Webhook secret rotated without `setWebhook` rerun   | [Rotation: `TELEGRAM_WEBHOOK_SECRET`](#rotation-telegram_webhook_secret) |
| `webhook_auth.result = :bot_disabled` in prod               | `TELEGRAM_BOT_ENABLED != "true"` but webhook active | Flip env or `deleteWebhook`                              |
| `webhook_auth.result = :server_misconfigured`               | Env shape broken after boot                         | Compare env against `runtime.exs` expectations           |
| `transport.result = :telegram_unavailable`, sustained       | Telegram outage or egress issue                     | [Telegram transport outages](#telegram-transport-outages)|
| `transport.result = :telegram_rejected`, `retriable = false`| Bad request: blocked / stale chat / malformed       | Operator allowlist hygiene                               |
| `alert.result = :ok` with `failed > 0` on one chat          | That operator blocked or left                       | [Partial alert fan-out failure](#partial-alert-fan-out-failure) |
| `alert.result = :all_failed`                                | Transport outage, or whole allowlist is dead        | [Alert `result: :all_failed`](#alert-result-all_failed)  |
| `alert.result = :no_operators`                              | `TELEGRAM_OPERATORS` empty or all records malformed | [Alert `result: :no_operators`](#alert-result-no_operators) |
