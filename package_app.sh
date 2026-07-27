#!/bin/bash
# Builds VoiceType in release mode and assembles a self-contained .app bundle.
# Usage: ./package_app.sh [output_dir]   (defaults to ~/Downloads)
set -euo pipefail

cd "$(dirname "$0")"

OUT_DIR="${1:-$HOME/Downloads}"
PLIST=Sources/VoiceType/Resources/Info.plist
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")

# Auto-bump the build number every time so each packaged app is a distinct,
# non-overwriting file — otherwise VERSION never changes and this would just
# clobber the same VoiceType.<VERSION>.app on every run.
BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"

APP="$OUT_DIR/VoiceType.$VERSION.$BUILD.app"
ARCH_DIR=".build/arm64-apple-macosx/release"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ARCH_DIR/VoiceType" "$APP/Contents/MacOS/VoiceType"
cp Sources/VoiceType/Resources/Info.plist "$APP/Contents/Info.plist"
cp Sources/VoiceType/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ARCH_DIR/KeyboardShortcuts_KeyboardShortcuts.bundle" "$APP/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle"

# Verify the KeyboardShortcuts bundle was copied successfully and is non-empty
if ! [ -d "$APP/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle" ]; then
    echo "ERROR: KeyboardShortcuts bundle directory not found at $APP/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle" >&2
    exit 1
fi

if ! find "$APP/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle" -type f | grep -q .; then
    echo "ERROR: KeyboardShortcuts bundle is empty at $APP/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle" >&2
    exit 1
fi

codesign --force --deep -s - "$APP"

echo "Packaged $APP"
