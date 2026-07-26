#!/bin/bash
# Builds VoiceType in release mode and assembles a self-contained .app bundle.
# Usage: ./package_app.sh [output_dir]   (defaults to ~/Downloads)
set -euo pipefail

cd "$(dirname "$0")"

OUT_DIR="${1:-$HOME/Downloads}"
APP="$OUT_DIR/VoiceType.app"
ARCH_DIR=".build/arm64-apple-macosx/release"

swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$ARCH_DIR/VoiceType" "$APP/Contents/MacOS/VoiceType"
cp Sources/VoiceType/Resources/Info.plist "$APP/Contents/Info.plist"
cp Sources/VoiceType/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ARCH_DIR/KeyboardShortcuts_KeyboardShortcuts.bundle" "$APP/Contents/Resources/KeyboardShortcuts_KeyboardShortcuts.bundle"

codesign --force --deep -s - "$APP"

echo "Packaged $APP"
