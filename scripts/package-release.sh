#!/usr/bin/env bash
# Build a signed macOS release and write Sparkle artifacts to dist/release/.
# Requires self-signed cert in keychain (or SCONEOS_SIGN_IDENTITY).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

VERSION="${1:-$("$ROOT/scripts/next-release-version.sh")}"

if [[ ! -f "$ROOT/sparkle-public-key.txt" ]]; then
  echo "package-release: sparkle-public-key.txt missing — run scripts/generate-sparkle-key.sh first." >&2
  exit 1
fi

if [[ -n "${SCONEOS_SIGN_IDENTITY:-}" && "${SCONEOS_SIGN_IDENTITY}" != "-" ]]; then
  SIGN_ID="$SCONEOS_SIGN_IDENTITY"
else
  SIGN_ID="$(resolve_sign_identity)"
fi
if [[ "$SIGN_ID" == "-" ]]; then
  echo "package-release: no self-signed identity — run scripts/setup-self-signed-cert.sh first." >&2
  exit 1
fi

WORK="$ROOT/dist/release"
STAGE="$WORK/stage"
rm -rf "$WORK"
mkdir -p "$STAGE"

BUILD_NUMBER="${SCONEOS_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}"

SCONEOS_DIST_DIR="$STAGE" \
SCONEOS_APP_SHORT_VERSION="$VERSION" \
SCONEOS_BUILD_NUMBER="$BUILD_NUMBER" \
SCONEOS_SIGN_IDENTITY="$SIGN_ID" \
SCONEOS_SIGN_ENTITLEMENTS="$ROOT/Sconeos.local.entitlements" \
  "$ROOT/scripts/build-macos.sh" release

APP="$STAGE/Sconeos.app"
[[ -d "$APP" ]] || { echo "package-release: missing $APP" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

ZIP="$WORK/Sconeos-${VERSION}.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
rm -rf "$STAGE"

GA="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "$GA" ]] || { echo "package-release: generate_appcast not found — run 'swift build'." >&2; exit 1; }
GA_ARGS=(--download-url-prefix "https://sconeos.gattey.com/" --link "https://sconeos.gattey.com")
[[ -n "${SPARKLE_ED_KEY_FILE:-}" ]] && GA_ARGS+=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
"$GA" "${GA_ARGS[@]}" "$WORK"

printf '%s\n' "$VERSION" > "$ROOT/VERSION"

echo "package-release: v${VERSION} (build ${BUILD_NUMBER}), identity=${SIGN_ID}"
echo "  dist/release/$(basename "$ZIP")"
echo "  dist/release/appcast.xml"
