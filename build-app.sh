#!/bin/bash
# Builds DroidCopy.app into ./build. Needs only the Xcode Command Line Tools and adb.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product DroidCopy
APP=build/DroidCopy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DroidCopy "$APP/Contents/MacOS/DroidCopy"

# The app icon, drawn by icon/icon.swift.
ICONSET=$(mktemp -d)/AppIcon.iconset
swift icon/icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DroidCopy</string>
    <key>CFBundleDisplayName</key><string>DroidCopy</string>
    <key>CFBundleIdentifier</key><string>local.droidcopy</string>
    <key>CFBundleExecutable</key><string>DroidCopy</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>local.droidcopy.items</string>
            <key>UTTypeDescription</key><string>DroidCopy device items</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# A background-only helper app that starts adb's server, so the server isn't counted as part of
# DroidCopy (which would keep DroidCopy "Running in Background" in the Dock after it quits).
HELPER="$APP/Contents/Helpers/DroidCopy adb.app"
mkdir -p "$HELPER/Contents/MacOS"
cat > "$HELPER/Contents/MacOS/adb-helper" <<'SH'
#!/bin/sh
# Started by DroidCopy with the path to adb. Starts adb's server and exits.
exec "$1" start-server
SH
chmod +x "$HELPER/Contents/MacOS/adb-helper"
cat > "$HELPER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DroidCopy adb</string>
    <key>CFBundleIdentifier</key><string>local.droidcopy.adb-helper</string>
    <key>CFBundleExecutable</key><string>adb-helper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSBackgroundOnly</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$HELPER" >/dev/null || { echo "codesign of the helper failed (see above)" >&2; exit 1; }

codesign --force --sign - "$APP" >/dev/null || { echo "codesign failed (see above)" >&2; exit 1; }
echo "Built $(pwd)/$APP"
