/**
 * Execution state types.
 *
 * These map 1:1 to the callback kinds in the contract.
 */

export type ExecutionState =
  | "pending"
  | "broadcast"
  | "confirmed"
  | "reverted"
  | "aborted";

export interface ExecutionRecord {
  executionPlanId: string;
  state: ExecutionState;
  txHash?: string;
  blockNumber?: number;
  reason?: string;
  updatedAt: string;
}
