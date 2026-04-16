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

## Phoenix-side scaffolding (landing in this issue)

- `BankWeb.API.V1.ConnectController.request/2` at
  `POST /v1/connect/smart_account`. Accepts the signed payload the
  JS hook built, validates shape, writes an `intent-to-connect`
  audit event, and calls the adapter-side grant dispatch (stubbed
  until the adapter exposes the endpoint).
- `assets/js/hooks/wallet_connect.js` — scaffold with EIP-1193
  detection, clear `TODO` markers for the wagmi/viem integration, and
  the `phx:wallet_connect:request` push that calls the controller.
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

## Blocker note for issue #43

In-repo scaffolding is complete and mergeable:

- `POST /v1/connect/smart_account` endpoint with a JSON contract.
- `BankWeb.API.V1.ConnectController` calling a stub
  `Bank.Delegations.request_connect/1`.
- `assets/js/hooks/wallet_connect.js` with the EIP-1193 detection
  shape, TODO markers, and the Phoenix push glue.
- This doc covering target flow, open SDK choices, and security
  considerations.

**What's blocked**: (a) SDK + delegation-type decisions, (b) adapter
repo adding `POST /dispatch/grant_delegation` and the matching
`delegation.state_changed{state: "granted"}` callback with the new
payload shape. Once both land, wiring this up is a couple hundred
lines of client code and an `AdapterClient.dispatch_grant_delegation/1`
on the Phoenix side.

Track the SDK-side work in its own issue once we pick wagmi vs
WalletConnect; track the adapter-side work in the adapter repo.
