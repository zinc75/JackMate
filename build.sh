#!/bin/bash
# ============================================================
# build.sh — JackMate GitHub distribution build script
# Compiles JackMate without opening Xcode.
#
# Requirements: Xcode Command Line Tools
#   xcode-select --install
#
# Usage:
#   ./build.sh          → Release build, ad-hoc signature
#   ./build.sh --debug  → Debug build (optimizations disabled)
# ============================================================
set -e

# ── Configuration ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="JackMate"
BUNDLE_ID="io.github.zinc75.JackMate"
DEPLOYMENT_TARGET="15.7"
VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "1.0.0")"

SOURCES_DIR="$SCRIPT_DIR/Sources"
ASSETS_DIR="$SCRIPT_DIR/Assets.xcassets"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"

# Swift compiler flags
SWIFT_FLAGS=(
    "-module-name" "JackMate"
    "-swift-version" "5"
    "-Xfrontend" "-default-isolation" "-Xfrontend" "MainActor"
    "-enable-upcoming-feature" "MemberImportVisibility"
)

# Debug vs Release
if [[ "$1" == "--debug" ]]; then
    BUILD_CONFIG="Debug"
    OPT_FLAGS=("-Onone" "-g")
    echo "Mode: Debug"
else
    BUILD_CONFIG="Release"
    OPT_FLAGS=("-O" "-whole-module-optimization")
    echo "Mode: Release"
fi

echo ""
echo "Building JackMate $VERSION..."
echo "=============================="
echo ""

# ── Prerequisites check ─────────────────────────────────────────────────────────
if ! command -v xcrun &>/dev/null; then
    echo "Error: xcrun not found."
    echo "Install Xcode Command Line Tools: xcode-select --install"
    exit 1
fi

SDK=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null)
if [ -z "$SDK" ]; then
    echo "Error: macOS SDK not found."
    echo "Check: xcrun --show-sdk-path --sdk macosx"
    exit 1
fi

if [ ! -d "$SOURCES_DIR" ]; then
    echo "Error: Sources/ directory not found."
    echo "This directory should contain the Swift and C source files."
    exit 1
fi

echo "SDK:     $SDK"
echo "Sources: $SOURCES_DIR"
echo ""

# ── Prepare build directory ─────────────────────────────────────────────────────
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/intermediates"

# ── Step 1: Compile C bridge ─────────────────────────────────────────────────────
echo "[1/5] Compiling C bridge (JackBridge.c)..."

for ARCH in arm64 x86_64; do
    echo "      -> $ARCH"
    xcrun clang \
        -c \
        -target "${ARCH}-apple-macos${DEPLOYMENT_TARGET}" \
        -isysroot "$SDK" \
        -I"$SOURCES_DIR" \
        "${OPT_FLAGS[@]}" \
        "$SOURCES_DIR/JackBridge.c" \
        -o "$BUILD_DIR/intermediates/JackBridge-${ARCH}.o"
done

echo "      Done."
echo ""

# ── Step 2: Compile Swift ────────────────────────────────────────────────────────
echo "[2/5] Compiling Swift sources..."

# Collect Swift files
mapfile -t SWIFT_FILES < <(find "$SOURCES_DIR" -name "*.swift" | sort)
echo "      ${#SWIFT_FILES[@]} Swift files found."

for ARCH in arm64 x86_64; do
    echo "      -> $ARCH"
    xcrun swiftc \
        -sdk "$SDK" \
        -target "${ARCH}-apple-macos${DEPLOYMENT_TARGET}" \
        "${SWIFT_FLAGS[@]}" \
        "${OPT_FLAGS[@]}" \
        -import-objc-header "$SOURCES_DIR/JackMate-Bridging-Header.h" \
        -Xcc "-I$SOURCES_DIR" \
        "${SWIFT_FILES[@]}" \
        -Xlinker "$BUILD_DIR/intermediates/JackBridge-${ARCH}.o" \
        -o "$BUILD_DIR/intermediates/${APP_NAME}-${ARCH}"
done

echo "      Done."
echo ""

# ── Step 3: Universal binary ────────────────────────────────────────────────────
echo "[3/5] Creating universal binary (arm64 + x86_64)..."

xcrun lipo -create \
    "$BUILD_DIR/intermediates/${APP_NAME}-arm64" \
    "$BUILD_DIR/intermediates/${APP_NAME}-x86_64" \
    -output "$BUILD_DIR/intermediates/${APP_NAME}"

echo "      Done."
echo ""

# ── Step 4: Compile asset catalog ───────────────────────────────────────────────
echo "[4/5] Compiling Assets.xcassets..."

if [ -d "$ASSETS_DIR" ]; then
    mkdir -p "$BUILD_DIR/intermediates/assets"
    xcrun actool \
        --notices --warnings \
        --platform macosx \
        --minimum-deployment-target "$DEPLOYMENT_TARGET" \
        --target-device mac \
        --app-icon AppIcon \
        --accent-color AccentColor \
        --output-partial-info-plist "$BUILD_DIR/intermediates/assetcatalog_info.plist" \
        --compile "$BUILD_DIR/intermediates/assets" \
        "$ASSETS_DIR" 2>&1 | grep -v "^$" || true
    echo "      Done."
else
    echo "      Warning: Assets.xcassets not found — app icon will be missing."
fi
echo ""

# ── Step 5: Assemble .app bundle ─────────────────────────────────────────────────
echo "[5/5] Assembling .app bundle..."

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Main executable
cp "$BUILD_DIR/intermediates/${APP_NAME}" "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"

# Compiled assets (icon + asset catalog)
if [ -d "$BUILD_DIR/intermediates/assets" ]; then
    find "$BUILD_DIR/intermediates/assets" -name "*.icns" -exec cp {} "$APP_BUNDLE/Contents/Resources/" \; 2>/dev/null || true
    find "$BUILD_DIR/intermediates/assets" -name "Assets.car" -exec cp {} "$APP_BUNDLE/Contents/Resources/" \; 2>/dev/null || true
fi

# Localized InfoPlist.strings
for LANG in en fr de it es; do
    LPROJ_SRC="$SCRIPT_DIR/${LANG}.lproj"
    if [ -d "$LPROJ_SRC" ]; then
        mkdir -p "$APP_BUNDLE/Contents/Resources/${LANG}.lproj"
        cp "$LPROJ_SRC/InfoPlist.strings" "$APP_BUNDLE/Contents/Resources/${LANG}.lproj/" 2>/dev/null || true
    fi
done

# Info.plist — copy template and inject version/bundle ID
cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION"           "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID"      "$APP_BUNDLE/Contents/Info.plist"

# PkgInfo
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# Ad-hoc code signature — allows local launch without a Developer ID certificate.
# For distribution, sign with a Developer ID and notarize with Apple.
codesign -s - --force "$APP_BUNDLE" 2>/dev/null && \
    echo "      Ad-hoc signature applied." || \
    echo "      Warning: codesign failed — app may not launch on some systems."

echo ""
echo "=============================="
echo "Build succeeded: $APP_BUNDLE"
echo ""
echo "To launch:"
echo "  open \"$APP_BUNDLE\""
echo ""
echo "If macOS blocks the app (unverified developer):"
echo "  Ctrl+click -> Open -> Open anyway"
echo "  Or from Terminal: xattr -rd com.apple.quarantine \"$APP_BUNDLE\""
echo ""
