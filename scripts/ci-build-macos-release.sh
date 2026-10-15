#!/usr/bin/env bash
# CI-only: import signing cert, compute version from merged PR checkbox, build, and package a macOS release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

CODESIGN_P12_B64="${SCONEOS_CODESIGN_P12_BASE64:-${GATTEY_CODESIGN_P12_BASE64:-}}"
CODESIGN_P12_PASS="${SCONEOS_CODESIGN_P12_PASSWORD:-${GATTEY_CODESIGN_P12_PASSWORD:-}}"

if [[ -z "$CODESIGN_P12_B64" || -z "$CODESIGN_P12_PASS" ]]; then
  echo "ci-build-macos-release: SCONEOS_CODESIGN_P12_BASE64 and SCONEOS_CODESIGN_P12_PASSWORD are required." >&2
  exit 1
fi
if [[ -z "${SPARKLE_ED_PRIVATE_KEY_BASE64:-}" ]]; then
  echo "ci-build-macos-release: SPARKLE_ED_PRIVATE_KEY_BASE64 is required." >&2
  exit 1
fi

decode_secret_b64() {
  printf '%s' "$1" | tr -d '[:space:]' | base64 -D 2>/dev/null || printf '%s' "$1" | tr -d '[:space:]' | base64 -d
}

P12_PASS="$(printf '%s' "$CODESIGN_P12_PASS" | tr -d '[:space:]')"
decode_secret_b64 "$CODESIGN_P12_B64" > /tmp/codesign.p12
p12_size="$(wc -c </tmp/codesign.p12 | tr -d ' ')"
if [[ "$p12_size" -lt 500 ]]; then
  echo "ci-build-macos-release: decoded P12 is only ${p12_size} bytes." >&2
  exit 1
fi
if ! openssl pkcs12 -in /tmp/codesign.p12 -noout -passin "pass:${P12_PASS}" 2>/dev/null && \
   ! openssl pkcs12 -in /tmp/codesign.p12 -legacy -noout -passin "pass:${P12_PASS}" 2>/dev/null; then
  echo "ci-build-macos-release: P12 failed openssl check (size ${p12_size} bytes)." >&2
  exit 1
fi
decode_secret_b64 "$SPARKLE_ED_PRIVATE_KEY_BASE64" > /tmp/sparkle_ed.key
export SPARKLE_ED_KEY_FILE=/tmp/sparkle_ed.key

security delete-keychain build.keychain 2>/dev/null || true
security create-keychain -p "$P12_PASS" build.keychain
security set-keychain-settings -lut 21600 build.keychain
security default-keychain -s build.keychain
security unlock-keychain -p "$P12_PASS" build.keychain
security import /tmp/codesign.p12 -k build.keychain -f pkcs12 -P "$P12_PASS" -A \
  -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$P12_PASS" build.keychain
security list-keychains -d user -s build.keychain
rm -f /tmp/codesign.p12

SIGN_ID="$(resolve_sign_identity)"
if [[ "$SIGN_ID" == "-" ]]; then
  smoke="$(mktemp)"
  cp /bin/echo "$smoke"
  if codesign --force --sign "$SCONEOS_SELF_SIGNED_NAME" "$smoke" 2>/dev/null; then
    SIGN_ID="$SCONEOS_SELF_SIGNED_NAME"
  fi
  rm -f "$smoke"
fi
if [[ "$SIGN_ID" == "-" ]]; then
  echo "ci-build-macos-release: no valid signing identity in build.keychain." >&2
  exit 1
fi
export SCONEOS_SIGN_IDENTITY="$SIGN_ID"

cd "$ROOT"
swift build -c release --product Sconeos

VERSION="$("$ROOT/scripts/next-release-version.sh")"
echo "ci-build-macos-release: packaging v${VERSION}"
"$ROOT/scripts/package-release.sh" "$VERSION"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "version=${VERSION}" >> "$GITHUB_OUTPUT"
fi
