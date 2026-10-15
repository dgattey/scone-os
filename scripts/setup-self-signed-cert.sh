#!/usr/bin/env bash
# Create (or refresh) a self-signed code-signing certificate for Sconeos releases.
#
# Sparkle can install updates only when the new .app is signed with the same identity as the
# running app. A stable self-signed cert in the login keychain satisfies that.
#
# Outputs (gitignored):
#   .cert/sconeos.crt   — trust this once per Mac
#   .cert/sconeos.p12   — import into CI via GitHub secrets
#
# After running locally, set keychain access for codesign (non-interactive builds):
#   security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k login.keychain-db
#
# GitHub Actions secrets (base64 the p12; never commit the file):
#   SCONEOS_CODESIGN_P12_BASE64
#   SCONEOS_CODESIGN_P12_PASSWORD
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/lib/signing.sh
source "$ROOT/scripts/lib/signing.sh"

CERT_DIR="$ROOT/.cert"
NAME="$SCONEOS_SELF_SIGNED_NAME"
CN="Sconeos Self-Signed"
DAYS=3650
P12_PASS="${SCONEOS_CODESIGN_P12_PASSWORD:-sconeos}"

mkdir -p "$CERT_DIR"
KEY="$CERT_DIR/key.pem"
CRT="$CERT_DIR/sconeos.crt"
P12="$CERT_DIR/sconeos.p12"
CSR="$CERT_DIR/cert.csr"
EXT="$CERT_DIR/v3.ext"

cat >"$EXT" <<EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
EOF

if [[ ! -f "$KEY" ]]; then
  openssl genrsa -out "$KEY" 2048
fi

openssl req -new -key "$KEY" -out "$CSR" -subj "/CN=${CN}/O=Sconeos/C=US"
openssl x509 -req -in "$CSR" -signkey "$KEY" -sha256 -days "$DAYS" -out "$CRT" -extfile "$EXT"
openssl pkcs12 -export -legacy \
  -inkey "$KEY" -in "$CRT" -out "$P12" \
  -passout "pass:${P12_PASS}" \
  -name "$NAME" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES

# Replace any prior import with the same common name.
security delete-identity -c "$CN" 2>/dev/null || true
security import "$P12" -k ~/Library/Keychains/login.keychain-db -P "$P12_PASS" \
  -T /usr/bin/codesign -T /usr/bin/security -T /usr/bin/productbuild

security add-trusted-cert -r trustRoot -k ~/Library/Keychains/login.keychain-db "$CRT" 2>/dev/null || true
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k ~/Library/Keychains/login.keychain-db 2>/dev/null || true

echo "setup-self-signed-cert: imported \"$NAME\""
security find-identity -v -p codesigning | grep -F "$NAME" || true
echo
echo "Trust the cert once on this Mac (admin password):"
echo "  sudo security add-trusted-cert -d -r trustAsRoot -k /Library/Keychains/System.keychain \"$CRT\""
echo
echo "CI secrets (run locally, paste into GitHub → Settings → Secrets):"
echo "  SCONEOS_CODESIGN_P12_BASE64=$(base64 <"$P12" | tr -d '\n' | head -c 40)…"
echo "  SCONEOS_CODESIGN_P12_PASSWORD=${P12_PASS}"
echo
echo "Full base64 for SCONEOS_CODESIGN_P12_BASE64:"
base64 <"$P12" | tr -d '\n'
echo
echo "Export Sparkle EdDSA key for CI (if not already in 1Password):"
echo "  .build/artifacts/sparkle/Sparkle/bin/generate_keys -x /tmp/sparkle_ed.key"
echo "  → secret SPARKLE_ED_PRIVATE_KEY_BASE64 = base64 of that file"
