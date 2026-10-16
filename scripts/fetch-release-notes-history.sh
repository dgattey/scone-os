#!/usr/bin/env bash
# Download recent GitHub Releases (releases.json) and their attached appcast.xml assets (appcast-<tag>.xml) into
# <dest-dir> as history inputs for cumulative-release-notes.sh. Best-effort: missing gh/auth/network only warns.
#
# Usage:
#   ./scripts/fetch-release-notes-history.sh <dest-dir>
set -euo pipefail

DEST="${1:?fetch-release-notes-history: destination directory is required (arg 1)}"
REPO="${SCONEOS_GITHUB_REPO:-dgattey/scone-os}"
LIMIT="${SCONEOS_RELEASE_NOTES_MAX_VERSIONS:-10}"

warn() { echo "fetch-release-notes-history: $*" >&2; }

if ! command -v gh >/dev/null 2>&1; then
  warn "gh not installed; carrying forward notes from the previous appcast only."
  exit 0
fi

mkdir -p "$DEST"
if ! gh api "repos/${REPO}/releases?per_page=${LIMIT}" >"$DEST/releases.json" 2>/dev/null; then
  warn "could not list releases for ${REPO}; carrying forward notes from the previous appcast only."
  rm -f "$DEST/releases.json"
  exit 0
fi

tags="$(python3 -c '
import json, sys
for r in json.load(open(sys.argv[1])):
    if any(a.get("name") == "appcast.xml" for a in r.get("assets", [])):
        print(r["tag_name"])
' "$DEST/releases.json")"

for tag in $tags; do
  gh release download "$tag" -R "$REPO" -p appcast.xml -O "$DEST/appcast-${tag}.xml" --clobber >/dev/null 2>&1 \
    || warn "could not download appcast.xml from ${tag}"
done
