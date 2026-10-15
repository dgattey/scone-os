#!/usr/bin/env bash
# Print the next semantic version based on the merged PR's Release info checkbox
# (- [x] Major / - [x] Minor / - [x] Patch, defaulting to patch).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APPCAST="${SCONEOS_APPCAST_PATH:-$ROOT/server/public/appcast.xml}"
VERSION_FILE="$ROOT/VERSION"
BASE="${SCONEOS_RELEASE_BASE_URL:-https://sconeos.gattey.com}"

parse_release_type_from_body() {
  local body="${1:-}"
  if printf '%s\n' "$body" | grep -qiE '^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]*Major\b'; then
    printf 'major\n'
  elif printf '%s\n' "$body" | grep -qiE '^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]*Minor\b'; then
    printf 'minor\n'
  else
    printf 'patch\n'
  fi
}

fetch_merged_pr_body() {
  if [[ -n "${SCONEOS_PR_BODY:-}" ]]; then
    printf '%s\n' "$SCONEOS_PR_BODY"
    return 0
  fi
  if [[ -n "${PR_BODY:-}" ]]; then
    printf '%s\n' "$PR_BODY"
    return 0
  fi
  if [[ -n "${GITHUB_EVENT_PATH:-}" && -f "${GITHUB_EVENT_PATH}" ]] && command -v python3 >/dev/null 2>&1; then
    local ev_body
    ev_body="$(python3 - "$GITHUB_EVENT_PATH" <<'PY' 2>/dev/null || true
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    ev = json.load(f)
pr = ev.get("pull_request") or {}
body = pr.get("body") or ""
if body:
    print(body)
PY
)"
    if [[ -n "$ev_body" ]]; then
      printf '%s\n' "$ev_body"
      return 0
    fi
  fi
  if [[ -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_SHA:-}" && -n "${GITHUB_TOKEN:-}" ]] && command -v python3 >/dev/null 2>&1; then
    local api_json
    if api_json="$(curl -fsSL \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      "https://api.github.com/repos/${GITHUB_REPOSITORY}/commits/${GITHUB_SHA}/pulls" 2>/dev/null)"; then
      python3 - "$api_json" <<'PY' 2>/dev/null || true
import json, sys
pulls = json.loads(sys.argv[1])
if isinstance(pulls, list) and pulls:
    print(pulls[0].get("body") or "")
PY
      return 0
    fi
  fi
}

release_type=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    major|minor|patch)
      release_type="$1"
      shift
      ;;
    --pr-body)
      release_type="$(parse_release_type_from_body "${2:-}")"
      shift 2
      ;;
    *)
      echo "Usage: scripts/next-release-version.sh [major|minor|patch] [--pr-body <text>]" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$release_type" ]]; then
  if [[ -n "${SCONEOS_RELEASE_TYPE:-}" ]]; then
    release_type="$(printf '%s' "$SCONEOS_RELEASE_TYPE" | tr '[:upper:]' '[:lower:]')"
  elif [[ -n "${RELEASE_TYPE:-}" ]]; then
    release_type="$(printf '%s' "$RELEASE_TYPE" | tr '[:upper:]' '[:lower:]')"
  else
    pr_body="$(fetch_merged_pr_body || true)"
    release_type="$(parse_release_type_from_body "$pr_body")"
  fi
fi

current="1.0.0"
if [[ -f "$APPCAST" ]]; then
  parsed="$(sed -n 's/.*<sparkle:shortVersionString>\([^<]*\)<\/sparkle:shortVersionString>.*/\1/p' "$APPCAST" | head -1)"
  [[ -n "$parsed" ]] && current="$parsed"
elif tmp="$(mktemp)" && curl -fsS "$BASE/appcast.xml" -o "$tmp" 2>/dev/null; then
  parsed="$(sed -n 's/.*<sparkle:shortVersionString>\([^<]*\)<\/sparkle:shortVersionString>.*/\1/p' "$tmp" | head -1)"
  [[ -n "$parsed" ]] && current="$parsed"
  rm -f "$tmp"
else
  rm -f "${tmp:-}" 2>/dev/null || true
  latest_tag="$(git -C "$ROOT" tag --list --sort=-v:refname 2>/dev/null | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | head -1 | sed 's/^v//' || true)"
  if [[ -n "$latest_tag" ]]; then
    current="$latest_tag"
  elif [[ -f "$VERSION_FILE" ]]; then
    current="$(tr -d '[:space:]' <"$VERSION_FILE")"
  fi
fi

current="${current%%-*}"
IFS='.' read -r major minor patch <<<"$current"
major="${major:-1}"
minor="${minor:-0}"
patch="${patch:-0}"

case "$release_type" in
  major)
    printf '%s.0.0\n' "$((major + 1))"
    ;;
  minor)
    printf '%s.%s.0\n' "$major" "$((minor + 1))"
    ;;
  patch|*)
    printf '%s.%s.%s\n' "$major" "$minor" "$((patch + 1))"
    ;;
esac
