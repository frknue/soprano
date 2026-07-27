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

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
export PATH="/opt/homebrew/opt/swift/bin:$PATH"

echo "Building Soprano Dev..."
cd "$repo_root"
swift build

dev_app="$repo_root/.build/debug/Soprano Dev.app"
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
