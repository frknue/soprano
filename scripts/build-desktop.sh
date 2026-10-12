#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$script_dir/.." && pwd)"
app="$root/.build/desktop/Soprano Desktop.app"
export PATH="/opt/homebrew/opt/swift/bin:$PATH"
sdk="${SOPRANO_DESKTOP_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk}"
if [[ "$sdk" != /* || ! -d "$sdk" ]]; then
    echo "SOPRANO_DESKTOP_SDK must name an installed absolute macOS SDK directory." >&2
    exit 1
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -swift-version 6 -O -whole-module-optimization -parse-as-library -target "$(uname -m)-apple-macos14.0" \
    -sdk "$sdk" \
    "$root"/Desktop/*.swift \
    "$root/Sources/Soprano/Config/Theme.swift" \
    "$root/Sources/Soprano/Views/RetroChrome.swift" \
    "$root/Sources/Soprano/Utilities/NSColor+Hex.swift" \
    -framework AppKit -framework Carbon -framework CoreText -framework QuartzCore \
    -framework ScreenCaptureKit -framework IOKit \
    -o "$app/Contents/MacOS/SopranoDesktop"
cp "$root/Desktop/Info.plist" "$app/Contents/Info.plist"
cp "$root/Sources/Soprano/Resources/DepartureMono-Regular.woff2" "$app/Contents/Resources/"
cp "$root/Support/Licenses/LICENSE-departure-mono" "$app/Contents/Resources/"

assets="$root/.build/desktop/assets"
"$app/Contents/MacOS/SopranoDesktop" render-assets "$assets"
iconset="$root/.build/desktop/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    /opt/homebrew/bin/magick "$assets/desktop-icon.png" -resize "${size}x${size}" "$iconset/icon_${size}x${size}.png"
    double=$((size * 2))
    /opt/homebrew/bin/magick "$assets/desktop-icon.png" -resize "${double}x${double}" "$iconset/icon_${size}x${size}@2x.png"
done
/usr/bin/iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
"$script_dir/sign-app.sh" "$app"
printf 'Built: %s\n' "$app"
