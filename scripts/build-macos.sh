#!/usr/bin/env bash
# Build build/Sconeos.app (Swift release binaries by default, matching GP's package-macos.sh).
#
# Dev defaults reproduce GP's package-macos.sh behavior (ad-hoc signature unless SCONEOS_SIGN_IDENTITY
# is set, embeds Sparkle.framework, signs inside-out with local entitlements).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

CONFIG="${1:-release}"
case "$CONFIG" in
  debug|release) ;;
  *)
    echo "Usage: scripts/build-macos.sh [debug|release]" >&2
    exit 2
    ;;
esac

DEFAULT_SHORT_VERSION="1.0.0"
if [[ -f "$ROOT/VERSION" ]]; then
  DEFAULT_SHORT_VERSION="$(tr -d '[:space:]' <"$ROOT/VERSION")"
fi
DEFAULT_BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

SHORT_VERSION="${SCONEOS_APP_SHORT_VERSION:-$DEFAULT_SHORT_VERSION}"
BUILD_NUMBER="${SCONEOS_BUILD_NUMBER:-$DEFAULT_BUILD_NUMBER}"
SIGN_ID="${SCONEOS_SIGN_IDENTITY:-$(resolve_sign_identity)}"
SIGN_ENTITLEMENTS="${SCONEOS_SIGN_ENTITLEMENTS:-$ROOT/Sconeos.local.entitlements}"

SU_FEED_URL="${SCONEOS_SU_FEED_URL:-https://sconeos.gattey.com/appcast.xml}"
SU_PUBLIC_KEY=""
if [[ -f "$ROOT/sparkle-public-key.txt" ]]; then
  SU_PUBLIC_KEY="$(tr -d '[:space:]' <"$ROOT/sparkle-public-key.txt")"
fi

# codesign with the configured identity, splitting any extra options (e.g. --options runtime).
csign() {
  if [[ -n "${SCONEOS_CODESIGN_EXTRA_OPTS:-}" ]]; then
    # shellcheck disable=SC2086
    codesign --force --sign "$SIGN_ID" ${SCONEOS_CODESIGN_EXTRA_OPTS} "$@"
  else
    codesign --force --sign "$SIGN_ID" "$@"
  fi
}

APP_BIN="$ROOT/.build/$CONFIG/Sconeos"
if [[ -f "$APP_BIN" ]]; then
  stale="$(find Sources -name '*.swift' -newer "$APP_BIN" -print -quit 2>/dev/null || true)"
  if [[ -n "${stale:-}" ]]; then
    echo "build-macos: app sources newer than binary — forcing Sconeos rebuild" >&2
    rm -f "$APP_BIN"
  fi
fi

swift build -c "$CONFIG" --product Sconeos

BIN_DIR="$(swift build -c "$CONFIG" --product Sconeos --show-bin-path)"
if [[ -f "$BIN_DIR/Sconeos" ]]; then
  BINARY="$BIN_DIR/Sconeos"
elif [[ -f "$ROOT/.build/arm64-apple-macosx/$CONFIG/Sconeos" ]]; then
  BINARY="$ROOT/.build/arm64-apple-macosx/$CONFIG/Sconeos"
elif [[ -f "$ROOT/.build/$CONFIG/Sconeos" ]]; then
  BINARY="$ROOT/.build/$CONFIG/Sconeos"
else
  echo "Sconeos binary missing for config $CONFIG" >&2
  exit 1
fi

# Locate the Sparkle framework SwiftPM produced (copied next to the product, or in the artifact bundle).
SPARKLE_SRC=""
for cand in \
  "$BIN_DIR/Sparkle.framework" \
  "$ROOT/.build/$CONFIG/Sparkle.framework" \
  "$ROOT"/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework; do
  if [[ -d "$cand" ]]; then SPARKLE_SRC="$cand"; break; fi
done
if [[ -z "$SPARKLE_SRC" ]]; then
  echo "build-macos: Sparkle.framework not found under .build — run 'swift build' first" >&2
  exit 1
