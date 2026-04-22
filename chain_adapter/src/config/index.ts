/**
 * Environment-based configuration.
 *
 * Every value is read from `process.env` at import time.
 * Missing required values throw immediately so the service
 * fails at startup rather than mid-request.
 */

function required(key: string): string {
  const value = process.env[key];
  if (!value) {
    throw new Error(`Missing required env var: ${key}`);
  }
  return value;
}

function optional(key: string, fallback: string): string {
  return process.env[key] || fallback;
}

function optionalInt(key: string, fallback: number): number {
  const raw = process.env[key];
  if (!raw) return fallback;
  const n = parseInt(raw, 10);
  if (isNaN(n)) throw new Error(`Env var ${key} must be an integer, got: ${raw}`);
  return n;
}

function optionalString(key: string): string | undefined {
  const value = process.env[key];
  return value && value.length > 0 ? value : undefined;
}

export interface AdapterConfig {
  /** HTTP server */
  port: number;
  host: string;

  /**
   * Optional TLS material. When both `tlsCertPath` and `tlsKeyPath`
   * are set, the Fastify listener serves HTTPS instead of plain HTTP.
   * Most deployments terminate TLS at an upstream ingress and leave
   * these unset; this hook exists for operators who want the adapter
   * itself to terminate TLS (e.g. when there is no ingress in front
   * of it on a private subnet).
   */
  tlsCertPath?: string;
  tlsKeyPath?: string;

  /**
   * Bearer the adapter REQUIRES on inbound `POST /dispatch/*`
   * requests. Phoenix sends this on every dispatch. Compared in
   * constant time. The pair on the Phoenix side is
   * `:bank, Bank.AdapterClient, :dispatch_secret` /
   * `ADAPTER_DISPATCH_SECRET`.
   */
  dispatchAuthSecret: string;

  /** Phoenix callback */
  phoenixBaseUrl: string;
  /**
   * Bearer the adapter SENDS on outbound `POST /internal/adapter/callback`
   * to Phoenix. Phoenix's `BankWeb.Plugs.VerifyAdapterAuth` validates
   * it. The pair on the Phoenix side is
   * `:bank, Bank.AdapterClient, :callback_secret` /
   * `ADAPTER_CALLBACK_SECRET`.
   *
   * Distinct from `dispatchAuthSecret` so each direction can be
   * rotated independently and a leak in one direction does not
   * authenticate the other.
   */
  callbackAuthSecret: string;

  /** Base chain */
  baseRpcUrl: string;
  baseChainId: number;

  /**
   * Bundler JSON-RPC endpoint for ERC-4337 v0.7 UserOperations.
   * Distinct from `baseRpcUrl` so the adapter can point at a dedicated
   * bundler (Pimlico, Alchemy AA, Stackup, etc.) separate from its
   * state-reading RPC. For local dev a combined RPC can be used by
   * setting both to the same URL.
   */
  bundlerRpcUrl: string;

  /**
   * The smart account address this adapter is bonded to (the `sender`
   * of every UserOperation in v0.1). Must already be deployed on the
   * target chain and funded. In production this comes from a smart
   * account provisioning flow; in v0.1 it is a single operator-managed
   * account.
   */
  smartAccountAddress: `0x${string}`;

  /** EntryPoint v0.7 address — same on every EVM chain. Overridable
   * for test networks that deploy a non-canonical EntryPoint. */
  entryPointAddress: `0x${string}`;

  /**
   * Address of the Kernel v3 Permission Validator module installed on
   * `smartAccountAddress`. Optional in v0.1 because the live revoke
   * path is still the sentinel UserOp (see
   * `src/chains/base/revoke.ts`); it does NOT touch the validator
   * yet. The cryptographic revoke that does is GitHub #58.
   *
   * The architectural decision behind this field is captured in
   * `docs/smart-account-and-revoke-design.md` (GitHub #56) in the
   * Phoenix repo. The mapping helpers and ABI fragment that consume
   * this address live in `src/chains/base/permission_validator.ts`.
   *
   * Fail-closed posture: leaving this unset is FINE for v0.1 because
   * the sentinel path doesn't read it — but accessing it MUST be
   * routed through `requirePermissionValidatorAddress(config)`, which
   * throws a loud, #58-referencing error when unset. The strict
   * accessor exists so #58 cannot silently degrade back to a sentinel
   * if the env var is forgotten on a Kernel-provisioned deploy.
   */
  permissionValidatorAddress?: `0x${string}`;

