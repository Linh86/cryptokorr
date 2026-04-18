# Bank security posture (alpha)

This document captures the trust boundaries the alpha operates within
and the controls expected at each boundary. Issue #33 hardened the
Phoenix ↔ adapter surface, which is the highest-leverage boundary
today.

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

| Secret                       | Where it lives             | Rotated on                    |
| ---------------------------- | -------------------------- | ----------------------------- |
| `ADAPTER_DISPATCH_SECRET`    | env var (both services)    | milestone end, staff change   |
| `ADAPTER_CALLBACK_SECRET`    | env var (both services)    | milestone end, staff change   |
| `SECRET_KEY_BASE`            | env var (Phoenix)          | milestone end                 |
| Adapter TLS server key       | mounted file (adapter)     | certificate expiry (optional) |
| Bundler RPC key (Base)       | adapter env var            | vendor-driven                 |

Secrets are never committed to the repo. See `.env.example` (if
present) for the development defaults that the tests and local dev
rely on.

## Incident response

See `docs/runbook.md` for operator procedures covering pause / resume,
adapter incidents, stuck executions, and revoke failures.
