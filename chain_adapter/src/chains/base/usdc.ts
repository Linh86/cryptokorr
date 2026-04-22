/**
 * USDC on Base — contract ABI fragment + transfer helper.
 *
 * Only the ERC-20 `transfer` function is needed for v0.1.
 * No approval / allowance dance — the smart-account delegation
 * grants transfer authority directly.
 */

import { type Abi } from "viem";

/** Minimal ERC-20 ABI for transfer + balanceOf. */
export const ERC20_TRANSFER_ABI: Abi = [
  {
    name: "transfer",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "to", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

/** USDC on Base mainnet. */
export const USDC_BASE_ADDRESS =
  "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as const;

/** USDC has 6 decimals. */
export const USDC_DECIMALS = 6;
