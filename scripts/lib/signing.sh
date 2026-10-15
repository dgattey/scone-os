# Self-signed code signing for macOS releases (scripts/build-macos.sh / scripts/package-release.sh).
# Source from bash: source "$(dirname "$0")/lib/signing.sh"

SCONEOS_SELF_SIGNED_NAME="${SCONEOS_SELF_SIGNED_NAME:-Sconeos Self-Signed}"

# Prints the self-signed codesign identity (SHA-1 hash preferred), or ad-hoc (-) when missing.
resolve_sign_identity() {
  local line
  line="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "\"${SCONEOS_SELF_SIGNED_NAME}\"" | head -1 || true)"
  if [[ -z "$line" ]]; then
    printf '%s' '-'
    return 0
  fi
  if [[ "$line" =~ ^[[:space:]]*[0-9]+\)[[:space:]]+([0-9A-F]+)[[:space:]]+ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  printf '%s' "$SCONEOS_SELF_SIGNED_NAME"
}

sign_identity_is_real() {
  [[ "$(resolve_sign_identity)" != "-" ]]
}
