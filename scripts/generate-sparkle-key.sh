#!/usr/bin/env bash
# One-time: create the EdDSA key pair Sparkle uses to sign app updates.
#
# The PRIVATE key is stored in your login keychain (never leaves this machine, never committed).
# The PUBLIC key is written to sparkle-public-key.txt, which IS committed and gets baked
# into the app's Info.plist (SUPublicEDKey) by release-kit so the updater can verify downloads.
#
# Export/back up the private key with:  generate_keys -x sparkle_private.key  (keep it somewhere safe)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/sparkle-public-key.txt"

GK="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
if [[ ! -x "$GK" ]]; then
  echo "generate-sparkle-key: $GK not found. Run 'swift build' first." >&2
  exit 1
fi

# Idempotent: creates the keychain private key only if one does not already exist.
"$GK" >/dev/null

PUB="$("$GK" -p | tr -d '[:space:]')"
if [[ -z "$PUB" ]]; then
  echo "generate-sparkle-key: could not read the public key from the keychain" >&2
  exit 1
fi

printf '%s\n' "$PUB" >"$OUT"
echo "Wrote public key -> $OUT"
echo "  $PUB"
echo
echo "Next: commit sparkle-public-key.txt, then build with ./run dev build release."
