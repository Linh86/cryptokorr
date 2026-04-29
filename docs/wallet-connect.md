# Browser wallet connect

Design doc + integration plan for replacing the v0.1 placeholder
connection UX on the control tower landing page with a real browser
wallet flow. Tracks against issue #43 (milestone: Bank v1.1 Backlog).

## State of the world (v0.1)

- Delegations are granted through the adapter's callback flow, not
  through a browser-native sign-in.
- The control tower landing page (`ControlLive`) explicitly shows
  "Browser wallet connection is not yet available in v0.1" when no
  delegation is present.
- Partners connect by handing the Bank team their smart account id
  out of band; we provision the delegation on the adapter side and
  wait for the adapter to emit `delegation.state_changed{state:
  "granted"}`, which Phoenix picks up via
  `BankWeb.Internal.AdapterCallbackController` and promotes to
  `:active`.

## Target flow (v1.1)

End to end, the browser should drive it:

```
┌────────┐     1. connect btn      ┌──────────────┐
│  User  │──────────────────────▶ │ Control tower│
└────┬───┘                         └──────┬───────┘
     │                                    │ 2. push "request"
     │                                    ▼
     │                            ┌───────────────┐
     │     3. wallet prompt       │  JS hook      │
     │   ◀─────────────────────── │ (WalletConnect│
     │                            │  or EIP-1193) │
     │ 4. sign delegation         └───────┬───────┘
     ├──────────────────────────────────▶ │
     │ 5. return tx                       │
     │ ◀──────────────────────────────────┤
     │                                    │ 6. POST /v1/connect/smart_account
     │                                    ▼
     │                            ┌───────────────┐
     │                            │  Phoenix      │
     │                            │ ConnectController
     │                            └───────┬───────┘
     │                                    │ 7. dispatch_grant_delegation
     │                                    ▼
     │                            ┌───────────────┐
     │                            │  Adapter      │
     │                            │  (TS repo)    │
     │                            └───────┬───────┘
     │                                    │ 8. grant confirmed on chain
     │                                    │ 9. callback "granted"
     │                                    ▼
     │                            ┌───────────────┐
     │                            │ AdapterCallback│
     │                            │ Controller    │
     │                            └───────┬───────┘
     │     10. live update                │
     │ ◀──────────────────────────────────┘
     ▼
  Control tower shows delegation :active
```

Steps 3–5 run entirely client-side. Step 7 is the new outbound
endpoint on the adapter (currently only `dispatch_transfer` and
`dispatch_revoke_delegation` exist). Step 9 reuses the existing
callback kind.

## Phoenix-side scaffolding (landed)

- `BankWeb.API.V1.ConnectController.request/2` at
  `POST /v1/connect/smart_account`. Accepts a payload (signed or
  null), validates shape, writes an `intent-to-connect` audit
  event, and calls `Bank.Delegations.request_connect/1`, which
  enqueues `Bank.Runtime.Workers.GrantDelegation`. The worker
  dispatches to the live adapter endpoint
  `POST /dispatch/grant_delegation` (no longer stubbed — wired
  end-to-end since #58, confirmed live on Base Sepolia under PR
  #132).
- `assets/js/hooks/wallet_connect.js` — scaffold with EIP-1193
  detection, clear `TODO` markers for the wagmi/viem integration, and
  the `phx:wallet_connect:request` push that calls the controller.
  Until a wallet SDK lands, the hook reports
  `wallet_connect:stub` and operator-driven flows post a
  `delegation_payload: null` body directly.
- Control tower: replace the passive "not yet available" text with
  a **Connect wallet** button that talks to the hook. When the hook
  is stubbed (no wallet SDK installed), the button stays disabled
  and shows a tooltip.

## Remaining work (the actual SDK integration)

Blocked on choices we should make together:

1. **SDK choice.** wagmi + viem is the current default for EVM dapps.
   WalletConnect is the lowest-common-denominator across mobile
   wallets. Picking one drives the npm deps and the hook surface.
2. **Delegation type.** ERC-7579? Native EntryPoint v0.7 session
   keys? The adapter side has opinions — we align with them first.
3. **Adapter endpoint.** `POST /dispatch/grant_delegation` needs to
   exist in the TypeScript adapter before Phoenix can call it. Open
   tracking issue in that repo.
4. **UX pass.** The "two-signature" problem (one for the delegation,
   one for the initial funding) needs to be hidden behind a single
   "Connect" button — design-pass needed.

## Security considerations

- Never store raw private keys or signed userops server-side. The
  browser signs, the adapter broadcasts.
- The connect endpoint writes an audit event with the requested
  scope *before* the adapter is called, so even a partial failure
  leaves an operator trail.
- Connect is rate-limited at Phoenix (`max_requests: 10/min` per
  client IP) — prevents a spam loop spinning up adapter calls.
- The browser must verify chain id matches the expected target
  (Base/Base Sepolia) before signing. The hook enforces this and
  refuses to sign on wrong-network wallets.

## Status — #43 / #58 grant flow

Server-side flow now lands end-to-end:

- `POST /v1/connect/smart_account` endpoint with a JSON contract.
- `BankWeb.API.V1.ConnectController` audits the request and calls
  `Bank.Delegations.request_connect/1`, which now enqueues
  `Bank.Runtime.Workers.GrantDelegation` (#58 grant flow).
- The worker calls `Bank.AdapterClient.dispatch_grant_delegation/2`
  on `POST /dispatch/grant_delegation`.
- The adapter's `executeGrant` builds a real ZeroDev permission
  plugin (`toPermissionValidator(...)`, sudo + regular slots)
  signed by `OPERATOR_PRIVATE_KEY`, sends a no-op first UserOp to
  trigger the EIP-712 enable signature, and emits
  `delegation.state_changed{state: "granted"}` with a populated
  KEYLESS `permission` block (no session privateKey embedded —
  see `docs/security.md` and Subagent D's review under the #58
  grant-flow PR).
- `Bank.Delegations.apply_callback/1` decodes the artifacts; the
  resulting row is `cryptographically_revocable?/1` and a future
  revoke takes the cryptographic `Kernel.uninstallValidation(...)`
  path (#58 PR #129).

**Still client-side scaffolding**: `assets/js/hooks/wallet_connect.js`
detects EIP-1193 providers and pushes a `wallet_connect:request`
event, but the actual signing of a delegation payload requires a
wallet SDK choice (wagmi vs WalletConnect) plus a delegation
type (ERC-7579 session key vs EntryPoint v0.7 native session
key). Until that lands the JS hook reports `wallet_connect:stub`
and the controller's `delegation_payload` field carries `null`.

**Operator runbook**: end-to-end cryptographic grant + revoke
runs against a provisioned `OPERATOR_PRIVATE_KEY` matching the
kernel's root validator (see `scripts/provision-kernel.ts`), a
real Base Sepolia bundler endpoint, and a kernel deployed under
that operator EOA. Adapter unit tests mock the SDK; the live
broadcast path is exercised through the operator smoke runbook
in [`docs/mvp-smoke-runbook.md`](mvp-smoke-runbook.md). #58 and
#31 closed under PR #132 — the first end-to-end run on Base
Sepolia confirmed the path against smart account
`0xacb3390BF0E13eB0755317Fbb2C73Ed185F4142C` (install tx
`0xbbb3a2e8…`, revoke tx `0xf81c969d…`, block `40820243`).
