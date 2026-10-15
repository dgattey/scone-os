#!/usr/bin/env bash
# Validate release signing material and push GitHub Actions secrets for release-macos.yml.
#
# Does not create or delete keychains (avoids macOS "Keychain Not Found" dialogs).
# Default: openssl-check the P12, then `gh secret set` on this repo.
#
# Usage:
#   ./scripts/export-ci-secrets.sh
#   ./scripts/export-ci-secrets.sh --print-only
#   ./scripts/export-ci-secrets.sh --dry-run
#   ./scripts/export-ci-secrets.sh --skip-sparkle
#   ./scripts/export-ci-secrets.sh --sparkle-key-file /path/to/key
#   ./scripts/export-ci-secrets.sh --repo owner/name
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

NAME="$SCONEOS_SELF_SIGNED_NAME"
CERT_DIR="$ROOT/.cert"
CRT="$CERT_DIR/sconeos.crt"
KEY="$CERT_DIR/key.pem"
P12="$CERT_DIR/sconeos.p12"
P12_PASS="${SCONEOS_CODESIGN_P12_PASSWORD:-sconeos}"

PRINT_ONLY=false
DRY_RUN=false
SKIP_SPARKLE=false
REPO=""
SPARKLE_KEY_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --print-only) PRINT_ONLY=true ;;
    --dry-run) DRY_RUN=true ;;
    --skip-sparkle) SKIP_SPARKLE=true ;;
    --repo) REPO="${2:?--repo requires owner/name}"; shift ;;
    --sparkle-key-file) SPARKLE_KEY_FILE="${2:?--sparkle-key-file requires a path}"; shift ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \?//'
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

write_p12_from_pem() {
  openssl pkcs12 -export -legacy \
    -inkey "$KEY" -in "$CRT" -out "$P12" \
    -passout "pass:${P12_PASS}" \
    -name "$NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES
}

ensure_p12() {
  mkdir -p "$CERT_DIR"
  if [[ -f "$KEY" && -f "$CRT" ]]; then
    echo "export-ci-secrets: building $P12 from .cert/key.pem + sconeos.crt" >&2
    write_p12_from_pem
  elif [[ -f "$P12" ]]; then
    echo "export-ci-secrets: using existing $P12" >&2
  else
    echo "export-ci-secrets: no signing material — run ./scripts/setup-self-signed-cert.sh first." >&2
    exit 1
  fi
}

verify_p12() {
  if ! openssl pkcs12 -in "$P12" -noout -passin "pass:${P12_PASS}" 2>/dev/null && \
     ! openssl pkcs12 -in "$P12" -legacy -noout -passin "pass:${P12_PASS}" 2>/dev/null; then
    echo "export-ci-secrets: $P12 failed openssl check." >&2
    return 1
  fi
  local b64 decoded
  b64="$(base64 <"$P12" | tr -d '\n')"
  decoded="$(mktemp)"
  printf '%s' "$b64" | base64 -d >"$decoded"
  if ! openssl pkcs12 -in "$decoded" -noout -passin "pass:${P12_PASS}" 2>/dev/null && \
     ! openssl pkcs12 -in "$decoded" -legacy -noout -passin "pass:${P12_PASS}" 2>/dev/null; then
    echo "export-ci-secrets: base64 round-trip failed — do not paste secrets by hand." >&2
    rm -f "$decoded"
    return 1
  fi
  rm -f "$decoded"
  if security find-identity -v -p codesigning 2>/dev/null | grep -F "\"${NAME}\"" | head -1 | grep -q .; then
    echo "export-ci-secrets: login keychain has \"${NAME}\"." >&2
  else
    echo "export-ci-secrets: run ./scripts/setup-self-signed-cert.sh for local signing (CI uses the P12 secret)." >&2
  fi
  echo "export-ci-secrets: P12 OK ($(wc -c <"$P12" | tr -d ' ') bytes, ${#b64} base64 chars)" >&2
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
  local candidate
  for candidate in \
    "$CERT_DIR/sparkle_ed.key" \
    "$ROOT/sparkle_private.key" \
    "$HOME/.config/sconeos/sparkle_ed.key"; do
    if [[ -f "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  local gk="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
  if [[ -x "$gk" ]] && "$gk" -x "$CERT_DIR/sparkle_ed.key" 2>/dev/null && [[ -f "$CERT_DIR/sparkle_ed.key" ]]; then
    printf '%s' "$CERT_DIR/sparkle_ed.key"
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

ensure_p12
verify_p12
P12_B64="$(base64 <"$P12" | tr -d '\n')"

SPARKLE_B64=""
if [[ "$SKIP_SPARKLE" != true ]]; then
  if SPARKLE_PATH="$(resolve_sparkle_key_file)"; then
    SPARKLE_B64="$(base64 <"$SPARKLE_PATH" | tr -d '\n')"
    echo "export-ci-secrets: Sparkle key OK (${#SPARKLE_B64} base64 chars)" >&2
  elif [[ "$DRY_RUN" == true ]]; then
    echo "export-ci-secrets: [dry-run] no local Sparkle key" >&2
  elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    _repo="$(resolve_github_repo)"
    if gh secret list --repo "$_repo" 2>/dev/null | awk '{print $1}' | grep -qx SPARKLE_ED_PRIVATE_KEY_BASE64; then
      echo "export-ci-secrets: keeping existing SPARKLE_ED_PRIVATE_KEY_BASE64 on $_repo" >&2
      SKIP_SPARKLE=true
    else
      echo "export-ci-secrets: no Sparkle key — run ./scripts/generate-sparkle-key.sh, then re-run." >&2
      exit 1
    fi
  else
    echo "export-ci-secrets: no Sparkle key; use --skip-sparkle or --sparkle-key-file." >&2
    exit 1
  fi
fi

if [[ "$PRINT_ONLY" == true ]]; then
  echo "SCONEOS_CODESIGN_P12_PASSWORD=$P12_PASS"
  echo "SCONEOS_CODESIGN_P12_BASE64=$P12_B64"
  [[ -n "$SPARKLE_B64" ]] && echo "SPARKLE_ED_PRIVATE_KEY_BASE64=$SPARKLE_B64"
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
push_github_secret SCONEOS_CODESIGN_P12_PASSWORD "$P12_PASS"
push_github_secret SCONEOS_CODESIGN_P12_BASE64 "$P12_B64"
[[ -n "$SPARKLE_B64" ]] && push_github_secret SPARKLE_ED_PRIVATE_KEY_BASE64 "$SPARKLE_B64"
echo "export-ci-secrets: done."
