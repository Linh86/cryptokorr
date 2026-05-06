# Browser-signed ZeroDev permission install — design note

> Status: design (#472). Implementation lands in #473 (frontend),
> #474 (Phoenix attestation + on-chain verification), #475 (revoke
> parity decision and any implementation), #476 (smoke + docs).

## TL;DR

The current install path is functionally complete on Base Sepolia,
but the install UserOperation is signed server-side by the chain
adapter's `OPERATOR_PRIVATE_KEY`. This compromises the
non-custodial product claim (launch risk R2 in the MVP product
assessment).

This design replaces it with a browser-signed install: the user's
connected EOA wallet on Base Sepolia signs the install
UserOperation directly via the ZeroDev SDK, the browser submits to
the bundler directly, and Phoenix marks the delegation `:active`
only after **Phoenix-side on-chain verification** of the installed
permission validator.

The new path is the default for new Base Sepolia users. Existing
delegations continue to work unchanged. The operator-side revoke
path stays server-signed for v0.1 as documented "operator
emergency revoke" — see § Revoke parity.

---

## 1. Smart-account model

### Decision

**Counterfactual Kernel v3.1 account, owned by the user's EOA at
inception. The first UserOp is the install itself, which both
deploys the account and installs the permission validator in one
EntryPoint v0.7 transaction.**

### Why

The current path uses a pre-provisioned Kernel v3.1 account whose
root validator is `OPERATOR_ADDRESS`
(`chain_adapter/scripts/provision-kernel.ts`). That model is the
load-bearing assumption behind operator-signed install: only the
operator key can sign for that root validator, so only the
operator can install plugins. Switching to a browser-signed
install means the user's EOA must be the root validator.

