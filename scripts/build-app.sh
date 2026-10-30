#!/bin/bash
# Builds DiskLens.app into build/ from the SwiftPM DiskLensApp product.
# The bundle is ad-hoc signed, which is enough to run it locally; distribution
# needs a Developer ID signature and notarization.
set -euo pipefail
cd "$(dirname "$0")/.."

# Universal (Apple silicon and Intel). ARCHS="arm64" builds faster for local runs.
ARCHS="${ARCHS:-arm64 x86_64}"
ARCH_FLAGS=()
for arch in $ARCHS; do ARCH_FLAGS+=(--arch "$arch"); done
swift build -c release "${ARCH_FLAGS[@]}" --product DiskLensApp
swift build -c release "${ARCH_FLAGS[@]}" --product DiskLensAgent
BIN_DIR="$(swift build -c release "${ARCH_FLAGS[@]}" --show-bin-path)"

APP=build/DiskLens.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/DiskLensApp" "$APP/Contents/MacOS/DiskLens"
# The background agent, registered as a login item by the app (SMAppService).
cp "$BIN_DIR/DiskLensAgent" "$APP/Contents/MacOS/DiskLensAgent"
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/app.disklens.DiskLens.agent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>app.disklens.DiskLens.agent</string>
    <key>BundleProgram</key>
    <string>Contents/MacOS/DiskLensAgent</string>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>app.disklens.DiskLens</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>Nice</key>
    <integer>10</integer>
</dict>
</plist>
PLIST

# Resources of the core library, such as the cleanup rules (found through Bundle.module).
cp -R "$BIN_DIR/DiskLens_DiskLensCore.bundle" "$APP/Contents/Resources/"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Version from VERSION; the build number counts commits, so every release is higher.
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain -- Sources Package.swift 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

cat > "$APP/Contents/Info.plist" <<PLIST
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
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>DiskLensBuildDate</key>
    <string>$BUILD_DATE</string>
    <key>DiskLensCommit</key>
    <string>$COMMIT</string>
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

# Nested code first, then the app that seals it.
codesign --force --sign - --identifier app.disklens.DiskLens.agent "$APP/Contents/MacOS/DiskLensAgent"
codesign --force --sign - "$APP"
echo "Built $APP"
