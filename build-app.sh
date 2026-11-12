#!/bin/bash
# Builds DroidCopy.app into ./build. Needs only the Xcode Command Line Tools and adb.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/DroidCopy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DroidCopy "$APP/Contents/MacOS/DroidCopy"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DroidCopy</string>
    <key>CFBundleDisplayName</key><string>DroidCopy</string>
    <key>CFBundleIdentifier</key><string>local.droidcopy</string>
    <key>CFBundleExecutable</key><string>DroidCopy</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null || { echo "codesign failed (see above)" >&2; exit 1; }
echo "Built $(pwd)/$APP"
