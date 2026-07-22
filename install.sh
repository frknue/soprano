#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_root="${SOPRANO_INSTALL_DIR:-/Applications}"

if [[ "$install_root" != /* || "$install_root" == "/" ]]; then
    echo "SOPRANO_INSTALL_DIR must be an absolute directory other than /." >&2
    exit 2
fi

export PATH="/opt/homebrew/opt/swift/bin:$PATH"

echo "Building Soprano for release..."
cd "$script_dir"
swift build -c release

installed_app="$install_root/Soprano.app"
"$script_dir/scripts/package-app.sh" \
    release \
    "$installed_app" \
    "com.soprano.app" \
    "Soprano"

echo "Installed Soprano at $installed_app"
echo "The running app was not restarted; the update takes effect on its next launch."
