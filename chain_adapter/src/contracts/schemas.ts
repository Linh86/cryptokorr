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

/**
 * 0x-prefixed hex blob (calldata, signed payloads, etc.). Length is not
 * pinned — calldata size depends on the encoded function. Empty `"0x"`
 * is rejected because a swap call must carry an inner function selector.
 */
const hexBlob = z.string().regex(/^0x[0-9a-fA-F]+$/);

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
    // Execution-route fields (optional, additive). #189 / #190 produce a
    // rich route map; the wire-level dispatch envelope passes the
    // adapter-relevant subset under `route` so the adapter can build the
    // approve+swap UserOperation. When all required execution fields are
    // present the adapter dispatches a real UserOp; when any is missing
    // it aborts with `swap_route_incomplete: <field>`. Quote-only routes
    // (without execution fields) preserve the v0.1 fail-closed posture.
    swap_target_contract: hexAddress.optional(),
    calldata: hexBlob.optional(),
    spender: hexAddress.optional(),
    source_token_address: hexAddress.optional(),
    destination_token_address: hexAddress.optional(),
    minimum_output_amount: decimalString.optional(),
    value: decimalString.optional(),
    route_provider: z.string().min(1).optional(),
    deadline: rfc3339.optional(),
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
 * dispatch AND on the granted callback. Carries the data the
 * cryptographic revoke needs to reconstruct the ZeroDev plugin and
 * build the `Kernel.uninstallValidation(...)` UserOp.
 *
 * Shape:
 *   * `blob` — `serializePermissionAccount(account, undefined)`
 *     output (base64 string). The privateKey parameter is
 *     deliberately omitted at grant time so the blob is KEYLESS:
 *     Phoenix never holds session-signer secrets. See Subagent D's
 *     security review (PR #129 grant-flow follow-up) and
 *     `docs/security.md`. Adapter feeds the blob back to
 *     `deserializePermissionAccount(...)` to rebuild the same
 *     policies + signer-contract identity the grant flow
 *     installed.
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
 *   * `session_signer_address` — 0x-prefixed 20-byte hex (42 chars).
 *     The session ECDSA EOA bound to the permission. Required
 *     because the blob is keyless: at revoke-time the adapter
 *     rebuilds a stub `ModularSigner` whose `account.address`
 *     equals this value. `getEnableData(...)` only reads the
 *     address; no signing happens during revoke. Without this
 *     field the deserializer would throw "No signer or serialized
 *     sessionKey provided". Optional only for backwards-compat
 *     with rows that predate the keyless-blob design; Phoenix's
 *     `cryptographically_revocable?/1` refuses to dispatch a
 *     `permission` block without it.
 *   * `installed_at_block` — install UserOp's chain-level block
 *     anchor for operator triage. Optional.
 *   * `install_tx_hash` — install UserOp's chain-level tx hash for
 *     operator triage. Optional.
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
  session_signer_address: z
    .string()
    .regex(
      /^0x[0-9a-fA-F]{40}$/,
      "session_signer_address must be 0x + 40 hex chars (20 bytes)",
    )
    .optional(),
  installed_at_block: z.number().int().nonnegative().optional(),
  install_tx_hash: z.string().min(1).optional(),
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

/**
 * POST /dispatch/grant_delegation (#58 grant flow).
 *
 * Phoenix-initiated request to install a fresh ZeroDev permission
 * plugin on the kernel account. The adapter:
 *
 *   1. Builds a `PermissionPlugin` via
 *      `toPermissionValidator(...)` using a session signer derived
 *      from the runtime `DELEGATION_SIGNER_KEY`.
 *   2. Installs it via `createKernelAccount({ plugins: { sudo,
 *      regular } })` + a no-op first UserOp signed by the operator
 *      (sudo) EOA — that triggers the EIP-712 enable signature
 *      flow which writes the validator to the kernel's storage.
 *   3. Calls `serializePermissionAccount(account, undefined)` —
 *      KEYLESS — and emits a `delegation.state_changed{state:
 *      "granted"}` callback whose `permission` block carries the
 *      keyless blob plus the `session_signer_address` Phoenix
 *      needs to rebuild the stub `ModularSigner` at revoke-time.
 *
 * The synchronous response is `202 accepted`; chain progress is
 * reported via the callback path. The grant fails closed with a
 * `delegation.state_changed{state: "grant_failed"}` callback. It
 * must not emit `state: "granted"` without a `permission` block,
 * because Phoenix treats `granted` as an active delegation.
 */
export const DispatchGrantDelegationSchema = z.object({
  contract_version: z.literal(1),
  action: z.literal("grant_delegation"),
  smart_account_id: z.string().min(1),
  // 8453 (Base) or 84532 (Base Sepolia). The adapter cross-checks
  // this against `config.baseChainId` and refuses on mismatch.
  chain_id: z.number().int(),
  // The wallet-side EOA the user signed from. Threaded through for
  // audit + future signature verification; the adapter does not
  // currently parse it.
  account: z.string().min(1),
  // Caller-supplied policy hints. Adapter's grant path picks the
  // initial policy set; eventual richer policies will be derived
  // from this map. Empty object is a valid sudo-policy install.
  scope: z.record(z.unknown()),
  // Optional opaque blob the JS hook built (signed delegation
  // parameters); the adapter does not parse it today, but the
  // dispatch contract carries it through so a future signature-
  // verifying adapter is wire-compatible.
  delegation_payload: z.unknown().nullable().optional(),
  correlation_id: z.string().nullable().optional(),
  emitted_at: rfc3339,
});
export type DispatchGrantDelegation = z.infer<typeof DispatchGrantDelegationSchema>;

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
  state: z.enum([
    "granted",
    "grant_failed",
    "revoking",
    "revoke_failed",
    "revoked",
    "expired",
  ]),
  reason: z.string().min(1),
  tx_refs: z.array(TxRefSchema).optional(),
  // Optional permission artifact block, populated when the adapter
  // emits a `granted` callback after a real ZeroDev permission
  // install (#58 grant flow). Phoenix's `apply_callback/1`
  // already decodes this shape; absence keeps the pre-#58
  // sentinel-era flow unchanged.
  permission: PermissionBlockSchema.optional(),
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
