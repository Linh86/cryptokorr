/**
 * Grant-delegation dispatch handler (#58 grant flow).
 *
 * Mirrors the revoke dispatch shape:
 *   1. Validate payload against `DispatchGrantDelegationSchema`.
 *   2. Hand off to `executeGrant(...)`, which builds + installs a
 *      ZeroDev permission plugin and emits the
 *      `delegation.state_changed{state: "granted"}` callback.
 *   3. Return `202 accepted` regardless of on-chain outcome —
 *      callbacks carry the verdict (success: granted with
 *      permission block; failure: `grant_failed` + precise
 *      `reason`). HTTP status is acknowledgement of the dispatch
 *      only.
 *
 * Idempotency: an in-memory set of in-flight `smart_account_id`s
 * suppresses duplicate on-chain installs triggered by Oban
 * retries. Duplicate dispatches still 202 so Phoenix's
 * `GrantDelegation` worker doesn't churn into terminal failure;
 * the on-chain install side-effect happens at most once per
 * in-flight window.
 */

import {
  DispatchGrantDelegationSchema,
  type DispatchGrantDelegation,
} from "../contracts/schemas.js";
import { ValidationError } from "../lib/errors.js";
import { logger } from "../lib/logger.js";
import type { AdapterConfig } from "../config/index.js";
import type { CallbackClient } from "../callbacks/client.js";
import type { BaseClients } from "../chains/base/client.js";
import { executeGrant } from "../chains/base/grant.js";

export interface GrantDeps {
  config: AdapterConfig;
  callbackClient: CallbackClient;
  baseClients: BaseClients;
}

export interface GrantDispatchResult {
  accepted: true;
  smart_account_id: string;
  status: "installing";
}

const inFlight = new Set<string>();

/** Exposed for tests — clears the in-flight registry. */
export function resetGrantState(): void {
  inFlight.clear();
}

/**
 * Handle POST /dispatch/grant_delegation.
 */
export async function handleGrantDispatch(
  body: unknown,
  deps: GrantDeps,
): Promise<GrantDispatchResult> {
  const parsed = DispatchGrantDelegationSchema.safeParse(body);
  if (!parsed.success) {
    throw new ValidationError(
      "Invalid grant_delegation dispatch payload",
      parsed.error.issues,
    );
  }

  const dispatch: DispatchGrantDelegation = parsed.data;

  logger.info("Grant delegation dispatch received", {
    smart_account_id: dispatch.smart_account_id,
    chain_id: dispatch.chain_id,
    account: dispatch.account,
  });

  if (inFlight.has(dispatch.smart_account_id)) {
    logger.warn(
      "Grant already in flight for this smart account; skipping duplicate on-chain install",
      {
        smart_account_id: dispatch.smart_account_id,
      },
    );

    return {
      accepted: true,
      smart_account_id: dispatch.smart_account_id,
      status: "installing",
    };
  }

  inFlight.add(dispatch.smart_account_id);
  try {
    await executeGrant({
      smartAccountId: dispatch.smart_account_id,
      chainId: dispatch.chain_id,
      account: dispatch.account,
      scope: dispatch.scope,
      config: deps.config,
      clients: deps.baseClients,
      callbackClient: deps.callbackClient,
    });
  } catch (err) {
    // executeGrant emits a grant_failed callback before throwing,
    // so the request audit trail is intact. We swallow the error
    // here so the dispatch returns 202 — the contract is "callback
    // shape carries the verdict".
    logger.error("Grant execution ended with error", {
      smart_account_id: dispatch.smart_account_id,
      error: err instanceof Error ? err.message : String(err),
    });
  } finally {
    inFlight.delete(dispatch.smart_account_id);
  }

  return {
    accepted: true,
    smart_account_id: dispatch.smart_account_id,
    status: "installing",
  };
}
