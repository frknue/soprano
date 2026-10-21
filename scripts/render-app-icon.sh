#!/bin/bash
# Renders the Folio app icon with scripts/render-app-icon.swift (shared by the whole Soprano
# family) and writes Sources/Soprano/Resources/AppIcon.icns plus the README's app-icon.png
# (1024×1024). Usage: render-app-icon.sh
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

export DEVELOPER_DIR=/Library/Developer/CommandLineTools
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

iconset="$work_dir/AppIcon.iconset"
swift "$script_dir/render-app-icon.swift" soprano "$iconset"

staged_icns="$work_dir/AppIcon.icns"
/usr/bin/iconutil -c icns -o "$staged_icns" "$iconset"
mv -f "$staged_icns" "$icns_path"
echo "Wrote $icns_path"

cp "$iconset/icon_512x512@2x.png" "$readme_png"
echo "Wrote $readme_png"
