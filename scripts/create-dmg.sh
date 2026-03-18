#!/bin/bash
#
# create-dmg.sh — Builds the app and creates a distributable DMG.
#
# Usage: ./scripts/create-dmg.sh [--skip-build]
#
# Output: dist/CTTranscriber-<version>.dmg
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="CT Transcriber"
BUNDLE_ID="com.branch.ct-transcriber"
DMG_DIR="$PROJECT_DIR/dist"

cd "$PROJECT_DIR"

# Get version from project.yml
VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | awk -F'"' '{print $2}')
VERSION=${VERSION:-"0.1.0"}
DMG_NAME="CTTranscriber-${VERSION}.dmg"

echo "=== CT Transcriber DMG Builder ==="
echo "Version: $VERSION"
echo "Output: $DMG_DIR/$DMG_NAME"
echo ""

# Step 1: Build (unless --skip-build)
if [[ "${1:-}" != "--skip-build" ]]; then
    echo "Building..."
    xcodebuild -scheme CTTranscriber \
        -configuration Release \
        -derivedDataPath build/DerivedData \
        -destination 'platform=macOS' \
        build 2>&1 | tail -3

    echo "Build complete."
fi

# Find the built app
APP_PATH=$(find build/DerivedData -name "$APP_NAME.app" -path "*/Release/*" -type d 2>/dev/null | head -1)
if [ -z "$APP_PATH" ]; then
    # Try Debug if Release not found
    APP_PATH=$(find build/DerivedData -name "$APP_NAME.app" -type d 2>/dev/null | head -1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Error: Could not find built app. Run without --skip-build."
    exit 1
fi

echo "Found app: $APP_PATH"

# Step 2: Create DMG
mkdir -p "$DMG_DIR"

# Create a temporary directory for the DMG contents
STAGING_DIR=$(mktemp -d)
trap "rm -rf '$STAGING_DIR'" EXIT

cp -R "$APP_PATH" "$STAGING_DIR/"

# Create Applications symlink
ln -s /Applications "$STAGING_DIR/Applications"

# Create README
cat > "$STAGING_DIR/README.txt" << 'EOF'
CT Transcriber — Audio & Video Transcription for macOS

INSTALLATION:
  Drag "CT Transcriber" to the Applications folder.

FIRST LAUNCH:
  macOS may show a Gatekeeper warning since the app is unsigned.
  To bypass: right-click the app → Open, or run:
    xattr -cr /Applications/CT\ Transcriber.app

The app will automatically set up its Python environment on first launch
(downloads ~60 MB Miniconda + dependencies). No manual setup required.

REQUIREMENTS:
  - macOS 14.0+ (Sonoma)
  - Apple Silicon (M1/M2/M3/M4)
  - Internet connection for first setup and LLM features
EOF

# Remove any existing DMG
rm -f "$DMG_DIR/$DMG_NAME"

# Create DMG using hdiutil
echo "Creating DMG..."
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_DIR/$DMG_NAME"

echo ""
echo "=== Done ==="
echo "DMG: $DMG_DIR/$DMG_NAME"
echo "Size: $(du -sh "$DMG_DIR/$DMG_NAME" | awk '{print $1}')"
