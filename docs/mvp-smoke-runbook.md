# CryptoBank MVP smoke test (Base Sepolia)

Operator runbook for re-running the cryptographic grant + revoke
flow that closed #58 / #31 under PR #132. Repeats the proven
dance against a live local stack in <5 minutes.

Pairs with:

- [`docs/provisioning-kernel-v3.md`](provisioning-kernel-v3.md) — one-shot smart-account deploy.
- [`docs/zerodev-permissions-integration.md`](zerodev-permissions-integration.md) — on-chain shape.
- [`docs/incident-runbook.md`](incident-runbook.md) — if a smoke fails in the field.
- [`priv/adapter/contract.md`](../priv/adapter/contract.md) — Phoenix ↔ adapter contract.

## Prereqs

- Adapter `.env` populated (see [`chain_adapter/.env.example`](../chain_adapter/.env.example)). Required at minimum: `BASE_RPC_URL`, `BUNDLER_RPC_URL`, `BASE_CHAIN_ID=84532`, `SMART_ACCOUNT_ADDRESS`, `DELEGATION_SIGNER_KEY`, `OPERATOR_PRIVATE_KEY`, `OPERATOR_ADDRESS`, `ADAPTER_DISPATCH_SECRET`, `ADAPTER_CALLBACK_SECRET`, `PHOENIX_BASE_URL`.
- Phoenix running on `:4000` (`mix phx.server`).
- Adapter running on `:4100` with logs captured: `npm run dev 2>&1 | tee /tmp/cryptobank-adapter.log` from `chain_adapter/`.
- Operator EOA funded on Base Sepolia (small testnet ETH for gas, smart account funded for UserOp prefund).
- Smart account already deployed under that operator EOA per [`docs/provisioning-kernel-v3.md`](provisioning-kernel-v3.md).

## 1. Health

```sh
curl -s http://localhost:4000/health
curl -s http://localhost:4100/health
```

Expected: 200 from both.
- Phoenix: `{"status":"ok","service":"bank","version":"…"}`.
- Adapter: includes `"contract_version":1` and `"supported_chains":["base"]`.

## 2. Grant

```sh
curl -X POST http://localhost:4000/v1/connect/smart_account \
  -H 'Content-Type: application/json' \
  -d '{
    "smart_account_id": "sa_smoke_01",
    "account": "0xYourOperatorEOA",
    "chain_id": 84532,
    "delegation_payload": null
  }'
```

Expected synchronous response: `202 accepted` with body
`{"status":"accepted","smart_account_id":"sa_smoke_01","note":"…"}`.

Wait ~15s. Inspect Phoenix DB:

```sh
mix run -e 'Bank.Delegations.get("sa_smoke_01") |> IO.inspect()'
```

Expected: a `%Bank.Delegations.Delegation{}` row with
`state: :active`, `permission_id` populated (4 bytes),
`validation_id` populated (21 bytes), `kernel_version: "0.3.1"`,
`session_signer_address` populated (0x + 40 hex), `install_tx_hash`
populated (0x + 64 hex), `installed_at_block` populated.

If `state: :active` but `permission_id` is nil, the cryptographic
grant FAILED and Phoenix accepted the synchronous receipt without
an artifact. Read `/tmp/cryptobank-adapter.log` for the
`grant_failed` callback `reason` code:

| `reason` | What to check |
| --- | --- |
| `operator_key_missing` | `OPERATOR_PRIVATE_KEY` / `OPERATOR_ADDRESS` not set, placeholder, or mismatched derivation. |
| `chain_id_mismatch` | Adapter `BASE_CHAIN_ID` differs from the dispatch's `chain_id`. |
| `permission_install_failed` | Bundler rejected the install UserOp. Check bundler URL, smart-account funding, kernel state. |
| `permission_serialization_failed` | `serializePermissionAccount(...)` threw. Check `@zerodev/permissions` package version + adapter logs. |

## 3. Revoke

```sh
curl -X POST http://localhost:4000/v1/security/revoke_delegation \
  -H 'Content-Type: application/json' \
  -d '{
    "smart_account_id": "sa_smoke_01",
    "reason": "smoke_test"
  }'
```

