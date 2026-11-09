#!/bin/bash
# Builds Soprano for release and installs it under ~/.local (or SOPRANO_INSTALL_PREFIX).
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
install_prefix="${SOPRANO_INSTALL_PREFIX:-$HOME/.local}"

if [[ "$install_prefix" != /* || "$install_prefix" == "/" ]]; then
    echo "SOPRANO_INSTALL_PREFIX must be an absolute directory other than /." >&2
    exit 2
fi

echo "Building Soprano for release..."
cd "$repo_root"
"$script_dir/prefetch-zig-deps.sh"
cargo build -p soprano --release

SOPRANO_BUILD_PROFILE=release "$script_dir/package-linux.sh" "$install_prefix"

# Let launchers pick up the new entry and icons now rather than at next login.
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$install_prefix/share/applications" >/dev/null 2>&1 || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1 \
    && [[ -f "$install_prefix/share/icons/hicolor/index.theme" ]]; then
    gtk-update-icon-cache -q -t "$install_prefix/share/icons/hicolor" >/dev/null 2>&1 || true
fi

echo "Installed Soprano at $install_prefix/bin/soprano"
case ":$PATH:" in
    *":$install_prefix/bin:"*) ;;
    *) echo "Add $install_prefix/bin to PATH to run soprano from a shell." ;;
esac
echo "The running app was not restarted; the update takes effect on its next launch."