A pre-provisioning fork ("we deploy a Kernel for the user with
their EOA as root before they install") moves the operator key
back into the critical path of account setup, which negates the
non-custodial claim. A counterfactual account avoids it: ZeroDev
SDK's `createKernelAccount({ ownerSigner })` returns a
deterministic CREATE2 address; the EntryPoint deploys the account
on the first UserOp via `initCode`; that first UserOp can ALSO
carry the install call. No server key signs anything on this path.

### Implications

- **First-UserOp gas.** The user's EOA pays gas on Base Sepolia in
  testnet ETH. The frontend documents the
  [Base Sepolia faucet](https://www.alchemy.com/faucets/base-sepolia)
  and refuses to broadcast if `eth_getBalance` is below a
  conservative threshold (recommendation: 0.005 ETH for the
  install + first transfer). Paymaster sponsorship is **out of
  scope for v0.1**; tracked as a v0.2 follow-up.
- **No funded smart-account precondition.** The smart account's
  USDC/USDT balance can be zero at install time — the install
  UserOp consumes ETH from the user's EOA, not from the
  not-yet-deployed smart account. Funding the smart account with
  USDC for swaps/transfers is a separate post-install step.
- **Provisioning script is no longer load-bearing for new users.**
  `chain_adapter/scripts/provision-kernel.ts` stays for legacy /
  operator-shared smart accounts but is not invoked on the
  browser-signed path. The script is kept under `chain_adapter/`
  rather than removed because legacy delegations continue to use
  the kernels it provisioned (§ 7).

### Failure modes specific to counterfactual deployment

- **EOA has insufficient gas.** Frontend pre-checks `eth_getBalance`
  before requesting signature. If below threshold, surface a
  faucet link and abort cleanly — no signature request fires.
- **Bundler rejects deployment + install in one UserOp.** Pimlico
  and Alchemy AA both support combined initCode+callData; this
  has been working in dev. The fallback (split deployment +
  install across two UserOps) is **not implemented in v0.1**;
  failure surfaces as `bundler_rejected: <safe-category>`.
- **EntryPoint refuses initCode (e.g., already deployed).** Means
  the user's EOA already had a Kernel account at this CREATE2
  address from a prior session. ZeroDev SDK detects this and
  skips `initCode`; the install proceeds against the existing
  account. No special handling needed.

---

## 2. ZeroDev / browser SDK packages

### Decision

**Add to the Phoenix asset bundle:**

| Package | Version | Purpose |
|---------|---------|---------|
| `@zerodev/sdk` | `5.5.10` | `createKernelAccount`, `createKernelAccountClient`, `KERNEL_V3_1` |
| `@zerodev/permissions` | `5.6.3` | `toPermissionValidator`, `serializePermissionAccount`, `toECDSASigner` |
| `@zerodev/ecdsa-validator` | `5.4.9` | `signerToEcdsaValidator` (root-validator for the user's EOA) |
| `viem` | `^2.31.3` | wallet client (`custom(window.ethereum)`), public client, ABI helpers |
| `permissionless` | `^0.2.x` | bundler client (used by `@zerodev/sdk` under the hood; pinned so `npm audit` can verify) |

**No `wagmi`, no `RainbowKit`, no React.** The Phoenix frontend is
LiveView + esbuild + a thin JS hook layer. We extend the existing
`assets/js/hooks/wallet_connect.js` pattern with a sibling hook
(`session_install.js`) that imports the ZeroDev SDK directly.

### Versions are pinned to the adapter's

The chain adapter already runs `@zerodev/sdk@5.5.10`,
`@zerodev/permissions@5.6.3`, and
`@zerodev/ecdsa-validator@5.4.9` (see `chain_adapter/package.json`).
Keeping the browser bundle on the **same versions** avoids any
serialization mismatch between
`serializePermissionAccount(...)` in the browser and
`deserializePermissionAccount(...)` on the adapter at revoke time
(this is the kernel/package-version pin that the existing
`KERNEL_PERMISSION_PIN` enforces — see
`chain_adapter/src/chains/base/permission_validator.ts`).

### Bundle-size impact (estimate)

ZeroDev SDK + `@zerodev/permissions` + `viem` + `permissionless`
add roughly **180 KB** minified + gzipped to the Phoenix
LiveView asset bundle (current bundle is ~110 KB
post-tailwind/esbuild). The total ~290 KB still fits the
operator-facing dashboard's perf budget; LiveView's first-paint
is already TTI-bounded by Phoenix's WebSocket handshake, not by
JS.

The bundle is loaded **only on the wallet-install screen** via a
LiveView dynamic import / route-scoped hook split — not on
Dashboard, Queue, Audit, etc. So the cost is paid once per
install, never on hot operator paths.

### Out of scope

- **WalletConnect.** Browser EIP-1193 only. WalletConnect /
  MetaMask Mobile / Coinbase Wallet support is a v0.2 follow-up.
- **Wagmi React hooks.** No React. The hook is plain TS.

---

## 3. Permission scope source of truth

### Decision

**Phoenix is the single source of truth. The browser fetches the
canonical scope from a Phoenix endpoint and feeds it to the
ZeroDev SDK byte-for-byte. The browser does not author or mutate
the scope.**

### Why

`Bank.SessionPermissions.Scope` already canonicalizes the scope
(USDC transfer, 0x swap, allowlisted Morpho ERC-4626 deposit;
deny: arbitrary calldata, unlimited approvals, borrow/leverage,
withdraw, mainnet). The exact bytes that the user signs MUST
match the bytes Phoenix records on the persisted delegation row —
otherwise Phoenix's `cryptographically_revocable?/1` check will
fail closed at revoke time and the operator-emergency revoke
fallback will be the only option.

Construction in the browser would create a real risk that a
different (older / forked / patched) ZeroDev SDK build encodes
the scope with different policy contracts or different ordering,
and the install UserOp goes through with a scope Phoenix can't
mirror. Keeping construction Phoenix-side also makes the policy
auditable — every install carries the Phoenix git SHA in audit so
post-hoc review can pin which scope rules were active.

### New endpoint

```
GET /v1/wallet_bindings/:binding_id/install_envelope
```

**Auth:** session-cookie (the operator who initiated the binding
is logged in). 401 if no session, 403 if the binding is not in
the caller's workspace, 422 if the binding is not in
`verified_at` state.

**Response (200):**

```json
{
  "binding_id": "<uuid>",
  "smart_account_id": "<sa_id>",
  "chain_id": 84532,
  "entry_point_address": "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  "kernel_implementation_address": "0x...",
  "kernel_version": "0.3.1",
  "permissions_package_version": "5.6.3",
  "session_signer_address": "0x...",
  "scope": {
    "policies": [
      {
        "policy": "call_policy_v0_0_5",
        "address": "0x...",
        "permissions": [
          {
            "target": "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
            "selector": "0xa9059cbb",
            "value_limit": "0",
            "rules": []
          }
        ]
      },
      { "policy": "rate_limit_policy", "count": 100, "interval_seconds": 86400 },
      { "policy": "timestamp_policy", "valid_until": "<iso8601>", "valid_after": null }
    ],
    "deny_summary": [
      "no unlimited approvals",
      "no arbitrary calldata",
      "no borrow / leverage",
      "no withdraw / redeem",
      "no mainnet"
    ]
  },
  "bundler_rpc_url": "https://api.pimlico.io/v2/84532/rpc?apikey=<browser-tier-key>",
  "human_readable_summary": "USDC transfer · 0x swap · allowlisted Morpho USDC deposit · 24h"
}
```

**Notes:**

- `scope.policies` is the SDK-shaped policy list. The browser
  converts it to ZeroDev SDK's `toPermissionValidator(...)` args
  via a thin adapter; no policy logic in the browser beyond
  passing the values through.
- `session_signer_address` is the EOA Phoenix mints for the
  session signer. (Phoenix already mints this and stores it in
  `WalletBinding.session_signer_address`; cf.
  `lib/bank/session_permissions/scope.ex` and the
  `wallet_bindings` schema.) Browser uses
  `toECDSASigner({ signer: { address, type: "eoa" } })` — note
  this is a stub signer because the browser does not need to
  produce the session signer's signature at install time, only
  its address.
- `bundler_rpc_url` is the **browser-tier** Pimlico endpoint with
  a separate, tightly rate-limited public-tier API key (§ 4).
- `human_readable_summary` is what the install UI renders above
  the "Sign with your wallet" button.

### Audit posture

`GET /v1/wallet_bindings/:id/install_envelope` emits an audit
event `delegation.install_envelope_issued` carrying
`(binding_id, sa_id, chain_id, scope_hash)` where `scope_hash` is
SHA-256 of the canonical-JSON-encoded scope policies. The same
hash is stored on the persisted delegation row at attestation
time so post-hoc audit can prove "this is the exact scope the
operator was shown."

---

## 4. Bundler / RPC path

### Decision

**Browser sends the install UserOp directly to a separate
browser-tier bundler RPC endpoint, distinct from the
adapter-tier bundler.**

### Why

| Option | Pros | Cons |
|---|---|---|
| Browser → Phoenix → bundler | one bundler URL, server controls rate limit | Phoenix becomes a non-custodial proxy; abuse vector against Phoenix; latency; double-SSL termination |
| Browser → adapter → bundler | adapter already speaks bundler, has Req helpers | adapter would need a public-facing CORS endpoint and a rate limiter; doubles adapter's blast radius |
| **Browser → bundler (direct)** | cleanest non-custodial story; bundler enforces rate limit; Phoenix never proxies user gas | requires a separate browser-tier API key |

The bundler is the right abuse boundary: Pimlico, Alchemy AA, and
Stackup all enforce per-API-key rate limits at the
`eth_sendUserOperation` level. A browser-tier key with
~10 req/min/user is sufficient for install + the rare
operator-initiated re-bind, and is independent of the
adapter-tier key that handles all execution dispatches.

### Configuration

Two new operator config knobs at deploy time:

```elixir
# config/runtime.exs
config :bank, BankWeb.Endpoint,
  bundler_rpc_url_browser: System.get_env("BUNDLER_RPC_URL_BROWSER")
```

The Phoenix `install_envelope` endpoint reads this and embeds it
in the response. The URL contains the public-tier API key inline
(it's a public secret — published to every browser anyway), so
operators **must** rotate it independently of the adapter-tier
`BUNDLER_RPC_URL`. Document this in the operator runbook.

### Abuse posture

- **No CSRF risk** — the install attestation endpoint requires
  the binding-scoped session cookie + the actual `userop_hash`
  observed on chain (which Phoenix re-verifies by reading kernel
  state).
- **No DoS amplification** — the browser's bundler URL has its
  own quota, separate from the adapter's; an abusive browser
  cannot starve real swap dispatch.
- **No secret leakage** — Phoenix never sees or holds the user's
  EOA private key; the bundler URL published to the browser is
  ratelimitable and rotatable by the operator.

### Why not a paymaster

Paymaster sponsorship would let the operator pay the user's gas,
removing the "needs Sepolia ETH" friction. **Out of scope for
v0.1.** Reasons:

1. Paymaster integration introduces an operator-side abuse vector
   (one user can drain the paymaster's deposit) that needs a
   separate rate-limit and verifying-paymaster signature flow.
2. Sepolia ETH faucets exist; this is a friction, not a blocker.
3. Mainnet is post-MVP, so the marginal value of paymaster
   sponsorship for testnet alone is low.

Tracked as v0.2 follow-up.

---

## 5. Failure semantics

The browser is the canonical reporter of every step's outcome.
Phoenix is the canonical verifier of on-chain state.

| State | Trigger | Browser action | Phoenix action | Audit event |
|---|---|---|---|---|
| `awaiting_signature` | install UI loaded | render scope, await user click | none | `delegation.install_envelope_issued` (on `GET install_envelope`) |
| `signing` | user clicks "Sign" | `eth_requestAccounts` + ZeroDev `kernelClient.sendUserOperation` | none | none |
| `user_rejected` | wallet returns reject | `POST install_attestation` with `status: "user_rejected"` | record event; binding stays in `:verified` state for retry | `delegation.install_failed` with `reason: "user_rejected"` |
| `bundler_rejected` | bundler returns 4xx/5xx | `POST install_attestation` with `status: "bundler_rejected"` + safe category atom | record event; binding stays in `:verified` for retry | `delegation.install_failed` with `reason: "bundler_rejected:<category>"` |
| `submitted` | bundler returns userop hash | render "broadcasting…"; `POST install_attestation` with `status: "submitted"` + `userop_hash` | persist a `:pending` delegation row keyed by `(sa_id, userop_hash)`; do NOT mark active yet | `delegation.install_signed_by_user` |
| `confirmed_browser_side` | bundler `waitForUserOperationReceipt` returns success | `POST install_attestation` with `status: "confirmed"` + `tx_hash` + `block_number` | enqueue `Bank.Runtime.Workers.VerifyInstallOnchain` | `delegation.install_broadcast` |
| `confirmed_phoenix_verified` | Phoenix reads kernel state and confirms permission validator is installed with expected `permission_id` + `validation_id` | UI re-polls and renders "active" | flip delegation row to `:active`, populate `permission_*` columns | `delegation.install_confirmed_onchain` |
| `reverted` | bundler receipt reports `success: false` | `POST install_attestation` with `status: "reverted"` + `tx_hash` + on-chain reason | mark pending delegation row `:install_failed`; do NOT mark active | `delegation.install_failed` with `reason: "userop_reverted:<safe-reason>"` |
| `callback_missing` | browser closed before reporting outcome | none | binding has 15-min TTL; if no attestation lands, the pending delegation row (if it exists) is reaped by a cron sweep into `:install_failed` with `reason: "attestation_timeout"` | `delegation.install_failed` with `reason: "attestation_timeout"` |

**Important invariant:** `confirmed_browser_side` is **not
sufficient** to mark the delegation `:active`. The browser is
untrusted from Phoenix's perspective — a malicious browser could
report a fake `userop_hash`. Phoenix verifies on-chain via
`Bank.Chains.KernelVerifier` (new module, see § 9) before
flipping state.

### Reason categories (fixed allowlist)

The browser MUST collapse failure detail to one of these atoms
before posting attestation. Mirrors the
`Bank.Quotes.LiveProvider` posture (#174).

```
user_rejected
bundler_rejected
bundler_unavailable
chain_id_mismatch
insufficient_funds
userop_reverted
attestation_timeout
unknown
```

Free-form upstream strings (bundler error bodies, wallet vendor
messages) are NEVER persisted on the delegation row's
`last_reason` column or in the `delegation.install_failed`
audit event.

---

## 6. Revoke parity

### Decision

**Revoke stays server-signed in v0.1 as "operator emergency
revoke," and is documented as such. Browser-signed revoke is
tracked as a v0.2 follow-up.**

### Why

Revoke is the kill switch. It must work even when the user wallet
is unavailable (lost device, compromised key, vacationing user,
operator response to wallet-side compromise). A browser-signed
revoke would create the failure mode "user can't revoke their
own delegation because their wallet is unreachable" — which is
exactly the situation in which revoke matters most.

Revoke does NOT compromise the non-custodial claim because:

  1. The operator's revoke power is bounded — they can ONLY
     uninstall the permission validator; they cannot move funds,
     execute swaps, or extract value from the smart account.
  2. The user can also self-revoke (post-v0.1) by re-signing the
     equivalent uninstall UserOp from their wallet.
  3. The operator key's authority is constrained by the kernel's
     `onlyEntryPointOrSelfOrRoot` guard — only the root validator
     can install/uninstall plugins. With browser-signed install,
     **the user is the root validator**, not the operator. So
     the operator-signed revoke path that's live today CANNOT
     work for browser-signed delegations: the operator key is no
     longer authorized.

### What this means for v0.1 implementation

- **Legacy delegations** (server-signed install, operator EOA is
  root) — revoke continues to work via the existing
  `Bank.Runtime.Workers.RevokeDelegation` + the adapter's
  `executeCryptographicRevoke` path. No code change.
- **New delegations** (browser-signed install, user EOA is root)
  — revoke MUST be browser-signed, OR the operator falls back
  to the existing **sentinel revoke** path (`execute(self, 0,
  0x)` no-op UserOp), which produces a real audit anchor but
  does NOT cryptographically uninstall the permission. The
  sentinel path is what we already ship for legacy
  pre-cryptographic-revoke delegations; it's well-understood
  and operator-supervised.

For v0.1 launch:

  - The default revoke path for browser-signed delegations is the
    **sentinel revoke** (audit-only). Operators are explicitly
    informed — see § 8 (audit / docs).
  - A browser-signed revoke flow ships in v0.2 and uses the same
    `install_attestation`-style attestation path (browser signs
    `Kernel.uninstallValidation(...)`, reports outcome, Phoenix
    verifies on-chain).
  - The cryptographic revoke we already ship via the operator
    EOA continues to work for legacy delegations only.

### Open question

**Should browser-signed delegations expose a "revoke now via your
wallet" button in the operator console?** Recommendation: **no,
not in v0.1.** The operator is not the user; the operator's
"revoke" intent is the sentinel-revoke audit anchor. A user-side
revoke button lives on the wallet-quickstart page (or follow-up
self-serve flow) in v0.2. This keeps v0.1 surface area tight and
is consistent with the audit-anchor-only posture.

---

## 7. Backwards compatibility

### Decision

**Existing legacy Sepolia delegations keep working unchanged. No
migration. New installs go through the browser-signed path; old
delegations stay on the server-signed-revoke (cryptographic) path
until they expire or the operator manually triggers a re-install.**

### Why

The `delegations` table already supports both modes (see
`lib/bank/delegations/delegation.ex`):

  - `permission_blob` and friends are nullable. Legacy rows where
    the artifact columns are NULL fall through to the sentinel
    revoke path.
  - Cryptographically revocable rows (artifacts populated)
    continue to use the operator-EOA revoke flow, which works
    because those rows were installed when the operator EOA was
    the kernel's root validator.
  - New browser-signed delegations also populate the artifact
    columns, but with the user EOA as the root validator. Phoenix
    can't tell the two apart from the artifact bytes alone, so we
    add a `root_validator_owner` enum column on `delegations`
    (`:operator` for legacy, `:user` for browser-signed). Revoke
    branches on this column to pick the right code path.

### Schema migration

```elixir
# priv/repo/migrations/<ts>_add_delegation_root_validator_owner.exs
defmodule Bank.Repo.Migrations.AddDelegationRootValidatorOwner do
  use Ecto.Migration

  def change do
    alter table(:delegations) do
      # nil for legacy rows; operator for the existing server-signed
      # path; user for the browser-signed path (#473).
      add :root_validator_owner, :string
    end

    # Backfill legacy rows: every existing row was installed with
    # the operator EOA as root validator. The MVP claim "no
    # mainnet" means there are no production rows at risk.
    execute(
      "UPDATE delegations SET root_validator_owner = 'operator' WHERE root_validator_owner IS NULL",
      ""
    )
  end
end
```

**Backfill safety:** the only `delegations` rows that exist in
production today are testnet rows from the operator-shared smart
account. The `UPDATE … WHERE root_validator_owner IS NULL` is
safe by the same principle.

### Code paths (post-migration)

```elixir
# Bank.Runtime.Workers.RevokeDelegation
case delegation.root_validator_owner do
  :operator -> ExistingCryptographicRevokeViaOperatorEOA.dispatch(delegation)
  :user     -> SentinelRevokeWithUserOpAnchor.dispatch(delegation)
end
```

The user-side cryptographic revoke (browser-signed) is added in
v0.2; until then, `:user` delegations get the sentinel path.

### Operator-facing impact

The operator console's "active delegations" list shows BOTH
types side-by-side. An additional column / badge labels each
delegation as "user-signed" (browser-signed, v0.1) or
"operator-signed (legacy)." The revoke button on each row dispatches the appropriate flow per the table above.

---

## 8. Audit, endpoint, and event names

The implementation issues (#473, #474, #475) reference this
section directly so naming is fixed here.

### New endpoints

| Method | Path | Purpose | Owner | Auth |
|---|---|---|---|---|
| GET | `/v1/wallet_bindings/:id/install_envelope` | Browser fetches canonical scope + bundler URL + smart-account address. Phoenix is source of truth. | Phoenix (#474) | session cookie |
| POST | `/v1/wallet_bindings/:id/install_attestation` | Browser reports each step's outcome. Phoenix records audit + enqueues verification. | Phoenix (#474) | session cookie |
| GET | `/v1/wallet_bindings/:id/install_status` | Browser polls install state for UI. Returns `awaiting | signing | submitted | verifying | active | failed`. | Phoenix (#474) | session cookie |

### New audit event types

```
delegation.install_envelope_issued
delegation.install_signed_by_user
delegation.install_broadcast
delegation.install_confirmed_onchain
delegation.install_failed
```

All carry `correlation_id == binding_id` (Phoenix already uses
binding-id correlation for connect events). Subject type is
`wallet_binding` for the first three and `delegation` for the
last two (because at confirmation/failure time a delegation row
exists).

### New worker

```
Bank.Runtime.Workers.VerifyInstallOnchain
```

Triggered by `install_attestation{status: "confirmed"}`. Loads
the kernel address, calls `Bank.Chains.KernelVerifier.verify/3`
(new module — uses an `eth_call` to read installed validators),
asserts the `validation_id` matches the one Phoenix issued in
the install envelope, then flips the delegation row to `:active`.

The worker is idempotent and uses Oban's
`max_attempts: 5, backoff: :exponential`. On exhaustion, the
delegation row stays `:install_failed` with reason
`onchain_verification_unreachable`.

### New schema column

```
delegations.root_validator_owner :string
  -- nil | "operator" | "user"
  -- Branches the revoke path. See § 7.
```

---

## 9. Sequence diagram

```mermaid
sequenceDiagram
    autonumber
    participant U as User
    participant W as User EOA wallet<br/>(MetaMask / browser)
    participant B as Browser<br/>(LiveView + session_install.js)
    participant P as Phoenix
    participant R as Bundler RPC<br/>(browser-tier)
    participant K as Kernel v3.1 SA<br/>(counterfactual)
    participant V as Bank.Runtime.<br/>VerifyInstallOnchain

    U->>B: clicks "Install session permission"
    B->>P: GET /v1/wallet_bindings/:id/install_envelope
    P-->>P: emits delegation.install_envelope_issued audit
    P-->>B: { scope, bundler_rpc_url, sa_address, kernel_version, ... }
    B->>U: renders scope summary + "Sign with your wallet"
    U->>B: clicks "Sign"
    B->>W: ZeroDev SDK builds counterfactual Kernel account<br/>+ install permission UserOp; requests signature
    W->>U: shows EIP-712 install UserOp prompt
    U->>W: signs

    alt user rejects
        W-->>B: rejection
        B->>P: POST install_attestation { status: "user_rejected" }
        P-->>P: delegation.install_failed audit
        P-->>B: 200 ack
    else signed
        W-->>B: signature
        B->>R: eth_sendUserOperation (initCode + install callData)

        alt bundler accepts
            R-->>B: userop_hash
            B->>P: POST install_attestation { status: "submitted", userop_hash }
            P-->>P: persists pending delegation row<br/>delegation.install_signed_by_user audit
            P-->>B: 200 ack

            B->>R: waitForUserOperationReceipt(userop_hash)

            alt receipt success
                R-->>B: { tx_hash, block_number, success: true }
                B->>P: POST install_attestation { status: "confirmed", tx_hash, block_number }
                P-->>P: delegation.install_broadcast audit<br/>enqueue VerifyInstallOnchain
                P-->>B: 200 ack
                B->>U: renders "verifying on chain…"

                P->>V: VerifyInstallOnchain.run(delegation_id)
                V->>K: eth_call read installed validators
                K-->>V: validators bytes
                V-->>V: assert permission_id + validation_id match envelope

                alt verification passes
                    V->>P: flip delegation :active,<br/>populate permission_* columns
                    P-->>P: delegation.install_confirmed_onchain audit
                    B->>P: GET /v1/wallet_bindings/:id/install_status
                    P-->>B: { state: "active", delegation_id }
                    B->>U: renders "active delegation"
                else verification fails (wrong scope / not installed)
                    V->>P: mark :install_failed,<br/>reason: "onchain_state_mismatch"
                    P-->>P: delegation.install_failed audit
                end
            else receipt revert
                R-->>B: { success: false, reason: "<chain reason>" }
                B->>P: POST install_attestation { status: "reverted", tx_hash, reason: "userop_reverted:<safe-category>" }
                P-->>P: delegation.install_failed audit
            end

        else bundler rejects
            R-->>B: 4xx/5xx error
            B->>P: POST install_attestation { status: "bundler_rejected", reason: "bundler_rejected:<category>" }
            P-->>P: delegation.install_failed audit
        end
    end
```

---

## 10. Security invariants (named)

These are the load-bearing invariants the implementation MUST
preserve. Each one is testable and is asserted by at least one
test in the implementation issues.

### 10.1 Base Sepolia only

  - The install envelope endpoint refuses any binding whose
    `chain_id` is not `84532`. Mainnet bindings (`8453`) get
    `422 unsupported_chain`.
  - The browser hook reads `eth_chainId` before requesting
    signature; if not `0x14a34` (84532), it surfaces a
    "switch network" prompt and refuses to broadcast.
  - The bundler URL embedded in the install envelope is the
    Base Sepolia bundler. A misconfigured operator that sets a
    mainnet bundler URL is caught by the bundler's chain-id
    response (`eth_chainId` from the bundler must match 84532
    or the install refuses).
  - Pinned by tests in #474 (Phoenix endpoint) and #473
    (browser hook).

### 10.2 No server / operator private key signs the normal install

  - Phoenix has no signing key. `OPERATOR_PRIVATE_KEY` exists on
    the chain adapter but is read **only** by the legacy
    cryptographic revoke path (§ 6) and the legacy server-signed
    install path (which is feature-flagged off for new bindings).
  - The new install-envelope endpoint does NOT touch the adapter
    or the operator key.
  - Pinned by a test in #474 that asserts the new install path
    never calls `Bank.AdapterClient.dispatch_grant_delegation/2`.

### 10.3 Phoenix verifies on-chain state before active delegation

  - `confirmed_browser_side` is NOT enough. The
    `VerifyInstallOnchain` worker reads the kernel's installed
    validators directly via `eth_call` and asserts the
    `permission_id` + `validation_id` Phoenix issued in the
    install envelope are the ones actually installed.
  - The `:active` state transition only fires from
    `VerifyInstallOnchain` — never from a browser attestation
    alone.
  - Pinned by a test in #474 that simulates a malicious browser
    posting a fake `userop_hash` and asserts the delegation
    stays `:pending` and ultimately `:install_failed`.

### 10.4 Bounded scope — no unlimited approval, arbitrary calldata, borrow / leverage, withdraw authority

  - `Bank.SessionPermissions.Scope` is the canonical scope
    source. Its policy list is exhaustively documented and
    versioned in the codebase.
  - The browser does not author the scope; it relays Phoenix's
    canonical bytes to the ZeroDev SDK. Mid-flight scope
    mutation by a hostile browser would not change what the
    user signed (the EIP-712 typed-data binds the policies),
    AND would not pass the on-chain verification step (Phoenix
    re-asserts the installed `validation_id` matches the
    envelope's).
  - Pinned by a test in #474 that posts an attestation with a
    forged `validation_id` and asserts the verification fails.

### 10.5 No private key in Phoenix; no private key in the browser save the user's

  - Phoenix has no signing capability at all.
  - The browser only ever sees the user's own `window.ethereum`
    provider. No session-signer key is generated browser-side
    (the session signer is a Phoenix-issued EOA whose address
    rides on the install envelope; the kernel verifies its
    signatures during runtime swap/transfer dispatch, not at
    install time).

---

## 11. Open questions / explicit deferrals

These are intentionally NOT decided in this design and are
tracked as v0.2 follow-ups so #473–#476 can ship cleanly.

  - **Paymaster sponsorship of the first UserOp.** The user
    pays gas in Sepolia ETH for v0.1. (§ 1)
  - **Browser-signed revoke.** Revoke stays operator-side
    (sentinel for browser-signed delegations) in v0.1. (§ 6)
  - **WalletConnect / mobile wallets.** Browser EIP-1193 only
    in v0.1. (§ 2)
  - **Multi-chain.** Base Sepolia only. Mainnet enabling lives
    behind a separate epic that re-runs go / no-go review.
    (§ 10.1)
  - **Permission scope versioning across deploys.** The install
    envelope embeds `permissions_package_version` and
    `kernel_version`; future re-installs that need a new
    `validation_id` because a policy changed are tracked
    separately. (§ 3)

---

## 12. Implementation handoff

This design unblocks four implementation issues. Each maps to a
discrete worker:

| # | Title | Owner | Surface |
|---|---|---|---|
| **#473** | A.1 frontend ZeroDev browser install flow | Frontend | `assets/js/hooks/session_install.js`, install LiveView state, dependency add to `assets/package.json` |
| **#474** | A.2 Phoenix install attestation + on-chain verification | Backend | `BankWeb.API.V1.WalletBindings*Controller`, `Bank.Runtime.Workers.VerifyInstallOnchain`, `Bank.Chains.KernelVerifier`, schema migration for `root_validator_owner` |
| **#475** | A.3 revoke parity | Backend | `Bank.Runtime.Workers.RevokeDelegation` branches on `root_validator_owner`; sentinel path for `:user` delegations; docs for the v0.2 browser-signed revoke roadmap |
| **#476** | A.4 smoke + docs | Docs | `docs/runbooks/browser-signed-install.md`, `docs/wallet-quickstart.md` rewrite, `mix bank.browser_install.smoke` (operator-confirmed `--confirm` recipe like `bank.swap.smoke`), update `docs/mvp-readiness.md` |

### Cross-cutting tests each implementation issue must add

- **Secret hygiene.** No `OPERATOR_PRIVATE_KEY` / `Authorization`
  / `Bearer` / `sk_(live|test)_*` / PEM / credentialed-URL
  patterns surface in the install endpoint response, the
  attestation audit row, the install envelope, or the install
  status payload. Mirrors #174 / #176 / #194.
- **Workspace isolation.** Bindings in workspace A cannot
  install on smart accounts owned by workspace B. The install
  envelope endpoint returns 403 across workspaces; the
  attestation endpoint validates the same.
- **Replay determinism.** `Bank.Audit.replay/1` for a delegation
  shows the new event chain (envelope_issued →
  signed_by_user → broadcast → confirmed_onchain | failed).
- **Drift tests.** `docs/runbooks/browser-signed-install.md`
  must reference every endpoint name, every audit event name,
  and every reason-category atom listed in §§ 5 and 8 — pinned
  by a doc-drift suite (mirrors the #196 / #177 pattern).