fi

DIST="${SCONEOS_DIST_DIR:-$ROOT/build}"
APP="$DIST/Sconeos.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
FRAMEWORKS_DIR="$CONTENTS/Frameworks"
ICON_FILE="$ROOT/build/AppIcon.icns"
CAR_FILE="$RESOURCES_DIR/Assets.car"
PLIST_FILE="$CONTENTS/Info.plist"
ASSET_CATALOG="$ROOT/build/Assets.xcassets"
ICON_BUNDLE="$ROOT/build/AppIcon.icon"

rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp "$BINARY" "$MACOS_DIR/Sconeos"
chmod +x "$MACOS_DIR/Sconeos"

# Strip any absolute build-machine / Xcode toolchain LC_RPATH entries that SwiftPM embeds
# (e.g. /Applications/Xcode_26.5.app/.../usr/lib/swift-6.2/macosx on CI runners), keeping
# only bundle-relative (@executable_path / @loader_path) or /usr/lib/swift paths. Otherwise
# XprotectService logs an rPathCmd failure on client Macs that lack that exact Xcode path.
while IFS= read -r rpath; do
  [[ -z "$rpath" ]] && continue
  case "$rpath" in
    @executable_path*|@loader_path*|/usr/lib/swift*) ;;
    *)
      install_name_tool -delete_rpath "$rpath" "$MACOS_DIR/Sconeos" 2>/dev/null || true
      ;;
  esac
done < <(otool -l "$MACOS_DIR/Sconeos" | awk '/cmd LC_RPATH/{f=1;next} f && /path /{print $2; f=0}')
if ! otool -l "$MACOS_DIR/Sconeos" | awk '/cmd LC_RPATH/{f=1;next} f && /path /{print $2; f=0}' | grep -Fxq '@executable_path/../Frameworks'; then
  install_name_tool -add_rpath '@executable_path/../Frameworks' "$MACOS_DIR/Sconeos" 2>/dev/null || true
fi

