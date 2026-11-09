#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
install_root="${SOPRANO_INSTALL_DIR:-/Applications}"

if [[ "$install_root" != /* || "$install_root" == "/" ]]; then
    echo "SOPRANO_INSTALL_DIR must be an absolute directory other than /." >&2
    exit 2
fi

# libghostty-vt builds with Zig 0.16; prefer Homebrew's keg-only zig@0.16 when present.
if [[ -z "${ZIG:-}" && -x /opt/homebrew/opt/zig@0.16/bin/zig ]]; then
    export ZIG=/opt/homebrew/opt/zig@0.16/bin/zig
fi

echo "Building Soprano for release..."
cd "$repo_root"
"$script_dir/prefetch-zig-deps.sh"
cargo build -p soprano --release

installed_app="$install_root/Soprano.app"
"$script_dir/package-app.sh" \
    release \
    "$installed_app" \
    "com.soprano.app" \
    "Soprano"

echo "Installed Soprano at $installed_app"
echo "The running app was not restarted; the update takes effect on its next launch."
