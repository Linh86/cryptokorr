/**
 * Zod schemas for the Phoenix ↔ Adapter contract (v1).
 *
 * These are the source of truth for request/response validation.
 * They MUST match the JSON fixtures in priv/adapter/fixtures/.
 * Contract tests verify this at build time.
 */

import { z } from "zod";

// -------------------------------------------------------------------------
// Shared primitives
// -------------------------------------------------------------------------

const uuid = z.string().uuid();
const hexAddress = z.string().regex(/^0x[0-9a-fA-F]+$/);
const decimalString = z.string().regex(/^\d+(\.\d+)?$/);
const rfc3339 = z.string().datetime({ offset: true });

// -------------------------------------------------------------------------
// Dispatch: Phoenix → Adapter
// -------------------------------------------------------------------------

/** POST /dispatch/transfer */
export const DispatchTransferSchema = z.object({
  contract_version: z.literal(1),
  action: z.literal("transfer"),
  execution_plan_id: uuid,
  intent_id: uuid,
  smart_account_id: z.string().min(1),
  chain: z.string().min(1),
  asset: z.string().min(1),
  amount: decimalString,
  target: z.object({
    address: hexAddress,
    counterparty_id: uuid.nullable(),
  }),
  signing_requirements: z.object({
    delegation_id: z.string().min(1),
    scope: z.record(z.unknown()),
  }),
  correlation_id: uuid,
  emitted_at: rfc3339,
});
export type DispatchTransfer = z.infer<typeof DispatchTransferSchema>;

/** POST /dispatch/swap */
export const DispatchSwapSchema = z.object({
  contract_version: z.literal(1),
  action: z.literal("swap"),
  execution_plan_id: uuid,
  intent_id: uuid,
  smart_account_id: z.string().min(1),
  chain: z.string().min(1),
  input_asset: z.string().min(1),
  output_asset: z.string().min(1),
  input_amount: decimalString,
  expected_output: decimalString,
  slippage_bps: z.number().int().nonnegative(),
  route: z.object({
    venue: z.string().min(1),
    path: z.array(z.string()),
  }),
  signing_requirements: z.object({
    delegation_id: z.string().min(1),
    scope: z.record(z.unknown()),
  }),
  correlation_id: uuid,
  emitted_at: rfc3339,
});
export type DispatchSwap = z.infer<typeof DispatchSwapSchema>;

/**
 * Permission block (#58). Optional sibling field on the revoke
 * dispatch carrying the data the cryptographic revoke needs to
 * reconstruct the ZeroDev plugin and build the
 * `Kernel.uninstallValidation(...)` UserOp.
 *
 * Shape:
 *   * `blob` — `serializePermissionAccount(...)` output (base64
 *     string). Adapter feeds it back to
 *     `deserializePermissionAccount(...)` to rebuild the same plugin
 *     the grant flow installed. Stored verbatim by Phoenix; opaque to
 *     the wire.
 *   * `permission_id` — 0x-prefixed 4-byte hex (10 chars). The 4-byte
 *     ZeroDev permissionId; denormalized for audit / diagnostics.
 *   * `validation_id` — 0x-prefixed 21-byte hex (44 chars). The
 *     `bytes21 vId` value `Kernel.uninstallValidation(...)` consumes:
 *     `0x02 ‖ rightPad(permissionId, 20)`. Adapter validates this
 *     matches the permissionId before broadcasting.
 *   * `kernel_version` — kernel implementation version (e.g.
 *     `"0.3.1"`). Pinned at grant-time so a future kernel upgrade is
 *     not silently reconciled against an old blob.
 *   * `package_version` — `@zerodev/permissions` package version the
 *     blob was produced under. Adapter refuses if it differs from
 *     `KERNEL_PERMISSION_PIN.zeroDevPermissionsPackageVersion` —
 *     fail-closed posture against package drift.
 *
 * Absent → adapter takes the sentinel path. Present → adapter
 * attempts cryptographic revoke and fails closed
 * (`state=revoke_failed`) if it cannot honor the block; never
 * silently downgrades to sentinel.
 */
export const PermissionBlockSchema = z.object({
  blob: z.string().min(1),
  permission_id: z
    .string()
    .regex(/^0x[0-9a-fA-F]{8}$/, "permission_id must be 0x + 8 hex chars (4 bytes)"),
  validation_id: z
    .string()
    .regex(/^0x[0-9a-fA-F]{42}$/, "validation_id must be 0x + 42 hex chars (21 bytes)"),
  kernel_version: z.string().min(1),
  package_version: z.string().min(1),
});
export type PermissionBlock = z.infer<typeof PermissionBlockSchema>;

