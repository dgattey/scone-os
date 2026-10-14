#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-macos.sh" "$@"
open "$ROOT/build/SconeOS.app"
