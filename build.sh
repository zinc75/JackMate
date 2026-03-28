#!/bin/bash
# ============================================================
# build.sh — JackMate GitHub distribution build script
# Compiles JackMate without opening Xcode.
#
# Requirements: Xcode (full install, not just Command Line Tools)
#   Required for: swiftc with @MainActor default isolation, actool (app icon).
#   Install Xcode from the Mac App Store, then run this script — no extra setup needed.
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
VERSION="$(cat "$SCRIPT_DIR/src/VERSION" 2>/dev/null || echo "1.0.0")"

SOURCES_DIR="$SCRIPT_DIR/src/Sources"
ASSETS_DIR="$SCRIPT_DIR/src/Assets.xcassets"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/${APP_NAME}.app"

# Swift compiler flags
SWIFT_FLAGS=(
    "-module-name" "JackMate"
    "-swift-version" "5"
    "-Xfrontend" "-default-isolation" "-Xfrontend" "MainActor"
    "-disable-bridging-pch"
    "-enable-upcoming-feature" "MemberImportVisibility"
)

# Debug vs Release
if [[ "$1" == "--debug" ]]; then
    BUILD_CONFIG="Debug"
    C_OPT_FLAGS=("-O0" "-g")
    SWIFT_OPT_FLAGS=("-Onone" "-g")
    echo "Mode: Debug"
else
    BUILD_CONFIG="Release"
    C_OPT_FLAGS=("-O2")
    SWIFT_OPT_FLAGS=("-O")
    echo "Mode: Release"
fi

echo ""
echo "Building JackMate $VERSION..."
echo "=============================="
echo ""

# ── Prerequisites check ─────────────────────────────────────────────────────────
XCODE_APP="/Applications/Xcode.app/Contents/Developer"
if [ ! -d "$XCODE_APP" ]; then
    echo "Error: Xcode not found at /Applications/Xcode.app"
    echo "Install Xcode from the Mac App Store: https://apps.apple.com/app/xcode/id497799835"
    exit 1
fi
export DEVELOPER_DIR="$XCODE_APP"

XCODE_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "/Applications/Xcode.app/Contents/Info.plist" 2>/dev/null)
XCODE_MAJOR=$(echo "$XCODE_VERSION" | cut -d. -f1)
MIN_XCODE=26
if [ -z "$XCODE_MAJOR" ] || [ "$XCODE_MAJOR" -lt "$MIN_XCODE" ]; then
    echo "Error: Xcode $MIN_XCODE+ required (found ${XCODE_VERSION:-unknown})."
    echo "Install Xcode from the Mac App Store: https://apps.apple.com/app/xcode/id497799835"
    exit 1
fi

SDK=$(xcrun --show-sdk-path --sdk macosx 2>/dev/null)
if [ -z "$SDK" ]; then
    echo "Error: macOS SDK not found."
    echo "Open Xcode once after installing to accept the license and install components."
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

# ── Spinner (for long compilation steps) ────────────────────────────────────────
# Displays an animated braille spinner on the current line until the given PID exits.
# Prints a ✓ and moves to the next line when done.
spin() {
    local pid=$1 prefix="${2:-}" frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r%s%s" "$prefix" "${frames:$((i % 10)):1}"
        sleep 0.1
        i=$(( i + 1 ))
    done
    printf "\r%s%s\n" "$prefix" "✓"
}

# ── Step 1: Compile C bridge ─────────────────────────────────────────────────────
echo "[1/5] Compiling C bridge (JackBridge.c)..."

for ARCH in arm64 x86_64; do
    CLANG_LOG=$(mktemp)
    xcrun clang \
        -c \
        -target "${ARCH}-apple-macos${DEPLOYMENT_TARGET}" \
        -isysroot "$SDK" \
        -I"$SOURCES_DIR" \
        "${C_OPT_FLAGS[@]}" \
        "$SOURCES_DIR/JackBridge.c" \
        -o "$BUILD_DIR/intermediates/JackBridge-${ARCH}.o" \
        2>"$CLANG_LOG" &
    CLANG_PID=$!
    spin $CLANG_PID "      -> $ARCH  "
    set +e; wait $CLANG_PID; CLANG_EXIT=$?; set -e
    if [ $CLANG_EXIT -ne 0 ]; then
        printf "\r      Error compiling C bridge (%s):\n" "$ARCH"
        cat "$CLANG_LOG" >&2
        rm -f "$CLANG_LOG"; exit 1
    fi
    rm -f "$CLANG_LOG"
done
echo ""

# ── Step 2: Compile Swift ────────────────────────────────────────────────────────
echo "[2/5] Compiling Swift sources..."

# Collect Swift files (bash 3.2 compatible — no mapfile)
SWIFT_FILES=()
while IFS= read -r f; do
    SWIFT_FILES+=("$f")
done < <(find "$SOURCES_DIR" -name "*.swift" | sort)
echo "      ${#SWIFT_FILES[@]} Swift files found."

