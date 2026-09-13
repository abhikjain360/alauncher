#!/usr/bin/env bash
# One-time setup: a self-signed code-signing identity in its own keychain.
#
# macOS ties Accessibility and Microphone grants to an app's code signature.
# Ad-hoc signatures change on every build, so grants would be lost on each
# rebuild. Signing every build with this one identity keeps them.
#
# Nothing here needs admin rights or is trusted system-wide. To undo:
#   security delete-keychain ~/Library/Keychains/alauncher-signing.keychain-db
#   rm -r ~/Library/Application\ Support/alauncher/signing
set -euo pipefail

source "$(dirname "$0")/signing-env.sh"

if [[ -f "$SIGNING_KEYCHAIN" ]]; then
    security unlock-keychain -p "$(cat "$SIGNING_PASSWORD_FILE")" "$SIGNING_KEYCHAIN"
    if security find-certificate -c "$SIGNING_IDENTITY" "$SIGNING_KEYCHAIN" >/dev/null 2>&1; then
        echo "Signing identity already set up in $SIGNING_KEYCHAIN"
        exit 0
    fi
    echo "error: $SIGNING_KEYCHAIN exists but has no '$SIGNING_IDENTITY' certificate" >&2
    exit 1
fi

umask 077
mkdir -p "$SIGNING_DIR"
[[ -f "$SIGNING_PASSWORD_FILE" ]] || openssl rand -base64 32 >"$SIGNING_PASSWORD_FILE"
password=$(cat "$SIGNING_PASSWORD_FILE")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat >"$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGNING_IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# macOS's own LibreSSL writes a PKCS#12 file that `security import` can read;
# OpenSSL 3 defaults to ciphers it can't.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$work/cert.cnf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$SIGNING_IDENTITY" -out "$work/identity.p12" -passout "pass:$password"

# `create-keychain` also appends the new keychain to the user search list.
# Put the list back afterwards so other apps never try to unlock this one.
read_search_list

security create-keychain -p "$password" "$SIGNING_KEYCHAIN"
security list-keychains -d user -s "${search_list[@]}"
security set-keychain-settings "$SIGNING_KEYCHAIN"
security unlock-keychain -p "$password" "$SIGNING_KEYCHAIN"
security import "$work/identity.p12" -k "$SIGNING_KEYCHAIN" -P "$password" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$SIGNING_KEYCHAIN" >/dev/null

echo "Created '$SIGNING_IDENTITY' in $SIGNING_KEYCHAIN"
