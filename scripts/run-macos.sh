#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Sconeos.app"
"$ROOT/scripts/build-macos.sh" "$@"
# Quit only this repo's build so an installed /Applications/Sconeos.app keeps running, and launch without taking focus.
pkill -f "^$APP/Contents/MacOS/Sconeos" 2>/dev/null || true
open -g "$APP"
