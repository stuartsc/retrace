#!/bin/bash

# Build and package Retrace as a proper .app bundle
# This allows macOS to properly identify the app for permissions

set -e  # Exit on error

APP_NAME="Retrace"
BUNDLE_ID="io.retrace.app"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"

if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | awk -F '"' '/Developer ID Application|Apple Development/ { print $2; exit }')
fi

if [ -z "$SIGN_IDENTITY" ]; then
    SIGN_IDENTITY="-"
    echo "⚠️  No local code signing identity found; falling back to ad-hoc signing."
    echo "   macOS privacy permissions may need to be re-granted after each rebuild."
else
    echo "🔐 Using code signing identity: $SIGN_IDENTITY"
fi

echo "🔨 Building Retrace..."
./scripts/check_no_nanoseconds_sleep.sh
swift build -c release

echo "📦 Creating app bundle..."

# Create app bundle structure
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$FRAMEWORKS_DIR"

# Copy executable
cp "$BUILD_DIR/Retrace" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy dynamic frameworks required by SwiftPM binary targets.
SPARKLE_FRAMEWORK="$BUILD_DIR/Sparkle.framework"
if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    SPARKLE_FRAMEWORK=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
fi

if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "❌ Sparkle.framework not found. Run swift build -c release and try again."
    exit 1
fi

ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"

if ! otool -l "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

# Copy Info.plist
cp "UI/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "✍️  Signing app bundle..."

# Sign the app bundle with entitlements. Prefer a stable real identity so TCC
# permissions survive rebuilds; fall back to ad-hoc when unavailable.
codesign --force --deep --sign "$SIGN_IDENTITY" --entitlements "UI/Retrace.entitlements" "$APP_BUNDLE"

echo "✅ Build complete!"
echo ""
echo "📍 App bundle location: $APP_BUNDLE"
echo ""

# Check if app is already in Applications
if [ -d "/Applications/$APP_NAME.app" ]; then
    echo "📲 Found existing app in /Applications/, updating in place..."
    echo "   This preserves your permissions settings."

    # Kill the app if running
    pkill -x "$APP_NAME" 2>/dev/null || true

    # Replace the app
    rm -rf "/Applications/$APP_NAME.app"
    cp -r "$APP_BUNDLE" /Applications/

    echo "✅ Updated /Applications/$APP_NAME.app"
    echo ""
    echo "To run:"
    echo "  open /Applications/$APP_NAME.app"
else
    echo "💡 For persistent permissions during development, install to /Applications/:"
    echo "   cp -r $APP_BUNDLE /Applications/ && open /Applications/$APP_NAME.app"
    echo ""
    echo "Or run from build directory (permissions reset on each rebuild):"
    echo "   open $APP_BUNDLE"
fi
