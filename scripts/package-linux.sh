#!/bin/bash
# Installs the cargo-built `soprano` binary and its resources under a Linux prefix:
#
#   <prefix>/bin/soprano
#   <prefix>/share/soprano/                          resources (scripts/stage-resources.sh)
#   <prefix>/share/applications/soprano.desktop
#   <prefix>/share/icons/hicolor/<N>x<N>/apps/soprano.png
#
# Only Soprano's own files are replaced, so the prefix may be shared (~/.local, /usr/local).
# Build first: cargo build -p soprano [--release]
#
# Environment:
#   SOPRANO_BUILD_PROFILE  debug or release (default release): which cargo build to package
#   SOPRANO_DESKTOP_EXEC   the desktop entry's command (default <prefix>/bin/soprano);
#                          relocatable archives use plain `soprano`
# Usage: package-linux.sh <absolute-prefix>
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <absolute-prefix>" >&2
    exit 2
fi

prefix="$1"
if [[ "$prefix" != /* || "$prefix" == "/" ]]; then
    echo "The prefix must be an absolute directory other than /: $prefix" >&2
    exit 2
fi
prefix="${prefix%/}"

configuration="${SOPRANO_BUILD_PROFILE:-release}"
if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    echo "SOPRANO_BUILD_PROFILE must be debug or release." >&2
    exit 2
fi

target_dir="${CARGO_TARGET_DIR:-}"
if [[ -n "$target_dir" && ( "$target_dir" != /* || "$target_dir" == "/" ) ]]; then
    echo "CARGO_TARGET_DIR must be an absolute directory other than /." >&2
    exit 2
fi

desktop_exec="${SOPRANO_DESKTOP_EXEC:-$prefix/bin/soprano}"
if [[ "$desktop_exec" == *[\"\`\$\\]* || "$desktop_exec" == *$'\n'* ]]; then
    echo "SOPRANO_DESKTOP_EXEC must not contain quotes, backslashes, \$, \` or newlines." >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
target_dir="${target_dir:-$repo_root/target}"
binary_path="$target_dir/$configuration/soprano"
app_icon="$repo_root/resources/icons/app-icon.png"

for required_path in "$binary_path" "$app_icon"; do
    if [[ ! -e "$required_path" ]]; then
        echo "Missing build artifact: $required_path" >&2
        exit 1
    fi
done

mkdir -p "$prefix/bin" "$prefix/share"
stage_dir="$(mktemp -d "$prefix/share/.soprano-package.XXXXXX")"
cleanup() {
    rm -rf "$stage_dir"
}
trap cleanup EXIT

staged_resources="$stage_dir/soprano"
"$script_dir/stage-resources.sh" linux "$staged_resources"
ln -s "../../../bin/soprano" "$staged_resources/bin/soprano"

# Desktop entry.
staged_desktop="$stage_dir/soprano.desktop"
cat > "$staged_desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Soprano
GenericName=Terminal Multiplexer
Comment=Tiling terminal multiplexer for AI coding agents
Exec="$desktop_exec"
Icon=soprano
Terminal=false
StartupNotify=true
Categories=System;TerminalEmulator;Development;
Keywords=terminal;agents;multiplexer;tmux;
EOF

# Icons: hicolor sizes rendered from the 1024 px app icon with the first resizer available.
staged_icons="$stage_dir/icons"
icon_sizes=(16 24 32 48 64 128 256 512)
resizer=""
if command -v magick >/dev/null 2>&1; then
    resizer="magick"
elif command -v convert >/dev/null 2>&1; then
    resizer="convert"
elif command -v sips >/dev/null 2>&1; then
    resizer="sips"
fi
if [[ -n "$resizer" ]]; then
    for size in "${icon_sizes[@]}"; do
        icon_dir="$staged_icons/hicolor/${size}x${size}/apps"
        mkdir -p "$icon_dir"
        case "$resizer" in
            magick | convert)
                "$resizer" "$app_icon" -resize "${size}x${size}" "$icon_dir/soprano.png"
                ;;
            sips)
                sips -z "$size" "$size" "$app_icon" --out "$icon_dir/soprano.png" >/dev/null
                ;;
        esac
    done
else
    echo "Note: no ImageMagick or sips; installing the full-size icon to share/pixmaps only."
fi

# Install: resources swap in whole, everything else is replaced file by file.
installed_resources="$prefix/share/soprano"
previous_resources="$stage_dir/previous-soprano"
if [[ -e "$installed_resources" || -L "$installed_resources" ]]; then
    mv "$installed_resources" "$previous_resources"
fi
if ! mv "$staged_resources" "$installed_resources"; then
    if [[ -e "$previous_resources" ]]; then
        mv "$previous_resources" "$installed_resources"
    fi
    exit 1
fi

cp "$binary_path" "$prefix/bin/.soprano.new"
chmod 755 "$prefix/bin/.soprano.new"
mv -f "$prefix/bin/.soprano.new" "$prefix/bin/soprano"

mkdir -p "$prefix/share/applications"
cp "$staged_desktop" "$prefix/share/applications/soprano.desktop"

if [[ -n "$resizer" ]]; then
    for size in "${icon_sizes[@]}"; do
        icon_dir="$prefix/share/icons/hicolor/${size}x${size}/apps"
        mkdir -p "$icon_dir"
        cp "$staged_icons/hicolor/${size}x${size}/apps/soprano.png" "$icon_dir/soprano.png"
    done
else
    mkdir -p "$prefix/share/pixmaps"
    cp "$app_icon" "$prefix/share/pixmaps/soprano.png"
fi
