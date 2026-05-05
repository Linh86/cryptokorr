# Bank security posture (alpha)

This document captures the trust boundaries the alpha operates within
and the controls expected at each boundary. Issue #33 hardened the
Phoenix ↔ adapter surface, which is the highest-leverage boundary
today.

> **Mainnet readiness gate.** Before any first Base mainnet broadcast,
> review and sign [`docs/runbooks/base-mainnet-go-no-go.md`](runbooks/base-mainnet-go-no-go.md) —
> it grades the boundaries below against the rehearsal (#180) and
> the capped canary (#181) and produces an explicit GO / NO-GO
> verdict per scope. The verdict is binding only with all three
> signatures (operator, workspace admin, repo maintainer).

## Trust boundaries

```
   ┌──────────────────┐    private network    ┌──────────────────┐
   │ TypeScript       │   bearer (both ways)  │ Phoenix control  │
   │ chain adapter    │◀──────── + ──────────▶│ plane (Bank)     │
   │                  │   operator-supplied   │                  │
   │                  │   transport (TLS)     │                  │
   └──────────────────┘                       └──────────────────┘
         ▲                                           ▲
         │ RPC + bundler                             │ operator
         │                                           │ (HTTPS + SSO)
         ▼                                           ▼
    ┌──────────┐                               ┌──────────┐
    │ Chain /  │                               │ Operator │
    │ bundler  │                               │ console  │
    └──────────┘                               └──────────┘
```

Phoenix and the TypeScript adapter MUST NOT be exposed on the public
internet. They coexist on a private network (VPC, overlay, etc.) and
authenticate each request at the application layer with a bearer
secret. Transport encryption is **operator-supplied** — typically a
TLS-terminating ingress in front of each service — and is not
something either service ships out of the box.

## Phoenix ↔ adapter

Two distinct bearer secrets gate the two directions of the trust
boundary so each can be rotated independently and a leak in one
direction does not authenticate the other:

| Direction              | Env var (both services)     | Phoenix config key           |
| ---------------------- | --------------------------- | ---------------------------- |
| Phoenix → adapter      | `ADAPTER_DISPATCH_SECRET`   | `:dispatch_secret`           |
| adapter → Phoenix      | `ADAPTER_CALLBACK_SECRET`   | `:callback_secret`           |

Both secrets MUST be 256-bit opaque strings. Generate each with
`openssl rand -hex 32` and provision matching values on both sides.

### Inbound callbacks (adapter → Phoenix)

`POST /internal/adapter/callback`

1. **Transport** — Phoenix itself does not terminate TLS. In production
   it is expected to sit behind a TLS-terminating ingress (load
   balancer, sidecar proxy, mesh) that the operator configures; the
   bearer below is what is authoritative for the request, regardless
   of how the transport is terminated.
2. **Application auth** — `Authorization: Bearer <secret>` checked
   via `BankWeb.Plugs.VerifyAdapterAuth`, which uses
   `Plug.Crypto.secure_compare/2` to avoid timing leaks. The secret
   is read from `:bank, Bank.AdapterClient, :callback_secret` at
   request time.
3. **Contract validation** — `contract_version` must match the value
   Phoenix advertises; unknown kinds are rejected 422.
4. **Privacy** — callbacks MUST NOT carry PII; tx hashes and
   smart-account ids are acceptable.

### Outbound dispatch (Phoenix → adapter)

`Bank.AdapterClient.dispatch_transfer/1`, `dispatch_revoke_delegation/1`

1. **Transport** — `ADAPTER_BASE_URL` decides whether the connection
   runs over `http://` or `https://`. The dispatch client does not
   pin a transport on its own; it accepts an arbitrary `:req_options`
   keyword that the operator can use to configure server-cert pinning
   or client-side mTLS. The shape, when wired:

   ```elixir
   config :bank, Bank.AdapterClient,
     base_url: "https://adapter.internal:4100",
     dispatch_secret: System.fetch_env!("ADAPTER_DISPATCH_SECRET"),
     callback_secret: System.fetch_env!("ADAPTER_CALLBACK_SECRET"),
     req_options: [
       connect_options: [
         transport_opts: [
           cacertfile: "/etc/bank/adapter-ca.pem",
           # The next two are only needed for client-side mTLS:
           certfile: "/etc/bank/phoenix-client.pem",
           keyfile: "/etc/bank/phoenix-client.key",
           verify: :verify_peer,
           server_name_indication: ~c"adapter.internal"
         ]
       ]
     ]
   ```

   Phoenix does not ship a default mTLS configuration — most
   deployments will use a TLS-terminating ingress on the adapter side
   and rely on the bearer + private-network controls. The hook above
   exists so that operators who do want mTLS can opt in without
   patching the client.

2. **Application auth** — Phoenix sets `Authorization: Bearer <secret>`
   (the dispatch secret) on every request. The TS adapter validates
   this header on every `/dispatch/*` route via a Fastify preHandler
   that uses constant-time comparison. Missing, malformed, or wrong
   bearer → `401 unauthorized`. The `/health` endpoint stays public
   so liveness probes do not need credentials.
3. **Timeouts** — 5s receive timeout by default. Retries are owned
   by the caller's Oban worker, not `Req`.

### Shared secret management

- Each secret is a 256-bit opaque string, base64 or hex-encoded,
  generated with a CSPRNG. Example: `openssl rand -hex 32`.
- Rotated at the end of each alpha milestone and any time staff with
  access rotates off the team. The two secrets can be rotated
  independently.
- Procedure: provision the new secret to both services, then fail
  over. Because both the plug and the adapter preHandler resolve the
  expected secret at request time, a staged rollout that deploys one
  side first with the new secret will reject the other until both
  match. Plan the rollout accordingly (rotate the receiving side
  first, then the sender — for the dispatch secret that is adapter
  before Phoenix; for the callback secret it is Phoenix before
  adapter).

### Required adapter configuration in production

Phoenix `config/runtime.exs` raises on boot in `:prod` if any of
`ADAPTER_BASE_URL`, `ADAPTER_DISPATCH_SECRET`, or
`ADAPTER_CALLBACK_SECRET` is missing. There is no compile-time
fallback for these values — `config/config.exs` does not set defaults
for `:bank, Bank.AdapterClient`, and the dev defaults live only in
`config/dev.exs`. This guard exists so that a misconfigured production
deploy fails immediately rather than booting with a development secret
that any caller on the private network could replay against
`/internal/adapter/callback`. If the inbound plug ever finds the
callback secret absent at request time (defense in depth), it returns
`401 server_misconfigured` and refuses the callback. The behavior is
regression-tested by `Bank.AdapterConfigTest` and
`BankWeb.Plugs.VerifyAdapterAuthTest`.

## Operator console (`/`, `/dashboard`, …)

- Served over HTTPS.
- **Session auth is in scope for the private alpha.** Google OAuth is
  the identity layer; admin approval into a workspace grants product
  access. There is no public signup. The full operator-facing
  walkthrough — required env vars (`GOOGLE_OAUTH_CLIENT_ID/SECRET/
  REDIRECT_URI`, `BANK_ADMIN_EMAILS`), the Stub provider for local
  dev, the pending → approve flow, and the role/workspace gates —
  lives in [`docs/runbooks/auth-and-access.md`](runbooks/auth-and-access.md).
- CSRF protection is enabled on all non-GET browser routes via the
  `:browser` pipeline.

## External `/v1/` API

- HTTPS only.
- **API-key authentication is wired.** Workspace-scoped keys
  (`Authorization: Bearer cb_<body>`) are verified by
  `BankWeb.Plugs.VerifyAPIKey`, which also refuses `:revoked`,
  `:expired`, and `:workspace_paused` keys. The plug populates the
  same `current_scope` shape the browser path resolves, so domain
  code reads workspace + role uniformly across surfaces. See
  [`docs/runbooks/api-key-auth-smoke.md`](runbooks/api-key-auth-smoke.md)
  for issuance / rotation, and
  [`docs/runbooks/auth-and-access.md`](runbooks/auth-and-access.md)
  for how the API-key path composes with the workspace gate.
- Rate limiting and quota enforcement are out of scope for alpha.

## Telegram bot operator surface (#54)

The operator-facing Telegram bot is used for alerting, queue approvals,
runtime-status checks, and high-risk pause / resume step-up
confirmation. It is a **convenience surface**, not a second source of
truth.

Controls:

- Bot token kept as an env var secret (`TELEGRAM_BOT_TOKEN`), never
  committed to the repo.
- Webhook secret kept as an env var secret (`TELEGRAM_WEBHOOK_SECRET`)
  and verified before the controller normalizes any update.
- Operator allowlist kept in `TELEGRAM_OPERATORS` as user id + chat id
  + role + audit actor tuples.
- Allowlist of Telegram user ids and chat ids. Unknown senders are
  ignored.
- Every mutating bot action maps onto an existing control-plane action
  (`approve`, `reject`, `pause`, `resume`) rather than introducing a new
  path.
- Bot callbacks carry short-lived, signed action tokens so Telegram
  button presses cannot be replayed outside their intended decision or
  time window.
- High-risk pause / resume actions require a second confirmation step in
  Telegram and include a deep link back to the web console.
- All bot-delivered alerts and approvals must emit audit events that
  identify Telegram as the surface of origin.
- The bot does **not** support free-form transaction authoring.

## Planned next alpha control: address and wallet risk screening (#55)

Counterparty curation is necessary but not sufficient. The next alpha
extension should add layered wallet-intelligence controls:

- **Hard block:** exact match against OFAC digital currency entries and
  OpenSanctions `CryptoWallet` sanctions data.
- **Warning / challenge:** exact or high-confidence matches from
  community scam feeds such as ScamSniffer, EtherScamDB, and BTC-
  specific abuse lists.
- **Context / labeling:** public attribution and cluster context from
  GraphSense tagpacks and similar public tag sources.
- **Internal scoring only:** graph- or feature-based suspicious-wallet
  scores using research datasets such as Elliptic++. Model output alone
  must never create a hard block.

The operator and audit surfaces should preserve:

- source feed
- confidence / control tier
- last-seen timestamp
- evidence link or source URI

This keeps the system explainable: sanctions produce a legal block,
community scam feeds produce a challenge, and internal models only widen
human review.

## Secrets inventory

| Secret                       | Where it lives             | Rotated on                    |
| ---------------------------- | -------------------------- | ----------------------------- |
| `ADAPTER_DISPATCH_SECRET`    | env var (both services)    | milestone end, staff change   |
| `ADAPTER_CALLBACK_SECRET`    | env var (both services)    | milestone end, staff change   |
| `TELEGRAM_BOT_TOKEN`         | env var (Phoenix)          | milestone end, staff change   |
| `TELEGRAM_WEBHOOK_SECRET`    | env var (Phoenix)          | milestone end, staff change   |
| `TELEGRAM_OPERATORS`         | env var (Phoenix)          | staff change, role change     |
| `SECRET_KEY_BASE`            | env var (Phoenix)          | milestone end                 |
| `DELEGATION_SIGNER_KEY`      | env var (adapter)          | per-account, on key compromise |
| `OPERATOR_PRIVATE_KEY` (#58) | env var (adapter)          | per-account, on key compromise |
| Adapter TLS server key       | mounted file (adapter)     | certificate expiry (optional) |
| Bundler RPC key (Base)       | adapter env var            | vendor-driven                 |

Secrets are never committed to the repo. See `.env.example` (if
present) for the development defaults that the tests and local dev
rely on.

### Adapter signing keys (`DELEGATION_SIGNER_KEY` / `OPERATOR_PRIVATE_KEY`)

The adapter holds two distinct EVM private keys with disjoint
authority. Conflating them would let a leak of the runtime session
key escalate to root authority over the smart account, so
`chain_adapter/src/config/index.ts` refuses any configuration where
both env vars derive to the same EOA.

- **`DELEGATION_SIGNER_KEY`** — runtime session key. Signs
  UserOperation hashes for transfers. Bound to whatever validation
  the smart account installs at the `regular` slot (a ZeroDev
  permission plugin in production); its on-chain authority is
  scoped by the policies attached to that permission. Treated as a
  hot key — present in adapter memory whenever a UserOp is
  dispatched.
- **`OPERATOR_PRIVATE_KEY` (#58)** — kernel root validator (sudo)
  EOA. The same EOA `provision-kernel.ts --broadcast` deploys the
  kernel against; pinned by the kernel's `rootValidator` slot at
  initialization. Signs `Kernel.uninstallValidation(...)` UserOps
  AND the EIP-712 enable signature on every grant install
  (`executeGrant`'s first UserOp). Required for both the
  cryptographic revoke path (#58 part 1) AND the cryptographic
  grant path (#58 part 2). When absent, the adapter:
   * Refuses any revoke dispatch carrying a `permission` block
     (`state=revoke_failed, reason=operator_key_missing`).
   * Refuses any grant dispatch (`state=grant_failed,
     reason=operator_key_missing`). Phoenix does not create an
     active delegation row for a permission that was never
     installed.
  Should live behind tighter controls than the runtime session
  key (HSM / KMS / cold-signing sidecar — tracked as a follow-up
  hardening track per Subagent D's review).

### Session-key secrecy (#58 grant flow)

The grant flow binds the ZeroDev permission to the adapter's
configured runtime session key (`DELEGATION_SIGNER_KEY`). That is
the same key the adapter uses to sign later UserOperations under
the installed regular validator. Installing a permission for a
throwaway key would be safer-looking but unusable: after the grant
returns, no runtime component would be able to sign through that
permission.

The serialized blob persisted in Phoenix is **KEYLESS**:
`serializePermissionAccount(account, undefined)` — the optional
`privateKey` parameter is deliberately omitted. Subagent D's
security review (PR #129 grant-flow follow-up) verified that
ZeroDev's serializer embeds the privateKey VERBATIM if passed,
so persisting the blob with the key would make Phoenix an
unintended hot wallet.

The session signer's EOA address rides on the wire as
`permission.session_signer_address` and is stored in
`delegations.session_signer_address`. At revoke time the adapter
rebuilds a stub `ModularSigner` whose `account.address` equals
that value; `getEnableData(...)` reads only the address (no
signing), so the keyless blob round-trips cleanly without
holding any signing authority outside the adapter.

**Operator implication**: a leak of the Phoenix database does
NOT compromise any session signing key. The runtime session key
lives only in the adapter environment; the only signing material
Phoenix stores is none. An attacker would still need adapter
secrets (`DELEGATION_SIGNER_KEY` for regular UserOps or
`OPERATOR_PRIVATE_KEY` for root operations) to turn Phoenix data
into on-chain action.

Both keys are validated at startup:

  * `0x` + 64 hex chars (32 bytes), `isHex` test passes.
  * Must NOT match `/placeholder|0x_/i`.
  * For `OPERATOR_PRIVATE_KEY` only: derived address MUST equal
    `OPERATOR_ADDRESS` (paste-mismatch guard) and MUST differ from
    the EOA derived from `DELEGATION_SIGNER_KEY` (role-conflation
    guard).

The pair `(OPERATOR_PRIVATE_KEY, OPERATOR_ADDRESS)` is required
for the cryptographic grant + revoke path (live on Base Sepolia
since PR #132 — #58 / #31 closed). Leaving both unset keeps the
adapter on the legacy sentinel revoke path AND refuses any
`grant_delegation` dispatch (`state=grant_failed,
reason=operator_key_missing`) — Phoenix never persists an
active row that was never installed. Setting only one of them is
refused at startup so a half-configured deploy fails fast.

## Incident response

See `docs/runbook.md` for operator procedures covering pause / resume,
adapter incidents, stuck executions, and revoke failures.
