#!/usr/bin/env sh
# Adapter runtime env hygiene check.
#
# Confirms every env var the adapter reads at startup is present and is
# not a literal placeholder, then reports which of three operational
# modes the adapter will come up in:
#
#   - sentinel-era       PERMISSION_VALIDATOR_ADDRESS unset; revoke is
#                        anchored via the sentinel UserOp only.
#   - straddle           PERMISSION_VALIDATOR_ADDRESS set, but
#                        KERNEL_PERMISSION_VALIDATOR_PIN (in
#                        src/chains/base/permission_validator.ts) is
#                        still null (#83 has not landed). Revoke is
#                        still sentinel; the runtime also logs a
#                        warn-level line saying so (see
#                        src/chains/base/revoke.ts). This mode is a
#                        WARN, not an error — it is legitimate during
#                        the rollout window between #84 and #83.
#   - kernel-provisioned PERMISSION_VALIDATOR_ADDRESS set AND the pin
#                        is populated. Cryptographic revoke (#58) will
#                        route the real ERC-7579 disable.
#
# NOT part of the adapter runtime. NOT a substitute for `loadConfig()`
# in src/config/index.ts — that is the authoritative loader and will
# still throw on missing values at server start. This script exists so
# an operator can fail fast on a half-configured host BEFORE starting
# the service, and so the operator can see which mode the host will
# come up in.
#
# Tracks: GitHub #84 (provisioning verification, Step 7).
#
# The full step-by-step runbook lives in the Phoenix repo at
# `docs/provisioning-kernel-v3.md`. This file implements
# Step 7 of that runbook.
#
# Usage:
#   sh scripts/check-env.sh                # check current shell env
#   ( set -a; . ./.env; sh scripts/check-env.sh )   # check a dotenv file
#
# Exit codes:
#   0 — every required env is set, no placeholders or malformed values
#       detected. Mode is reported on stdout but does NOT affect the
#       exit code: straddle is a WARN, not an error.
#   1 — at least one required env is missing, malformed, or holds a
#       placeholder.
#
# This script makes NO network calls. It reads only environment
# variables and a sibling TypeScript source file.

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

# Optional envs that have defaults or are mode-dependent.
OPTIONAL="
PORT
HOST
ADAPTER_TLS_CERT_PATH
ADAPTER_TLS_KEY_PATH
BASE_CHAIN_ID
ENTRY_POINT_ADDRESS
PERMISSION_VALIDATOR_ADDRESS
CONTRACT_VERSION
"

# Envs expected to hold a 0x-prefixed 20-byte EVM address.
ADDRESS_ENVS="
SMART_ACCOUNT_ADDRESS
USDC_CONTRACT_ADDRESS
ENTRY_POINT_ADDRESS
PERMISSION_VALIDATOR_ADDRESS
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

# Locate the sibling TS source so we can read the current value of
# KERNEL_PERMISSION_VALIDATOR_PIN. The script is run from repo root in
# practice; resolve relative to the script location so `cd` elsewhere
# doesn't break the check.
script_dir="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
pin_source="${script_dir}/../src/chains/base/permission_validator.ts"

# Returns 0 if KERNEL_PERMISSION_VALIDATOR_PIN is still null in source,
# 1 if it appears to be populated, 2 if we can't find the source file.
pin_is_null() {
  if [ ! -f "$pin_source" ]; then
    return 2
  fi
  # Match either a same-line or next-line `null` initializer. Anything
  # else (object literal, function call) is treated as "populated".
  # grep -E is POSIX.
  if grep -E "^export const KERNEL_PERMISSION_VALIDATOR_PIN[^=]*=[[:space:]]*null" \
      "$pin_source" >/dev/null 2>&1; then
    return 0
  fi
  # Multi-line form: declaration line ends with `=` and the next non-
  # blank line is `null`. Use sed/awk to peek.
  if awk '
    /^export const KERNEL_PERMISSION_VALIDATOR_PIN/ {
      found = 1
      # same line
      if ($0 ~ /=[[:space:]]*null/) { print "NULL"; exit }
      next
    }
    found && /^[[:space:]]*null[[:space:]]*;?[[:space:]]*$/ { print "NULL"; exit }
    found && NF > 0 { print "POPULATED"; exit }
  ' "$pin_source" | grep -q "^NULL$"; then
    return 0
  fi
  return 1
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
pv_addr="${PERMISSION_VALIDATOR_ADDRESS:-}"

# Determine pin state up front so the mode block can reason about it.
pin_state="unknown"
if pin_is_null; then
  pin_state="null"
else
  case $? in
    1) pin_state="populated" ;;
    2) pin_state="unknown" ;;
  esac
fi

if [ -z "$pv_addr" ]; then
  echo "  mode: sentinel-era"
  echo "  PERMISSION_VALIDATOR_ADDRESS is unset, so the adapter will use"
  echo "  the sentinel revoke path (writes an on-chain anchor; does NOT"
  echo "  cryptographically disable the delegation). This is correct for"
  echo "  v0.1 deploys but a Kernel-provisioned host MUST set this var."
  echo "  See docs/provisioning-kernel-v3.md."
elif is_placeholder "$pv_addr" || ! is_evm_address "$pv_addr"; then
  # The required/optional blocks above already recorded the error; the
  # mode line should say BROKEN so the operator sees both signals.
  echo "  mode: BROKEN"
  echo "  PERMISSION_VALIDATOR_ADDRESS is set but the value is not a"
  echo "  usable 0x-prefixed 20-byte address (placeholder or malformed)."
  echo "  Either unset this var (sentinel-era) or replace with the real"
  echo "  Permission Validator address recorded by the Step 6 receipt."
elif [ "$pin_state" = "null" ]; then
  echo "  mode: straddle (PERMISSION_VALIDATOR_ADDRESS set, pin null)"
  echo "  PERMISSION_VALIDATOR_ADDRESS=$pv_addr"
  echo "  KERNEL_PERMISSION_VALIDATOR_PIN in"
  echo "    src/chains/base/permission_validator.ts"
  echo "  is still null, so the live revoke remains sentinel until #83"
  echo "  lands a verified pin. The runtime mirrors this asymmetry with"
  echo "  a warn-level log in src/chains/base/revoke.ts. This is a WARN"
  echo "  state, not a failure — it is expected during the rollout"
  echo "  window between #84 and #83."
elif [ "$pin_state" = "populated" ]; then
  echo "  mode: kernel-provisioned"
  echo "  PERMISSION_VALIDATOR_ADDRESS=$pv_addr"
  echo "  KERNEL_PERMISSION_VALIDATOR_PIN appears populated in"
  echo "    src/chains/base/permission_validator.ts"
  echo "  The cryptographic revoke path (#58) will route the real"
  echo "  ERC-7579 disable. Confirm the pin's deployedBytecodeKeccak256"
  echo "  matches the receipt from scripts/verify-installed-validator.ts"
  echo "  before declaring the deploy healthy."
else
  echo "  mode: kernel-provisioned (pin state unverifiable locally)"
  echo "  PERMISSION_VALIDATOR_ADDRESS=$pv_addr"
  echo "  The sibling source file"
  echo "    $pin_source"
  echo "  was not found, so this script could not determine whether"
  echo "  KERNEL_PERMISSION_VALIDATOR_PIN is null. If you are running"
  echo "  this script outside the chain_adapter repo tree that is"
  echo "  expected; otherwise verify the path."
fi

echo
if [ "$errors" -gt 0 ]; then
  echo "FAIL: $errors required-env problem(s)"
  exit 1
fi
echo "PASS: required envs look healthy"
exit 0
