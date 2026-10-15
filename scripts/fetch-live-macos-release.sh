#!/usr/bin/env bash
# Copy the live Sparkle feed + zip into server/public/ (for deploys that do not rebuild the app).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PUBLIC="$ROOT/server/public"
BASE="${SCONEOS_RELEASE_BASE_URL:-https://sconeos.gattey.com}"

mkdir -p "$PUBLIC"
if ! curl -fsS "$BASE/appcast.xml" -o "$PUBLIC/appcast.xml"; then
  echo "fetch-live-macos-release: no live appcast at $BASE/appcast.xml (first release is OK)." >&2
  exit 0
fi

zip_url="$(sed -n 's/.*url="\([^"]*Sconeos[^"]*\.zip\)".*/\1/p' "$PUBLIC/appcast.xml" | head -1)"
if [[ -z "$zip_url" ]]; then
  echo "fetch-live-macos-release: appcast has no enclosure URL." >&2
  exit 0
fi

dest="$PUBLIC/$(basename "$zip_url")"
curl -fsS "$zip_url" -o "$dest"
echo "fetch-live-macos-release: $(basename "$dest") + appcast.xml"
