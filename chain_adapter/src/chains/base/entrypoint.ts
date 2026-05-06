/**
 * EntryPoint v0.7 constants + SimpleAccount ABI fragment.
 *
 * v0.1 targets ERC-4337 v0.7 because that is the version actively
 * maintained across major bundlers (Pimlico, Alchemy, Stackup, Biconomy)
 * and the version viem exposes first-class support for in
 * `viem/account-abstraction`.
 *
 * The adapter owns a single smart account on Base in v0.1. Its concrete
 * implementation (SimpleAccount, Kernel, Safe, Biconomy Nexus, etc.) can
 * be swapped later without changing the callback contract — every
 * AA-compatible wallet exposes some variant of `execute(target, value,
 * data)`. We ship against the SimpleAccount shape because it's the
 * canonical reference implementation and works with every EntryPoint
 * v0.7 wallet we'd realistically use in v0.1.
 */

import { entryPoint07Address } from "viem/account-abstraction";
import { type Abi } from "viem";

/**
 * EntryPoint v0.7 singleton address.
 *
 * Same on every EVM chain (deterministic deploy). Re-exported so the
 * rest of the adapter never reaches into `viem/account-abstraction`
 * directly for the address.
 */
export const ENTRY_POINT_07_ADDRESS = entryPoint07Address;

/**
 * Minimal SimpleAccount ABI — the single `execute(target, value, data)`
 * entrypoint every AA wallet exposes. Used to wrap a concrete
 * contract call (e.g. USDC.transfer) into the inner calldata of a
 * UserOperation.
 */
export const SIMPLE_ACCOUNT_EXECUTE_ABI: Abi = [
  {
    name: "execute",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "dest", type: "address" },
      { name: "value", type: "uint256" },
      { name: "func", type: "bytes" },
    ],
    outputs: [],
  },
] as const;

/**
 * SimpleAccount `executeBatch(address[] dest, uint256[] value, bytes[] func)`
 * ABI — used by the swap path (#192) to atomically submit ERC20
 * `approve(spender, amount)` + the 0x router call in a single
 * UserOperation. Splitting into two UserOps would let an attacker
 * race the approval against the swap; one batched UserOp keeps the
 * approve scope bounded to the same operation.
 *
 * SimpleAccount's reference implementation has had `executeBatch`
 * since EntryPoint v0.6 with the same shape; viem's account-
 * abstraction module emits the same selector, so the canonical
 * v0.7 user-op hash stays correct end-to-end.
 */
export const SIMPLE_ACCOUNT_EXECUTE_BATCH_ABI: Abi = [
  {
    name: "executeBatch",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "dest", type: "address[]" },
      { name: "value", type: "uint256[]" },
      { name: "func", type: "bytes[]" },
    ],
    outputs: [],
  },
] as const;
