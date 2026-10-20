#!/usr/bin/env bash
# Build a signed macOS release and write Sparkle artifacts to dist/release/ and server/public/.
# Signs ad-hoc unless SCONEOS_SIGN_IDENTITY names a real identity.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

PUBLIC_DIR="$ROOT/server/public"
VERSION="${1:-$("$ROOT/scripts/next-release-version.sh")}"

if [[ ! -f "$ROOT/sparkle-public-key.txt" ]]; then
  echo "package-release: sparkle-public-key.txt missing — run scripts/generate-sparkle-key.sh first." >&2
  exit 1
fi

cleanup_files=()
cleanup() {
  for f in "${cleanup_files[@]:-}"; do
    [[ -n "$f" && -e "$f" ]] && rm -rf "$f"
  done
}
trap cleanup EXIT

decode_secret_b64() {
  printf '%s' "$1" | tr -d '[:space:]' | base64 -D 2>/dev/null || printf '%s' "$1" | tr -d '[:space:]' | base64 -d
}

# Resolve Sparkle EdDSA private key (explicit file -> CI secret -> repo-local .cert/sparkle_ed.key)
if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  if [[ ! -f "$SPARKLE_ED_KEY_FILE" ]]; then
    echo "package-release: SPARKLE_ED_KEY_FILE not found at $SPARKLE_ED_KEY_FILE" >&2
    exit 1
  fi
elif [[ -n "${SPARKLE_ED_PRIVATE_KEY_BASE64:-}" ]]; then
  KEY_FILE="$(mktemp /tmp/sconeos-sparkle-ed.XXXXXX.key)"
  cleanup_files+=("$KEY_FILE")
  decode_secret_b64 "$SPARKLE_ED_PRIVATE_KEY_BASE64" >"$KEY_FILE"
  export SPARKLE_ED_KEY_FILE="$KEY_FILE"
else
  for candidate in \
    "$ROOT/.cert/sparkle_ed.key" \
    "$ROOT/sparkle_private.key" \
    "$HOME/.config/sconeos/sparkle_ed.key"; do
    if [[ -f "$candidate" ]]; then
      export SPARKLE_ED_KEY_FILE="$candidate"
      break
    fi
  done
fi

if [[ -z "${SPARKLE_ED_KEY_FILE:-}" || ! -f "${SPARKLE_ED_KEY_FILE}" ]]; then
  echo "package-release: Sparkle EdDSA private key missing (set SPARKLE_ED_KEY_FILE, SPARKLE_ED_PRIVATE_KEY_BASE64, or place key at .cert/sparkle_ed.key)" >&2
  exit 1
fi

SIGN_ID="${SCONEOS_SIGN_IDENTITY:-$(resolve_sign_identity)}"

WORK="$ROOT/dist/release"
STAGE="$WORK/stage"
rm -rf "$WORK"
mkdir -p "$STAGE" "$PUBLIC_DIR"

BUILD_NUMBER="${SCONEOS_BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD)}"
if [[ -z "${SCONEOS_BUILD_NUMBER:-}" && -f "$PUBLIC_DIR/appcast.xml" ]]; then
  last_build="$(sed -n 's/.*<sparkle:version>\([^<]*\)<\/sparkle:version>.*/\1/p' "$PUBLIC_DIR/appcast.xml" | head -1)"
  if [[ -n "$last_build" && "$BUILD_NUMBER" -le "$last_build" ]]; then
    BUILD_NUMBER=$((last_build + 1))
  fi
fi

SCONEOS_DIST_DIR="$STAGE" \
SCONEOS_APP_SHORT_VERSION="$VERSION" \
SCONEOS_BUILD_NUMBER="$BUILD_NUMBER" \
SCONEOS_SIGN_IDENTITY="$SIGN_ID" \
SCONEOS_SIGN_ENTITLEMENTS="$ROOT/Sconeos.local.entitlements" \
  "$ROOT/scripts/build-macos.sh" release

APP="$STAGE/Sconeos.app"
[[ -d "$APP" ]] || { echo "package-release: missing $APP" >&2; exit 1; }
codesign --verify --deep --strict "$APP"

if [[ "$SIGN_ID" == "-" ]]; then
  DESIGNATED_REQ="$(codesign -d -r- "$APP" 2>/dev/null || true)"
  if [[ "$DESIGNATED_REQ" != *'identifier "com.sconeos.SconeOS"'* ]]; then
    echo "package-release: expected ad-hoc designated requirement 'identifier \"com.sconeos.SconeOS\"', got: ${DESIGNATED_REQ:-<none>}" >&2
    exit 1
  fi
