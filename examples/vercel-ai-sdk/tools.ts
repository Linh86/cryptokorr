/**
 * Vercel AI SDK tool definitions wrapping the CryptoBank
 * TypeScript SDK. Drops into `generateText({...tools})` /
 * `streamText({...tools})`.
 *
 * The tools are plain `tool({...})`-shaped objects: a description,
 * a JSON-Schema-flavoured `parameters` block (the example uses
 * inline JSON Schema so it works without a Zod dependency), and an
 * `execute` function that calls the SDK and returns the result
 * verbatim. Swap to `z.object({...})` if your project already
 * depends on Zod.
 *
 * **No private keys cross the wire.** The SDK uses the bearer API
 * key from `CRYPTOBANK_API_KEY`. The browser must never see this
 * key — see `README.md`.
 *
 * **`approval_required` is a successful response.** After a write
 * tool the LLM should call `getDecision` and branch on
 * `decision.outcome`. The tool descriptions name this contract.
 */

import { Cryptobank } from "@cryptobank/sdk";
import type {
  Decision,
  IntentSubmitResult,
  IntentTarget,
} from "@cryptobank/sdk";

/**
 * Minimal tool shape compatible with `ai`'s `tool({...})` factory
 * AND with hand-rolled tool registries. The `parameters` field is
 * inline JSON Schema; if your project uses Zod, replace the schema
 * with `z.object({...})` and the body of `execute` stays
 * identical.
 */
export interface CryptobankTool<Args, Result> {
  description: string;
  parameters: { type: "object"; properties: Record<string, unknown>; required: string[] };
  execute: (args: Args) => Promise<Result>;
}

export interface SubmitTransferArgs {
  agentId?: string;
  asset?: string;
  chain?: string;
  amount: string;
  target: IntentTarget;
  notes?: string;
  smartAccountId?: string;
  idempotencyKey?: string;
}

export interface SubmitAllocateIdleCapitalArgs {
  agentId?: string;
  amount: string;
  vaultAddress: string;
  asset?: string;
  chain?: string;
  smartAccountId?: string;
  notes?: string;
  idempotencyKey?: string;
}

export interface CryptobankToolset {
  submitTransfer: CryptobankTool<SubmitTransferArgs, IntentSubmitResult>;
  submitAllocateIdleCapital: CryptobankTool<
    SubmitAllocateIdleCapitalArgs,
    IntentSubmitResult
  >;
  getDecision: CryptobankTool<{ decisionId: string }, Decision>;
}

const SUPPORTED_CHAIN = "base-sepolia";
const DEFAULT_ASSET = "USDC";

/**
 * Build the toolset. Each call constructs a fresh client from
 * `Cryptobank.fromEnv()` so the credentials stay server-side.
 *
 * Pass `client` to inject a pre-built one (e.g. for unit tests).
 */
export function buildCryptobankTools(opts: { client?: Cryptobank } = {}): CryptobankToolset {
  const client = opts.client ?? Cryptobank.fromEnv();
  const defaultAgentId = process.env["CRYPTOBANK_AGENT_ID"] ?? "agent-vercel-ai-example";

  const submitTransfer: CryptobankTool<SubmitTransferArgs, IntentSubmitResult> = {
    description:
      "Submit a USDC transfer intent on Base Sepolia. Returns the intent id + initial " +
      "state. Use getDecision after the runtime settles. approval_required is a " +
      "successful response — surface it to the operator instead of looping.",
    parameters: {
      type: "object",
      properties: {
        agentId: {
          type: "string",
          description: `Defaults to ${JSON.stringify(defaultAgentId)} when omitted.`,
        },
        asset: {
          type: "string",
          enum: [DEFAULT_ASSET],
          description: "MVP allowlist: USDC only.",
        },
        chain: {
          type: "string",
          enum: [SUPPORTED_CHAIN],
          description: "MVP: Base Sepolia only.",
        },
        amount: {
          type: "string",
          description: "Decimal string (e.g. '10.5'). Must be positive.",
        },
        target: {
          type: "object",
          description:
            "Tagged union: { counterpartyId, addressLabelId? } XOR { rawAddress }.",
        },
        notes: { type: "string" },
        smartAccountId: { type: "string" },
        idempotencyKey: { type: "string" },
      },
      required: ["amount", "target"],
    },
    execute: (args) =>
      client.submitTransfer({
        agentId: args.agentId ?? defaultAgentId,
        asset: args.asset ?? DEFAULT_ASSET,
        chain: args.chain ?? SUPPORTED_CHAIN,
        amount: args.amount,
        target: args.target,
        ...(args.notes !== undefined && { notes: args.notes }),
        ...(args.smartAccountId !== undefined && { smartAccountId: args.smartAccountId }),
        ...(args.idempotencyKey !== undefined && { idempotencyKey: args.idempotencyKey }),
      }),
  };

  const submitAllocateIdleCapital: CryptobankTool<
    SubmitAllocateIdleCapitalArgs,
    IntentSubmitResult
  > = {
    description:
      "Deposit USDC into the workspace's allowlisted Morpho ERC-4626 vault on Base " +
      "Sepolia. Returns the intent id + initial state. Use getDecision afterwards. " +
      "approval_required is a successful response — surface it to the operator.",
    parameters: {
      type: "object",
      properties: {
        agentId: {
          type: "string",
          description: `Defaults to ${JSON.stringify(defaultAgentId)} when omitted.`,
        },
        amount: {
          type: "string",
          description: "Decimal string (e.g. '10.5'). Must be positive.",
        },
        vaultAddress: {
          type: "string",
          description:
            "Allowlisted Morpho USDC vault on Base Sepolia (workspace policy verified " +
            "server-side; out-of-list vaults return morpho_vault_not_allowlisted).",
        },
        asset: {
          type: "string",
          enum: [DEFAULT_ASSET],
          description: "MVP: USDC only.",
        },
        chain: {
          type: "string",
          enum: [SUPPORTED_CHAIN],
          description: "MVP: Base Sepolia only.",
        },
        smartAccountId: { type: "string" },
        notes: { type: "string" },
        idempotencyKey: { type: "string" },
      },
      required: ["amount", "vaultAddress"],
    },
    execute: (args) =>
      client.submitAllocateIdleCapital({
        agentId: args.agentId ?? defaultAgentId,
        asset: args.asset ?? DEFAULT_ASSET,
        chain: args.chain ?? SUPPORTED_CHAIN,
        amount: args.amount,
        vaultAddress: args.vaultAddress,
        ...(args.notes !== undefined && { notes: args.notes }),
        ...(args.smartAccountId !== undefined && { smartAccountId: args.smartAccountId }),
        ...(args.idempotencyKey !== undefined && { idempotencyKey: args.idempotencyKey }),
      }),
  };

  const getDecision: CryptobankTool<{ decisionId: string }, Decision> = {
    description:
      "Fetch a CryptoBank decision envelope by id. Read decision.outcome to branch: " +
      "auto_exec (dispatched), approval_required (operator must approve — successful, " +
      "not an error), hold (waiting for data), block (terminal refusal).",
    parameters: {
      type: "object",
      properties: {
        decisionId: { type: "string", description: "Decision id (UUID)." },
      },
      required: ["decisionId"],
    },
    execute: (args) => client.getDecision(args.decisionId),
  };

  return { submitTransfer, submitAllocateIdleCapital, getDecision };
}
