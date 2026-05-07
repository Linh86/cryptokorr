#!/usr/bin/env bash
# Pre-commit guard against committing literal private keys or known dev secrets.
#
# Source of truth: docs/runbooks/secrets-rotation.md (audit finding C1).
#
# Usage:
#   make hooks-install     # install as .git/hooks/pre-commit
#   git commit             # script runs automatically; non-zero exit blocks
#   git commit --no-verify # bypass (only for audited test fixtures)
#
# What this guards against:
#   * Env-style assignments: `<UPPER>_KEY=0x<64-hex>` and similar.
#   * Bare 64-hex values prefixed with 0x outside known-safe paths.
#   * The literal placeholder dev secrets that shipped in the original
#     `chain_adapter/.env` (`dev-adapter-dispatch-secret`,
#     `dev-adapter-callback-secret`).
#
# What this does NOT guard:
#   * Address-shaped 40-hex values (public).
#   * Hashes, signatures, calldata (on-chain artifacts).
#   * Any of the safe paths listed in SAFE_PATH_REGEX below.
#
# Failure mode: prints offending lines with file:line, exits 1.

set -euo pipefail

# ---- regex catalog ---------------------------------------------------------

# 64-hex strings prefixed with 0x. Anchored loosely so we catch both
# `KEY=0x...` and bare `0x...` in source.
PRIVATE_KEY_REGEX='0x[0-9a-fA-F]{64}\b'

# Known-bad placeholder dev secrets that shipped in early .env scaffolding.
# Add new entries here when you discover one in the wild.
KNOWN_BAD_LITERALS_REGEX='dev-adapter-(dispatch|callback)-secret'

# Paths where 64-hex values are expected (test fixtures, lockfiles, examples).
# Anything matching this regex is allowed to contain matches.
SAFE_PATH_REGEX='(^|/)(test/|chain_adapter/test/|chain_adapter/dist/|priv/repo/seeds\.exs|.*\.example$|.*\.lock$|mix\.lock$|chain_adapter/package-lock\.json$|.*/node_modules/|_build/|deps/)'

# Repo root (script is invoked from .git/hooks/pre-commit so $PWD is correct,
# but we resolve explicitly to be safe).
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

# ---- collect staged additions ---------------------------------------------

# Staged file list, exclude deletions (D), only Added/Modified/Renamed.
mapfile -t STAGED < <(git diff --cached --name-only --diff-filter=AMR)

if [[ ${#STAGED[@]} -eq 0 ]]; then
  exit 0
fi

violations=0

# ---- per-file scan --------------------------------------------------------

scan_file() {
  local path="$1"

  # Skip safe paths entirely.
  if [[ "$path" =~ $SAFE_PATH_REGEX ]]; then
    return 0
  fi

  # Skip binary files.
  if ! git diff --cached --numstat -- "$path" | grep -qE '^[0-9]+\s+[0-9]+\s'; then
    return 0
  fi

  # Pull only the lines being ADDED in this commit (prefix +, not +++).
  # Annotate with `git diff` line numbers so we can report file:line.
  local hits
  hits="$(
    git diff --cached -U0 -- "$path" |
      awk -v path="$path" '
        # POSIX-portable @@ parser — works under BSD awk (macOS) and gawk.
        /^@@/ {
          # @@ -a,b +c,d @@  → find token starting with "+"
          for (i = 1; i <= NF; i++) {
            tok = $i
            if (substr(tok, 1, 1) == "+") {
              sub(/,.*/, "", tok)         # drop the count after the comma
              sub(/^\+/, "", tok)         # drop leading +
              ln = tok + 0 - 1            # numeric coercion; -1 because /^\+/ below pre-increments
              break
            }
          }
          next
        }
        /^\+\+\+/ { next }
        /^\+/ {
          ln++
          line = substr($0, 2)            # strip leading +
          print path ":" ln ":" line
        }
        /^-/  { next }
        /^ /  { ln++ }
      '
  )"

  if [[ -z "$hits" ]]; then
    return 0
  fi

  # Filter the added lines for our regex catalog.
  local pk_hits bad_hits
  pk_hits="$(echo "$hits" | grep -E "$PRIVATE_KEY_REGEX" || true)"
  bad_hits="$(echo "$hits" | grep -E "$KNOWN_BAD_LITERALS_REGEX" || true)"

  if [[ -n "$pk_hits" ]]; then
    echo
    echo "❌ Possible private key (0x + 64 hex) staged in: $path"
    echo "$pk_hits" | sed 's/^/   /'
    violations=$((violations + 1))
  fi

  if [[ -n "$bad_hits" ]]; then
    echo
    echo "❌ Known-bad dev secret literal staged in: $path"
    echo "$bad_hits" | sed 's/^/   /'
    violations=$((violations + 1))
  fi
}

for path in "${STAGED[@]}"; do
  scan_file "$path"
done

# ---- exit -----------------------------------------------------------------

if [[ "$violations" -gt 0 ]]; then
  cat <<EOF

────────────────────────────────────────────────────────────────────
secret-guard: blocked ${violations} probable secret(s) in staged changes.

If this is a real secret:
  * Do NOT amend over it. Rotate the secret first
    (docs/runbooks/secrets-rotation.md).
  * Then unstage the file and re-commit without the literal.

If this is a documented test fixture or example:
  * Move it under one of the safe paths (test/, *.example, etc.) OR
  * Add the path to SAFE_PATH_REGEX in scripts/secret-guard.sh.

To bypass once for an audited addition:
  git commit --no-verify   # explain why in the commit message.
────────────────────────────────────────────────────────────────────
EOF
  exit 1
fi

exit 0