Expected synchronous response: `202` with body
`{"status":"revoke_enqueued","smart_account_id":"sa_smoke_01"}`.

Wait ~15s. Inspect Phoenix DB:

```sh
mix run -e '
import Ecto.Query
Bank.Repo.one(from d in Bank.Delegations.Delegation,
  where: d.smart_account_id == "sa_smoke_01",
  order_by: [desc: d.inserted_at], limit: 1)
|> IO.inspect()'
```

(`Bank.Delegations.get/1` returns `nil` for terminal rows, so the
direct query is what surfaces `:revoked`.)

Expected: row `state: :revoked`, `last_tx_hash` populated. The
adapter log shows the revoke UserOp hash, the kernel's
`uninstallValidation` userOp, and the receipt.

If `state: :revoke_failed`, read the callback `reason` code:

| `reason` | What to check |
| --- | --- |
| `operator_key_missing` | Same as grant — operator key absent or invalid. |
| `validation_id_mismatch` | `validation_id` does not equal `0x02 ‖ rightPad(permission_id, 20)`. Database corruption or schema drift. |
| `package_version_mismatch` | Adapter's pinned `@zerodev/permissions` version differs from the one persisted with the grant. |
| `session_signer_missing` | `session_signer_address` absent on the row (keyless blob requires it). |
| `unaccepted_signer_module` | Blob references a signer module outside `KERNEL_PERMISSION_PIN.acceptedSignerContracts`. |
| `unaccepted_policy_module` | Blob references a policy module outside `KERNEL_PERMISSION_PIN.acceptedPolicyContracts` (or empty list). |
| `permission_deserialization_failed` | `deserializePermissionAccount(...)` threw. Likely persisted-blob / SDK-version mismatch. |
| `deinit_computation_failed` | `getEnableData(...)` threw. Verify the stub signer + policy chain. |
| `uninstall_validation_reverted` | UserOp made it on chain but reverted. Check the receipt + kernel state. |

## 4. Public proof

The currently-pinned smoke proof (PR #132):

- smart account: `0xacb3390BF0E13eB0755317Fbb2C73Ed185F4142C`
- permission id: `0xbb2f68d9`
- validation id: `0x02bb2f68d900000000000000000000000000000000`
- install tx: `0xbbb3a2e8ae78e6c7c4ce6fb5c69f735baaf3af346ffd5b2ff7954724db39891a`
- revoke userOp: `0x478ec3b1e9fc76f5aa1d523024ce0e7d10922125fdc8da750d40cca004e069e7`
- revoke tx: `0xf81c969dafc25eccd0dccad0379317ec64b66916a45cdb9fae8c38e31d795ceb`
- revoke block: `40820243`

A successful smoke produces NEW tx hashes; record them in the
deployment journal alongside the operator EOA, smart-account
address, kernel version, and timestamp.

## 5. Failure triage

| Phoenix state | Likely adapter callback `reason` | What to check |
| --- | --- | --- |
| `:pending` (no transition after 30s) | (no callback yet) | Adapter not running, dispatch route bearer mismatch, or worker stuck. Check `/tmp/cryptobank-adapter.log`. |
| `:active`, `permission_id` nil | `grant_failed` reasons (Step 2 table) | Cryptographic grant did not produce artifacts; review the `grant_failed` callback. |
| `:revoking` (stuck) | (no terminal callback) | Adapter accepted dispatch but never confirmed. Check bundler health + adapter log. |
| `:revoke_failed` | Step 3 table | Match the callback `reason` to the table; remediate, then re-issue `POST /v1/security/revoke_delegation`. |
| `:revoked`, `last_tx_hash` set | n/a | Success — record the new tx hashes. |

If the cryptographic path fails closed and you need to clear the
delegation regardless, the operator escape hatch is to rotate the
smart account's owner off chain (see
[`docs/incident-runbook.md`](incident-runbook.md)) — the adapter
does NOT silently downgrade to the legacy sentinel revoke when a
`permission` block is present and the cryptographic path refuses.
