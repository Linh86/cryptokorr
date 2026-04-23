/**
 * Revoke-delegation dispatch handler.
 *
 * v0.1 mechanics:
 *   1. Validate payload against the contract schema.
 *   2. Emit a `delegation.state_changed` callback with state=`revoking`
 *      BEFORE touching the chain so Phoenix commits to fail-closed
 *      immediately.
 *   3. Submit a sentinel on-chain transaction (see
 *      `chains/base/revoke.ts`) and emit the terminal state_changed
 *      callback once the attempt resolves — `revoked` on confirmed
 *      success only, `revoke_failed` on any chain-level failure (send
 *      rejection, confirmation timeout, sentinel revert). Phoenix
 *      never dangles in `:revoking`, and success is never conflated
 *      with failure.
 *
 * Idempotency: an in-memory set of in-flight smart_account_ids
 * suppresses duplicate on-chain sends triggered by Oban retries (the
 * original HTTP call may have succeeded past the adapter's listen
 * socket even if Phoenix recorded a timeout). Duplicates still receive
 * a fresh `revoking` callback so the Phoenix projection stays synced.
 *
 * Cryptographic revocation at the smart-account level remains
 * blocked on three concrete missing artifacts (see
 * `chains/base/revoke.ts` and `chains/base/userop.ts` for the exact
 * one-line swap): a smart-account implementation that supports
 * modules, a deployed permission-module address, and the module's
 * revoke ABI. The sentinel tx does not prevent the delegation key
 * from signing another userop. Phoenix enforces fail-closed on its
 * side for the entire window. Tracked in Phoenix issue #31.
 */

import {
  DispatchRevokeDelegationSchema,
  type DispatchRevokeDelegation,
} from "../contracts/schemas.js";
import { ValidationError } from "../lib/errors.js";
import { logger } from "../lib/logger.js";
import type { CallbackClient } from "../callbacks/client.js";
import { nextCallbackId } from "../callbacks/client.js";
import type { BaseClients } from "../chains/base/client.js";
import { executeRevoke } from "../chains/base/revoke.js";

export interface RevokeDeps {
  callbackClient: CallbackClient;
  baseClients: BaseClients;
}

export interface RevokeDispatchResult {
  accepted: true;
  smart_account_id: string;
  status: "revoking";
}

const inFlight = new Set<string>();

/** Exposed for tests — clears the in-flight registry. */
export function resetRevokeState(): void {
  inFlight.clear();
}

/**
 * Handle POST /dispatch/revoke_delegation.
 */
export async function handleRevokeDispatch(
  body: unknown,
  deps: RevokeDeps,
): Promise<RevokeDispatchResult> {
  const parsed = DispatchRevokeDelegationSchema.safeParse(body);
  if (!parsed.success) {
    throw new ValidationError(
      "Invalid revoke_delegation dispatch payload",
      parsed.error.issues,
    );
  }

  const dispatch: DispatchRevokeDelegation = parsed.data;

  logger.info("Revoke delegation dispatch received", {
    smart_account_id: dispatch.smart_account_id,
    delegation_id: dispatch.delegation_id,
    reason: dispatch.reason,
  });

  await deps.callbackClient.send({
    contract_version: 1,
    callback_id: nextCallbackId(),
    kind: "delegation.state_changed",
    smart_account_id: dispatch.smart_account_id,
    delegation_id: dispatch.delegation_id,
    state: "revoking",
    reason: dispatch.reason,
    emitted_at: new Date().toISOString(),
  });

  if (inFlight.has(dispatch.smart_account_id)) {
    logger.warn("Revoke already in flight for this smart account; skipping duplicate on-chain send", {
      smart_account_id: dispatch.smart_account_id,
    });

    return {
      accepted: true,
      smart_account_id: dispatch.smart_account_id,
      status: "revoking",
    };
  }

  inFlight.add(dispatch.smart_account_id);
  try {
    await executeRevoke(
      dispatch.smart_account_id,
      dispatch.delegation_id,
      dispatch.reason,
      deps.baseClients,
      deps.callbackClient,
    );
  } catch (err) {
    logger.error("Revoke execution ended with error", {
      smart_account_id: dispatch.smart_account_id,
      error: err instanceof Error ? err.message : String(err),
    });
  } finally {
    inFlight.delete(dispatch.smart_account_id);
  }

  return {
    accepted: true,
    smart_account_id: dispatch.smart_account_id,
    status: "revoking",
  };
}
