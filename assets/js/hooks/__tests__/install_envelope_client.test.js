/**
 * Vitest unit tests for the envelope/attestation HTTP boundary.
 * Mocks `globalThis.fetch`. No real network.
 */

import {describe, it, expect, beforeEach, vi} from "vitest"

import {
  fetchInstallEnvelope,
  postSubmittedAttestation,
  postConfirmedAttestation,
  postFailureAttestation,
} from "../install_envelope_client.js"

function jsonResponse(body, init = {}) {
  return new Response(body === undefined ? "" : JSON.stringify(body), {
    status: init.status ?? 200,
    headers: {"content-type": "application/json", ...(init.headers || {})},
  })
}

beforeEach(() => {
  // Provide a minimal `document` so the CSRF reader runs.
  globalThis.document = {
    querySelector: () => ({getAttribute: () => "csrf-token-fixture"}),
  }
})

describe("fetchInstallEnvelope", () => {
  it("hits the browser route with no /v1/ prefix and parses the body", async () => {
    const calls = []
    const fetchImpl = vi.fn(async (url, init) => {
      calls.push({url, init})
      return jsonResponse({chain_id: 84_532, bundler_rpc_url: "http://localhost:9999"})
    })

    const envelope = await fetchInstallEnvelope("binding-abc", {fetch: fetchImpl})

    expect(envelope.chain_id).toBe(84_532)
    expect(calls[0].url).toBe("/wallet_bindings/binding-abc/install_envelope")
    expect(calls[0].init.method).toBe("GET")
    expect(calls[0].init.headers.accept).toBe("application/json")
    expect(calls[0].init.credentials).toBe("same-origin")
  })

  it("encodes the binding id in the URL", async () => {
    const fetchImpl = vi.fn(async (url) => {
      expect(url).toBe("/wallet_bindings/with%20spaces/install_envelope")
      return jsonResponse({chain_id: 84_532})
    })
    await fetchInstallEnvelope("with spaces", {fetch: fetchImpl})
  })

  it("throws with code='unknown' on an unrecognised non-2xx status", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse({error: {code: "binding_not_verified"}}, {status: 422}))
    await expect(fetchInstallEnvelope("b1", {fetch: fetchImpl})).rejects.toMatchObject({
      code: "binding_not_verified",
    })
  })

  it("throws with code='bundler_unavailable' on 5xx", async () => {
    const fetchImpl = vi.fn(async () => jsonResponse(null, {status: 503}))
    await expect(fetchInstallEnvelope("b1", {fetch: fetchImpl})).rejects.toMatchObject({
      code: "bundler_unavailable",
    })
  })

  it("throws with code='network_error' on fetch failure", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new TypeError("Failed to fetch")
    })
    await expect(fetchInstallEnvelope("b1", {fetch: fetchImpl})).rejects.toMatchObject({
      code: "network_error",
    })
  })

  it("throws with code='unknown' on missing binding id", async () => {
    const fetchImpl = vi.fn()
    await expect(fetchInstallEnvelope(null, {fetch: fetchImpl})).rejects.toThrow(/missing binding_id/)
    expect(fetchImpl).not.toHaveBeenCalled()
  })
})

describe("postSubmittedAttestation", () => {
  it("POSTs the canonical body with CSRF + same-origin credentials", async () => {
    const calls = []
    const fetchImpl = vi.fn(async (url, init) => {
      calls.push({url, init})
      return jsonResponse(null, {status: 202})
    })

    const result = await postSubmittedAttestation(
      "b1",
      {
        install_userop_hash: "0xhash",
        permission_id: "0xperm",
        validation_id: "0xvalid",
        smart_account_address: "0xsa",
      },
      {fetch: fetchImpl},
    )

    expect(result).toEqual({ok: true, status: 202})
    expect(calls[0].url).toBe("/wallet_bindings/b1/install_attestation")
    expect(calls[0].init.method).toBe("POST")
    expect(calls[0].init.headers["x-csrf-token"]).toBe("csrf-token-fixture")
    expect(calls[0].init.headers["content-type"]).toBe("application/json")
    expect(JSON.parse(calls[0].init.body)).toEqual({
      status: "submitted",
      install_userop_hash: "0xhash",
      permission_id: "0xperm",
      validation_id: "0xvalid",
      smart_account_address: "0xsa",
    })
  })
})

describe("postConfirmedAttestation", () => {
  it("POSTs the canonical confirmed body", async () => {
    const calls = []
    const fetchImpl = vi.fn(async (url, init) => {
      calls.push({url, init})
      return jsonResponse(null, {status: 202})
    })

    await postConfirmedAttestation(
      "b1",
      {install_userop_hash: "0xhash", tx_hash: "0xtx", block_number: 7_000_001},
      {fetch: fetchImpl},
    )

    expect(JSON.parse(calls[0].init.body)).toEqual({
      status: "confirmed",
      install_userop_hash: "0xhash",
      tx_hash: "0xtx",
      block_number: 7_000_001,
    })
  })
})

describe("postFailureAttestation", () => {
  it.each([
    ["user_rejected", "user_rejected"],
    ["bundler_rejected", "bundler_rejected"],
    ["bundler_unavailable", "bundler_rejected"],
    ["chain_id_mismatch", "bundler_rejected"],
    ["insufficient_funds", "bundler_rejected"],
    ["userop_reverted", "reverted"],
    ["attestation_timeout", "bundler_rejected"],
    ["unknown", "bundler_rejected"],
  ])("maps reason %s to status %s", async (reason, expectedStatus) => {
    const calls = []
    const fetchImpl = vi.fn(async (_url, init) => {
      calls.push({init})
      return jsonResponse(null, {status: 202})
    })
    await postFailureAttestation("b1", reason, {fetch: fetchImpl})
    const body = JSON.parse(calls[0].init.body)
    expect(body).toEqual({status: expectedStatus, reason})
  })

  it("does not crash if fetch throws — returns ok:false", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new TypeError("network down")
    })
    const result = await postFailureAttestation("b1", "user_rejected", {fetch: fetchImpl})
    expect(result.ok).toBe(false)
  })
})
