/**
 * Test fixture loader.
 *
 * Mirrors the canonical JSON fixtures from the Phoenix repo at
 * priv/adapter/fixtures/. Tests load these to verify that our Zod
 * schemas accept the exact shapes Phoenix produces.
 *
 * If these fixtures change in Phoenix and the adapter is not updated,
 * contract tests will fail — which is the point.
 */

import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

/** Path to the Phoenix repo's fixture directory. */
const PHOENIX_FIXTURES_DIR = join(
  __dirname,
  "..",
  "..",
  "..",
  "priv",
  "adapter",
  "fixtures",
);

function loadFixture<T>(filename: string): T {
  const content = readFileSync(join(PHOENIX_FIXTURES_DIR, filename), "utf-8");
  return JSON.parse(content) as T;
}

// ---- Dispatch fixtures ----

export const dispatchTransfer = loadFixture("dispatch_transfer.json");
export const dispatchSwap = loadFixture("dispatch_swap.json");
export const dispatchRevokeDelegation = loadFixture(
  "dispatch_revoke_delegation.json",
);
export const dispatchGrantDelegation = loadFixture(
  "dispatch_grant_delegation.json",
);

// ---- Callback fixtures ----

export const callbackExecutionBroadcast = loadFixture(
  "callback_execution_broadcast.json",
);
export const callbackExecutionConfirmed = loadFixture(
  "callback_execution_confirmed.json",
);
export const callbackExecutionReverted = loadFixture(
  "callback_execution_reverted.json",
);
export const callbackExecutionAborted = loadFixture(
  "callback_execution_aborted.json",
);
export const callbackDelegationStateChanged = loadFixture(
  "callback_delegation_state_changed.json",
);
export const callbackDelegationGranted = loadFixture(
  "callback_delegation_granted.json",
);
