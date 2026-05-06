/**
 * USDC on Base — contract ABI fragment + transfer / approve helpers.
 *
 * For the transfer path (#137) only `transfer` and `balanceOf` are
 * needed — the smart-account delegation grants transfer authority
 * directly. For the swap path (#192) the adapter additionally needs
 * `approve(spender, amount)` so the smart account can authorise a
 * bounded amount of input token for the 0x router. The runtime
 * chooses bounded over unbounded to keep blast radius limited if a
 * router is later compromised.
 */

import { type Abi } from "viem";

/** Minimal ERC-20 ABI for transfer + approve + balanceOf. */
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
    name: "approve",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
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
