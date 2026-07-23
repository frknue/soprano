#!/bin/bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 <debug|release> <output.app> <bundle-id> <bundle-name>" >&2
    exit 2
fi

configuration="$1"
output_app="$2"
bundle_identifier="$3"
bundle_name="$4"

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
    echo "Unsupported build configuration: $configuration" >&2
    exit 2
fi

if [[ "$output_app" != /* || "$output_app" != *.app ]]; then
    echo "The output must be an absolute .app path: $output_app" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
build_dir="$repo_root/.build/$configuration"
output_parent="$(dirname "$output_app")"

binary_path="$build_dir/Soprano"
resource_bundle="$build_dir/Soprano_Soprano.bundle"
info_plist="$repo_root/Support/Info.plist"
app_icon="$repo_root/Sources/Soprano/Resources/AppIcon.icns"

ghostty_resources_dir=""
ghostty_resource_candidates=(
    "${SOPRANO_GHOSTTY_RESOURCES_DIR:-}"
    "$repo_root/ghostty/zig-out/share/ghostty"
    "${GHOSTTY_RESOURCES_DIR:-}"
    "/Applications/Ghostty.app/Contents/Resources/ghostty"
)

for candidate in "${ghostty_resource_candidates[@]}"; do
    if [[ -n "$candidate" \
        && -d "$candidate/themes" \
        && -d "$candidate/shell-integration" \
        && -f "$(dirname "$candidate")/terminfo/78/xterm-ghostty" ]]; then
        ghostty_resources_dir="$candidate"
        break
    fi
done

if [[ -z "$ghostty_resources_dir" ]]; then
    echo "Unable to find complete Ghostty runtime resources." >&2
    echo "Build Ghostty first, install Ghostty.app, or set SOPRANO_GHOSTTY_RESOURCES_DIR." >&2
    exit 1
fi

ghostty_terminfo_dir="$(dirname "$ghostty_resources_dir")/terminfo"

for required_path in "$binary_path" "$resource_bundle" "$info_plist" "$app_icon"; do
    if [[ ! -e "$required_path" ]]; then
        echo "Missing build artifact: $required_path" >&2
        exit 1
    fi
done

mkdir -p "$output_parent"
stage_dir="$(mktemp -d "$output_parent/.soprano-package.XXXXXX")"
staged_app="$stage_dir/$(basename "$output_app")"
previous_app="$stage_dir/previous.app"

cleanup() {
    rm -rf "$stage_dir"
}
trap cleanup EXIT

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources"
cp "$binary_path" "$staged_app/Contents/MacOS/Soprano"
cp "$info_plist" "$staged_app/Contents/Info.plist"
cp "$app_icon" "$staged_app/Contents/Resources/AppIcon.icns"
cp -R "$resource_bundle" "$staged_app/Contents/Resources/Soprano_Soprano.bundle"
cp -R "$ghostty_resources_dir" "$staged_app/Contents/Resources/ghostty"
cp -R "$ghostty_terminfo_dir" "$staged_app/Contents/Resources/terminfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $bundle_name" "$staged_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $bundle_name" "$staged_app/Contents/Info.plist"

"$script_dir/sign-app.sh" "$staged_app"

if [[ -e "$output_app" ]]; then
    mv "$output_app" "$previous_app"
fi

if ! mv "$staged_app" "$output_app"; then
    if [[ -e "$previous_app" ]]; then
        mv "$previous_app" "$output_app"
    fi
    exit 1
fi
