#!/usr/bin/env sh
# Adapter runtime env hygiene check.
#
# Confirms every env var the adapter reads at startup is present and is
# not a literal placeholder. Stays a no-secrets, no-RPC local script.
#
# An earlier version of this script also detected a tri-state revoke
# "mode" derived from a `PERMISSION_VALIDATOR_ADDRESS` env var and a
# parsed `KERNEL_PERMISSION_VALIDATOR_PIN` source-file constant. That
# model was wrong — `@zerodev/permissions` does not expose a single
# Permission Validator contract address, and the env var has been
# removed. The runtime is sentinel-era today and stays that way until
# the ZeroDev SDK integration described in
# `docs/zerodev-permissions-integration.md` ships.
#
# NOT part of the adapter runtime. NOT a substitute for `loadConfig()`
# in src/config/index.ts — that is the authoritative loader and will
# still throw on missing values at server start. This script exists so
# an operator can fail fast on a half-configured host BEFORE starting
# the service.
#
# Usage:
#   sh scripts/check-env.sh                # check current shell env
#   ( set -a; . ./.env; sh scripts/check-env.sh )   # check a dotenv file
#
# Exit codes:
#   0 — every required env is set, no placeholders or malformed values
#       detected.
#   1 — at least one required env is missing, malformed, or holds a
#       placeholder.
#
# This script makes NO network calls. It reads only environment
# variables.

set -u

# Required envs (no defaults in src/config/index.ts).
REQUIRED="
ADAPTER_DISPATCH_SECRET
ADAPTER_CALLBACK_SECRET
PHOENIX_BASE_URL
BASE_RPC_URL
BUNDLER_RPC_URL
SMART_ACCOUNT_ADDRESS
DELEGATION_SIGNER_KEY
USDC_CONTRACT_ADDRESS
"

# Optional envs that have defaults at load time.
OPTIONAL="
PORT
HOST
ADAPTER_TLS_CERT_PATH
ADAPTER_TLS_KEY_PATH
BASE_CHAIN_ID
ENTRY_POINT_ADDRESS
CONTRACT_VERSION
"

# Envs expected to hold a 0x-prefixed 20-byte EVM address.
ADDRESS_ENVS="
SMART_ACCOUNT_ADDRESS
USDC_CONTRACT_ADDRESS
ENTRY_POINT_ADDRESS
"

errors=0

# Mask secret values so a CI log does not leak them.
mask() {
  name="$1"
  value="$2"
  case "$name" in
    *SECRET*|*KEY|*PRIVATE*|*TOKEN*)
      len=${#value}
      if [ "$len" -le 8 ]; then
        echo "********"
      else
        echo "${value%????????}…[redacted ${len}c]"
      fi
      ;;
    *)
      echo "$value"
      ;;
  esac
}

is_placeholder() {
  case "$1" in
    *_placeholder|*_PLACEHOLDER) return 0 ;;
    *) return 1 ;;
  esac
}

# Returns 0 if $1 names an env expected to hold a 20-byte EVM address.
# We deliberately word-split $ADDRESS_ENVS on whitespace rather than
# relying on a multi-line case pattern, because `$ADDRESS_ENVS` is
# newline-separated and `*" $name "*` against a newline-wrapped value
# never matches in POSIX sh.
is_address_env() {
  needle="$1"
  # shellcheck disable=SC2086
  for candidate in $ADDRESS_ENVS; do
    if [ "$candidate" = "$needle" ]; then
      return 0
    fi
  done
  return 1
}

# Detect trailing whitespace on the raw env value. A stray space or
# newline pasted into a secrets UI is a real operator-error mode and
# silently breaks address comparisons downstream.
has_trailing_whitespace() {
  case "$1" in
    *" "|*"	"|*"
")
      return 0 ;;
    *) return 1 ;;
  esac
}

# Validate shape of an EVM address. EIP-55 checksum is deliberately
# NOT enforced — viem's `isAddress` accepts any-case 20-byte hex, and
# checksum policy belongs in the loader, not in a local preflight.
# This check only rejects obviously malformed inputs: wrong length,
# non-hex characters, missing 0x prefix.
is_evm_address() {
  addr="$1"
  # Must be exactly "0x" + 40 hex chars = 42 chars total.
  if [ "${#addr}" -ne 42 ]; then
    return 1
  fi
  case "$addr" in
    0x*|0X*) ;;
    *) return 1 ;;
  esac
  # Strip 0x / 0X prefix and test remaining chars are hex.
  rest="${addr#0[xX]}"
  # POSIX shell pattern: anything outside [0-9a-fA-F] is disallowed.
  case "$rest" in
    *[!0-9a-fA-F]*) return 1 ;;
    *) return 0 ;;
  esac
}

echo "== adapter env hygiene check =="

for name in $REQUIRED; do
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    echo "  MISSING   $name"
    errors=$((errors + 1))
    continue
  fi
  if is_placeholder "$value"; then
    echo "  PLACEHOLD $name=$value (literal placeholder)"
    errors=$((errors + 1))
    continue
  fi
  if has_trailing_whitespace "$value"; then
    echo "  WHITESPCE $name has trailing whitespace — re-paste without the trailing space/newline"
    errors=$((errors + 1))
    continue
  fi
  # Shape check for address-typed envs.
  if is_address_env "$name"; then
    if ! is_evm_address "$value"; then
      echo "  MALFORMED $name=$value (not a 0x-prefixed 20-byte hex address)"
      errors=$((errors + 1))
      continue
    fi
  fi
  echo "  ok        $name=$(mask "$name" "$value")"
done

echo
echo "-- optional --"
for name in $OPTIONAL; do
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    echo "  unset     $name"
    continue
  fi
  if is_placeholder "$value"; then
    echo "  PLACEHOLD $name=$value (literal placeholder)"
    errors=$((errors + 1))
    continue
  fi
  if has_trailing_whitespace "$value"; then
    echo "  WHITESPCE $name has trailing whitespace — re-paste without the trailing space/newline"
    errors=$((errors + 1))
    continue
  fi
  if is_address_env "$name"; then
    if ! is_evm_address "$value"; then
      echo "  MALFORMED $name=$value (not a 0x-prefixed 20-byte hex address)"
      errors=$((errors + 1))
      continue
    fi
  fi
  echo "  ok        $name=$(mask "$name" "$value")"
done

echo
echo "-- adapter mode --"
echo "  mode: sentinel-era (awaiting ZeroDev SDK integration)"
echo "  The adapter's revoke path is a sentinel UserOp (writes an"
echo "  on-chain anchor; does NOT cryptographically disable the"
echo "  delegation). The corrected ZeroDev permissions model — and"
echo "  the runtime SDK integration that lights up cryptographic"
echo "  revoke — is tracked in docs/zerodev-permissions-integration.md."

echo
if [ "$errors" -gt 0 ]; then
  echo "FAIL: $errors required-env problem(s)"
  exit 1
fi
echo "PASS: required envs look healthy"
exit 0
