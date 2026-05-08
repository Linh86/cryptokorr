// Browser-route fetch helpers for the session permission install
// flow (#501). All requests carry the Phoenix CSRF token from the
// `<meta name="csrf-token">` tag; the browser routes themselves
// land under #500 (Worker B).
//
// **No bundler URLs, no API keys, no ZeroDev SDK in this module.**
// This module is the boundary between the hook (which knows the
// state machine) and Phoenix (which is the source of truth for the
// envelope and the failure-category allowlist).

const ENVELOPE_PATH_PREFIX = "/wallet_bindings/"
const ENVELOPE_PATH_SUFFIX = "/install_envelope"
const ATTESTATION_PATH_SUFFIX = "/install_attestation"

function csrfToken() {
  if (typeof document === "undefined") return null
  const meta = document.querySelector("meta[name='csrf-token']")
  return meta ? meta.getAttribute("content") : null
}

function buildHeaders(method) {
  const headers = {accept: "application/json"}
  if (method !== "GET") {
    headers["content-type"] = "application/json"
    const token = csrfToken()
    if (token) headers["x-csrf-token"] = token
  }
  return headers
}

function buildUrl(prefix, bindingId, suffix) {
  if (!bindingId || typeof bindingId !== "string") {
    throw new Error("session_permission_install: missing binding_id")
  }
  return prefix + encodeURIComponent(bindingId) + suffix
}

/**
 * GET the canonical install envelope from Phoenix. Returns the
 * envelope on 200; throws an Error on non-200 / parse failure with
 * a structured `code` property mapped to the failure-category
 * allowlist where possible.
 */
export async function fetchInstallEnvelope(bindingId, opts = {}) {
  const fetchImpl = opts.fetch || globalThis.fetch
  const url = buildUrl(ENVELOPE_PATH_PREFIX, bindingId, ENVELOPE_PATH_SUFFIX)

  let response
  try {
    response = await fetchImpl(url, {method: "GET", headers: buildHeaders("GET"), credentials: "same-origin"})
  } catch (err) {
    const wrapped = new Error("envelope_network_error")
    wrapped.cause = err
    wrapped.code = "network_error"
    throw wrapped
  }

  let body = null
  try {
    body = await response.json()
  } catch {
    body = null
  }

  if (!response.ok) {
    const wrapped = new Error("envelope_request_failed")
    wrapped.code = (body && body.error && body.error.code) || mapHttpToFailure(response.status)
    wrapped.status = response.status
    throw wrapped
  }
  if (!body || typeof body !== "object") {
    const wrapped = new Error("envelope_invalid_body")
    wrapped.code = "unknown"
    throw wrapped
  }
  return body
}

/**
 * POST a `submitted` attestation. Body matches Phoenix's
 * `Bank.SessionPermissions.BrowserInstall.record_attestation/3`
 * required keys for status `submitted`.
 *
 * STRICT: throws on any non-2xx response. The thrown error has a
 * structured `code` mapped to the failure-category allowlist (or
 * the BE-supplied `error.code` when present) and a `status`
 * carrying the HTTP status. Callers MUST treat a thrown error as
 * "the BE did NOT accept the attestation" and refuse to advance
 * the UI past `:installing` on the back of it.
 */
export async function postSubmittedAttestation(bindingId, payload, opts = {}) {
  const body = {
    status: "submitted",
    install_userop_hash: payload.install_userop_hash,
    permission_id: payload.permission_id,
    validation_id: payload.validation_id,
  }
  if (payload.smart_account_address) body.smart_account_address = payload.smart_account_address
  return postAttestationStrict(bindingId, body, opts)
}

/**
 * POST a `confirmed` attestation. Phoenix flips the row to
 * `:active` only after the on-chain verifier (#474) re-checks
 * kernel state.
 *
 * STRICT: throws on any non-2xx response (see
 * `postSubmittedAttestation`).
 */
export async function postConfirmedAttestation(bindingId, payload, opts = {}) {
  const body = {
    status: "confirmed",
    install_userop_hash: payload.install_userop_hash,
    tx_hash: payload.tx_hash,
    block_number: payload.block_number,
  }
  return postAttestationStrict(bindingId, body, opts)
}

/**
 * POST a failure attestation with a reason from
 * `Bank.SessionPermissions.BrowserInstall.failure_categories/0`.
 * Pass the failure category atom as a string (e.g.
 * `"user_rejected"`).
 *
 * LENIENT: never throws. The hook is already on a failure path
 * when this fires; we don't want a Phoenix outage to mask the
 * original failure reason in the UI. Returns `{ok, status}` so
 * callers can log if they want, but no caller is required to.
 */
