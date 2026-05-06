# Changelog — `cryptobank` (Python SDK)

All notable changes to the Python SDK ship in this file. Versioning
follows [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

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

- Sync `Cryptobank` client and async `AsyncCryptobank` client with
  identical method names.
- Workspace-scoped auth via `CRYPTOBANK_API_KEY` / constructor
  argument.
- Intent submission: `submit_transfer`, `submit_swap`,
  `submit_allocate_idle_capital`. Wire `kind` is `allocate_idle_capital`
  for the Morpho ERC-4626 deposit.
- Intent inspection: `get_intent`, `simulate_intent`, `cancel_intent`,
  `get_audit_trail`.
- Decision flow: `get_decision`, `wait_for_decision` (treats
  `approval_required` as a successful result, not an exception).
- Counterparties (`list_counterparties`), runtime status
  (`get_runtime_status`), and policy (`get_policy`, `list_policies`).
- Operator namespace at `client.operator.*` for approve/reject + pause/
  resume.
- Typed exception hierarchy keyed off the wire `error.code`
  (`APIError → AuthenticationError / AuthorizationError /
  ValidationError → SwapSafetyError / MorphoSafetyError / NotFoundError /
  ConflictError → IdempotencyConflictError / WrongStateError /
  RateLimitError / ServiceUnavailableError → WorkspacePausedError /
  ChainPausedError / UpstreamError`). Matches
  [`docs/api/error-codes.md`](../../docs/api/error-codes.md).
- Idempotency keys: auto-generated UUID v4 per write, replays surface
  `idempotent_replay: true` instead of raising.
- Retry posture: only on `retryable: true` codes, never for
  `/v1/security/*`, never on non-idempotent calls. Exponential backoff
  capped at 30s, total wall-clock bounded at `timeout × 4`.
- Secret hygiene: API key never logged, never in error messages, never
  in `repr()`.

### Notes

- MVP scope: Base Sepolia (`chain="base-sepolia"`) and USDC. Mainnet
  surfaces as `mainnet_disabled` until the workspace flag is set.
- Zero runtime dependencies (stdlib `urllib.request` for HTTP).

### Known limitations

- `simulate_intent` and `cancel_intent` rely on `/v1/intents/:id/{simulate,cancel}` being live; the routes exist but the engines complete progressively.
- Withdraw / redeem from Morpho is intentionally absent — operator-only via the LiveView.

[0.1.0]: https://github.com/Linh86/cryptobank/releases/tag/cryptobank-py-0.1.0
[Unreleased]: https://github.com/Linh86/cryptobank/compare/cryptobank-py-0.1.0...HEAD
