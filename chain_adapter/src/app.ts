/**
 * App factory — builds the Fastify instance with all routes.
 *
 * Separated from server.ts so tests can create app instances
 * without binding to a port.
 */

import { createHash, timingSafeEqual } from "node:crypto";
import Fastify, {
  type FastifyInstance,
  type FastifyReply,
  type FastifyRequest,
} from "fastify";
import type { AdapterConfig } from "./config/index.js";
import type { CallbackClient } from "./callbacks/client.js";
import type { BaseClients } from "./chains/base/client.js";
import { handleTransferDispatch } from "./dispatch/transfer.js";
import { handleSwapDispatch } from "./dispatch/swap.js";
import { handleMorphoDepositDispatch } from "./dispatch/morpho_deposit.js";
import { handleRevokeDispatch } from "./dispatch/revoke.js";
import { handleGrantDispatch } from "./dispatch/grant.js";
import {
  InstallSignSessionPortionSchema,
  type InstallSignSessionPortion,
} from "./contracts/schemas.js";
import { signInstallSessionPortion } from "./install/session_signer.js";
import { AdapterError, ValidationError } from "./lib/errors.js";
import { logger } from "./lib/logger.js";

export interface AppDeps {
  config: AdapterConfig;
  callbackClient: CallbackClient;
  baseClients: BaseClients | null; // null in test mode
  /**
   * Optional TLS material. When set, Fastify serves HTTPS instead of
   * plain HTTP. `server.ts` reads the cert / key files at startup when
   * both `ADAPTER_TLS_CERT_PATH` and `ADAPTER_TLS_KEY_PATH` are
   * configured. Tests leave this unset.
   */
  tls?: {
    cert: string | Buffer;
    key: string | Buffer;
  };
}

export function buildApp(deps: AppDeps): FastifyInstance {
  const app = Fastify({
    logger: false, // we use our own logger
    ...(deps.tls
      ? { https: { cert: deps.tls.cert, key: deps.tls.key } }
      : {}),
  });

  const { config, callbackClient, baseClients } = deps;
  const verifyDispatchAuth = makeVerifyDispatchAuth(config.dispatchAuthSecret);

  // -----------------------------------------------------------------------
  // Error handler
  // -----------------------------------------------------------------------

  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof ValidationError) {
      return reply.status(error.statusCode).send({
        error: {
          code: error.code,
          message: error.message,
          details: error.details,
          retryable: error.retryable,
        },
      });
    }

    if (error instanceof AdapterError) {
      return reply.status(error.statusCode).send({
        error: {
          code: error.code,
          message: error.message,
          retryable: error.retryable,
        },
      });
    }

    // Unexpected errors
    const errMsg = error instanceof Error ? error.message : String(error);
    const errStack = error instanceof Error ? error.stack : undefined;
    logger.error("Unhandled error", {
      message: errMsg,
      stack: errStack,
    });

    return reply.status(500).send({
      error: {
        code: "internal_error",
        message: "An unexpected error occurred",
        retryable: false,
      },
    });
  });

  // -----------------------------------------------------------------------
  // GET /health
  // -----------------------------------------------------------------------

  app.get("/health", async (_request, reply) => {
    return reply.status(200).send({
      status: "ok",
      service: "cryptokorr-ts-adapter",
      contract_version: config.contractVersion,
      supported_chains: ["base", "base-sepolia"],
      supported_assets: ["USDC"],
      timestamp: new Date().toISOString(),
    });
  });

  // -----------------------------------------------------------------------
  // POST /dispatch/transfer
  // -----------------------------------------------------------------------

  app.post(
    "/dispatch/transfer",
    { preHandler: verifyDispatchAuth },
    async (request: FastifyRequest, reply) => {
      const result = await handleTransferDispatch(request.body, {
        callbackClient,
        baseClients: baseClients!,
        usdcAddress: config.usdcContractAddress,
      });

      return reply.status(202).send(result);
    },
  );

  // -----------------------------------------------------------------------
  // POST /dispatch/swap
  // -----------------------------------------------------------------------

  app.post(
    "/dispatch/swap",
    { preHandler: verifyDispatchAuth },
    async (request: FastifyRequest, reply) => {
      const result = await handleSwapDispatch(request.body, {
        callbackClient,
        baseClients,
      });

      return reply.status(202).send(result);
    },
  );

  // -----------------------------------------------------------------------
  // POST /dispatch/morpho_deposit (#206)
  // -----------------------------------------------------------------------

  app.post(
    "/dispatch/morpho_deposit",
    { preHandler: verifyDispatchAuth },
    async (request: FastifyRequest, reply) => {
      const result = await handleMorphoDepositDispatch(request.body, {
        callbackClient,
        baseClients,
        usdcAddress: config.usdcContractAddress,
      });

      return reply.status(202).send(result);
    },
  );

  // -----------------------------------------------------------------------
  // POST /dispatch/revoke_delegation
  // -----------------------------------------------------------------------

  app.post(
    "/dispatch/revoke_delegation",
    { preHandler: verifyDispatchAuth },
    async (request: FastifyRequest, reply) => {
      const result = await handleRevokeDispatch(request.body, {
        config,
        callbackClient,
        baseClients: baseClients!,
      });

      return reply.status(202).send(result);
    },
  );

  // -----------------------------------------------------------------------
  // POST /dispatch/grant_delegation (#58 grant flow)
  // -----------------------------------------------------------------------

  app.post(
    "/dispatch/grant_delegation",
    { preHandler: verifyDispatchAuth },
    async (request: FastifyRequest, reply) => {
      const result = await handleGrantDispatch(request.body, {
        config,
        callbackClient,
        baseClients: baseClients!,
      });

      return reply.status(202).send(result);
    },
  );

  // -----------------------------------------------------------------------
  // POST /install/sign_session_portion
  //
  // Server-side signing of the install UserOp's permission-validator
  // portion. The browser hook builds the install UserOp with viem +
  // ZeroDev SDK, computes the UserOp hash, and the SDK then asks the
  // permission validator's signer to `signMessage({raw: userOpHash})`.
  // That signer is the adapter's `DELEGATION_SIGNER_KEY` — its private
  // key MUST NOT leave this process. Phoenix proxies the hash here;
  // the adapter signs and returns the signature; the browser hook
  // embeds it in the UserOp.
  //
  // Auth: identical to `/dispatch/*` — Phoenix sends
  // `Authorization: Bearer <ADAPTER_DISPATCH_SECRET>`. The browser
  // NEVER hits this endpoint directly; CSRF + browser-session auth
  // is enforced one hop earlier at Phoenix's proxy route.
  // -----------------------------------------------------------------------

  app.post(
    "/install/sign_session_portion",
    { preHandler: verifyDispatchAuth },
    async (request: FastifyRequest, reply) => {
      const parsed = InstallSignSessionPortionSchema.safeParse(request.body);
      if (!parsed.success) {
        throw new ValidationError(
          "Invalid install/sign_session_portion payload",
          parsed.error.issues,
        );
      }

      const body: InstallSignSessionPortion = parsed.data;

      // Sanitized log — never echo the hash itself (it's hash of a
      // UserOp whose contents the operator might want kept tight)
      // and NEVER the signature, which is the secret.
      logger.info("install/sign_session_portion: signing requested", {
        binding_id: body.binding_id,
        smart_account_id: body.smart_account_id,
        has_expected_signer:
          typeof body.session_signer_address === "string",
      });

      const result = await signInstallSessionPortion(
        {
          user_op_hash: body.user_op_hash as `0x${string}`,
          session_signer_address: body.session_signer_address,
        },
        { delegationSignerKey: config.delegationSignerKey as `0x${string}` },
      );

      return reply.status(200).send(result);
    },
  );

  return app;
}

