#!/bin/bash
# Builds DiskLens.app into build/ from the SwiftPM DiskLensApp product.
# The bundle is ad-hoc signed, which is enough to run it locally; distribution
# needs a Developer ID signature and notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product DiskLensApp
BIN_DIR="$(swift build -c release --show-bin-path)"

APP=build/DiskLens.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DiskLensApp" "$APP/Contents/MacOS/DiskLens"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>DiskLens</string>
    <key>CFBundleDisplayName</key>
    <string>DiskLens</string>
    <key>CFBundleIdentifier</key>
    <string>app.disklens.DiskLens</string>
    <key>CFBundleExecutable</key>
    <string>DiskLens</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
