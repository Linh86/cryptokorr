// Shared EIP-6963 wallet-provider registry.
//
// Both the `WalletConnect` and `SessionPermissionInstall` hooks need
// to call `request()` against the SAME injected wallet — otherwise the
// user picks MetaMask in the multi-wallet picker but the install hook
// keeps asking whichever wallet won the `window.ethereum` last-write
// race (typically Trust). Centralising the registry here prevents
// that drift.
//
// Discovery happens once per page load via the EIP-6963 protocol
// (`eip6963:announceProvider` events). When the user picks a wallet
// via the LiveView picker, the server pushes
// `wallet_connect:use_provider` with a uuid — each hook's
// `handleEvent` then calls `selectByUuid(uuid)` from this module.
// `getProvider()` then returns the selected EIP-1193 provider object;
// non-EIP-6963 wallets fall back to `window.ethereum`.
//
// The registry is a module-level singleton intentionally — hooks
// mount/unmount independently but the user's wallet selection is a
// page-level concern.

// Persist the selection by `rdns` (e.g. `"io.metamask"`), not by
// `uuid`. EIP-6963 says uuid SHOULD be unique per call — extensions
// typically regenerate it on every page load — so a uuid in
// localStorage almost never matches a provider on the next visit.
// `rdns` is the stable canonical wallet identifier.
const STORAGE_KEY = "cb:wallet:selected_rdns"

const providers = new Map() // uuid → { info, provider }
const subscribers = new Set() // observer callbacks
let selectedProvider = null
let selectedUuid = null
let discoveryStarted = false

// localStorage helpers — wrapped so test envs / privacy-mode browsers
// without storage access can't crash the registry.
function persistRdns(rdns) {
  try {
    if (rdns) {
      window.localStorage.setItem(STORAGE_KEY, rdns)
    } else {
      window.localStorage.removeItem(STORAGE_KEY)
    }
  } catch (_) {
    // No storage — selection is in-memory only this session.
  }
}

function readPersistedRdns() {
  try {
    return window.localStorage.getItem(STORAGE_KEY)
  } catch (_) {
    return null
  }
}

function notify() {
  const list = listInfos()
  for (const cb of subscribers) {
    try {
      cb(list, selectedProvider)
    } catch (_) {
      // Swallow per-subscriber errors so one buggy hook doesn't
      // poison the rest of the registry.
    }
  }
}

function handleAnnounce(event) {
  const detail = event && event.detail
  if (!detail || !detail.info || !detail.provider) return
  const info = detail.info
  if (!info.uuid) return
  providers.set(info.uuid, {info, provider: detail.provider})

  // If localStorage remembered the user's previous pick by rdns,
  // restore it as soon as that wallet announces. Survives page
  // reloads so the install flow doesn't fall back to whichever
  // wallet won the last-write race over `window.ethereum`.
  if (!selectedProvider) {
    const persistedRdns = readPersistedRdns()
    if (persistedRdns && info.rdns === persistedRdns) {
      selectedUuid = info.uuid
      selectedProvider = detail.provider
    }
  }

  notify()
}

// Boot the registry. Idempotent — repeated calls during multiple hook
// `mounted()` lifecycles are no-ops after the first.
export function startDiscovery() {
  if (discoveryStarted) return
  discoveryStarted = true
  window.addEventListener("eip6963:announceProvider", handleAnnounce)
  window.dispatchEvent(new Event("eip6963:requestProvider"))
}

// Subscribe to provider changes. Callback receives `(infos[], selectedProvider)`
// on every announcement and on every selection. Returns an unsubscribe fn.
export function subscribe(callback) {
  subscribers.add(callback)
  // Fire immediately so the subscriber sees current state.
  try {
    callback(listInfos(), selectedProvider)
  } catch (_) {}
  return () => subscribers.delete(callback)
}

// Pure data — info entries (uuid/name/rdns/icon) for the LiveView
// picker. Provider objects stay inside the registry; only the
// hooks call `request()` on them.
export function listInfos() {
  const list = []
  for (const {info} of providers.values()) {
    list.push({uuid: info.uuid, name: info.name, rdns: info.rdns, icon: info.icon})
  }
  return list
}

// Server tells us which wallet the user picked. Returns the provider
// (or null when the uuid is unknown — e.g. wallet got removed).
// Persists the selection in localStorage by `rdns` (the stable
// canonical wallet id, e.g. "io.metamask") so a page reload doesn't
// drop us back to "first announced wins".
export function selectByUuid(uuid) {
  const entry = providers.get(uuid)
  if (!entry) return null
  selectedUuid = uuid
  selectedProvider = entry.provider
  persistRdns(entry.info.rdns)
  notify()
  return selectedProvider
}

// Active provider for `request()` calls. Falls back to the first
// announced provider, then to legacy `window.ethereum`. Used by both
// hooks instead of reading `window.ethereum` directly.
export function getProvider() {
  if (selectedProvider) return selectedProvider
  for (const {provider} of providers.values()) return provider
  return typeof window !== "undefined" ? window.ethereum || null : null
}

// Auto-pick the wallet that already has accounts authorized for this
// origin. The persisted-uuid path covers the common case where the
// user picked once and reloads later, but if localStorage was cleared
// or never populated (incognito, first-load, different machine), we
// can still recover by asking each announced provider for its
// `eth_accounts` (passive — no popup) and picking the first one with
// a non-empty result. Trust answers `[]` for an unauthorized origin
// and MetaMask answers `[address]` if the user previously approved
// the dapp; this picks MetaMask.
//
// Idempotent: returns the already-selected provider if a selection
// exists. Returns null when no provider has authorized accounts —
// that's the fresh-install case, the user must click the picker /
// connect button to grant access first.
export async function autoSelectActive() {
  if (selectedProvider) return selectedProvider
  for (const [uuid, {provider}] of providers) {
    let accounts
    try {
      accounts = await provider.request({method: "eth_accounts"})
    } catch (_) {
      continue
    }
    if (accounts && accounts.length > 0) {
      const entry = providers.get(uuid)
      selectedUuid = uuid
      selectedProvider = provider
      if (entry) persistRdns(entry.info.rdns)
      notify()
      return provider
    }
  }
  return null
}

// Test-only escape hatch — drops all state so unit tests don't leak
// across cases. Not called from production code.
export function __resetForTests() {
  providers.clear()
  subscribers.clear()
  selectedProvider = null
  selectedUuid = null
  discoveryStarted = false
  try {
    window.localStorage.removeItem(STORAGE_KEY)
  } catch (_) {}
}
