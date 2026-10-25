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
