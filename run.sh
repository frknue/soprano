#!/bin/bash
set -euo pipefail

# Clear any stale window position
defaults delete "com.apple.SwiftUI" 2>/dev/null || true
defaults delete -g "SopranoMainWindow" 2>/dev/null || true

export PATH="/opt/homebrew/opt/swift/bin:$PATH"

echo "Building Soprano..."
swift build

build_dir=".build/debug"
app_path="$build_dir/Soprano.app"

echo "Creating development app bundle..."
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$build_dir/Soprano" "$app_path/Contents/MacOS/Soprano"
cp "Support/Info.plist" "$app_path/Contents/Info.plist"
cp "Sources/Soprano/Resources/AppIcon.icns" "$app_path/Contents/Resources/AppIcon.icns"
cp -R "$build_dir/Soprano_Soprano.bundle" "$app_path/Soprano_Soprano.bundle"

echo "Launching Soprano..."
exec open -n -W "$app_path"
