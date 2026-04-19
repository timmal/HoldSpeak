#!/usr/bin/env bash
# Create a persistent self-signed code-signing certificate in login keychain
# so TCC permissions (Accessibility, Input Monitoring, Microphone) survive rebuilds.
# Run once per machine.
set -euo pipefail

CERT_NAME="PushToTalk Dev (self-signed)"

if security find-identity -v -p codesigning login.keychain-db 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "Already have '$CERT_NAME' in login keychain. Nothing to do."
  exit 0
fi

WORK=$(mktemp -d)
cd "$WORK"

cat > cert.cnf <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
x509_extensions    = v3_req

[ dn ]
CN = $CERT_NAME

[ v3_req ]
basicConstraints       = critical,CA:FALSE
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes -keyout cert.key -out cert.crt \
  -days 3650 -config cert.cnf >/dev/null 2>&1

openssl pkcs12 -export -legacy -inkey cert.key -in cert.crt -out cert.p12 \
  -name "$CERT_NAME" -password pass:ptt

security import cert.p12 -k ~/Library/Keychains/login.keychain-db \
  -P "ptt" -T /usr/bin/codesign -A >/dev/null

# Trust for code signing
security add-trusted-cert -d -r trustRoot -k ~/Library/Keychains/login.keychain-db \
  -p codeSign cert.crt 2>/dev/null || true

rm -rf "$WORK"

echo "Installed '$CERT_NAME' into login keychain."
echo "rebuild.sh will now sign the app with this identity, TCC grants will persist across rebuilds."
