#!/bin/bash
# Renders the Folio app icon with scripts/render-app-icon.swift (shared by the whole Soprano
# family) as an Icon Composer document and writes Sources/Soprano/Resources/AppIcon.icns plus
# the README's app-icon.png (1024×1024). Every iconset member is the Default appearance
# rendered by Icon Composer's ictool at the body size (824 of 1024) and padded to the macOS
# icon canvas. Needs Xcode 26 or later (default /Applications/Xcode.app, override with
# XCODE_DIR). Usage: render-app-icon.sh
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

xcode_app="${XCODE_DIR:-/Applications/Xcode.app}"
ictool="$xcode_app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ ! -x "$ictool" ]]; then
    echo "Missing $ictool (needs Xcode 26 or later; set XCODE_DIR)" >&2
    exit 1
fi

# Defaults only: a caller's own toolchain choice wins.
: "${DEVELOPER_DIR:=/Library/Developer/CommandLineTools}"
: "${SDKROOT:=$DEVELOPER_DIR/SDKs/MacOSX26.sdk}"
export DEVELOPER_DIR SDKROOT
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
icns_path="$repo_root/Sources/Soprano/Resources/AppIcon.icns"
readme_png="$repo_root/app-icon.png"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/soprano-icon.XXXXXX")"
cleanup() {
    rm -rf "$work_dir"
}
trap cleanup EXIT

icon_document="$work_dir/AppIcon.icon"
swift "$script_dir/render-app-icon.swift" soprano "$icon_document"

# One iconset member: the tile at 824/1024 of the member size, centred on a transparent canvas.
render_member() {
    local pixels="$1" output="$2"
    local tile=$(((pixels * 824 + 512) / 1024))
    rm -f "$work_dir/tile.png"
    if ! "$ictool" "$icon_document" --export-image --output-file "$work_dir/tile.png" \
        --platform macOS --rendition Default --width "$tile" --height "$tile" --scale 1 \
        >"$work_dir/ictool.log" 2>&1 || [[ ! -s "$work_dir/tile.png" ]]; then
        echo "ictool failed for $pixels px:" >&2
        cat "$work_dir/ictool.log" >&2
        exit 1
    fi
    /usr/bin/sips --padToHeightWidth "$pixels" "$pixels" "$work_dir/tile.png" --out "$output" >/dev/null
}

iconset="$work_dir/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    render_member "$size" "$iconset/icon_${size}x${size}.png"
    render_member $((size * 2)) "$iconset/icon_${size}x${size}@2x.png"
done

staged_icns="$work_dir/AppIcon.icns"
/usr/bin/iconutil -c icns -o "$staged_icns" "$iconset"
mv -f "$staged_icns" "$icns_path"
echo "Wrote $icns_path"

cp "$iconset/icon_512x512@2x.png" "$readme_png"
echo "Wrote $readme_png"
