#!/bin/bash
set -euo pipefail

# Rebuilds libghostty and refreshes everything derived from it in one step:
#
#   lib/libghostty.a                        the static library that gets linked
#   Sources/GhosttyKit/include/ghostty.h    the C API the Swift side compiles against
#   Support/ghostty-version.txt             the version GhosttyVersionTests asserts
#
# These three have to come from the same ghostty build. The library is not tracked
# (141 MB), so git cannot catch it when they drift apart, and a header that disagrees
# with the library can change a by-value struct layout and corrupt memory at runtime
# without a single compiler diagnostic. Copying them by hand is what lets that happen,
# so this script is the only supported way to update them.

usage() {
    echo "Usage: $0 [ghostty-ref]" >&2
    echo "  ghostty-ref  optional tag/commit to check out in ghostty/ first (e.g. v1.3.1)." >&2
    echo "               Omit to build whatever the submodule is currently at." >&2
}

if [[ $# -gt 1 ]]; then
    usage
    exit 2
fi

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi

requested_ref="${1:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
ghostty_dir="$repo_root/ghostty"
version_stamp="$repo_root/Support/ghostty-version.txt"

if [[ ! -f "$ghostty_dir/build.zig" ]]; then
    echo "The ghostty submodule is not checked out." >&2
    echo "Run: git submodule update --init --recursive" >&2
    exit 1
fi

# Metal shader compilation needs a full Xcode; Command Line Tools alone cannot do it.
developer_dir="${SOPRANO_DEVELOPER_DIR:-${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}}"

if [[ "$developer_dir" != /* ]]; then
    echo "The developer directory must be an absolute path: $developer_dir" >&2
    exit 2
fi

if [[ ! -x "$developer_dir/usr/bin/xcodebuild" ]]; then
    echo "No full Xcode found at: $developer_dir" >&2
    echo "libghostty needs the Metal toolchain, which Command Line Tools does not provide." >&2
    echo "Install Xcode, then run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    echo "  xcodebuild -downloadComponent MetalToolchain" >&2
    echo "Set SOPRANO_DEVELOPER_DIR to override the location." >&2
    exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
    echo "zig is not on PATH. Install the version required by ghostty/build.zig.zon." >&2
    exit 1
fi

minimum_zig="$(sed -n 's/.*\.minimum_zig_version = "\([^"]*\)".*/\1/p' "$ghostty_dir/build.zig.zon" | head -1)"
installed_zig="$(zig version)"

if [[ -n "$minimum_zig" && "$installed_zig" != "$minimum_zig" ]]; then
    echo "ghostty needs Zig $minimum_zig exactly but zig $installed_zig is installed." >&2
    exit 1
fi

if [[ -n "$requested_ref" ]]; then
    echo "Checking out ghostty $requested_ref..."
    git -C "$ghostty_dir" fetch --tags origin
    git -C "$ghostty_dir" checkout --detach "$requested_ref"
fi

building_commit="$(git -C "$ghostty_dir" rev-parse HEAD)"
recorded_commit="$(git -C "$repo_root" ls-tree HEAD ghostty | awk '{print $3}')"

if [[ -n "$recorded_commit" && "$building_commit" != "$recorded_commit" ]]; then
    echo "Note: ghostty/ is at $building_commit but the committed pin is $recorded_commit."
    echo "      Run 'git add ghostty' afterwards so the pin records what you built."
fi

echo "Building libghostty at $building_commit (this takes a while)..."
(
    cd "$ghostty_dir"
    DEVELOPER_DIR="$developer_dir" zig build \
        -Dapp-runtime=none \
        -Demit-xcframework=true \
        -Dxcframework-target=native \
        -Demit-macos-app=false \
        -Doptimize=ReleaseFast
)

xcframework_dir="$ghostty_dir/macos/GhosttyKit.xcframework"
built_libraries=()
built_headers=()

if [[ -d "$xcframework_dir" ]]; then
    while IFS= read -r artifact; do
        built_libraries+=("$artifact")
    done < <(find "$xcframework_dir" -type f -name 'libghostty*.a' -print)

    while IFS= read -r artifact; do
        built_headers+=("$artifact")
    done < <(find "$xcframework_dir" -type f -name 'ghostty.h' -print)
fi

if [[ "${#built_libraries[@]}" -ne 1 || "${#built_headers[@]}" -ne 1 ]]; then
    echo "The native Ghostty XCFramework did not contain one library and header." >&2
    echo "Found ${#built_libraries[@]} libraries and ${#built_headers[@]} headers in:" >&2
    echo "  $xcframework_dir" >&2
    exit 1
fi

built_library="${built_libraries[0]}"
built_header="${built_headers[0]}"

# Read the version out of the artifact rather than recomputing it, so the stamp cannot
# disagree with what ghostty_info() reports at runtime.
built_versions="$(
    strings -a "$built_library" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+-[a-z]+\+[0-9a-f]{7,}' \
        | sort -u
)"
version_count="$(printf '%s' "$built_versions" | grep -c . || true)"

if [[ "$version_count" -ne 1 ]]; then
    echo "Could not determine a single ghostty version from $built_library." >&2
    echo "Found: ${built_versions:-none}" >&2
    exit 1
fi

built_version="$built_versions"

stage_dir="$(mktemp -d "$repo_root/.build-ghostty.XXXXXX")"

cleanup() {
    rm -rf "$stage_dir"
}
trap cleanup EXIT

# Stage first so a failure cannot leave a new library next to an old header.
cp "$built_library" "$stage_dir/libghostty.a"
cp "$built_header" "$stage_dir/ghostty.h"
printf '%s\n' "$built_version" > "$stage_dir/ghostty-version.txt"

mkdir -p "$repo_root/lib" "$repo_root/Sources/GhosttyKit/include"
mv "$stage_dir/libghostty.a" "$repo_root/lib/libghostty.a"
mv "$stage_dir/ghostty.h" "$repo_root/Sources/GhosttyKit/include/ghostty.h"
mv "$stage_dir/ghostty-version.txt" "$version_stamp"

echo
echo "Updated to ghostty $built_version"
echo "  lib/libghostty.a"
echo "  Sources/GhosttyKit/include/ghostty.h"
echo "  Support/ghostty-version.txt"
echo
echo "Now verify the new C API still matches the Swift side:"
echo "  swift build && swift test"
