# `examples/vercel-ai-sdk/` — Vercel AI SDK tool definition (TypeScript SDK)

A copy-pastable Vercel AI SDK tool that wraps the **CryptoKorr
TypeScript SDK** (`@cryptokorr/sdk`). Drops into any
`generateText` / `streamText` call so an LLM can submit treasury
intents on Base Sepolia and the agent reads
`Decision.outcome` to handle `approval_required` correctly.

The example pins three tools that map 1:1 to SDK methods:

- `submitTransfer` — submit a USDC transfer intent.
- `submitAllocateIdleCapital` — deposit USDC into the workspace's
  allowlisted Morpho vault.
- `getDecision` — fetch the current decision envelope (used by
  the LLM after a write tool to surface the outcome).

A small mocked-fetch test pins the tool definitions' shape so a
future SDK or Vercel AI SDK version drift fails CI loudly. The
test does not hit any network.

## Scope

- **Base Sepolia only** (`chain: "base-sepolia"`). Mainnet
  (`base`) is post-MVP and surfaces as a typed
  `mainnet_disabled` error.
- **Server-side execution only.** The TypeScript SDK uses your
  workspace API key (`cb_<...>`); never embed it in browser /
  client-side code. The supported pattern is:
    1. The browser talks to **your** backend.
    2. Your backend authenticates the end user.
    3. Your backend uses this SDK to submit the intent.
- **`approval_required` is a successful response**, not an error.
  The example surfaces it explicitly so the LLM hands off to the
  operator instead of looping.
- **No paymaster / sponsored gas, no multi-account selector, no
  arbitrary contract calls** — the TS SDK doesn't expose those
  surfaces.

## Prerequisites

- Node **18+** (the SDK uses native `fetch` and
  `globalThis.crypto`).
- A workspace API key (`cb_<...>`) in `CRYPTOKORR_API_KEY`.
- A running CryptoKorr backend (default `http://localhost:4000`).

The Vercel AI SDK itself (`ai` package) is **not** required to
build the tool definitions — they are plain `tool({ ... })`
wrappers that work with any AI SDK version that exports `tool` and
accepts a Zod (or zod-like) schema. The example's smoke tests use
a tiny shape-checker so they run without installing `ai` or
`zod`.

## Install

```sh
cd examples/vercel-ai-sdk
npm install
```

The example installs the local TypeScript SDK from the repo
(`file:../../sdks/typescript`). To use the published package,
swap the `dependencies` entry to `"@cryptokorr/sdk": "^0.1.0"`.

## Environment variables

| Variable                  | Required | Purpose                                                          |
| ------------------------- | -------- | ---------------------------------------------------------------- |
| `CRYPTOKORR_API_KEY`      | yes      | Workspace API key (`cb_<...>`). Never log or commit this.        |
| `CRYPTOKORR_BASE_URL`     | no       | Defaults to `http://localhost:4000`.                            |
| `CRYPTOKORR_AGENT_ID`     | no       | Defaults to `agent-vercel-ai-example`. Used as the tool's        |
|                           |          | `agentId` field unless the LLM passes one.                       |

The example deliberately reads the API key from env so it never
lands in source control.

## Run

```sh
export CRYPTOKORR_API_KEY="cb_..."
node --experimental-strip-types ./demo.ts   # Node 22+
# or compile first: npx tsc -p tsconfig.json && node ./dist/demo.js
```

`demo.ts` builds a `CryptoKorr` client from `fromEnv()`, defines
the three tools, and prints their shape so you can copy them
straight into your `generateText({...tools})` call.

## Expected output

```
[demo]      CryptoKorr client ready
            base url   = http://localhost:4000
            tools      = ["submitTransfer", "submitAllocateIdleCapital", "getDecision"]

[demo]      submitTransfer.description:
            Submit a USDC transfer intent on Base Sepolia. Returns the
            intent id + initial state. Use getDecision after the runtime
            settles. approval_required is a successful response.

[demo]      submitAllocateIdleCapital.description:
            Deposit USDC into the workspace's allowlisted Morpho ERC-4626
            vault on Base Sepolia. Returns the intent id + initial state.
```

## Wire it into `generateText`

```ts
import { generateText } from "ai";
import { buildCryptoKorrTools } from "./tools.js";

const tools = await buildCryptoKorrTools();

const result = await generateText({
  model: yourModel,
  prompt: "Move 10 USDC into the idle-capital vault for agent-alice.",
  tools,
});
```

The LLM picks the right tool, fills in the arguments, and calls
the SDK on your behalf. The tool's `execute` returns the SDK
result verbatim (camelCase) so the LLM can switch on
`decision.outcome` and respond.

## Approval-required handling

After a write tool, the LLM should call `getDecision` with the
`intentId` (or the helper polling pattern below) and branch on
`decision.outcome`:

| `decision.outcome`     | Meaning                                     | LLM response pattern                              |
| ---------------------- | ------------------------------------------- | ------------------------------------------------- |
| `auto_exec`            | Runtime auto-dispatched.                    | "Done — dispatched on Base Sepolia."              |
| `approval_required`    | **Successful**, waiting for operator.       | "Submitted; waiting for operator approval."       |
| `hold`                 | Runtime needs more data.                    | "Held; the operator is refreshing."               |
| `block`                | Terminal refusal.                           | "Refused: …" (surface `decision.reasons`).        |

The tool definitions include a short docstring on each `execute`
so the LLM knows it must read `decision.outcome` and **never** treat
`approval_required` as an error.

## Safety notes

- **Workspace API keys are server-side credentials.** Anyone with
  view of your browser bundle can act as your workspace. Never
  embed `cb_<...>` in client-side code.
- **The Vercel AI SDK runs server-side in this example.** Use
  it from a Next.js Route Handler, an Edge function with
  appropriate secrets storage, or a Node service — not directly
  from a `"use client"` component.
- **Base Sepolia (`84532`) only.** The runtime rejects mainnet
  writes with `mainnet_disabled` unless the workspace flag is on.
- **No paymaster / sponsored gas.** The smart account pays.
- **No private keys, no signed payloads.** Only the Bearer API
  key crosses the wire.

## Smoke

The static smoke under `examples/test/` parses this README's env
var table, confirms `tools.ts` imports from the documented SDK
package name, and refuses any banned mainnet / paymaster /
unlimited-token claim. Run from the repo root:

```sh
python3 -m unittest discover -s examples/test
```

Mocked-fetch shape tests live in `examples/vercel-ai-sdk/test/`:

```sh
cd examples/vercel-ai-sdk
npm test
```
