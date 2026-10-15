#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-macos.sh" "$@"
killall Sconeos 2>/dev/null || true
open "$ROOT/build/Sconeos.app"

