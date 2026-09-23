#!/bin/bash
set -euo pipefail

install_root="${SOPRANO_INSTALL_DIR:-/Applications}"
agent_dir="${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}"
if [[ "$install_root" != /* || "$install_root" == "/" \
    || "$agent_dir" != /* || "$agent_dir" == "/" ]]; then
    echo "SOPRANO_INSTALL_DIR and PI_CODING_AGENT_DIR must be absolute directories other than /." >&2
    exit 2
fi

extension="$install_root/Soprano.app/Contents/Resources/Soprano_Soprano.bundle/SopranoOmpAmbient.js"
if [[ ! -f "$extension" ]]; then
    echo "Install Soprano before enabling omp shell integration: $extension" >&2
    exit 1
fi

mkdir -p "$agent_dir/extensions"
link="$agent_dir/extensions/soprano-omp.js"
if [[ -e "$link" || -L "$link" ]]; then
    if [[ -L "$link" && "$(readlink "$link")" == "$extension" ]]; then
        echo "omp shell integration already enabled: $link"
        exit 0
    fi
    echo "Refusing to replace existing omp extension: $link" >&2
    exit 1
fi

ln -s "$extension" "$link"
echo "Enabled omp shell integration: $link"
echo "Restart an existing omp session to load the extension."
