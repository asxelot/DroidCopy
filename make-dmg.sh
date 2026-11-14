#!/bin/bash
# Builds DroidCopy.app and puts it in build/DroidCopy-<version>.dmg: a disk image whose window
# shows the app and an Applications shortcut to drag it onto.
# Needs dmgbuild (pip install dmgbuild), which writes the window's layout without driving Finder.
set -euo pipefail
cd "$(dirname "$0")"

DMGBUILD=${DMGBUILD:-$(command -v dmgbuild || true)}
if [ -z "$DMGBUILD" ]; then
    echo "dmgbuild not found. Install it with: pip3 install dmgbuild (or set DMGBUILD=/path/to/dmgbuild)" >&2
    exit 1
fi

./build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/DroidCopy.app/Contents/Info.plist)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

swift dmg/background.swift "$WORK/background.png" 1
swift dmg/background.swift "$WORK/background@2x.png" 2
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" -out "$WORK/background.tiff" 2>/dev/null

OUT="build/DroidCopy-$VERSION.dmg"
rm -f "$OUT"
"$DMGBUILD" -s dmg/settings.py -D app=build/DroidCopy.app -D background="$WORK/background.tiff" \
    "DroidCopy" "$OUT"
echo "Built $OUT"
