/**
 * ERC-7579 modular smart account `execute` envelope.
 *
 * What this module pins (verifiable today, before any Permission
 * Validator deployment is chosen):
 *
 *   - `ERC_7579_EXECUTE_ABI` — the standard
 *     `execute(bytes32 mode, bytes executionCalldata)` entrypoint that
 *     every ERC-7579 account (Kernel v3, Biconomy Nexus, etc.) exposes.
 *     Selector `0xe9ae5c53`. Pinned in the tripwire test so any drift
 *     in the ABI shape surfaces at build time.
 *   - `ERC_7579_SINGLE_CALL_MODE` — the canonical "single call,
 *     default revert on failure, no extra mode selector or payload"
 *     mode. All-zeros bytes32: `callType=0x00`, `execType=0x00`,
 *     remaining 30 bytes zero. This is the mode every ERC-7579 account
 *     supports, and the only one #58 needs to wrap a single revoke
 *     call.
 *   - `encodeErc7579SingleCall` — the per-EIP-7579 packed body for
 *     single-call mode: `abi.encodePacked(target, value, callData)`.
 *   - `buildErc7579ExecuteCallData` — the full outer wrap.
 *
 * What this module deliberately does NOT pin:
 *
 *   - The Permission Validator's own ABI. That belongs to whichever
 *     concrete validator deployment #58 picks; pinning a function name
 *     or selector here before that deployment is verified would be
 *     speculation (see the prior #57 attempt that pinned
 *     `disablePermission(bytes32)` from a name we could not actually
 *     verify against a deployed contract).
 *
 * ## Why this matters for #58
 *
 * The previous #57 scaffolding wrapped the (then-speculative) revoke
 * inner call with `buildExecuteCallData` — the SimpleAccount-shaped
 * `execute(address,uint256,bytes)` envelope (selector `0xb61d27f6`).
 * That is structurally a different function from the ERC-7579
 * `execute(bytes32,bytes)` that a Kernel v3 / ERC-7579 account
 * dispatches on. Building an ERC-7579 user-op against a SimpleAccount
 * envelope would either revert on chain (selector miss) or, worse,
 * land on the wrong code path on an account that exposes both shapes.
 *
 * #58's outer wrap MUST be this module's `buildErc7579ExecuteCallData`
 * once the smart account has been migrated to Kernel v3. The inner
 * body is whatever `permission_validator.ts` returns — but that piece
 * is only buildable once the validator interface has been pinned
 * truthfully against a real deployment.
 *
 * ## References
 *
 *   - EIP-7579 — Minimal Modular Smart Accounts.
 *     `execute(bytes32 mode, bytes executionCalldata)` is the
 *     standardised entrypoint; the ModeCode layout (callType byte,
 *     execType byte, then mode selector + payload) is normative.
 *   - The selector `0xe9ae5c53` is `keccak256("execute(bytes32,bytes)")`
 *     truncated to 4 bytes; pinned in `test/erc7579.test.ts`.
 */

import {
  encodeFunctionData,
  encodePacked,
  type Abi,
  type Address,
  type Hex,
} from "viem";

/**
 * Standard name of the ERC-7579 execute entrypoint. Pinned separately
 * from the ABI so the selector test can reference it by string.
 */
export const ERC_7579_EXECUTE_FUNCTION = "execute" as const;

/**
 * Minimal ERC-7579 ABI — only the `execute(bytes32, bytes)` entrypoint
 * the adapter needs to wrap a single inner call.
 *
 * `payable` because the standard entrypoint is payable; the adapter
 * never sends value through it (single-call mode encodes `value=0`)
 * but the function shape is what counts for the selector.
 */
export const ERC_7579_EXECUTE_ABI: Abi = [
  {
    name: ERC_7579_EXECUTE_FUNCTION,
    type: "function",
    stateMutability: "payable",
    inputs: [
      { name: "mode", type: "bytes32" },
      { name: "executionCalldata", type: "bytes" },
    ],
    outputs: [],
  },
] as const;

/**
 * Canonical single-call ModeCode for ERC-7579: all 32 bytes zero.
 *
 *   - byte 0  (callType)     = 0x00 — single call
 *   - byte 1  (execType)     = 0x00 — default (revert on inner failure)
 *   - bytes 2-5  (unused)    = 0x00…
 *   - bytes 6-9  (modeSelector) = 0x00000000 — no extra mode handler
 *   - bytes 10-31 (modePayload) = 0x00…
 *
 * This is the only mode #58 needs: one inner call, default
 * revert-on-failure semantics so a failed permission-disable surfaces
 * as a revert in the user-op receipt rather than a silent no-op.
 */
export const ERC_7579_SINGLE_CALL_MODE: Hex =
  "0x0000000000000000000000000000000000000000000000000000000000000000" as const;

/**
 * Encode the `executionCalldata` body for ERC-7579 single-call mode:
 * `abi.encodePacked(target, value, callData)`.
 *
 * Layout: 20 bytes target ‖ 32 bytes value (big-endian uint256) ‖
 * variable-length inner calldata. The receiving account decodes by
 * fixed offsets — this MUST be packed encoding, not standard ABI
 * encoding, per EIP-7579.
 */
export function encodeErc7579SingleCall(
  target: Address,
  value: bigint,
  data: Hex,
): Hex {
  return encodePacked(
    ["address", "uint256", "bytes"],
    [target, value, data],
  );
}

/**
 * Build the full outer `execute(bytes32 mode, bytes executionCalldata)`
 * calldata for an ERC-7579 account, single-call mode.
 *
 * This is the function #58 will use as the OUTER envelope once the
 * smart account is migrated to Kernel v3 and the ZeroDev SDK
 * integration described in
 * `docs/zerodev-permissions-integration.md` lands. The inner body
 * it wraps is `Kernel.uninstallValidation(bytes21,bytes,bytes)`
 * called against the smart account itself — there is no separate
 * Permission Validator address to target. The exact integration
 * shape (signer + policies, deinit data reconstruction, plugin
 * blob persistence) is deferred to that doc.
 *
 * Until then this builder is unused on the live revoke path —
 * `executeRevoke` keeps calling `buildSentinelRevokeCallData`,
 * which uses the SimpleAccount envelope appropriate for the v0.1
 * deployment.
 */
export function buildErc7579ExecuteCallData(
  target: Address,
  value: bigint,
  data: Hex,
): Hex {
  return encodeFunctionData({
    abi: ERC_7579_EXECUTE_ABI,
    functionName: ERC_7579_EXECUTE_FUNCTION,
    args: [ERC_7579_SINGLE_CALL_MODE, encodeErc7579SingleCall(target, value, data)],
  });
}
