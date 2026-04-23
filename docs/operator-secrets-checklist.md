# Operator Secrets Checklist for Base Sepolia

Plain-language checklist for a non-developer operator preparing the
secrets and config needed before Kernel v3 provisioning and real
on-chain delegation revoke testing.

Pairs with:

- [docs/provisioning-kernel-v3.md](provisioning-kernel-v3.md) — the
  full provisioning runbook.
- [docs/deploy.md](deploy.md) — generic deployment procedure.
- [`chain_adapter/.env.example`](../chain_adapter/.env.example) — the
  runtime env template the adapter expects.

This checklist is intentionally split into:

- **real secrets** — never paste these into chat, tickets, or Git
- **sensitive config** — not a private key, but still should live in a
  secret store because it may contain provider credentials
- **public values** — safe to share inside the team when needed

## What you are preparing

You are getting ready for a future Base Sepolia test run. The goal is
to have everything ready so the later provisioning and revoke test is
mostly operational work, not more setup work.

## Where to store everything

Create one secure record in your password manager or secret store, for
example:

`CryptoBank / Base Sepolia / Chain Adapter`

Recommended fields:

- `ADAPTER_DISPATCH_SECRET`
- `ADAPTER_CALLBACK_SECRET`
- `OPERATOR_PRIVATE_KEY`
- `OPERATOR_ADDRESS`
- `DELEGATION_SIGNER_KEY`
- `DELEGATION_SIGNER_PUBKEY`
- `BASE_RPC_URL`
- `BUNDLER_RPC_URL`
- `PHOENIX_BASE_URL`
- `KERNEL_FACTORY_ADDRESS`
- `PERMISSION_VALIDATOR_ADDRESS`
- `SMART_ACCOUNT_ADDRESS`

## Real secrets you must protect

These must never be committed to Git or pasted into chat:

- `ADAPTER_DISPATCH_SECRET`
- `ADAPTER_CALLBACK_SECRET`
- `OPERATOR_PRIVATE_KEY`
- `DELEGATION_SIGNER_KEY`

Rules:

- `OPERATOR_PRIVATE_KEY` and `DELEGATION_SIGNER_KEY` must be different
  keys.
- `ADAPTER_DISPATCH_SECRET` and `ADAPTER_CALLBACK_SECRET` must be
  different values.

## Step-by-step

### 1. Create `ADAPTER_DISPATCH_SECRET`

This is the bearer secret Phoenix uses when it calls the adapter.

Generate it locally:

```bash
openssl rand -hex 32
```

Save the output as `ADAPTER_DISPATCH_SECRET`.

### 2. Create `ADAPTER_CALLBACK_SECRET`

This is the bearer secret the adapter uses when it calls Phoenix back.

Generate a second, different value:

```bash
openssl rand -hex 32
```

Save the output as `ADAPTER_CALLBACK_SECRET`.

### 3. Create the operator wallet

Create a fresh EVM wallet account used only for provisioning the smart
account and installing the validator.

Suggested label:

`CryptoBank Operator Sepolia`

Then:

1. export its private key
2. save it as `OPERATOR_PRIVATE_KEY`
3. save its public address as `OPERATOR_ADDRESS`

Do **not** reuse your personal wallet here.

### 4. Fund the operator wallet

Send Base Sepolia ETH to `OPERATOR_ADDRESS`.

This account needs gas for:

- smart-account deployment
- validator installation
- verification retries if something goes wrong

### 5. Create the delegation signer wallet

Create a second fresh EVM wallet account used for runtime delegation
signing.

Suggested label:

`CryptoBank Delegation Signer Sepolia`

Then:

1. export its private key
2. save it as `DELEGATION_SIGNER_KEY`
3. save its public address as `DELEGATION_SIGNER_PUBKEY`

This key must **not** match `OPERATOR_PRIVATE_KEY`.

### 6. Obtain `BASE_RPC_URL`

Get a Base Sepolia RPC endpoint from your provider.

Save the full endpoint as `BASE_RPC_URL`.

Treat it as sensitive config because the URL may contain an API key.

### 7. Obtain `BUNDLER_RPC_URL`

Get an ERC-4337 v0.7 bundler endpoint for Base Sepolia.

Save the full endpoint as `BUNDLER_RPC_URL`.

Treat it as sensitive config for the same reason as the RPC URL.

### 8. Record `PHOENIX_BASE_URL`

This is the base URL of the Phoenix app the adapter calls back into.

Example:

```text
https://staging.example.com
```

Save it as `PHOENIX_BASE_URL`.

### 9. Prepare `KERNEL_FACTORY_ADDRESS`

This is a public on-chain address, not a secret.

Look up the official Kernel v3 factory deployment for Base Sepolia and
save it as `KERNEL_FACTORY_ADDRESS`.

If you do not have the verified vendor source yet, leave the field
blank for now instead of inventing a placeholder.

### 10. Prepare `PERMISSION_VALIDATOR_ADDRESS`

This is also a public on-chain address, not a secret.

Look up the Permission Validator deployment for Base Sepolia and save it
as `PERMISSION_VALIDATOR_ADDRESS`.

If the validator deployment has not yet been chosen or verified, leave
the field blank for now.

### 11. Leave `SMART_ACCOUNT_ADDRESS` empty for now

Do not invent this value.

`SMART_ACCOUNT_ADDRESS` is produced later by the provisioning run and
should be filled in only after that run succeeds.

## What goes where later

| Field | Type | Used by |
| --- | --- | --- |
| `ADAPTER_DISPATCH_SECRET` | secret | Phoenix and adapter |
| `ADAPTER_CALLBACK_SECRET` | secret | Phoenix and adapter |
| `OPERATOR_PRIVATE_KEY` | secret | provisioning only |
| `OPERATOR_ADDRESS` | public helper | operator notebook / funding |
| `DELEGATION_SIGNER_KEY` | secret | adapter runtime |
| `DELEGATION_SIGNER_PUBKEY` | public | provisioning |
| `BASE_RPC_URL` | sensitive config | provisioning and adapter runtime |
| `BUNDLER_RPC_URL` | sensitive config | provisioning and adapter runtime |
| `PHOENIX_BASE_URL` | config | adapter runtime |
| `KERNEL_FACTORY_ADDRESS` | public | provisioning |
| `PERMISSION_VALIDATOR_ADDRESS` | public | provisioning and later runtime |
| `SMART_ACCOUNT_ADDRESS` | public | runtime after provisioning |

## Minimum ready state before testing

You are ready for the next step when you have all of these:

- two different bearer secrets
- two different wallet private keys
- one funded operator wallet on Base Sepolia
- one delegation signer public address
- one Base Sepolia RPC endpoint
- one Base Sepolia ERC-4337 bundler endpoint
- the Phoenix base URL

The following can remain blank until the chain-side provisioning run:

- `SMART_ACCOUNT_ADDRESS`
- `KERNEL_FACTORY_ADDRESS` if not yet confirmed
- `PERMISSION_VALIDATOR_ADDRESS` if not yet confirmed

## Safety rules

- Never paste private keys or secrets into chat.
- Never commit any of these values into the repo.
- Never reuse the same key for operator funding and delegation signing.
- If you are unsure whether a value is real, leave it blank instead of
  writing a placeholder and forgetting about it later.