for bundle in "$BIN_DIR"/*.bundle; do
  [[ -d "$bundle" ]] || continue
  cp -R "$bundle" "$MACOS_DIR/"
done

# Embed Sparkle.framework. ditto preserves the framework symlinks codesign needs.
rm -rf "$FRAMEWORKS_DIR/Sparkle.framework"
ditto "$SPARKLE_SRC" "$FRAMEWORKS_DIR/Sparkle.framework"

if [[ ! -f "$ICON_FILE" || ! -d "$ICON_BUNDLE" || "$ROOT/scripts/generate-icon.swift" -nt "$ICON_FILE" ]]; then
  swift "$ROOT/scripts/generate-icon.swift" "$ROOT"
fi
cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
if command -v xcrun >/dev/null 2>&1 && [[ -d "$ICON_BUNDLE" ]]; then
  PARTIAL_PLIST="$ROOT/build/assetcatalog_generated_info.plist"
  xcrun actool "$ICON_BUNDLE" \
    --compile "$RESOURCES_DIR" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$PARTIAL_PLIST" >/dev/null 2>&1 || true
  rm -f "$PARTIAL_PLIST"
elif command -v xcrun >/dev/null 2>&1 && [[ -d "$ASSET_CATALOG" ]]; then
  PARTIAL_PLIST="$ROOT/build/assetcatalog_generated_info.plist"
  xcrun actool "$ASSET_CATALOG" \
    --compile "$RESOURCES_DIR" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$PARTIAL_PLIST" >/dev/null 2>&1 || true
  rm -f "$PARTIAL_PLIST"
fi

SU_PUBLIC_KEY_PLIST=""
if [[ -n "$SU_PUBLIC_KEY" ]]; then
  SU_PUBLIC_KEY_PLIST="  <key>SUPublicEDKey</key>
  <string>${SU_PUBLIC_KEY}</string>"
fi

printf 'APPL????' > "$CONTENTS/PkgInfo"
cat > "$PLIST_FILE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Sconeos</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>com.sconeos.SconeOS</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Sconeos</string>
  <key>CFBundleDisplayName</key>
  <string>Sconeos</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${SHORT_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.music</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>Sconeos reads the current Spotify track and pauses Spotify after a room starts playing it.</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Sconeos discovers and controls Sonos speakers on your local network.</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_sonos._tcp</string>
  </array>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>CFBundleURLName</key>
      <string>com.sconeos.callback</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>sconeos</string>
      </array>
    </dict>
  </array>
  <key>SUFeedURL</key>
  <string>${SU_FEED_URL}</string>
${SU_PUBLIC_KEY_PLIST}
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>3600</integer>
</dict>
</plist>
PLIST

# SPM flat resource bundles lack Info.plist; add one so codesign accepts the .app.
for nested in "$MACOS_DIR"/*.bundle; do
  [[ -d "$nested" ]] || continue
  [[ -f "$nested/Info.plist" || -f "$nested/Contents/Info.plist" ]] && continue
  name="$(basename "$nested" .bundle)"
  cat > "$nested/Info.plist" <<BNDL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>com.sconeos.SconeOS.${name}</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleVersion</key>
  <string>1</string>
</dict>
</plist>
BNDL
done

for nested in "$MACOS_DIR"/*.bundle; do
  [[ -d "$nested" ]] || continue
  csign "$nested"
done

# Strip any quarantine / provenance extended attributes before signing so nothing stale
# or inherited from artifact downloads gets sealed or packaged.
xattr -cr "$APP" 2>/dev/null || true

# Sign Sparkle inside-out (XPC services, helper, Updater.app, then the framework). Never --deep:
# it corrupts the XPC signatures. Order matters so the outer signature seals valid inner ones.
FW="$FRAMEWORKS_DIR/Sparkle.framework"
FWV="$FW/Versions/B"
[[ -e "$FWV/XPCServices/Installer.xpc" ]] && csign "$FWV/XPCServices/Installer.xpc"
if [[ -e "$FWV/XPCServices/Downloader.xpc" ]]; then
  # Downloader.xpc ships sandbox/network entitlements that must survive re-signing.
  if [[ -n "${SCONEOS_CODESIGN_EXTRA_OPTS:-}" ]]; then
    # shellcheck disable=SC2086
    codesign --force --sign "$SIGN_ID" ${SCONEOS_CODESIGN_EXTRA_OPTS} --preserve-metadata=entitlements "$FWV/XPCServices/Downloader.xpc"
  else
    codesign --force --sign "$SIGN_ID" --preserve-metadata=entitlements "$FWV/XPCServices/Downloader.xpc"
  fi
fi
[[ -e "$FWV/Autoupdate" ]] && csign "$FWV/Autoupdate"
[[ -e "$FWV/Updater.app" ]] && csign "$FWV/Updater.app"
csign "$FW"

# Sign the outer app bundle with local entitlements (com.apple.security.network.client).
# When ad-hoc signing ('-'), pin the outer app's designated requirement to its bundle identifier
# rather than the default cdhash so Sparkle's SUCodeSigningVerifier matches old and new builds.
if [[ "$SIGN_ID" == "-" ]]; then
  csign --entitlements "$SIGN_ENTITLEMENTS" -r='designated => identifier "com.sconeos.SconeOS"' "$APP"
else
  csign --entitlements "$SIGN_ENTITLEMENTS" "$APP"
fi

touch "$APP"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true
fi

APP_SIZE="$(du -sh "$APP" | cut -f1)"
echo "Packaged: $APP ($APP_SIZE)" >&2
echo "  CFBundleShortVersionString=${SHORT_VERSION}  CFBundleVersion=${BUILD_NUMBER}  identity=${SIGN_ID}" >&2
echo "  Sparkle: feed=${SU_FEED_URL} publicKey=$([[ -n "$SU_PUBLIC_KEY" ]] && echo present || echo MISSING)" >&2
echo "$APP"
