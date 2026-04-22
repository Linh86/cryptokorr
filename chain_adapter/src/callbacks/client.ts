/**
 * Callback client — delivers adapter outcomes to Phoenix.
 *
 * POST {phoenix_base}/internal/adapter/callback
 *
 * The client validates outgoing payloads against their Zod schema
 * before sending so contract drift fails at the adapter, not at Phoenix.
 */

import type { AdapterConfig } from "../config/index.js";
import {
  CallbackSchemasByKind,
  type CallbackPayload,
} from "../contracts/schemas.js";
import { CallbackError } from "../lib/errors.js";
import { logger } from "../lib/logger.js";

export interface CallbackClient {
  send(payload: CallbackPayload): Promise<void>;
}

/**
 * Monotonic callback id generator.
 * Each adapter process instance has its own counter.
 */
let callbackSeq = 0;
export function nextCallbackId(): string {
  callbackSeq += 1;
  return `cb_${String(callbackSeq).padStart(4, "0")}`;
}

/** Reset for tests. */
export function resetCallbackSeq(): void {
  callbackSeq = 0;
}

/**
 * Create the real HTTP callback client.
 */
export function createCallbackClient(config: AdapterConfig): CallbackClient {
  const url = `${config.phoenixBaseUrl}/internal/adapter/callback`;
  const secret = config.callbackAuthSecret;

  return {
    async send(payload: CallbackPayload): Promise<void> {
      // Validate outgoing shape — fail loud at the adapter.
      const schema = CallbackSchemasByKind[payload.kind];
      const parsed = schema.safeParse(payload);
      if (!parsed.success) {
        logger.error("Outgoing callback failed self-validation", {
          kind: payload.kind,
          errors: parsed.error.issues,
        });
        throw new CallbackError(
          `Callback self-validation failed for ${payload.kind}: ${parsed.error.message}`,
        );
      }

      logger.info("Sending callback to Phoenix", {
        kind: payload.kind,
        url,
        callback_id: payload.callback_id,
      });

      try {
        const response = await fetch(url, {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            Authorization: `Bearer ${secret}`,
          },
          body: JSON.stringify(payload),
        });

        if (!response.ok) {
          const body = await response.text().catch(() => "(no body)");
          throw new CallbackError(
            `Phoenix returned ${response.status}: ${body}`,
          );
        }

        logger.info("Callback delivered", {
          kind: payload.kind,
          callback_id: payload.callback_id,
          status: response.status,
        });
      } catch (err) {
        if (err instanceof CallbackError) throw err;
        const message = err instanceof Error ? err.message : String(err);
        throw new CallbackError(`Callback delivery failed: ${message}`);
      }
    },
  };
}

/**
 * In-memory callback client for tests.
 * Collects payloads so tests can assert on them.
 */
export function createTestCallbackClient(): CallbackClient & {
  payloads: CallbackPayload[];
  clear(): void;
} {
  const payloads: CallbackPayload[] = [];
  return {
    payloads,
    clear() {
      payloads.length = 0;
    },
    async send(payload: CallbackPayload): Promise<void> {
      // Still validate — tests should catch bad shapes too.
      const schema = CallbackSchemasByKind[payload.kind];
      const parsed = schema.safeParse(payload);
      if (!parsed.success) {
        throw new CallbackError(
          `Test callback self-validation failed for ${payload.kind}: ${parsed.error.message}`,
        );
      }
      payloads.push(payload);
    },
  };
}
