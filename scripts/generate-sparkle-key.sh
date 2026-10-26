#!/usr/bin/env bash
# One-time: create the EdDSA key pair Sparkle uses to sign app updates.
#
# The PRIVATE key is stored in the login keychain account com.sconeos.SconeOS (never leaves this machine, never
# committed), not Sparkle's default ed25519 account, which every app on the Mac shares and release-kit never signs from.
# The PUBLIC key is written to sparkle-public-key.txt, which IS committed and gets baked
# into the app's Info.plist (SUPublicEDKey) by release-kit so the updater can verify downloads.
#
# Export/back up the private key with:  generate_keys --account com.sconeos.SconeOS -x <backup file>
# (keep it somewhere safe, outside the repo)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/sparkle-public-key.txt"
ACCOUNT="com.sconeos.SconeOS"

GK="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
if [[ ! -x "$GK" ]]; then
  echo "generate-sparkle-key: $GK not found. Run 'swift build' first." >&2
  exit 1
fi

# An empty account would get a brand-new key, and installed copies only trust the key in sparkle-public-key.txt.
if ! "$GK" --account "$ACCOUNT" -p >/dev/null 2>&1 && [[ -s "$OUT" ]]; then
  echo "generate-sparkle-key: the keychain has no $ACCOUNT key, but $OUT already names one." >&2
  echo "  Import that key instead of generating a new one:" >&2
  echo "    $GK --account $ACCOUNT -f <exported key file>" >&2
  echo "  If it's only in Sparkle's shared ed25519 account, export it first with: $GK -x <file>" >&2
  exit 1
fi

# Idempotent: creates the keychain private key only if one does not already exist.
"$GK" --account "$ACCOUNT" >/dev/null

PUB="$("$GK" --account "$ACCOUNT" -p | tr -d '[:space:]')"
if [[ -z "$PUB" ]]; then
  echo "generate-sparkle-key: could not read the public key from the keychain" >&2
  exit 1
fi

printf '%s\n' "$PUB" >"$OUT"
echo "Wrote public key -> $OUT"
echo "  $PUB"
echo
echo "Next: commit sparkle-public-key.txt, then build with swift run devkit build release."