/**
 * Build the inbound auth preHandler for `POST /dispatch/*`.
 *
 * Phoenix sends `Authorization: Bearer <ADAPTER_DISPATCH_SECRET>` on
 * every dispatch. This handler enforces it. The expected secret is
 * captured in the closure once at app build time; the bearer value
 * presented by the caller is compared in constant time so a wrong
 * token does not leak length information via timing.
 *
 * `/health` deliberately does NOT use this preHandler — liveness
 * probes are operational and stay public.
 *
 * Failure modes (all return 401, no `WWW-Authenticate` to discourage
 * blind retries from a misconfigured client):
 *   - missing header           → `missing_authorization`
 *   - non-Bearer scheme        → `invalid_authorization_scheme`
 *   - wrong bearer             → `invalid_credentials`
 *   - empty configured secret  → `server_misconfigured` (defense in
 *     depth; `loadConfig()` already throws on missing env)
 */
function makeVerifyDispatchAuth(expectedSecret: string) {
  return async function verifyDispatchAuth(
    request: FastifyRequest,
    reply: FastifyReply,
  ): Promise<void> {
    if (!expectedSecret) {
      logger.error(
        "Dispatch auth: no ADAPTER_DISPATCH_SECRET configured; refusing request",
      );
      await reply
        .status(401)
        .send({ error: { code: "server_misconfigured", retryable: false } });
      return;
    }

    const header = request.headers.authorization;
    if (!header) {
      await reply
        .status(401)
        .send({ error: { code: "missing_authorization", retryable: false } });
      return;
    }

    const [scheme, token] = splitBearer(header);
    if (scheme !== "Bearer" || !token) {
      await reply.status(401).send({
        error: { code: "invalid_authorization_scheme", retryable: false },
      });
      return;
    }

    if (!constantTimeEquals(token, expectedSecret)) {
      logger.warn("Dispatch auth: bearer mismatch", {
        ip: request.ip,
        path: request.url,
      });
      await reply
        .status(401)
        .send({ error: { code: "invalid_credentials", retryable: false } });
      return;
    }
  };
}

function splitBearer(header: string): [string, string] {
  const idx = header.indexOf(" ");
  if (idx === -1) return [header, ""];
  return [header.slice(0, idx), header.slice(idx + 1)];
}

/**
 * Constant-time string comparison. Hash both sides with SHA-256 first
 * so the buffers are always equal length — `timingSafeEqual` requires
 * equal-length buffers and would otherwise leak length via the
 * length-mismatch early return.
 */
function constantTimeEquals(a: string, b: string): boolean {
  const aHash = createHash("sha256").update(a).digest();
  const bHash = createHash("sha256").update(b).digest();
  return timingSafeEqual(aHash, bHash);
}
