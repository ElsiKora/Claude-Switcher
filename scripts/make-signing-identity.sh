#!/bin/zsh
# Creates the code-signing identity release builds are signed with (see
# build-app.sh): a self-signed "ElsiKora Claude Switcher" certificate in a
# keychain of its own, outside the login keychain. Run it once per signing Mac;
# keep identity.p12 and keychain-password from the folder safe, since a new
# identity makes macOS ask for Accessibility and keychain access again.
# Usage: scripts/make-signing-identity.sh   (folder: $SWITCHER_SIGNING_DIR or ~/.config/claude-switcher-signing)
set -euo pipefail
umask 077

dir="${SWITCHER_SIGNING_DIR:-$HOME/.config/claude-switcher-signing}"
keychain="$dir/signing.keychain-db"
[[ -e "$keychain" ]] && { echo "$keychain exists already" >&2; exit 1; }
mkdir -p "$dir"
cd "$dir" || exit 1

cat > cert.cnf <<'CNF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = ElsiKora Claude Switcher
O = ElsiKora
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:3072 -nodes -keyout key.pem -out cert.pem -days 7300 -config cert.cnf 2>/dev/null
openssl rand -base64 24 | tr -d '\n' > keychain-password
password=$(<keychain-password)
openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "ElsiKora Claude Switcher" -out identity.p12 -passout pass:"$password"
rm -f key.pem

security create-keychain -p "$password" "$keychain"
security set-keychain-settings "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import identity.p12 -k "$keychain" -P "$password" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
# codesign only signs with a certificate trusted for code signing; macOS asks
# for your password to trust this one, for code signing only.
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" cert.pem
security find-identity -v -p codesigning "$keychain"