/** POST /dispatch/revoke_delegation */
export const DispatchRevokeDelegationSchema = z.object({
  contract_version: z.literal(1),
  action: z.literal("revoke_delegation"),
  smart_account_id: z.string().min(1),
  // Opaque identifier that Phoenix has already stored against the
  // delegation row. The adapter echoes it into callbacks today and
  // does not parse it. New rows under #58 carry the 4-byte
  // permissionId hex (10 chars) here for human readability; the
  // adapter's actual revoke driver consumes `permission.validation_id`
  // instead.
  delegation_id: z.string().min(1),
  reason: z.string().min(1),
  // Optional `permission` block carrying the cryptographic revoke
  // payload (#58). Backwards-compatible: absent on legacy sentinel
  // rows whose grant flow predates this field.
  permission: PermissionBlockSchema.optional(),
  correlation_id: z.string().nullable(),
  emitted_at: rfc3339,
});
export type DispatchRevokeDelegation = z.infer<typeof DispatchRevokeDelegationSchema>;

// -------------------------------------------------------------------------
// Callbacks: Adapter → Phoenix
// -------------------------------------------------------------------------

const TxRefSchema = z
  .object({
    chain: z.string().min(1),
    hash: z.string().min(1).optional(),
    userop_hash: z.string().min(1).optional(),
    nonce: z.union([z.number().int(), z.string().min(1)]).optional(),
    block_number: z.number().int().optional(),
    status: z.string().optional(),
    bundler: z.string().min(1).optional(),
  })
  .refine((ref) => ref.hash !== undefined || ref.userop_hash !== undefined, {
    message: "tx_ref must include either `hash` or `userop_hash`",
    path: ["hash"],
  });
export type TxRef = z.infer<typeof TxRefSchema>;

export const CallbackExecutionBroadcastSchema = z.object({
  contract_version: z.literal(1),
  callback_id: z.string().min(1),
  kind: z.literal("execution.broadcast"),
  execution_plan_id: uuid,
  tx_refs: z.array(TxRefSchema).min(1),
  emitted_at: rfc3339,
});
export type CallbackExecutionBroadcast = z.infer<typeof CallbackExecutionBroadcastSchema>;

export const CallbackExecutionConfirmedSchema = z.object({
  contract_version: z.literal(1),
  callback_id: z.string().min(1),
  kind: z.literal("execution.confirmed"),
  execution_plan_id: uuid,
  tx_refs: z.array(TxRefSchema).min(1),
  final_balance_changes: z.object({
    items: z.array(
      z.object({
        asset: z.string().min(1),
        amount: z.string(), // signed decimal
      }),
    ),
  }),
  emitted_at: rfc3339,
});
export type CallbackExecutionConfirmed = z.infer<typeof CallbackExecutionConfirmedSchema>;

export const CallbackExecutionRevertedSchema = z.object({
  contract_version: z.literal(1),
  callback_id: z.string().min(1),
  kind: z.literal("execution.reverted"),
  execution_plan_id: uuid,
  tx_refs: z.array(TxRefSchema).min(1),
  reason: z.string().min(1),
  emitted_at: rfc3339,
});
export type CallbackExecutionReverted = z.infer<typeof CallbackExecutionRevertedSchema>;

export const CallbackExecutionAbortedSchema = z.object({
  contract_version: z.literal(1),
  callback_id: z.string().min(1),
  kind: z.literal("execution.aborted"),
  execution_plan_id: uuid,
  reason: z.string().min(1),
  emitted_at: rfc3339,
});
export type CallbackExecutionAborted = z.infer<typeof CallbackExecutionAbortedSchema>;

export const CallbackDelegationStateChangedSchema = z.object({
  contract_version: z.literal(1),
  callback_id: z.string().min(1),
  kind: z.literal("delegation.state_changed"),
  smart_account_id: z.string().min(1),
  delegation_id: z.string().min(1),
  state: z.enum(["granted", "revoking", "revoke_failed", "revoked", "expired"]),
  reason: z.string().min(1),
  tx_refs: z.array(TxRefSchema).optional(),
  emitted_at: rfc3339,
});
export type CallbackDelegationStateChanged = z.infer<
  typeof CallbackDelegationStateChangedSchema
>;

/** Union of all callback kinds. */
export type CallbackPayload =
  | CallbackExecutionBroadcast
  | CallbackExecutionConfirmed
  | CallbackExecutionReverted
  | CallbackExecutionAborted
  | CallbackDelegationStateChanged;

/** All callback schemas for validation. */
export const CallbackSchemasByKind = {
  "execution.broadcast": CallbackExecutionBroadcastSchema,
  "execution.confirmed": CallbackExecutionConfirmedSchema,
  "execution.reverted": CallbackExecutionRevertedSchema,
  "execution.aborted": CallbackExecutionAbortedSchema,
  "delegation.state_changed": CallbackDelegationStateChangedSchema,
} as const;