export async function postFailureAttestation(bindingId, reason, opts = {}) {
  const status = mapReasonToStatus(reason)
  const body = {status, reason}
  if (opts.install_userop_hash) body.install_userop_hash = opts.install_userop_hash
  return postAttestationLenient(bindingId, body, {...opts, install_userop_hash: undefined})
}

/**
 * STRICT POST helper. On `response.ok === false`, throws an Error
 * with `status` (HTTP status) and `code` (BE-supplied error code
 * if the body parses as `{error: {code: ...}}` or `{code: ...}`,
 * otherwise `"attestation_rejected"`). On a network failure
 * (fetch throws), throws an Error with `code: "network_error"`.
 */
async function postAttestationStrict(bindingId, body, opts = {}) {
  const fetchImpl = opts.fetch || globalThis.fetch
  const url = buildUrl(ENVELOPE_PATH_PREFIX, bindingId, ATTESTATION_PATH_SUFFIX)

  let response
  try {
    response = await fetchImpl(url, {
      method: "POST",
      headers: buildHeaders("POST"),
      credentials: "same-origin",
      body: JSON.stringify(body),
    })
  } catch (err) {
    const wrapped = new Error("attestation_network_error")
    wrapped.cause = err
    wrapped.code = "network_error"
    wrapped.status = 0
    throw wrapped
  }

  if (!response.ok) {
    let code = "attestation_rejected"
    try {
      const parsed = await response.json()
      const beCode = (parsed && parsed.error && parsed.error.code) || (parsed && parsed.code)
      if (typeof beCode === "string" && beCode.length > 0) code = beCode
    } catch {
      // Body wasn't JSON; fall through with the generic code.
    }
    const err = new Error("attestation POST failed: " + response.status)
    err.status = response.status
    err.code = code
    throw err
  }

  try {
    return await response.json()
  } catch {
    return {}
  }
}

/**
 * LENIENT POST helper used for failure attestations. Never throws
 * — returns `{ok, status}` so the hook can keep walking the
 * failure path even if Phoenix is briefly unreachable.
 */
async function postAttestationLenient(bindingId, body, opts) {
  const fetchImpl = opts.fetch || globalThis.fetch
  const url = buildUrl(ENVELOPE_PATH_PREFIX, bindingId, ATTESTATION_PATH_SUFFIX)
  try {
    const response = await fetchImpl(url, {
      method: "POST",
      headers: buildHeaders("POST"),
      credentials: "same-origin",
      body: JSON.stringify(body),
    })
    return {ok: response.ok, status: response.status}
  } catch (err) {
    return {ok: false, status: 0, error: err && err.message ? err.message : String(err)}
  }
}

/**
 * Map a BE-supplied error code (or generic fallback) to a JS
 * failure-category string compatible with
 * `Bank.SessionPermissions.BrowserInstall.failure_categories/0`.
 * Used by the hook when a strict attestation POST throws — the
 * hook needs an atom-shaped reason to push to the LiveView even
 * though the BE refusal vocabulary is wider than the
 * failure-category allowlist.
 */
export function mapBeFailureCode(code) {
  switch (code) {
    case "binding_revoked":
    case "binding_not_verified":
    case "workspace_paused":
    case "runtime_paused":
    case "invalid_attestation":
    case "invalid_status":
    case "duplicate_install":
    case "attestation_rejected":
      return "bundler_rejected"
    case "unsupported_chain":
      return "chain_id_mismatch"
    case "network_error":
      return "bundler_unavailable"
    case "forbidden":
    case "unauthenticated":
    case "not_found":
      return "unknown"
    default:
      return null
  }
}

function mapHttpToFailure(status) {
  if (status === 401 || status === 403) return "unknown"
  if (status === 404) return "unknown"
  if (status === 409) return "unknown"
  if (status === 422) return "unknown"
  if (status === 429) return "bundler_unavailable"
  if (status >= 500) return "bundler_unavailable"
  return "unknown"
}

// Phoenix's `parse_status/1` accepts: submitted | confirmed |
// user_rejected | bundler_rejected | reverted. Failure-reason
// allowlist (failure_categories/0) is independent.
function mapReasonToStatus(reason) {
  switch (reason) {
    case "user_rejected":
      return "user_rejected"
    case "bundler_rejected":
    case "bundler_unavailable":
    case "chain_id_mismatch":
    case "insufficient_funds":
    case "attestation_timeout":
      return "bundler_rejected"
    case "userop_reverted":
      return "reverted"
    default:
      return "bundler_rejected"
  }
}
