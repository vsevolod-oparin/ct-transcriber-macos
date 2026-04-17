#!/bin/bash
#
# create-dmg.sh — Builds the app and creates a distributable DMG.
#
# Usage: ./scripts/create-dmg.sh [--skip-build] [--notarize]
#
# Output: dist/CTTranscriber-<version>.dmg
#
# Signing: The app target in Xcode signs with "Developer ID Application" and
# Hardened Runtime. This script code-signs the produced DMG and (optionally)
# submits it to Apple for notarization + stapling.
#
# Notarization prerequisite (run once):
#   xcrun notarytool store-credentials ct-transcriber-notary \
#     --apple-id <your-apple-id> \
#     --team-id 7ADYWA7W8T \
#     --password <app-specific-password>
#
# Then invoke with: ./scripts/create-dmg.sh --notarize

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="CT Transcriber"
BUNDLE_ID="com.branch.ct-transcriber"
TEAM_ID="7ADYWA7W8T"
SIGNING_IDENTITY="Developer ID Application: Vsevolod Oparin ($TEAM_ID)"
NOTARY_PROFILE="ct-transcriber-notary"
DMG_DIR="$PROJECT_DIR/dist"

SKIP_BUILD=0
NOTARIZE=0
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=1 ;;
        --notarize)   NOTARIZE=1 ;;
        *) echo "Unknown arg: $arg"; exit 1 ;;
    esac
done

cd "$PROJECT_DIR"

# Extract version from pbxproj (first MARKETING_VERSION wins)
VERSION=$(grep -m1 'MARKETING_VERSION = ' CTTranscriber.xcodeproj/project.pbxproj \
    | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' | tr -d '"')
VERSION=${VERSION:-"0.1.0"}
DMG_NAME="CT-Transcriber-${VERSION}.dmg"

echo "=== CT Transcriber DMG Builder ==="
echo "Version:  $VERSION"
echo "Output:   $DMG_DIR/$DMG_NAME"
echo "Identity: $SIGNING_IDENTITY"
echo "Notarize: $NOTARIZE"
echo ""

# Step 1: Build (unless --skip-build)
if [ "$SKIP_BUILD" -eq 0 ]; then
    echo "Building Release..."
    xcodebuild -scheme CTTranscriber \
        -configuration Release \
        -derivedDataPath build/DerivedData \
        -destination 'platform=macOS' \
        clean build 2>&1 | tail -3
    echo "Build complete."
    echo ""
fi

# Locate the signed .app
APP_PATH=$(find build/DerivedData -name "$APP_NAME.app" -path "*/Release/*" -type d 2>/dev/null | head -1)
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Error: Could not find built Release app. Run without --skip-build."
    exit 1
fi
echo "Found app: $APP_PATH"

# Step 2: Verify the app bundle signature end-to-end
echo ""
echo "Verifying app signature..."
codesign --verify --deep --strict --verbose=1 "$APP_PATH" 2>&1 | tail -5
echo ""

# Step 3: Stage DMG contents
mkdir -p "$DMG_DIR"
STAGING_DIR=$(mktemp -d)
trap "rm -rf '$STAGING_DIR'" EXIT

cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

cat > "$STAGING_DIR/README.txt" << 'EOF'
CT Transcriber — Audio & Video Transcription for macOS

INSTALLATION:
  Drag "CT Transcriber" to the Applications folder, then launch it.

The app is signed with a Developer ID certificate and uses Hardened
Runtime. On first launch it will be checked by Gatekeeper.

REQUIREMENTS:
  - macOS 14.0+ (Sonoma)
  - Apple Silicon (M1/M2/M3/M4)
  - Internet connection for model downloads and LLM features
  - ffmpeg in PATH (optional — only required for WebM files)
EOF

# Step 4: Create DMG
rm -f "$DMG_DIR/$DMG_NAME"
echo "Creating DMG..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_DIR/$DMG_NAME" >/dev/null

# Step 5: Sign the DMG
echo "Signing DMG..."
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_DIR/$DMG_NAME"
codesign --verify --verbose=1 "$DMG_DIR/$DMG_NAME" 2>&1 | tail -3

# Step 6: Optional notarization + stapling
if [ "$NOTARIZE" -eq 1 ]; then
    echo ""
    echo "Submitting to Apple for notarization (this can take a few minutes)..."
    xcrun notarytool submit "$DMG_DIR/$DMG_NAME" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$DMG_DIR/$DMG_NAME"
    xcrun stapler validate "$DMG_DIR/$DMG_NAME"
fi

echo ""
echo "=== Done ==="
echo "DMG:  $DMG_DIR/$DMG_NAME"
echo "Size: $(du -sh "$DMG_DIR/$DMG_NAME" | awk '{print $1}')"
[ "$NOTARIZE" -eq 1 ] && echo "Notarized & stapled."
