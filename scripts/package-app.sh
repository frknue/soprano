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
soprano_license="$repo_root/LICENSE"
ghostty_license="$repo_root/Support/Licenses/LICENSE-ghostty"
swift_cmark_license="$repo_root/Support/Licenses/LICENSE-swift-cmark"

ghostty_resources_dir=""
ghostty_resource_candidates=(
    "${SOPRANO_GHOSTTY_RESOURCES_DIR:-}"
    "$repo_root/ghostty/zig-out/share/ghostty"
    "${GHOSTTY_RESOURCES_DIR:-}"
    "/Applications/Ghostty.app/Contents/Resources/ghostty"
)

# Soprano exports GHOSTTY_RESOURCES_DIR into every pane, pointing at its own bundle. Packaging
# from inside a Soprano pane would therefore copy the runtime resources out of the previously
# installed Soprano and straight back into the new one, forwarding them from build to build
# without them ever coming from ghostty again. Refuse to read resources out of a Soprano bundle.
is_soprano_bundle() {
    local resources_dir="$1"

    case "$resources_dir" in
        */Contents/Resources/ghostty) ;;
        *) return 1 ;;
    esac

    local bundle="${resources_dir%/Contents/Resources/ghostty}"
    local identifier

    identifier="$(
        defaults read "$bundle/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true
    )"

    case "$identifier" in
        com.soprano.*) return 0 ;;
        *) return 1 ;;
    esac
}

for candidate in "${ghostty_resource_candidates[@]}"; do
    if [[ -n "$candidate" \
        && -d "$candidate/themes" \
        && -d "$candidate/shell-integration" \
        && -f "$(dirname "$candidate")/terminfo/78/xterm-ghostty" ]]; then
        if is_soprano_bundle "$candidate"; then
            echo "Ignoring Ghostty resources inside a Soprano bundle: $candidate"
            continue
        fi

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

# The runtime resources (themes, shell-integration, terminfo) are found separately from the
# library Soprano links, so they can silently come from a different Ghostty version. That is
# mostly harmless for themes, but a mismatched terminfo or shell-integration breaks key
# handling and the prompt markers pane status depends on. Report what was picked, and say so
# when it does not match the linked library.
echo "Ghostty runtime resources: $ghostty_resources_dir"

linked_ghostty_version=""
if [[ -f "$repo_root/Support/ghostty-version.txt" ]]; then
    linked_ghostty_version="$(tr -d '[:space:]' < "$repo_root/Support/ghostty-version.txt")"
fi

resources_ghostty_version=""
if [[ "$ghostty_resources_dir" == "$repo_root/ghostty/zig-out/share/ghostty" ]]; then
    resources_ghostty_version="$linked_ghostty_version"
elif [[ "$ghostty_resources_dir" == *"/Ghostty.app/Contents/Resources/ghostty" ]]; then
    resources_app="${ghostty_resources_dir%/Contents/Resources/ghostty}"
    resources_ghostty_version="$(
        defaults read "$resources_app/Contents/Info.plist" CFBundleShortVersionString 2>/dev/null || true
    )"
fi

if [[ -n "$linked_ghostty_version" && -n "$resources_ghostty_version" ]]; then
    # Compare only X.Y.Z: the linked version carries a channel and commit suffix that a
    # released Ghostty.app never has.
    linked_release="${linked_ghostty_version%%-*}"
    resources_release="${resources_ghostty_version%%-*}"

    if [[ "$linked_release" != "$resources_release" ]]; then
        echo "Warning: resources are Ghostty $resources_ghostty_version but the linked" >&2
        echo "         libghostty is $linked_ghostty_version." >&2
        echo "         Build the submodule (scripts/build-ghostty.sh) so both come from one" >&2
        echo "         source, or set SOPRANO_GHOSTTY_RESOURCES_DIR to a matching directory." >&2

        if [[ "${SOPRANO_STRICT_GHOSTTY_RESOURCES:-0}" != "0" ]]; then
            echo "SOPRANO_STRICT_GHOSTTY_RESOURCES is set; refusing to package a mismatch." >&2
            exit 1
        fi
    fi
elif [[ -z "$resources_ghostty_version" ]]; then
    echo "Note: could not determine the version of those resources."
fi

for required_path in "$binary_path" "$resource_bundle" "$info_plist" "$app_icon" \
    "$soprano_license" "$ghostty_license" "$swift_cmark_license"; do
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

mkdir -p "$staged_app/Contents/MacOS" "$staged_app/Contents/Resources/bin"
cp "$binary_path" "$staged_app/Contents/MacOS/Soprano"
ln -s "../../MacOS/Soprano" "$staged_app/Contents/Resources/bin/soprano"
cp "$info_plist" "$staged_app/Contents/Info.plist"
cp "$app_icon" "$staged_app/Contents/Resources/AppIcon.icns"
cp "$soprano_license" "$staged_app/Contents/Resources/LICENSE"
cp "$ghostty_license" "$staged_app/Contents/Resources/LICENSE-ghostty"
cp "$swift_cmark_license" "$staged_app/Contents/Resources/LICENSE-swift-cmark"
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
