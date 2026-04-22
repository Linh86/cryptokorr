#!/usr/bin/env sh
# Adapter runtime env hygiene check.
#
# Confirms every env var the adapter reads at startup is present and is
# not a literal placeholder, then reports whether the adapter is
# configured in sentinel-era mode (no Permission Validator) or
# Kernel-provisioned mode (validator address bound).
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
#   0 — every required env is set, no placeholders detected
#   1 — at least one required env is missing or holds a placeholder

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

echo "== adapter env hygiene check =="

for name in $REQUIRED; do
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    echo "  MISSING   $name"
    errors=$((errors + 1))
  elif is_placeholder "$value"; then
    echo "  PLACEHOLD $name=$value (literal placeholder)"
    errors=$((errors + 1))
  else
    echo "  ok        $name=$(mask "$name" "$value")"
  fi
done

echo
echo "-- optional --"
for name in $OPTIONAL; do
  eval "value=\${$name:-}"
  if [ -z "$value" ]; then
    echo "  unset     $name"
  elif is_placeholder "$value"; then
    echo "  PLACEHOLD $name=$value (literal placeholder)"
    errors=$((errors + 1))
  else
    echo "  ok        $name=$(mask "$name" "$value")"
  fi
done

echo
echo "-- adapter mode --"
pv_addr="${PERMISSION_VALIDATOR_ADDRESS:-}"
if [ -z "$pv_addr" ]; then
  echo "  mode: SENTINEL-ERA"
  echo "  PERMISSION_VALIDATOR_ADDRESS is unset, so the adapter will use"
  echo "  the sentinel revoke path (writes an on-chain anchor; does NOT"
  echo "  cryptographically disable the delegation). This is correct for"
  echo "  v0.1 deploys but a Kernel-provisioned host MUST set this var."
  echo "  See docs/provisioning-kernel-v3.md."
elif is_placeholder "$pv_addr"; then
  echo "  mode: BROKEN — PERMISSION_VALIDATOR_ADDRESS is a placeholder."
  echo "  The strict accessor will throw at revoke time. Either unset"
  echo "  this var (sentinel-era) or set it to a real validator address."
else
  echo "  mode: KERNEL-PROVISIONED"
  echo "  PERMISSION_VALIDATOR_ADDRESS=$pv_addr"
  echo "  The cryptographic revoke path (#58) will use this validator."
  echo "  Confirm the address is the one #83 pinned a verified ABI"
  echo "  fragment against before relying on it for production revokes."
fi

echo
if [ "$errors" -gt 0 ]; then
  echo "FAIL: $errors required-env problem(s)"
  exit 1
fi
echo "PASS: required envs look healthy"
exit 0
