#!/usr/bin/env bash
# Creates a stable self-signed code-signing certificate for TypeWiser.
#
# WHY THIS EXISTS: macOS ties Accessibility permission to a code signature.
# An ad-hoc signature (`codesign -s -`) is identified by CDHash — a hash of the
# exact binary — so EVERY rebuild produces a new identity and silently voids the
# permission the user granted. The System Settings checkbox still looks ON while
# the app is untrusted, which is maddening to debug.
#
# Signing with a real certificate makes the designated requirement
#   identifier "xyz.crevn.typewiser" and certificate leaf = H"<cert hash>"
# which is stable across rebuilds. Grant once, keep working.
#
# Run once. Idempotent.
set -euo pipefail

IDENTITY="TypeWiser Dev"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "Signing identity '$IDENTITY' already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PW=typewiser

cat > "$TMP/cert.conf" <<CONF
[ req ]
distinguished_name = dn
x509_extensions = v3
prompt = no
[ dn ]
CN = $IDENTITY
[ v3 ]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CONF

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/cert.conf" 2>/dev/null

# Legacy PBE/MAC algorithms: OpenSSL 3 defaults produce a PKCS12 that macOS's
# `security` cannot read ("MAC verification failed").
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" \
    -passout "pass:$PW" -name "$IDENTITY" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db \
    -T /usr/bin/codesign -P "$PW" > /dev/null

# Without trust, codesign refuses the identity.
security add-trusted-cert -r trustRoot -p codeSign \
    -k ~/Library/Keychains/login.keychain-db "$TMP/cert.pem"

echo "Created signing identity '$IDENTITY'."
echo "Now run ./Scripts/bundle-app.sh, then grant Accessibility ONCE."
