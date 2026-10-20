#!/usr/bin/env bash
# Cut a macOS release from this Mac without CI. Every PR merged since the last release commit (the last change to
# VERSION) is batched into one release, bumped by the highest "# Release info" checkbox among them. Builds, ad-hoc
# signs, writes the Sparkle appcast and zip to server/public/, commits "Release vX.Y.Z", tags, and pushes main;
# Vercel's Git deploy publishes server/public/ to sconeos.gattey.com.
#
# Squash-merge subjects must end in "(#N)". PR bodies are read with `gh`; pass a release type to skip that
# lookup (notes then fall back to PR titles). A forge release is created only when `gh` can.
#
# Usage:
#   ./scripts/release-local.sh [major|minor|patch] [--dry-run]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "release-local: $*" >&2; exit 1; }

release_type=""
dry_run=false
for arg in "$@"; do
  case "$arg" in
    major|minor|patch) release_type="$arg" ;;
    --dry-run) dry_run=true ;;
    *) die "usage: scripts/release-local.sh [major|minor|patch] [--dry-run]" ;;
  esac
done

if [[ "$dry_run" == false ]]; then
  git fetch -q origin main
  [[ "$(git rev-parse --abbrev-ref HEAD)" == main ]] || die "check out main first"
  [[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || die "main is not at origin/main"
fi

last_release="$(git log -1 --format=%H -- VERSION)"
numbers=()
titles=()
while IFS= read -r subject; do
  [[ "$subject" =~ ^(.*)\ \(#([0-9]+)\)$ ]] || continue
  titles+=("${BASH_REMATCH[1]}")
  numbers+=("${BASH_REMATCH[2]}")
done < <(git log --first-parent --reverse --format=%s "${last_release:+$last_release..}HEAD")
[[ ${#numbers[@]} -gt 0 ]] || die "no merged PRs since the last release"

bodies=()
for n in "${numbers[@]}"; do
  body="$(gh pr view "$n" --json body -q .body 2>/dev/null || true)"
  [[ -n "$body" || -n "$release_type" ]] || die "could not read PR #$n; pass the release type explicitly"
  bodies+=("$body")
done

# The bodies are joined so the highest checked box across the whole batch wins.
if [[ -n "$release_type" ]]; then
  VERSION="$("$ROOT/scripts/next-release-version.sh" "$release_type")"
else
  VERSION="$("$ROOT/scripts/next-release-version.sh" --pr-body "$(printf '%s\n' "${bodies[@]}")")"
fi

NOTES_HEADING_RE='^#+[[:space:]]*(Release notes|Highlights|What changed\?|Summary|Overview)[[:space:]]*$'
notes_html=""
forge_notes=""
for i in "${!numbers[@]}"; do
  body="${bodies[$i]}"
  grep -qiE "$NOTES_HEADING_RE" <<<"$body" || body="- ${titles[$i]}"
  notes_html+="$(SCONEOS_RELEASE_NOTES="$body" "$ROOT/scripts/format-release-notes.sh" "$VERSION")"$'\n'
  forge_notes+="- ${titles[$i]} (#${numbers[$i]})"$'\n'
done
notes_html="${notes_html//$'</ul>\n<ul>'/}"

echo "release-local: v$(tr -d '[:space:]' <VERSION) -> v$VERSION from PRs: ${numbers[*]/#/#}"
if [[ "$dry_run" == true ]]; then
  printf '%s' "$notes_html"
  exit 0
fi

SCONEOS_RELEASE_NOTES="$notes_html" "$ROOT/scripts/package-release.sh" "$VERSION"

git add server/public VERSION
git commit -q -m "Release v$VERSION"
git tag "v$VERSION"
git push --atomic origin main "refs/tags/v$VERSION"

if gh release create "v$VERSION" "server/public/Sconeos-$VERSION.zip" server/public/appcast.xml \
  --verify-tag --title "v$VERSION" --notes "$forge_notes" >/dev/null 2>&1; then
  echo "release-local: published v$VERSION and created its forge release"
else
  echo "release-local: published v$VERSION (no forge release created)"
fi
