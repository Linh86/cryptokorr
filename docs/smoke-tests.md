# Base smoke tests

Repeatable checks that exercise Phoenix ↔ adapter ↔ Base end-to-end
before a demo, a partner session, or a fresh staging deploy. They are
not part of `mix test` — they spend real gas and require a funded
smart account, so they live behind explicit Mix tasks.

## When to run

- After every adapter deploy that touches dispatch or callback code.
- Before starting a design-partner pilot session.
- After rotating the adapter's `ADAPTER_AUTH_SECRET` — confirms both
  sides rehydrated the new value.
- As the final gate before cutting an alpha release.

## Preconditions

1. Staging Phoenix is running and pointing at the staging adapter.
2. The adapter is running against a bundler (Base Sepolia is the
   default staging chain).
3. `ADAPTER_BASE_URL` and `ADAPTER_AUTH_SECRET` are set on the host
   that runs the smoke task (or `config/runtime.exs` env is equivalent).
4. The smart account under test:
    - Exists on chain.
    - Has been funded with enough USDC + gas to cover the smoke
      transaction.
    - Has an `:active` delegation (either pre-seeded via the API or
      granted via the control tower connection flow).

## Transfer smoke

```shell
ADAPTER_BASE_URL=https://adapter-staging.internal \
ADAPTER_AUTH_SECRET=<staging-secret> \
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
ADAPTER_AUTH_SECRET=<staging-secret> \
SMART_ACCOUNT_ID=sa_alpha_01 \
mix bank.smoke.revoke
```

### PASS

```
PASS — revoke smoke
  smart_account_id : sa_alpha_01
  delegation_id    : del_alpha_01
  state            : revoked
  last_tx_hash     : 0x...
```

Exit code 0.

### Typical FAIL modes

| `reason`                          | Likely cause                                              |
| --------------------------------- | --------------------------------------------------------- |
| `:no_active_delegation`           | No delegation row exists for this smart account; grant first. |
| `{:delegation_not_active, state}` | Delegation is already `:revoking`, `:revoked`, or `:expired`. |
| `{:dispatch_failed, :adapter_unavailable}` | Adapter unreachable. |
| `{:timeout, :revoking}`           | Adapter accepted but no on-chain revoke landed. Check the adapter + bundler. |

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
