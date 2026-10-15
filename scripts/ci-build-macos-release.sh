#!/usr/bin/env bash
# CI-only: compute version from merged PR checkbox, build, and package a macOS release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

if [[ -z "${SPARKLE_ED_PRIVATE_KEY_BASE64:-}" ]]; then
  echo "ci-build-macos-release: SPARKLE_ED_PRIVATE_KEY_BASE64 is required." >&2
  exit 1
fi

decode_secret_b64() {
  printf '%s' "$1" | tr -d '[:space:]' | base64 -D 2>/dev/null || printf '%s' "$1" | tr -d '[:space:]' | base64 -d
}

decode_secret_b64 "$SPARKLE_ED_PRIVATE_KEY_BASE64" > /tmp/sparkle_ed.key
export SPARKLE_ED_KEY_FILE=/tmp/sparkle_ed.key

SIGN_ID="$(resolve_sign_identity)"
echo "ci-build-macos-release: signing identity=${SIGN_ID}" >&2
export SCONEOS_SIGN_IDENTITY="$SIGN_ID"

cd "$ROOT"
swift build -c release --product Sconeos

VERSION="$("$ROOT/scripts/next-release-version.sh")"
echo "ci-build-macos-release: packaging v${VERSION}"
"$ROOT/scripts/package-release.sh" "$VERSION"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "version=${VERSION}" >> "$GITHUB_OUTPUT"
fi
