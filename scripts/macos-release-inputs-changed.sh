#!/usr/bin/env bash
# Exit 0 when this commit should produce a new macOS release build.
set -euo pipefail

if [[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]]; then
  exit 0
fi

if [[ "${GITHUB_EVENT_NAME:-}" == "push" && -n "${GITHUB_EVENT_BEFORE:-}" && "${GITHUB_EVENT_BEFORE}" != "0000000000000000000000000000000000000000" ]]; then
  if git diff --name-only "$GITHUB_EVENT_BEFORE" "$GITHUB_SHA" | grep -qE \
    '^(Sources/|Package\.(swift|resolved)|Sconeos\.local\.entitlements|sparkle-public-key\.txt|scripts/(build-macos|package-release|format-release-notes|cumulative-release-notes|fetch-release-notes-history|ci-build-macos-release|export-ci-secrets|fetch-live-macos-release|generate-icon|lib/signing|next-release-version|macos-release-inputs-changed)\.(sh|swift)|\.github/workflows/release-macos\.yml)'; then
    exit 0
  fi
  exit 1
fi

exit 1
