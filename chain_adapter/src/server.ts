/**
 * Adapter service entry point.
 *
 * Loads config, creates clients, builds the Fastify app, and starts listening.
 */

import { readFileSync } from "node:fs";
import { loadConfig, type AdapterConfig } from "./config/index.js";
import { createCallbackClient } from "./callbacks/client.js";
import {
  assertBaseChainIdentity,
  createBaseClients,
} from "./chains/base/client.js";
import { buildApp, type AppDeps } from "./app.js";
import { logger } from "./lib/logger.js";

async function main() {
  logger.info("Starting cryptobank-ts-adapter");

  const config = loadConfig();
  const callbackClient = createCallbackClient(config);
  const baseClients = createBaseClients(config);

  // Refuse to start unless the configured Base RPC and bundler are
  // both on the expected chain. A wrong chain id would silently
  // produce user-op signatures bound to the wrong network and break
  // Phoenix's audit trail.
  try {
    await assertBaseChainIdentity(baseClients, config.baseChainId);
    logger.info("Base chain identity verified", {
      chain_id: config.baseChainId,
    });
  } catch (err) {
    logger.error("Chain identity check failed; refusing to start", {
      error: err instanceof Error ? err.message : String(err),
    });
    process.exit(1);
  }

  const tls = loadTlsMaterial(config);
  const app = buildApp({ config, callbackClient, baseClients, tls });

  try {
    await app.listen({ port: config.port, host: config.host });
    logger.info("Adapter listening", {
      port: config.port,
      host: config.host,
      contract_version: config.contractVersion,
      chains: ["base"],
      assets: ["USDC"],
      tls: Boolean(tls),
    });
  } catch (err) {
    logger.error("Failed to start adapter", {
      error: err instanceof Error ? err.message : String(err),
    });
    process.exit(1);
  }
}

/**
 * Read TLS cert + key from disk if both paths are configured. Both
 * must be set together; partial config is a fail-closed condition.
 *
 * Most deployments terminate TLS at an upstream ingress and leave
 * these unset. This hook exists for operators who want the adapter
 * itself to terminate TLS.
 */
function loadTlsMaterial(
  config: AdapterConfig,
): AppDeps["tls"] | undefined {
  const { tlsCertPath, tlsKeyPath } = config;
  if (!tlsCertPath && !tlsKeyPath) return undefined;
  if (!tlsCertPath || !tlsKeyPath) {
    logger.error(
      "TLS partially configured: both ADAPTER_TLS_CERT_PATH and ADAPTER_TLS_KEY_PATH must be set together",
    );
    process.exit(1);
  }
  try {
    return {
      cert: readFileSync(tlsCertPath),
      key: readFileSync(tlsKeyPath),
    };
  } catch (err) {
    logger.error("Failed to read TLS material", {
      error: err instanceof Error ? err.message : String(err),
    });
    process.exit(1);
  }
}

main();
