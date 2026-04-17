# Bank security posture (alpha)

This document captures the trust boundaries the alpha operates within
and the controls expected at each boundary. Issue #33 hardened the
Phoenix ↔ adapter surface, which is the highest-leverage boundary
today.

## Trust boundaries

```
   ┌──────────────────┐    private network    ┌──────────────────┐
   │ TypeScript       │◀─────── mTLS ────────▶│ Phoenix control  │
   │ chain adapter    │                       │ plane (Bank)     │
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
authenticate each request at both network and application layers.

## Phoenix ↔ adapter

### Inbound callbacks (adapter → Phoenix)

`POST /internal/adapter/callback`

1. **Transport** — the production target is mTLS terminated at the
   ingress (only the adapter's client certificate accepted; Phoenix
   itself does not terminate TLS). v0.1 does not yet ship an ingress
   with mTLS configured — see the staging "TODO" list in
   [docs/staging.md](staging.md). The bearer check below is the only
   live trust check in the current deployment.
2. **Application auth** — `Authorization: Bearer <secret>` checked
   via `BankWeb.Plugs.VerifyAdapterAuth`, which uses
   `Plug.Crypto.secure_compare/2` to avoid timing leaks. The secret
   is read from `:bank, Bank.AdapterClient, :auth_secret` at request
   time.
3. **Contract validation** — `contract_version` must match the value
   Phoenix advertises; unknown kinds are rejected 422.
4. **Privacy** — callbacks MUST NOT carry PII; tx hashes and
   smart-account ids are acceptable.

### Outbound dispatch (Phoenix → adapter)

`Bank.AdapterClient.dispatch_transfer/1`, `dispatch_revoke_delegation/1`

1. **Transport** — TLS with certificate verification is the production
   target. In v0.1, `config/runtime.exs` does not wire
   `req_options.transport_opts`, so the dispatch defaults to plain TLS
   (or HTTP, if `ADAPTER_BASE_URL` is `http://`). The mTLS shape is
   illustrated below for when it is wired:

   ```elixir
   # Illustrative — not currently set by runtime.exs.
   config :bank, Bank.AdapterClient,
     base_url: "https://adapter.internal:4100",
     auth_secret: System.fetch_env!("ADAPTER_AUTH_SECRET"),
     req_options: [
       connect_options: [
         transport_opts: [
           cacertfile: "/etc/bank/adapter-ca.pem",
           certfile: "/etc/bank/phoenix-client.pem",
           keyfile: "/etc/bank/phoenix-client.key",
           verify: :verify_peer,
           server_name_indication: ~c"adapter.internal"
         ]
       ]
     ]
   ```

2. **Application auth** — Phoenix sets `Authorization: Bearer <secret>`
   on every request. **The TS adapter does not currently validate this
   header on its dispatch endpoints in v0.1** — anything reachable on
   the adapter's private network can post to `/dispatch/*`. Tightening
   the dispatch-side check is tracked in #33.
3. **Timeouts** — 5s receive timeout by default. Retries are owned
   by the caller's Oban worker, not `Req`.

### Shared secret management

- `ADAPTER_AUTH_SECRET` is a 256-bit opaque string, base64 or
  hex-encoded, generated with a CSPRNG. Example:
  `openssl rand -hex 32`.
- Rotated at the end of each alpha milestone and any time staff with
  access rotates off the team.
- Procedure: provision the new secret to both services, then
  fail over. Because the plug reads the expected secret at request
  time, a staged rollout that deploys Phoenix first with the new
  secret will reject the adapter until the adapter is updated; plan
  the rollout accordingly (adapter rotates first, then Phoenix).

## Operator console (`/`, `/dashboard`, …)

- Served over HTTPS.
- Session auth is out of scope for alpha (single-operator deployments
  sit behind a corporate VPN). v1.1 will add SSO.
- CSRF protection is enabled on all non-GET browser routes via the
  `:browser` pipeline.

## External `/v1/` API

- HTTPS only.
- API-key authentication is expected; the pipeline is scaffolded but
  key issuance is tracked separately.
- Rate limiting and quota enforcement are out of scope for alpha.

## Secrets inventory

| Secret                   | Where it lives             | Rotated on                    |
| ------------------------ | -------------------------- | ----------------------------- |
| `ADAPTER_AUTH_SECRET`    | env var (both services)    | milestone end, staff change   |
| `SECRET_KEY_BASE`        | env var (Phoenix)          | milestone end                 |
| Adapter mTLS client key  | mounted file (Phoenix)     | certificate expiry            |
| Adapter mTLS server key  | mounted file (adapter)     | certificate expiry            |
| Bundler RPC key (Base)   | adapter env var            | vendor-driven                 |

Secrets are never committed to the repo. See `.env.example` (if
present) for the development defaults that the tests and local dev
rely on.

## Incident response

See `docs/runbook.md` for operator procedures covering pause / resume,
adapter incidents, stuck executions, and revoke failures.
