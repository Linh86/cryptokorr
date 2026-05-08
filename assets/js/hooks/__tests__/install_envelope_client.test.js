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
  mapBeFailureCode,
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
  it("POSTs the canonical body with CSRF + same-origin credentials and returns parsed body on ok", async () => {
    const calls = []
    const fetchImpl = vi.fn(async (url, init) => {
      calls.push({url, init})
      return jsonResponse({state: "pending", delegation_id: "deleg-1"}, {status: 202})
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

    expect(result).toEqual({state: "pending", delegation_id: "deleg-1"})
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

// ─────────────────────────────────────────────────────────────────────
// P2 hardening: STRICT failure handling on the submitted/confirmed
// attestation POSTs. These two POSTs are the BE's "ack" for the
// install state machine. If the BE returns non-2xx, the hook must
// NOT push `:submitted` / `:confirmed` to the LiveView — otherwise
// the UI advances past `:installing` while the DB has no anchored
// row to back it.
//
// The strict contract:
//   * `response.ok === true`  → resolve with the parsed JSON body
//                                (or `{}` if the body isn't JSON).
//   * `response.ok === false` → throw an Error with `status` (HTTP
//                                status) and `code` (BE-supplied
//                                error.code or generic
//                                `attestation_rejected` fallback).
//   * fetch() throws          → throw an Error with
//                                `code: "network_error"`.
// ─────────────────────────────────────────────────────────────────────

describe("postSubmittedAttestation — strict failure handling", () => {
  it("throws with BE-supplied error.code on 403", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({error: {code: "binding_revoked"}}, {status: 403}),
    )
    await expect(
      postSubmittedAttestation(
        "b1",
        {
          install_userop_hash: "0xhash",
          permission_id: "0xperm",
          validation_id: "0xvalid",
        },
        {fetch: fetchImpl},
      ),
    ).rejects.toMatchObject({status: 403, code: "binding_revoked"})
  })

  it("throws with BE-supplied error.code on 422", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({error: {code: "workspace_paused", message: "paused"}}, {status: 422}),
    )
    await expect(
      postSubmittedAttestation(
        "b1",
        {
          install_userop_hash: "0xhash",
          permission_id: "0xperm",
          validation_id: "0xvalid",
        },
        {fetch: fetchImpl},
      ),
    ).rejects.toMatchObject({status: 422, code: "workspace_paused"})
  })

  it("throws with code='attestation_rejected' fallback on 500 with empty body", async () => {
    const fetchImpl = vi.fn(
      async () => new Response("", {status: 500, headers: {"content-type": "text/plain"}}),
    )
    await expect(
      postSubmittedAttestation(
        "b1",
        {
          install_userop_hash: "0xhash",
          permission_id: "0xperm",
          validation_id: "0xvalid",
        },
        {fetch: fetchImpl},
      ),
    ).rejects.toMatchObject({status: 500, code: "attestation_rejected"})
  })

  it("throws with code='attestation_rejected' on 4xx with malformed body", async () => {
    const fetchImpl = vi.fn(
      async () =>
        new Response("not-json-at-all", {
          status: 422,
          headers: {"content-type": "text/plain"},
        }),
    )
    await expect(
      postSubmittedAttestation(
        "b1",
        {
          install_userop_hash: "0xhash",
          permission_id: "0xperm",
          validation_id: "0xvalid",
        },
        {fetch: fetchImpl},
      ),
    ).rejects.toMatchObject({status: 422, code: "attestation_rejected"})
  })

  it("throws with code='network_error' when fetch itself throws", async () => {
    const fetchImpl = vi.fn(async () => {
      throw new TypeError("Failed to fetch")
    })
    await expect(
      postSubmittedAttestation(
        "b1",
        {
          install_userop_hash: "0xhash",
          permission_id: "0xperm",
          validation_id: "0xvalid",
        },
        {fetch: fetchImpl},
      ),
    ).rejects.toMatchObject({code: "network_error", status: 0})
  })

  it("accepts a top-level `code` field as the fallback shape", async () => {
    // Some auxiliary error responders use `{code: "..."}` directly
    // rather than `{error: {code: "..."}}`. Both shapes are
    // accepted by the strict mapper.
    const fetchImpl = vi.fn(async () => jsonResponse({code: "runtime_paused"}, {status: 422}))
    await expect(
      postSubmittedAttestation(
        "b1",
        {
          install_userop_hash: "0xhash",
          permission_id: "0xperm",
          validation_id: "0xvalid",
        },
        {fetch: fetchImpl},
      ),
    ).rejects.toMatchObject({status: 422, code: "runtime_paused"})
  })
})

