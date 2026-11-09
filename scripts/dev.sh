#!/bin/bash
set -euo pipefail

launch_app=true
if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [--build-only]" >&2
    exit 2
fi
if [[ $# -eq 1 ]]; then
    if [[ "$1" != "--build-only" ]]; then
        echo "Usage: $0 [--build-only]" >&2
        exit 2
    fi
    launch_app=false
fi

target_dir="${CARGO_TARGET_DIR:-}"
if [[ -n "$target_dir" && ( "$target_dir" != /* || "$target_dir" == "/" ) ]]; then
    echo "CARGO_TARGET_DIR must be an absolute directory other than /." >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
target_dir="${target_dir:-$repo_root/target}"

# libghostty-vt builds with Zig 0.16; prefer Homebrew's keg-only zig@0.16 when present.
if [[ -z "${ZIG:-}" && -x /opt/homebrew/opt/zig@0.16/bin/zig ]]; then
    export ZIG=/opt/homebrew/opt/zig@0.16/bin/zig
fi

echo "Building Soprano Dev..."
cd "$repo_root"
"$script_dir/prefetch-zig-deps.sh"
cargo build -p soprano

dev_app="$target_dir/debug/Soprano Dev.app"
"$script_dir/package-app.sh" \
    debug \
    "$dev_app" \
    "com.soprano.dev" \
    "Soprano Dev"

echo "Created Soprano Dev at $dev_app"

if [[ "$launch_app" == true ]]; then
    echo "Launching an isolated Soprano Dev instance..."
    open -n "$dev_app"
fi
