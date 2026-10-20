# Ad-hoc code signing for macOS releases (scripts/build-macos.sh / scripts/package-release.sh).
# Source from bash: source "$(dirname "$0")/lib/signing.sh"

# Prints the codesign identity for macOS packaging (defaults to ad-hoc '-').
# Untrusted self-signed X.509 certificates are killed by syspolicyd/amfid on
# macOS Sequoia/Tahoe when quarantined; ad-hoc ('-') works cleanly with
# Gatekeeper "Open Anyway" and Sparkle 2 EdDSA update validation.
resolve_sign_identity() {
  if [[ -n "${SCONEOS_SIGN_IDENTITY:-}" ]]; then
    printf '%s' "$SCONEOS_SIGN_IDENTITY"
    return 0
  fi
  printf '%s' '-'
}
