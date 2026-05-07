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
 */
export async function postSubmittedAttestation(bindingId, payload, opts = {}) {
  const body = {
    status: "submitted",
    install_userop_hash: payload.install_userop_hash,
    permission_id: payload.permission_id,
    validation_id: payload.validation_id,
  }
  if (payload.smart_account_address) body.smart_account_address = payload.smart_account_address
  return postAttestation(bindingId, body, opts)
}

/**
 * POST a `confirmed` attestation. Phoenix flips the row to
 * `:active` only after the on-chain verifier (#474) re-checks
 * kernel state.
 */
export async function postConfirmedAttestation(bindingId, payload, opts = {}) {
  const body = {
    status: "confirmed",
    install_userop_hash: payload.install_userop_hash,
    tx_hash: payload.tx_hash,
    block_number: payload.block_number,
  }
  return postAttestation(bindingId, body, opts)
}

/**
 * POST a failure attestation with a reason from
 * `Bank.SessionPermissions.BrowserInstall.failure_categories/0`.
 * Pass the failure category atom as a string (e.g.
 * `"user_rejected"`).
 */
export async function postFailureAttestation(bindingId, reason, opts = {}) {
  const status = mapReasonToStatus(reason)
  const body = {status, reason}
  if (opts.install_userop_hash) body.install_userop_hash = opts.install_userop_hash
  return postAttestation(bindingId, body, {...opts, install_userop_hash: undefined})
}

async function postAttestation(bindingId, body, opts) {
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
    // Attestation post failures must not crash the hook — surface
    // them so the caller can still update the local UI even if
    // Phoenix is briefly unreachable.
    return {ok: false, status: 0, error: err && err.message ? err.message : String(err)}
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
