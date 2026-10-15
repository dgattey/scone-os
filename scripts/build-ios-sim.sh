#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-ios17.0-simulator"
SIM_BUILD_DIR="$ROOT/build/ios-sim"
MODULES_DIR="$SIM_BUILD_DIR/modules"
APP="$ROOT/build/Sconeos-iOS.app"

mkdir -p "$MODULES_DIR" "$APP"

SWIFTC=(
  xcrun --sdk iphonesimulator swiftc
  -target "$TARGET"
  -sdk "$SDK_PATH"
  -swift-version 6
  -package-name SconeKit
  -I "$MODULES_DIR"
  -Onone
)

compile_module() {
  local mod="$1"
  shift
  local out_obj="$MODULES_DIR/${mod}.o"
  local out_mod="$MODULES_DIR/${mod}.swiftmodule"
  local needs_build=0
  if [[ ! -f "$out_obj" || ! -f "$out_mod" ]]; then
    needs_build=1
  else
    for src in "$@"; do
      if [[ "$src" -nt "$out_obj" ]]; then
        needs_build=1
        break
      fi
    done
    for dep_mod in "$MODULES_DIR"/*.swiftmodule; do
      if [[ -f "$dep_mod" && "$dep_mod" != "$out_mod" && "$dep_mod" -nt "$out_obj" ]]; then
        needs_build=1
        break
      fi
    done
  fi
  if [[ "$needs_build" -eq 1 ]]; then
    "${SWIFTC[@]}" \
      -whole-module-optimization \
      -parse-as-library \
      -emit-module \
      -emit-module-path "$out_mod" \
      -emit-object \
      -o "$out_obj" \
      -module-name "$mod" \
      "$@"
  fi
}

compile_module SconeDomain Sources/SconeDomain/*.swift
compile_module SonosProtocolBoundary Sources/SonosProtocolBoundary/*.swift
compile_module SpotifyBridge Sources/SpotifyBridge/*.swift
compile_module SconeStore Sources/SconeStore/*.swift
compile_module SconeUI Sources/SconeUI/*.swift

"${SWIFTC[@]}" \
  -parse-as-library \
  -module-name SconeosApp \
  Sources/SconeosApp/*.swift \
  "$MODULES_DIR/SconeDomain.o" \
  "$MODULES_DIR/SonosProtocolBoundary.o" \
  "$MODULES_DIR/SpotifyBridge.o" \
  "$MODULES_DIR/SconeStore.o" \
  "$MODULES_DIR/SconeUI.o" \
  -o "$APP/Sconeos"

ICON_FILE="$ROOT/build/AppIcon.icns"
if [[ ! -f "$ICON_FILE" || "$ROOT/scripts/generate-icon.swift" -nt "$ICON_FILE" ]]; then
  swift "$ROOT/scripts/generate-icon.swift" "$ROOT"
fi

if [[ -f "$ROOT/build/icon-1024-light.png" && ( ! -f "$APP/AppIcon60x60@2x.png" || "$ROOT/scripts/generate-icon.swift" -nt "$APP/AppIcon60x60@2x.png" ) ]]; then
  sips -z 120 120 "$ROOT/build/icon-1024-light.png" --out "$APP/AppIcon60x60@2x.png" >/dev/null 2>&1 || true
  sips -z 180 180 "$ROOT/build/icon-1024-light.png" --out "$APP/AppIcon60x60@3x.png" >/dev/null 2>&1 || true
fi

cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>Sconeos</string>
  <key>CFBundleIdentifier</key>
  <string>com.sconeos.Sconeos</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Sconeos</string>
  <key>CFBundleDisplayName</key>
  <string>Sconeos</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSRequiresIPhoneOS</key>
  <true/>
  <key>UIDeviceFamily</key>
  <array>
    <integer>1</integer>
    <integer>2</integer>
  </array>
  <key>UILaunchScreen</key>
  <dict/>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>CFBundleIconFiles</key>
  <array>
    <string>AppIcon60x60</string>
  </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1

if [[ "${1:-}" == "--install" ]]; then
  xcrun simctl install booted "$APP" || true
fi

echo "$APP"
