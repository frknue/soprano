#!/bin/bash
# Packages the cargo-built `soprano` binary as a signed macOS app bundle.
# Build first: cargo build -p soprano [--release]
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

target_dir="${CARGO_TARGET_DIR:-}"
if [[ -n "$target_dir" && ( "$target_dir" != /* || "$target_dir" == "/" ) ]]; then
    echo "CARGO_TARGET_DIR must be an absolute directory other than /." >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
target_dir="${target_dir:-$repo_root/target}"
output_parent="$(dirname "$output_app")"

binary_path="$target_dir/$configuration/soprano"
info_plist="$repo_root/Support/Info.plist"
app_icon="$repo_root/resources/icons/AppIcon.icns"

# A pane inherits its Soprano's environment, so CARGO_TARGET_DIR can point into an installed
# Soprano.app. Packaging from there would copy the installed app's executable straight back
# into the new bundle instead of the one cargo just built. Refuse inputs from a Soprano bundle.
soprano_bundle_containing() {
    local path="$1"

    while [[ "$path" == */* && "$path" != "/" ]]; do
        if [[ "$path" == *.app && -f "$path/Contents/Info.plist" ]]; then
            local identifier
            identifier="$(
                defaults read "$path/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true
            )"
            if [[ "$identifier" == com.soprano.* ]]; then
                printf '%s\n' "$path"
                return 0
            fi
        fi
        path="$(dirname "$path")"
    done
    return 1
}

if bundle="$(soprano_bundle_containing "$binary_path")"; then
    echo "Refusing to package an executable from inside the Soprano bundle $bundle." >&2
    echo "Unset CARGO_TARGET_DIR or point it at a cargo target directory." >&2
    exit 1
fi

for required_path in "$binary_path" "$info_plist" "$app_icon"; do
    if [[ ! -e "$required_path" ]]; then
        echo "Missing build artifact: $required_path" >&2
        exit 1
    fi
done

version="$("$script_dir/cargo-version.sh")"

mkdir -p "$output_parent"
stage_dir="$(mktemp -d "$output_parent/.soprano-package.XXXXXX")"
staged_app="$stage_dir/$(basename "$output_app")"
previous_app="$stage_dir/previous.app"

cleanup() {
    rm -rf "$stage_dir"
}
trap cleanup EXIT

resources="$staged_app/Contents/Resources"
mkdir -p "$staged_app/Contents/MacOS"
"$script_dir/stage-resources.sh" macos "$resources"

cp "$binary_path" "$staged_app/Contents/MacOS/Soprano"
ln -s "../../MacOS/Soprano" "$resources/bin/soprano"
cp "$app_icon" "$resources/AppIcon.icns"

plist="$staged_app/Contents/Info.plist"
cp "$info_plist" "$plist"
/usr/bin/plutil -replace CFBundleExecutable -string "Soprano" "$plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_identifier" "$plist"
/usr/bin/plutil -replace CFBundleName -string "$bundle_name" "$plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "$bundle_name" "$plist"
/usr/bin/plutil -replace CFBundleIconFile -string "AppIcon" "$plist"
/usr/bin/plutil -replace CFBundleShortVersionString -string "$version" "$plist"
/usr/bin/plutil -replace CFBundleVersion -string "$version" "$plist"
/usr/bin/plutil -lint "$plist" >/dev/null

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
