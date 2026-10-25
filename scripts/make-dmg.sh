#!/bin/zsh
# Packs build/Claude Switcher.app into build/Claude-Switcher.dmg: the app, an Applications
# link and the background from docs/dmg. Needs dmgbuild (pip install dmgbuild).
# Usage: scripts/make-dmg.sh   (after scripts/build-app.sh)
set -euo pipefail

cd "${0:A:h}/.." || exit 1
app="$PWD/build/Claude Switcher.app"
dmg="$PWD/build/Claude-Switcher.dmg"
[[ -d "$app" ]] || { echo "build the app first: scripts/build-app.sh" >&2; exit 1; }
command -v dmgbuild >/dev/null || { echo "dmgbuild not found: pip install dmgbuild" >&2; exit 1; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tiffutil -cathidpicheck docs/dmg/background.png docs/dmg/background@2x.png -out "$work/background.tiff" >/dev/null 2>&1

rm -f "$dmg"
dmgbuild -s scripts/dmg-settings.py -D app="$app" -D background="$work/background.tiff" "Claude Switcher" "$dmg"
hdiutil verify -quiet "$dmg"
echo "built $dmg"
