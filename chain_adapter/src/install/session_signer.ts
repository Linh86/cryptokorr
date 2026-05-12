/**
 * Server-side signing of the install UserOp's session-validator
 * portion (#kernel-account-collision follow-up, Path A).
 *
 * The browser-driven install flow needs TWO signatures on the
 * install UserOp:
 *   1. The SUDO validator's signature over the enable typed-data —
 *      produced by the user's MetaMask via `personal_sign`. This
 *      authorizes installing the permission plugin in the first
 *      place.
 *   2. The PERMISSION VALIDATOR's signature over the UserOp hash —
 *      produced HERE. ZeroDev's `PermissionValidator.signUserOperation`
 *      calls `sessionAccount.signMessage({raw: userOpHash})`. The
 *      session account's private key is the adapter's
 *      `DELEGATION_SIGNER_KEY` — Phoenix proxies the hash here so
 *      the key never leaves this process.
 *
 * The signature is an EIP-191 `personal_sign` over the raw 32-byte
 * userOpHash — that's exactly what viem's `account.signMessage({raw})`
 * produces when called from the SDK on a `privateKeyToAccount`-based
 * signer. Recover on chain via `ecrecover` matches
 * `delegationSignerKey`'s public address.
 *
 * Hard refusal posture:
 *   - input must already be a 0x-prefixed 32-byte hex string (zod
 *     schema validates upstream);
 *   - if `expectedSignerAddress` is set, refuse when the derived
 *     address mismatches (catches misrouted requests against a
 *     differently-keyed adapter);
 *   - private-key material is NEVER returned or logged.
 */

import { type Hex, type WalletClient } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { ValidationError } from "../lib/errors.js";
import { logger } from "../lib/logger.js";

export interface SignInstallSessionPortionInput {
  user_op_hash: Hex;
  session_signer_address?: string;
}

export interface SignInstallSessionPortionResult {
  signature: Hex;
  session_signer_address: string;
}

export interface SignInstallSessionPortionDeps {
  /** The configured `DELEGATION_SIGNER_KEY` (0x + 64 hex). */
  delegationSignerKey: Hex;
}

/**
 * Build the session signer's signature over a UserOp hash.
 *
 * Pure function (no I/O); throws ValidationError on shape /
 * configuration mismatches so the Fastify route maps them to a
 * 4xx response.
 */
export async function signInstallSessionPortion(
  input: SignInstallSessionPortionInput,
  deps: SignInstallSessionPortionDeps,
): Promise<SignInstallSessionPortionResult> {
  const { user_op_hash, session_signer_address } = input;
  const { delegationSignerKey } = deps;

  // Defense in depth — zod schema already enforced shape upstream,
  // but the handler is a public API; refuse anything that didn't
  // make it through.
  if (
    typeof user_op_hash !== "string" ||
    !/^0x[0-9a-fA-F]{64}$/.test(user_op_hash)
  ) {
    throw new ValidationError(
      "user_op_hash must be 0x-prefixed 32-byte hex",
      [{ path: ["user_op_hash"] }],
    );
  }

  if (
    typeof delegationSignerKey !== "string" ||
    !/^0x[0-9a-fA-F]{64}$/.test(delegationSignerKey)
  ) {
    // Misconfigured adapter — surface as a 5xx-ish ValidationError
    // so Phoenix's proxy can map to `:adapter_unavailable` and the
    // browser hook can render a clear failure reason.
    throw new ValidationError(
      "delegation signer key is not configured or has wrong shape",
      [{ path: ["delegationSignerKey"] }],
    );
  }

  const account = privateKeyToAccount(delegationSignerKey);
  const derivedAddress = account.address.toLowerCase();

  if (
    typeof session_signer_address === "string" &&
    session_signer_address.toLowerCase() !== derivedAddress
  ) {
    // Misrouted: Phoenix is asking THIS adapter to sign, but the
    // expected signer doesn't match this adapter's key. Refuse so
    // we don't silently produce a signature the browser would
    // submit and the kernel would reject. The mismatched address
    // is intentionally NOT echoed back — it could leak operator
    // topology to an attacker who probes with crafted requests.
    logger.warn("install/sign_session_portion: signer-address mismatch", {
      derived_prefix: derivedAddress.slice(0, 6) + "…",
    });
    throw new ValidationError(
      "session_signer_address does not match this adapter's DELEGATION_SIGNER_KEY",
      [{ path: ["session_signer_address"] }],
    );
  }

  // EIP-191 personal_sign over the raw 32-byte hash. Matches
  // exactly what `privateKeyToAccount(...).signMessage({raw: ...})`
  // produces — that's the call path the ZeroDev SDK takes when it
  // delegates to a normal LocalAccount.
  const signature = await account.signMessage({ message: { raw: user_op_hash } });

  return {
    signature,
    session_signer_address: account.address,
  };
}

/**
 * Test helper — returns the address derived from a candidate key
 * WITHOUT signing. Used by the contract test to assert env-shape
 * without ever calling the signing path.
 */
export function deriveSessionSignerAddress(delegationSignerKey: Hex): string {
  return privateKeyToAccount(delegationSignerKey).address;
}

// Intentionally NOT exporting a `WalletClient`-based variant — the
// SDK never needs one and exposing it tempts callers to drag the
// full account into telemetry or logs.
export type { WalletClient };
