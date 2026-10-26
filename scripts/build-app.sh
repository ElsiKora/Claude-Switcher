#!/bin/zsh
# Builds "Claude Switcher.app" into build/ with Xcode (project.yml -> ClaudeSwitcher.xcodeproj).
# Usage: scripts/build-app.sh [--install]   (--install replaces /Applications/Claude Switcher.app and starts it)
set -euo pipefail

cd "${0:A:h}/.." || exit 1
root=$PWD
build_number=$(git rev-list --count HEAD 2>/dev/null || echo 1)

xcodegen generate --quiet
xcodebuild -project ClaudeSwitcher.xcodeproj -scheme ClaudeSwitcher -configuration Release \
  -derivedDataPath build/dd -destination 'platform=macOS' \
  CURRENT_PROJECT_VERSION="$build_number" build -quiet

app="$root/build/Claude Switcher.app"
rm -rf "$app"
ditto "build/dd/Build/Products/Release/Claude Switcher.app" "$app"

# Release builds are signed with the project's own code-signing identity
# (scripts/make-signing-identity.sh). macOS keys Accessibility and keychain
# access to the signature's designated requirement: with an ad hoc signature
# that is the build's hash, so every update lost both; with this identity it
# is the bundle id and the certificate, the same in every build.
signing="${SWITCHER_SIGNING_DIR:-$HOME/.config/claude-switcher-signing}"
if [[ -f "$signing/signing.keychain-db" ]]; then
  keychain="$signing/signing.keychain-db"
  security unlock-keychain -p "$(<"$signing/keychain-password")" "$keychain"
  identity=$(security find-certificate -c "ElsiKora Claude Switcher" -Z "$keychain" | awk '/^SHA-1 hash:/ { print $3 }')
  codesign --force --sign "$identity" --keychain "$keychain" --identifier com.elsikora.ClaudeSwitcher "$app"
  codesign -dr - "$app" 2>&1 | grep -q 'certificate root' || { echo "signature has no certificate requirement" >&2; exit 1; }
else
  echo "no signing identity in $signing: the build stays signed ad hoc" >&2
fi
codesign --verify --strict "$app"
echo "built $app (build $build_number)"

if [[ "${1:-}" == "--install" ]]; then
  dest="/Applications/Claude Switcher.app"
  running=$(pgrep -x ClaudeSwitcher || true)
  [[ -n "$running" ]] && kill $running && sleep 1
  rm -rf "$dest"
  ditto "$app" "$dest"
  open -a "$dest"
  echo "installed and started $dest"
fi
