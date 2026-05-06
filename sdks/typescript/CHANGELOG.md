# Changelog — `@cryptobank/sdk` (TypeScript SDK)

All notable changes to the TypeScript SDK ship in this file.
Versioning follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

The SDK is pinned against the `/v1/*` API contract; breaking changes to
that contract roll the SDK's major version, additive changes roll the
minor.

## [Unreleased]

## [0.1.0] — initial MVP foundation

First publishable revision of the SDK. Implements the full method
surface pinned in
[`docs/api/sdk-surface.md`](../../docs/api/sdk-surface.md) against the
v1 API contract.

### Added

- ESM `Cryptobank` class with workspace-scoped auth via
  `CRYPTOBANK_API_KEY` / constructor option.
- Intent submission: `submitTransfer`, `submitSwap`,
  `submitAllocateIdleCapital`. Wire `kind` is `allocate_idle_capital`
  for the Morpho ERC-4626 deposit.
- Intent inspection: `getIntent`, `simulateIntent`, `cancelIntent`,
  `getAuditTrail`.
- Decision flow: `getDecision`, `waitForDecision` (treats
  `approval_required` as a successful response, not a thrown error).
- Counterparties (`listCounterparties`), runtime status
  (`getRuntimeStatus`), and policy (`getPolicy`).
- Operator namespace at `client.operator.*` for approve/reject + pause/
  resume.
- Typed error hierarchy keyed off the wire `error.code`
  (`APIError → AuthenticationError / AuthorizationError /
  ValidationError → SwapSafetyError / MorphoSafetyError / NotFoundError /
  ConflictError → IdempotencyConflictError / WrongStateError /
  RateLimitError / ServiceUnavailableError → WorkspacePausedError /
  ChainPausedError / UpstreamError`). Matches
  [`docs/api/error-codes.md`](../../docs/api/error-codes.md).
- Idempotency keys: auto-generated UUID v4 per write, replays surface
  `idempotentReplay: true` instead of throwing.
- Retry posture: only on `retryable: true` codes, never for
  `/v1/security/*`, never on non-idempotent calls. Exponential backoff
  capped at 30s, total wall-clock bounded at `timeoutMs × 4`.
- Secret hygiene: API key never logged, never in error messages, never
  in `toString()`. A `cb_<...>` redactor scrubs every string the SDK
  surfaces.

### Notes

- MVP scope: Base Sepolia (`chain: "base-sepolia"`) and USDC. Mainnet
  surfaces as `mainnet_disabled` until the workspace flag is set.
- Targets Node 18+ — uses native `fetch` and `globalThis.crypto`.
- No runtime dependencies; `tsc -p tsconfig.build.json` produces a dual
  ESM + types build under `dist/`.

### Browser usage

Workspace API keys are operator credentials. The SDK is for
**server-side use only** (Node service, edge function, serverless
handler). The browser-driven non-custodial onboarding lives behind the
wallet flow described in `docs/wallet-quickstart.md`.

### Known limitations

- `simulateIntent` and `cancelIntent` rely on
  `/v1/intents/:id/{simulate,cancel}` being live; the routes exist but
  the engines complete progressively.
- Withdraw / redeem from Morpho is intentionally absent — operator-only
  via the LiveView.

[0.1.0]: https://github.com/Linh86/cryptobank/releases/tag/cryptobank-ts-0.1.0
[Unreleased]: https://github.com/Linh86/cryptobank/compare/cryptobank-ts-0.1.0...HEAD