fi

INFO_PLIST="$APP/Contents/Info.plist"
ZIP="$WORK/Sconeos-${VERSION}.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

NEW_NOTES="$(mktemp /tmp/sconeos-release-notes.XXXXXX)"
HISTORY_DIR="$(mktemp -d /tmp/sconeos-release-history.XXXXXX)"
cleanup_files+=("$NEW_NOTES" "$HISTORY_DIR")
"$ROOT/scripts/format-release-notes.sh" "$VERSION" > "$NEW_NOTES"
"$ROOT/scripts/fetch-release-notes-history.sh" "$HISTORY_DIR"
NOTES_HISTORY=()
[[ -f "$PUBLIC_DIR/appcast.xml" ]] && NOTES_HISTORY+=("$PUBLIC_DIR/appcast.xml")
shopt -s nullglob
NOTES_HISTORY+=("$HISTORY_DIR"/appcast-*.xml)
shopt -u nullglob
[[ -f "$HISTORY_DIR/releases.json" ]] && NOTES_HISTORY+=("$HISTORY_DIR/releases.json")
"$ROOT/scripts/cumulative-release-notes.sh" "$VERSION" "$NEW_NOTES" ${NOTES_HISTORY[@]+"${NOTES_HISTORY[@]}"} \
  > "$WORK/Sconeos-${VERSION}.html"

GA="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
[[ -x "$GA" ]] || { echo "package-release: generate_appcast not found — run 'swift build'." >&2; exit 1; }
GA_ARGS=(
  --embed-release-notes
  --disable-signing-warning
  --download-url-prefix "https://sconeos.gattey.com/"
  --link "https://sconeos.gattey.com"
  --full-release-notes-url "https://github.com/dgattey/scone-os/releases"
  --ed-key-file "$SPARKLE_ED_KEY_FILE"
)
"$GA" "${GA_ARGS[@]}" "$WORK"

ED_SIG="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$WORK/appcast.xml" | head -1 | tr -d '[:space:]')"
if [[ -z "$ED_SIG" ]]; then
  echo "package-release: failed to generate sparkle:edSignature in $WORK/appcast.xml" >&2
  exit 1
fi

# Cryptographically verify the generated Ed25519 signature against SUPublicEDKey in the built .app's Info.plist.
if [[ ! -f "$INFO_PLIST" || ! -x /usr/libexec/PlistBuddy ]]; then
  echo "package-release: missing $INFO_PLIST or /usr/libexec/PlistBuddy for signature verification" >&2
  exit 1
fi
PUB_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST" 2>/dev/null | tr -d '[:space:]' || true)"
if [[ -z "$PUB_KEY" ]]; then
  echo "package-release: SUPublicEDKey missing from $INFO_PLIST" >&2
  exit 1
fi
if openssl version 2>/dev/null | grep -q '^OpenSSL'; then
  TMP_PUB="$(mktemp /tmp/sconeos-sparkle-pub.XXXXXX.pem)"
  TMP_SIG="$(mktemp /tmp/sconeos-sparkle-sig.XXXXXX.bin)"
  cleanup_files+=("$TMP_PUB" "$TMP_SIG")
  {
    echo "-----BEGIN PUBLIC KEY-----"
    printf '302a300506032b6570032100%s' "$(decode_secret_b64 "$PUB_KEY" | xxd -p -c 64)" | xxd -r -p | base64
    echo "-----END PUBLIC KEY-----"
  } >"$TMP_PUB"
  decode_secret_b64 "$ED_SIG" >"$TMP_SIG"
  if ! openssl pkeyutl -verify -pubin -inkey "$TMP_PUB" -rawin -in "$ZIP" -sigfile "$TMP_SIG" >/dev/null 2>&1; then
    echo "package-release: Ed25519 signature does not verify against SUPublicEDKey in $INFO_PLIST (private/public key mismatch)" >&2
    exit 1
  fi
fi

rm -rf "$STAGE"

rm -f "$PUBLIC_DIR"/Sconeos-*.zip
cp "$ZIP" "$PUBLIC_DIR/"
cp "$WORK/appcast.xml" "$PUBLIC_DIR/appcast.xml"
printf '%s\n' "$VERSION" > "$ROOT/VERSION"

echo "package-release: v${VERSION} (build ${BUILD_NUMBER}), identity=${SIGN_ID}"
echo "  server/public/$(basename "$ZIP")"
echo "  server/public/appcast.xml"
