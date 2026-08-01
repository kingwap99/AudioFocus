#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AudioFocus"
HELPER_NAME="AudioFocusNativeHost"
BUNDLE_DIR="$PROJECT_DIR/${APP_NAME}.app"

echo "=== Building ${APP_NAME} ==="

# 1. Generate build timestamp
BUILD_TS=$(date '+%Y-%m-%d %H:%M:%S')
cat > "$PROJECT_DIR/Sources/AudioFocus/BuildInfo.swift" << SWIFTEOF
// Auto-generated build info
let BUILD_TIMESTAMP = "${BUILD_TS}"
SWIFTEOF
echo "Build timestamp: ${BUILD_TS}"

# 2. Build the Swift package
cd "$PROJECT_DIR"
swift build -c release 2>&1 || swift build 2>&1

# Determine which binary to use
if [ -f "$PROJECT_DIR/.build/release/${APP_NAME}" ]; then
    BINARY_SRC="$PROJECT_DIR/.build/release/${APP_NAME}"
    HELPER_SRC="$PROJECT_DIR/.build/release/${HELPER_NAME}"
else
    BINARY_SRC="$PROJECT_DIR/.build/debug/${APP_NAME}"
    HELPER_SRC="$PROJECT_DIR/.build/debug/${HELPER_NAME}"
fi

# 3. Create app bundle
echo "=== Creating app bundle ==="
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Helpers"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp "$BINARY_SRC" "$BUNDLE_DIR/Contents/MacOS/${APP_NAME}"
chmod +x "$BUNDLE_DIR/Contents/MacOS/${APP_NAME}"
cp "$HELPER_SRC" "$BUNDLE_DIR/Contents/Helpers/${HELPER_NAME}"
chmod +x "$BUNDLE_DIR/Contents/Helpers/${HELPER_NAME}"

# 4. Create Info.plist
cat > "$BUNDLE_DIR/Contents/Info.plist" << 'PLISTEOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>AudioFocus</string>
    <key>CFBundleIdentifier</key>
    <string>com.audiofocus.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>AudioFocus</string>
    <key>CFBundleDisplayName</key>
    <string>AudioFocus</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>AudioFocus needs access to audio capture to manage per-app mute functionality.</string>
</dict>
</plist>
PLISTEOF

echo "APPL????" > "$BUNDLE_DIR/Contents/PkgInfo"

# Ad-hoc signing makes local development builds launchable without requiring a
# personal Apple Development identity. Distribution builds should be signed and
# notarized with the publisher's own credentials.
# Existing local bundles can inherit Finder/resource-fork metadata when replaced.
# Remove it recursively before signing or strict signature verification will fail.
xattr -cr "$BUNDLE_DIR"
codesign --force --deep --sign - --timestamp=none "$BUNDLE_DIR"
xattr -d com.apple.FinderInfo "$BUNDLE_DIR" 2>/dev/null || true

echo ""
echo "=== Build Complete ==="
echo "App: $BUNDLE_DIR"
echo "Build: ${BUILD_TS}"
echo ""
echo "To run: open $BUNDLE_DIR"
