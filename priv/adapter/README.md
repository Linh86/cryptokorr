# TypeScript Adapter Contract (v0.1)

The Phoenix control plane and the TypeScript execution adapter are
separate services. This directory is the **control-plane side of the
contract** between them:

- `contract.md` — the message schema, lifecycle, and failure semantics.
- `fixtures/` — canonical JSON examples used by Elixir and TS tests
  to stay in sync.

The adapter source lives in a separate repo; its tests load these
same fixtures to verify its serialisation.

Non-goals for v0.1:

- Multi-chain dispatch. Only Base is in scope.
- Multi-asset dispatch. Only USDC transfers and whitelisted swaps.
- Multi-node control plane. One Phoenix node per deployment.

If you are extending the contract, update both `contract.md` and the
corresponding fixture in lockstep — the acceptance tests load the
fixtures by path.