describe("postConfirmedAttestation — strict failure handling", () => {
  it("throws with BE-supplied error.code on 403", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({error: {code: "binding_revoked"}}, {status: 403}),
    )
    await expect(
      postConfirmedAttestation(
        "b1",
        {install_userop_hash: "0xhash", tx_hash: "0xtx", block_number: 1},
        {fetch: fetchImpl},
      ),
    ).rejects.toMatchObject({status: 403, code: "binding_revoked"})
  })

  it("throws with code='attestation_rejected' on 422 with empty body", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse(undefined, {status: 422, headers: {"content-type": "text/plain"}}),
    )
    await expect(
      postConfirmedAttestation(
        "b1",
        {install_userop_hash: "0xhash", tx_hash: "0xtx", block_number: 1},
        {fetch: fetchImpl},
      ),
    ).rejects.toMatchObject({status: 422, code: "attestation_rejected"})
  })

  it("throws with code='attestation_rejected' on a 5xx with no body", async () => {
    const fetchImpl = vi.fn(
      async () => new Response("", {status: 502, headers: {"content-type": "text/plain"}}),
    )
    await expect(
      postConfirmedAttestation(
        "b1",
        {install_userop_hash: "0xhash", tx_hash: "0xtx", block_number: 1},
        {fetch: fetchImpl},
      ),
    ).rejects.toMatchObject({status: 502, code: "attestation_rejected"})
  })
})

describe("postSubmittedAttestation — strict success path", () => {
  it("resolves with the parsed body on a 200 response", async () => {
    const fetchImpl = vi.fn(async () =>
      jsonResponse({state: "pending", delegation_id: "del-7"}, {status: 200}),
    )
    const result = await postSubmittedAttestation(
      "b1",
      {install_userop_hash: "0xhash", permission_id: "0xperm", validation_id: "0xvalid"},
      {fetch: fetchImpl},
    )
    expect(result).toEqual({state: "pending", delegation_id: "del-7"})
  })

  it("resolves with `{}` on a 202 with empty body", async () => {
    const fetchImpl = vi.fn(
      async () => new Response("", {status: 202, headers: {"content-type": "text/plain"}}),
    )
    const result = await postSubmittedAttestation(
      "b1",
      {install_userop_hash: "0xhash", permission_id: "0xperm", validation_id: "0xvalid"},
      {fetch: fetchImpl},
    )
    expect(result).toEqual({})
  })
})

describe("mapBeFailureCode — BE error code → JS failure-category atom", () => {
  it.each([
    // BE refusal codes → bundler_rejected
    ["binding_revoked", "bundler_rejected"],
    ["binding_not_verified", "bundler_rejected"],
    ["workspace_paused", "bundler_rejected"],
    ["runtime_paused", "bundler_rejected"],
    ["invalid_attestation", "bundler_rejected"],
    ["invalid_status", "bundler_rejected"],
    ["duplicate_install", "bundler_rejected"],
    ["attestation_rejected", "bundler_rejected"],
    // Chain mismatch is its own category
    ["unsupported_chain", "chain_id_mismatch"],
    // Network-layer issues map to bundler_unavailable
    ["network_error", "bundler_unavailable"],
    // Auth-layer issues collapse to unknown — operator must
    // re-auth, not retry; the failure-category vocabulary doesn't
    // distinguish these and they're rare on a logged-in session
    ["forbidden", "unknown"],
    ["unauthenticated", "unknown"],
    ["not_found", "unknown"],
  ])("maps %s → %s", (code, expected) => {
    expect(mapBeFailureCode(code)).toBe(expected)
  })

  it("returns null for an unrecognised code so the caller falls back", () => {
    expect(mapBeFailureCode("totally-novel-code")).toBeNull()
    expect(mapBeFailureCode(null)).toBeNull()
    expect(mapBeFailureCode(undefined)).toBeNull()
  })
})