for ARCH in arm64 x86_64; do
    SWIFTC_LOG=$(mktemp)
    xcrun swiftc \
        -sdk "$SDK" \
        -target "${ARCH}-apple-macos${DEPLOYMENT_TARGET}" \
        "${SWIFT_FLAGS[@]}" \
        "${SWIFT_OPT_FLAGS[@]}" \
        -import-objc-header "$SOURCES_DIR/JackMate-Bridging-Header.h" \
        -Xcc "-I$SOURCES_DIR" \
        "${SWIFT_FILES[@]}" \
        -Xlinker "$BUILD_DIR/intermediates/JackBridge-${ARCH}.o" \
        -o "$BUILD_DIR/intermediates/${APP_NAME}-${ARCH}" \
        2>"$SWIFTC_LOG" &
    SWIFTC_PID=$!
    spin $SWIFTC_PID "      -> $ARCH  "
    set +e
    wait $SWIFTC_PID
    SWIFTC_EXIT=$?
    set -e
    if [ $SWIFTC_EXIT -ne 0 ]; then
        printf "\r      Error compiling %s:\n" "$ARCH"
        cat "$SWIFTC_LOG" >&2
        rm -f "$SWIFTC_LOG"
        exit 1
    fi
    rm -f "$SWIFTC_LOG"
done
echo ""

# ── Step 3: Universal binary ────────────────────────────────────────────────────
echo "[3/5] Creating universal binary (arm64 + x86_64)..."

xcrun lipo -create \
    "$BUILD_DIR/intermediates/${APP_NAME}-arm64" \
    "$BUILD_DIR/intermediates/${APP_NAME}-x86_64" \
    -output "$BUILD_DIR/intermediates/${APP_NAME}" &
spin $! "      -> universal  "
wait $!
echo ""

# ── Step 4: Compile asset catalog ───────────────────────────────────────────────
echo "[4/5] Compiling Assets.xcassets..."

if [ -d "$ASSETS_DIR" ]; then
    mkdir -p "$BUILD_DIR/intermediates/assets"
    ACTOOL_LOG=$(mktemp)
    xcrun actool \
        --notices --warnings \
        --platform macosx \
        --minimum-deployment-target "$DEPLOYMENT_TARGET" \
        --target-device mac \
        --app-icon AppIcon \
        --accent-color AccentColor \
        --output-partial-info-plist "$BUILD_DIR/intermediates/assetcatalog_info.plist" \
        --compile "$BUILD_DIR/intermediates/assets" \
        "$ASSETS_DIR" >/dev/null 2>"$ACTOOL_LOG" &
    ACTOOL_PID=$!
    spin $ACTOOL_PID "      -> assets  "
    set +e; wait $ACTOOL_PID; ACTOOL_EXIT=$?; set -e
    if [ $ACTOOL_EXIT -ne 0 ]; then
        printf "\r      Error compiling assets:\n"
        cat "$ACTOOL_LOG" >&2
        rm -f "$ACTOOL_LOG"; exit 1
    fi
    # Filter out dyld noise (system symbol mismatch warnings from Xcode beta internals)
    ACTOOL_WARN=$(grep -v "^dyld\[" "$ACTOOL_LOG" | grep -v "^$" || true)
    [ -n "$ACTOOL_WARN" ] && printf "%s\n" "$ACTOOL_WARN" | sed 's/^/      /'
    rm -f "$ACTOOL_LOG"
else
    echo "      Warning: Assets.xcassets not found — app icon will be missing."
fi
echo ""

# ── Step 5: Assemble .app bundle ─────────────────────────────────────────────────
echo "[5/5] Assembling .app bundle..."

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Main executable
printf "      -> executable  "
cp "$BUILD_DIR/intermediates/${APP_NAME}" "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"
chmod +x "$APP_BUNDLE/Contents/MacOS/${APP_NAME}"
printf "✓\n"

# Compiled assets (icon + asset catalog) + localized InfoPlist.strings
printf "      -> resources   "
if [ -d "$BUILD_DIR/intermediates/assets" ]; then
    find "$BUILD_DIR/intermediates/assets" -name "*.icns" -exec cp {} "$APP_BUNDLE/Contents/Resources/" \; 2>/dev/null || true
    find "$BUILD_DIR/intermediates/assets" -name "Assets.car" -exec cp {} "$APP_BUNDLE/Contents/Resources/" \; 2>/dev/null || true
fi
for LANG in en fr de it es; do
    LPROJ_SRC="$SCRIPT_DIR/src/${LANG}.lproj"
    if [ -d "$LPROJ_SRC" ]; then
        mkdir -p "$APP_BUNDLE/Contents/Resources/${LANG}.lproj"
        cp "$LPROJ_SRC/InfoPlist.strings" "$APP_BUNDLE/Contents/Resources/${LANG}.lproj/" 2>/dev/null || true
    fi
done
printf "✓\n"

# Info.plist — copy template and inject version/bundle ID
printf "      -> Info.plist  "
cp "$SCRIPT_DIR/src/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION"            "$APP_BUNDLE/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID"       "$APP_BUNDLE/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"
printf "✓\n"

# Ad-hoc code signature — allows local launch without a Developer ID certificate.
# For distribution, sign with a Developer ID and notarize with Apple.
printf "      -> signature   "
if codesign -s - --force "$APP_BUNDLE" 2>/dev/null; then
    printf "✓\n"
else
    printf "✗  (warning: codesign failed — app may not launch on some systems)\n"
fi

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
