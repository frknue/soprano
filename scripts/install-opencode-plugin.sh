#!/bin/bash
set -euo pipefail

config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
# Where the installed app keeps its bundle: the macOS app's Resources, or the Linux prefix
# install-linux.sh used.
if [[ "$(uname -s)" == "Darwin" ]]; then
    install_root="${SOPRANO_INSTALL_DIR:-/Applications}"
    bundle_dir="$install_root/Soprano.app/Contents/Resources/Soprano_Soprano.bundle"
else
    install_root="${SOPRANO_INSTALL_PREFIX:-$HOME/.local}"
    bundle_dir="$install_root/share/soprano/Soprano_Soprano.bundle"
fi
if [[ "$install_root" != /* || "$install_root" == "/" \
    || "$config_home" != /* || "$config_home" == "/" ]]; then
    echo "The install location and XDG_CONFIG_HOME must be absolute directories other than /." >&2
    exit 2
fi

plugin="$bundle_dir/SopranoOpenCodeAmbient"
if [[ ! -f "$plugin/tui.js" ]]; then
    echo "Install Soprano before enabling OpenCode shell integration: $plugin" >&2
    exit 1
fi

mkdir -p "$config_home/opencode/plugins"
link="$config_home/opencode/plugins/soprano"
if [[ -e "$link" || -L "$link" ]]; then
    if [[ -L "$link" && "$(readlink "$link")" == "$plugin" ]]; then
        echo "OpenCode shell integration already enabled: $link"
        exit 0
    fi
    echo "Refusing to replace existing OpenCode plugin: $link" >&2
    exit 1
fi

ln -s "$plugin" "$link"
echo "Enabled OpenCode shell integration: $link"
echo "Restart a running opencode to load the plugin."
