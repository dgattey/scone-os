#!/usr/bin/env bash
# Push the Sparkle EdDSA private key to GitHub Actions as SPARKLE_ED_PRIVATE_KEY_BASE64 for the dylkit workflow.
# Releases are signed ad-hoc, so no codesigning certificate is exported.
#
# Usage:
#   ./scripts/export-ci-secrets.sh
#   ./scripts/export-ci-secrets.sh --print-only
#   ./scripts/export-ci-secrets.sh --dry-run
#   ./scripts/export-ci-secrets.sh --sparkle-key-file /path/to/key
#   ./scripts/export-ci-secrets.sh --repo owner/name
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXPORT_DIR="$(mktemp -d)"
EXPORTED_KEY="$EXPORT_DIR/sparkle_ed.key"
trap 'rm -rf "$EXPORT_DIR"' EXIT

PRINT_ONLY=false
DRY_RUN=false
REPO=""
SPARKLE_KEY_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-only) PRINT_ONLY=true ;;
    --dry-run) DRY_RUN=true ;;
    --repo) REPO="${2:?--repo requires owner/name}"; shift ;;
    --sparkle-key-file) SPARKLE_KEY_FILE="${2:?--sparkle-key-file requires a path}"; shift ;;
    -h|--help)
      sed -n '2,10p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "export-ci-secrets: unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

resolve_github_repo() {
  if [[ -n "$REPO" ]]; then
    printf '%s' "$REPO"
    return 0
  fi
  if command -v gh >/dev/null 2>&1 && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null; then
    return 0
  fi
  local url
  url="$(git -C "$ROOT" remote get-url origin 2>/dev/null)" || true
  if [[ "$url" =~ github\.com[:/]([^/]+)/([^/.]+) ]]; then
    printf '%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  echo "export-ci-secrets: could not detect GitHub repo — use --repo owner/name." >&2
  return 1
}

resolve_sparkle_key_file() {
  if [[ -n "$SPARKLE_KEY_FILE" ]]; then
    [[ -f "$SPARKLE_KEY_FILE" ]] || {
      echo "export-ci-secrets: not found: $SPARKLE_KEY_FILE" >&2
      exit 1
    }
    printf '%s' "$SPARKLE_KEY_FILE"
    return 0
  fi
  local gk="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
  if [[ -x "$gk" ]] && "$gk" --account com.sconeos.SconeOS -x "$EXPORTED_KEY" 2>/dev/null \
    && [[ -s "$EXPORTED_KEY" ]]; then
    printf '%s' "$EXPORTED_KEY"
    return 0
  fi
  return 1
}

push_github_secret() {
  local name=$1 value=$2 tmp
  tmp="$(mktemp)"
  printf '%s' "$value" >"$tmp"
  if [[ "$DRY_RUN" == true ]]; then
    echo "export-ci-secrets: [dry-run] would set $name (${#value} chars) on $REPO"
    rm -f "$tmp"
    return 0
  fi
  gh secret set "$name" --repo "$REPO" <"$tmp"
  rm -f "$tmp"
  echo "export-ci-secrets: set $name on $REPO (${#value} chars)"
}

SPARKLE_B64=""
if SPARKLE_PATH="$(resolve_sparkle_key_file)"; then
  SPARKLE_B64="$(base64 <"$SPARKLE_PATH" | tr -d '\n')"
  echo "export-ci-secrets: Sparkle key OK (${#SPARKLE_B64} base64 chars)" >&2
elif [[ "$DRY_RUN" == true ]]; then
  echo "export-ci-secrets: [dry-run] no local Sparkle key" >&2
  exit 0
else
  echo "export-ci-secrets: no Sparkle key; run ./scripts/generate-sparkle-key.sh or pass --sparkle-key-file." >&2
  exit 1
fi

if [[ "$PRINT_ONLY" == true ]]; then
  echo "SPARKLE_ED_PRIVATE_KEY_BASE64=$SPARKLE_B64"
  exit 0
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "export-ci-secrets: install gh CLI or use --print-only." >&2
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "export-ci-secrets: run: gh auth login" >&2
  exit 1
fi

REPO="$(resolve_github_repo)"
echo "export-ci-secrets: pushing to $REPO" >&2
push_github_secret SPARKLE_ED_PRIVATE_KEY_BASE64 "$SPARKLE_B64"
echo "export-ci-secrets: done."
