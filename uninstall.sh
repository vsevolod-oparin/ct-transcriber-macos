#!/bin/bash
# CT Transcriber Uninstaller
# Removes the app and all associated data

APP_NAME="CT Transcriber"
BUNDLE_ID="com.branch.ct-transcriber"

echo "CT Transcriber Uninstaller"
echo "========================="
echo ""
echo "This will remove:"
echo "  • /Applications/${APP_NAME}.app"
echo "  • ~/Library/Application Support/CTTranscriber/"
echo "  • ~/Library/Application Support/CT Transcriber/"
echo "  • ~/.ct-transcriber/ (Python environment, ~500 MB)"
echo "  • ~/.config/ct-transcriber/"
echo ""
read -p "Are you sure? (y/N) " confirm
if [[ "$confirm" != [yY] ]]; then
    echo "Cancelled."
    exit 0
fi

# Quit the app if running
if pgrep -x "$APP_NAME" > /dev/null 2>&1; then
    echo "Quitting ${APP_NAME}..."
    osascript -e "tell application \"${APP_NAME}\" to quit" 2>/dev/null
    sleep 2
    pkill -x "$APP_NAME" 2>/dev/null
fi

removed=0

# Remove the app bundle
if [ -d "/Applications/${APP_NAME}.app" ]; then
    rm -rf "/Applications/${APP_NAME}.app"
    echo "✓ Removed /Applications/${APP_NAME}.app"
    ((removed++))
fi

# Remove Application Support data
for dir in "$HOME/Library/Application Support/CTTranscriber" \
           "$HOME/Library/Application Support/CT Transcriber"; do
    if [ -d "$dir" ]; then
        rm -rf "$dir"
        echo "✓ Removed $dir"
        ((removed++))
    fi
done

# Remove Python environment (miniconda + conda envs)
if [ -d "$HOME/.ct-transcriber" ]; then
    rm -rf "$HOME/.ct-transcriber"
    echo "✓ Removed ~/.ct-transcriber (Python environment)"
    ((removed++))
fi

# Remove XDG config
if [ -d "$HOME/.config/ct-transcriber" ]; then
    rm -rf "$HOME/.config/ct-transcriber"
    echo "✓ Removed ~/.config/ct-transcriber"
    ((removed++))
fi

# Remove legacy SwiftData store (pre-0.2.0 used default location)
for suffix in "" "-shm" "-wal"; do
    rm -f "$HOME/Library/Application Support/default.store${suffix}"
done

# Remove cached preferences
if [ -f "$HOME/Library/Preferences/${BUNDLE_ID}.plist" ]; then
    rm -f "$HOME/Library/Preferences/${BUNDLE_ID}.plist"
    echo "✓ Removed preferences plist"
    ((removed++))
fi

# Remove from Launch Services cache
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -u "/Applications/${APP_NAME}.app" 2>/dev/null

if [ "$removed" -eq 0 ]; then
    echo "Nothing found to remove."
else
    echo ""
    echo "Done. CT Transcriber has been completely removed."
fi