  /** Smart account / delegation */
  delegationSignerKey: string;

  /** USDC on Base */
  usdcContractAddress: `0x${string}`;

  /** Contract version advertised to Phoenix */
  contractVersion: number;
}

export function loadConfig(): AdapterConfig {
  return {
    port: optionalInt("PORT", 4100),
    host: optional("HOST", "0.0.0.0"),

    tlsCertPath: optionalString("ADAPTER_TLS_CERT_PATH"),
    tlsKeyPath: optionalString("ADAPTER_TLS_KEY_PATH"),

    dispatchAuthSecret: required("ADAPTER_DISPATCH_SECRET"),

    phoenixBaseUrl: required("PHOENIX_BASE_URL"),
    callbackAuthSecret: required("ADAPTER_CALLBACK_SECRET"),

    baseRpcUrl: required("BASE_RPC_URL"),
    baseChainId: optionalInt("BASE_CHAIN_ID", 8453),

    bundlerRpcUrl: required("BUNDLER_RPC_URL"),
    smartAccountAddress: required("SMART_ACCOUNT_ADDRESS") as `0x${string}`,
    entryPointAddress: optional(
      "ENTRY_POINT_ADDRESS",
      "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    ) as `0x${string}`,

    permissionValidatorAddress: optionalString("PERMISSION_VALIDATOR_ADDRESS") as
      | `0x${string}`
      | undefined,

    delegationSignerKey: required("DELEGATION_SIGNER_KEY"),

    usdcContractAddress: required("USDC_CONTRACT_ADDRESS") as `0x${string}`,

    contractVersion: optionalInt("CONTRACT_VERSION", 1),
  };
}

/**
 * Strict accessor for `permissionValidatorAddress`.
 *
 * The sentinel revoke path (v0.1) does NOT need a validator address;
 * leaving `PERMISSION_VALIDATOR_ADDRESS` unset is fine. The real
 * cryptographic revoke (#58) DOES need it, and silently falling back
 * to a sentinel if the env var is missing on a Kernel-provisioned
 * smart account would be a critical correctness bug — the operator
 * would believe a delegation was revoked when in fact only an anchor
 * was written. This accessor throws loudly to make that impossible.
 *
 * Call this from the real revoke encoder when #58 wires it; do NOT
 * read `config.permissionValidatorAddress` directly from execution
 * paths.
 */
export function requirePermissionValidatorAddress(
  config: AdapterConfig,
): `0x${string}` {
  if (!config.permissionValidatorAddress) {
    throw new Error(
      "PERMISSION_VALIDATOR_ADDRESS is not configured. " +
        "A cryptographic delegation revoke (Phoenix issue #58) requires the " +
        "Kernel v3 Permission Validator address bound to this smart account. " +
        "See docs/smart-account-and-revoke-design.md (#56) for provisioning, " +
        "or fall back to the sentinel revoke path if you intentionally have " +
        "no validator installed.",
    );
  }
  return config.permissionValidatorAddress;
}

/**
 * Test-safe config with sensible defaults. Use in tests only.
 */
export function testConfig(overrides: Partial<AdapterConfig> = {}): AdapterConfig {
  return {
    port: 0, // random port
    host: "127.0.0.1",
    dispatchAuthSecret: "test-dispatch-secret",
    phoenixBaseUrl: "http://localhost:4000",
    callbackAuthSecret: "test-callback-secret",
    baseRpcUrl: "http://localhost:8545",
    baseChainId: 8453,
    bundlerRpcUrl: "http://localhost:4337",
    smartAccountAddress: "0x0000000000000000000000000000000000000a11",
    entryPointAddress: "0x0000000071727de22e5e9d8baf0edac6f37da032",
    delegationSignerKey: "0x" + "ab".repeat(32),
    usdcContractAddress: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    contractVersion: 1,
    ...overrides,
  };
}
