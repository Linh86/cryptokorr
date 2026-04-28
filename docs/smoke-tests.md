# Base smoke tests

Repeatable checks that exercise Phoenix ↔ adapter ↔ Base end-to-end
before a demo, a partner session, or a fresh staging deploy. They are
not part of `mix test` — they spend real gas and require a funded
smart account, so they live behind explicit Mix tasks.

## When to run

- After every adapter deploy that touches dispatch or callback code.
- Before starting a design-partner pilot session.
- After rotating either `ADAPTER_DISPATCH_SECRET` or
  `ADAPTER_CALLBACK_SECRET` — the transfer smoke exercises both
  directions and confirms both sides rehydrated the new values.
- As the final gate before cutting an alpha release.

## Preconditions

1. Staging Phoenix is running and pointing at the staging adapter.
2. The adapter is running against a bundler (Base Sepolia is the
   default staging chain).
3. `ADAPTER_BASE_URL`, `ADAPTER_DISPATCH_SECRET`, and
   `ADAPTER_CALLBACK_SECRET` are set on the host that runs the smoke
   task (or `config/runtime.exs` env is equivalent).
4. The smart account under test:
    - Exists on chain.
    - Has been funded with enough USDC + gas to cover the smoke
      transaction.
    - Has an `:active` delegation (either pre-seeded via the API or
      granted via the control tower connection flow).

## Transfer smoke

```shell
ADAPTER_BASE_URL=https://adapter-staging.internal \
ADAPTER_DISPATCH_SECRET=<staging-dispatch-secret> \
ADAPTER_CALLBACK_SECRET=<staging-callback-secret> \
SMART_ACCOUNT_ID=sa_alpha_01 \
DELEGATION_ID=del_alpha_01 \
TARGET_ADDRESS=0x0000000000000000000000000000000000000DeAD \
AMOUNT=1 \
mix bank.smoke.transfer
```

### PASS

```
PASS — transfer smoke
  plan_id           : <uuid>
  execution_status  : confirmed
  final_outcome     : confirmed
  tx_refs           : [...]
```

Exit code 0.

### Typical FAIL modes

| `reason`                                 | Likely cause                                     |
| ---------------------------------------- | ------------------------------------------------ |
| `{:dispatch_failed, :adapter_unavailable}` | Adapter unreachable; check URL, network, auth. |
| `{:dispatch_failed, {:adapter_rejected, 422, _}}` | Validation error in payload (chain, asset, target). |
| `{:aborted, reason}`                      | Chain-side refusal: `bundler_rejected`, `paymaster_denied`, `delegation_revoked`, etc. |
| `{:reverted, reason}`                     | Userop included but reverted. Check target ERC-20 allowance / recipient contract. |
| `{:timeout, :signing}`                    | Adapter accepted but never emitted broadcast. Check adapter logs + bundler health. |
| `{:timeout, :broadcasting}`               | Broadcast arrived but no confirmation. Check chain explorer for the userop hash. |

## Revoke smoke

```shell
ADAPTER_BASE_URL=https://adapter-staging.internal \
ADAPTER_DISPATCH_SECRET=<staging-dispatch-secret> \
ADAPTER_CALLBACK_SECRET=<staging-callback-secret> \
SMART_ACCOUNT_ID=sa_alpha_01 \
mix bank.smoke.revoke
```

`delegation_id` is resolved from the `delegations` row keyed by
`SMART_ACCOUNT_ID`; the task fails with `:no_active_delegation` if
there is no active or pending delegation row. Phoenix then threads
that `delegation_id` into the adapter dispatch payload
(`POST /dispatch/revoke_delegation`, required field since #58's
threading commit), and the adapter echoes it back on every
`delegation.state_changed` callback so Phoenix's audit chain is keyed
to the same identity end-to-end.

`delegation_id` is opaque to Phoenix and to the smoke task — both
sides treat it as a free-form string. The on-the-wire encoding for
ZeroDev permissions (4-byte `permissionId`, 21-byte
`validationId`, or a serialized plugin blob) is deferred until the
SDK integration described in
[docs/zerodev-permissions-integration.md](zerodev-permissions-integration.md)
ships. Pre-integration grants continue to use the legacy `del_*`
placeholder shape.

### PASS

```
PASS — revoke smoke
  smart_account_id : sa_alpha_01
  delegation_id    : del_alpha_01
  state            : revoked
  last_tx_hash     : 0x...
```

Exit code 0.

> **What `state: revoked` means in the current (sentinel-era) runtime.**
> Until #58 ships, the adapter's revoke path broadcasts a no-op
> sentinel UserOp and treats a successful receipt as an **on-chain
> anchor** of the revoke intent. Phoenix transitions the delegation
> row to `:revoked` to reflect the trust downgrade — it does NOT
> imply the delegation key is cryptographically unable to sign. A
> `revoked` smoke PASS in sentinel-era means "the AA pipeline went
> end-to-end and the anchor landed", not "the authority record on
> chain has been disabled". `chain_adapter/scripts/check-env.sh`
> reports `mode: sentinel-era (awaiting ZeroDev SDK integration)`
> on every host today. Once #58 lands the cryptographic revoke (a
> `Kernel.uninstallValidation` call on the smart account itself —
> see [docs/zerodev-permissions-integration.md](zerodev-permissions-integration.md)),
> the same `state: revoked` additionally means the kernel rejected
> further user-ops from the disabled permission.

### Typical FAIL modes

| `reason`                          | Likely cause                                              |
| --------------------------------- | --------------------------------------------------------- |
| `:no_active_delegation`           | No delegation row exists for this smart account; grant first. |
| `{:delegation_not_active, state}` | Delegation is already `:revoking`, `:revoke_failed`, `:revoked`, or `:expired`. |
| `{:dispatch_failed, :adapter_unavailable}` | Adapter unreachable. |
| `{:timeout, :revoking}`           | Adapter accepted but no terminal callback yet. Check the adapter + bundler. |
| `{:revoke_failed, reason}`        | Adapter attempted the revoke but the chain-level attempt failed (send rejected, confirmation timeout, sentinel reverted, bundler hash mismatch). `reason` is the `last_reason` recorded on the delegation row. Operator must retry. |

## After a smoke run

- Review the intent replay for the created intent in the control
  tower (`/audit/replay/:intent_id`). The replay should show the full
  audit chain.
- If the smoke created test records (a "Smoke target" counterparty or
  a one-off address label), they are safe to leave in place — the
  next run reuses them by name + address.
- If a run failed partway, the transient plan stays in a
  non-terminal state. The `ConfirmExecution` safety-net poller will
  eventually age it out; for a faster reset, run the demo reset flow
  (see `docs/demo.md` once #39 lands).

## CI hook (future)

The tasks exit with status 0/1 so they compose with a deploy pipeline
once one exists. Plan: `mix bank.smoke.transfer` runs automatically
after a staging deploy, blocking the promote-to-prod step on a PASS.
