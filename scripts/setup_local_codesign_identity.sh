#!/usr/bin/env bash
set -euo pipefail

IDENTITY_NAME="${IDENTITY_NAME:-VibeGrid Local Code Signing}"
KEYCHAIN_PATH="${KEYCHAIN_PATH:-${HOME}/Library/Keychains/login.keychain-db}"
DAYS_VALID="${DAYS_VALID:-825}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

identity_exists() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' -v name="${IDENTITY_NAME}" '$2 == name { found = 1 } END { exit(found ? 0 : 1) }'
}

certificate_exists() {
  security find-certificate -a -c "${IDENTITY_NAME}" "${KEYCHAIN_PATH}" >/dev/null 2>&1
}

require_cmd security
require_cmd openssl

if [[ ! -f "${KEYCHAIN_PATH}" ]]; then
  echo "error: keychain not found: ${KEYCHAIN_PATH}" >&2
  exit 1
fi

if identity_exists; then
  echo "Code signing identity already exists: ${IDENTITY_NAME}"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
PKCS12_PASSWORD="$(openssl rand -hex 16)"
cleanup() {
  PKCS12_PASSWORD=""
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

cat > "${TMP_DIR}/openssl.cnf" <<'EOF'
[req]
default_bits = 2048
prompt = no
default_md = sha256
x509_extensions = v3_ca
distinguished_name = dn

[dn]
CN = REPLACE_IDENTITY_NAME

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical, CA:true
keyUsage = critical, digitalSignature, keyCertSign, cRLSign
extendedKeyUsage = codeSigning
EOF

ESCAPED_IDENTITY_NAME="$(printf '%s\n' "${IDENTITY_NAME}" | sed 's/[\/&]/\\&/g')"
sed -i '' "s/REPLACE_IDENTITY_NAME/${ESCAPED_IDENTITY_NAME}/g" "${TMP_DIR}/openssl.cnf"

openssl req -new -x509 -newkey rsa:2048 -days "${DAYS_VALID}" -nodes \
  -keyout "${TMP_DIR}/identity.key" \
  -out "${TMP_DIR}/identity.crt" \
  -config "${TMP_DIR}/openssl.cnf" >/dev/null 2>&1

printf '%s' "${PKCS12_PASSWORD}" > "${TMP_DIR}/p12pass"

PKCS12_ARGS=(-export -inkey "${TMP_DIR}/identity.key" -in "${TMP_DIR}/identity.crt"
  -name "${IDENTITY_NAME}" -out "${TMP_DIR}/identity.p12" -passout "file:${TMP_DIR}/p12pass")
# OpenSSL 3.x needs -legacy for older PKCS12 format; LibreSSL does not support it.
if openssl version 2>/dev/null | grep -q "^OpenSSL 3"; then
  PKCS12_ARGS+=(-legacy)
fi
openssl pkcs12 "${PKCS12_ARGS[@]}" >/dev/null 2>&1

security import "${TMP_DIR}/identity.p12" \
  -k "${KEYCHAIN_PATH}" \
  -P "${PKCS12_PASSWORD}" \
  -T /usr/bin/codesign \
  -T /usr/bin/security >/dev/null

echo ""
echo "Imported '${IDENTITY_NAME}' into ${KEYCHAIN_PATH}."
echo "Trust settings were NOT modified."
echo ""
echo "This script intentionally avoids marking self-signed certificates as trusted"
echo "in the login keychain by default."
echo ""
echo "If you ever need to revisit the old behavior, the previous commands are kept"
echo "below as commented reference only and should be reviewed before re-enabling."

# Previous trust-modifying behavior kept as reference only. Do not re-enable
# without reviewing the security implications and preferring an isolated dev
# keychain over the login keychain.
#
# echo ""
# echo "WARNING: This will trust a self-signed certificate for code signing in your"
# echo "login keychain. The trust is scoped to code signing only (not TLS or other"
# echo "policies). To revoke later, delete '${IDENTITY_NAME}' in Keychain Access."
# echo ""
# read -r -p "Continue? [y/N] " confirm
# case "${confirm}" in
#   [yY]|[yY][eE][sS]) ;;
#   *)
#     echo "Aborted. The certificate was imported but NOT trusted."
#     echo "To finish manually: open Keychain Access, find '${IDENTITY_NAME}',"
#     echo "double-click it, expand Trust, and set Code Signing to Always Trust."
#     exit 0
#     ;;
# esac
#
# if ! security add-trusted-cert \
#   -p codeSign \
#   -r trustRoot \
#   -k "${KEYCHAIN_PATH}" \
#   "${TMP_DIR}/identity.crt" >/dev/null 2>&1; then
#   if ! security add-trusted-cert \
#     -p codeSign \
#     -r trustAsRoot \
#     -k "${KEYCHAIN_PATH}" \
#     "${TMP_DIR}/identity.crt" >/dev/null 2>&1; then
#     echo "Warning: unable to set trust settings automatically for ${IDENTITY_NAME}."
#   fi
# fi

if identity_exists; then
  echo "Created local code signing identity: ${IDENTITY_NAME}"
  echo "Re-run: make install-app"
  echo ""
  echo "To remove this identity later:"
  echo "  1. Open Keychain Access"
  echo "  2. Search for '${IDENTITY_NAME}'"
  echo "  3. Delete the certificate and private key entries"
  exit 0
fi

if certificate_exists; then
  echo "Imported certificate and private key for '${IDENTITY_NAME}', but it is not"
  echo "currently trusted for code signing."
  echo ""
  echo "That is intentional: this script no longer changes login-keychain trust"
  echo "settings automatically."
  echo ""
  echo "If you need a usable local signing identity later, prefer an isolated dev"
  echo "keychain. If you choose to trust this cert manually, do it explicitly in"
  echo "Keychain Access after reviewing the security tradeoff."
  exit 0
fi

echo "error: failed to import certificate '${IDENTITY_NAME}' into ${KEYCHAIN_PATH}" >&2
exit 1
