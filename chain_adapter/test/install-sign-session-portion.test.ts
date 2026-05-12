/**
 * `POST /install/sign_session_portion` route + handler tests.
 *
 * Covers:
 *   - Auth posture (same as dispatch routes — Bearer required).
 *   - Schema refusal for malformed shapes.
 *   - Happy path: signature recovers to the configured signer.
 *   - Signer-address sanity check refuses when client expects a
 *     different signer than the adapter holds.
 *   - Misconfigured adapter (placeholder key) refuses cleanly.
 *
 * The actual SDK chain — viem's `account.signMessage({raw})` —
 * runs deterministically against a fixed test key, so the
 * signature can be verified by recovering the address from the
 * `(personal_sign)` hash deterministically.
 */

import { describe, it, expect, beforeEach } from "vitest";
import {
  hashMessage,
  recoverAddress,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type { FastifyInstance } from "fastify";

import { buildApp, type AppDeps } from "../src/app.js";
import { testConfig } from "../src/config/index.js";
import { createTestCallbackClient, resetCallbackSeq } from "../src/callbacks/client.js";
import {
  signInstallSessionPortion,
  deriveSessionSignerAddress,
} from "../src/install/session_signer.js";

const PATH = "/install/sign_session_portion";

const TEST_KEY = ("0x" + "ab".repeat(32)) as Hex;
const TEST_SIGNER = privateKeyToAccount(TEST_KEY).address;

// A real Hex 32-byte hash for the happy path. Doesn't need to be a
// chain-meaningful userOpHash — viem signs whatever raw bytes we
// pass and the signature recovers regardless.
const VALID_HASH = ("0x" + "11".repeat(32)) as Hex;

function authHeader(secret = "test-dispatch-secret") {
  return { authorization: `Bearer ${secret}` };
}

function happyBody(overrides: Record<string, unknown> = {}) {
  return {
    contract_version: 1,
    binding_id: "11111111-1111-4111-8111-111111111111",
    smart_account_id: "sa_wb_demo",
    user_op_hash: VALID_HASH,
    ...overrides,
  };
}

describe("signInstallSessionPortion (unit)", () => {
  it("produces a recoverable EIP-191 signature for a 32-byte hash", async () => {
    const result = await signInstallSessionPortion(
      { user_op_hash: VALID_HASH },
      { delegationSignerKey: TEST_KEY },
    );

    expect(result.session_signer_address).toBe(TEST_SIGNER);

    // EIP-191 personal_sign: hash = keccak256("\x19Ethereum Signed Message:\n32" + rawHash)
    // Recover from that digest must yield the configured signer.
    const digest = hashMessage({ raw: VALID_HASH });
    const recovered = await recoverAddress({ hash: digest, signature: result.signature });
    expect(recovered.toLowerCase()).toBe(TEST_SIGNER.toLowerCase());
  });

  it("accepts a matching session_signer_address", async () => {
    await expect(
      signInstallSessionPortion(
        {
          user_op_hash: VALID_HASH,
          session_signer_address: TEST_SIGNER,
        },
        { delegationSignerKey: TEST_KEY },
      ),
    ).resolves.toHaveProperty("signature");
  });

  it("accepts a matching session_signer_address regardless of case (checksum vs lowercase)", async () => {
    // The browser may forward the EIP-55 checksum form from the
    // envelope. The handler must compare case-insensitively so a
    // checksummed request from a lowercase-keyed adapter (or vice
    // versa) doesn't trip a false-positive misroute.
    const upper = TEST_SIGNER.toLowerCase();
    await expect(
      signInstallSessionPortion(
        {
          user_op_hash: VALID_HASH,
          session_signer_address: upper,
        },
        { delegationSignerKey: TEST_KEY },
      ),
    ).resolves.toHaveProperty("signature");
  });

  it("refuses when session_signer_address mismatches the configured key", async () => {
    const other = "0x" + "ff".repeat(20);
    await expect(
      signInstallSessionPortion(
        {
          user_op_hash: VALID_HASH,
          session_signer_address: other,
        },
        { delegationSignerKey: TEST_KEY },
      ),
    ).rejects.toThrow(/session_signer_address does not match/);
  });

  it("refuses a malformed hash even at the unit boundary", async () => {
    await expect(
      signInstallSessionPortion(
        { user_op_hash: "not-a-hash" as Hex },
        { delegationSignerKey: TEST_KEY },
      ),
    ).rejects.toThrow(/0x-prefixed 32-byte hex/);
  });

  it("refuses a missing or malformed delegation signer key", async () => {
    await expect(
      signInstallSessionPortion(
        { user_op_hash: VALID_HASH },
        { delegationSignerKey: "" as Hex },
      ),
    ).rejects.toThrow(/delegation signer key/);
  });

  it("deriveSessionSignerAddress matches privateKeyToAccount", () => {
    expect(deriveSessionSignerAddress(TEST_KEY)).toBe(TEST_SIGNER);
  });
});

describe("POST /install/sign_session_portion (route)", () => {
  let app: FastifyInstance;

  beforeEach(async () => {
    resetCallbackSeq();
    const deps: AppDeps = {
      config: testConfig(),
      callbackClient: createTestCallbackClient(),
      baseClients: null,
    };
    app = buildApp(deps);
    await app.ready();
  });

  it("returns 401 when Authorization header is missing", async () => {
    const response = await app.inject({
      method: "POST",
      url: PATH,
      payload: happyBody(),
    });
    expect(response.statusCode).toBe(401);
    expect(response.json().error.code).toBe("missing_authorization");
  });

  it("returns 401 when the Bearer secret is wrong", async () => {
    const response = await app.inject({
      method: "POST",
      url: PATH,
      headers: authHeader("wrong-secret"),
      payload: happyBody(),
    });
    expect(response.statusCode).toBe(401);
    expect(response.json().error.code).toBe("invalid_credentials");
  });

  it("returns 400 on missing user_op_hash", async () => {
    const { user_op_hash: _drop, ...payload } = happyBody();
    void _drop;

    const response = await app.inject({
      method: "POST",
      url: PATH,
      headers: authHeader(),
      payload,
    });
    expect(response.statusCode).toBe(400);
    expect(response.json().error.code).toBe("validation_error");
  });

  it("returns 400 on a non-hex user_op_hash", async () => {
    const response = await app.inject({
      method: "POST",
      url: PATH,
      headers: authHeader(),
      payload: happyBody({ user_op_hash: "not-a-hash" }),
    });
    expect(response.statusCode).toBe(400);
    expect(response.json().error.code).toBe("validation_error");
  });

  it("returns 400 on a wrong-length user_op_hash", async () => {
    const response = await app.inject({
      method: "POST",
      url: PATH,
      headers: authHeader(),
      payload: happyBody({ user_op_hash: "0xdeadbeef" }),
    });
    expect(response.statusCode).toBe(400);
    expect(response.json().error.code).toBe("validation_error");
  });

  it("returns 400 when session_signer_address mismatches the adapter's key", async () => {
    const response = await app.inject({
      method: "POST",
      url: PATH,
      headers: authHeader(),
      payload: happyBody({
        session_signer_address: "0x" + "ff".repeat(20),
      }),
    });
    expect(response.statusCode).toBe(400);
    expect(response.json().error.code).toBe("validation_error");
    // Hard refusal posture: the adapter's actual signer address is
    // NEVER echoed back to a probing caller. Topology leak guard.
    expect(JSON.stringify(response.json())).not.toContain(TEST_SIGNER);
  });

  it("returns 200 with a valid signature on the happy path", async () => {
    const response = await app.inject({
      method: "POST",
      url: PATH,
      headers: authHeader(),
      payload: happyBody(),
    });
    expect(response.statusCode).toBe(200);

    const body = response.json();
    expect(body.session_signer_address).toBe(TEST_SIGNER);
    expect(body.signature).toMatch(/^0x[0-9a-fA-F]+$/);

    // Recoverable.
    const digest = hashMessage({ raw: VALID_HASH });
    const recovered = await recoverAddress({
      hash: digest,
      signature: body.signature,
    });
    expect(recovered.toLowerCase()).toBe(TEST_SIGNER.toLowerCase());
  });

  it("response NEVER carries the delegation signer key", async () => {
    const response = await app.inject({
      method: "POST",
      url: PATH,
      headers: authHeader(),
      payload: happyBody(),
    });
    const raw = response.body;
    // The private key would be 64 hex chars without 0x prefix; pin
    // both forms.
    expect(raw).not.toContain(TEST_KEY);
    expect(raw).not.toContain(TEST_KEY.slice(2));
  });
});
