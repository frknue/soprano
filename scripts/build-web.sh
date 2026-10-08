#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"

if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "Building omp web requires Node.js >= 22.19.0 and npm." >&2
    exit 1
fi
node -e 'const check = require(process.argv[1]); if (!check.isNodeVersionSupported(process.versions.node)) { console.error(check.getUnsupportedNodeVersionMessage(process.versions.node)); process.exit(1); }' "$repo_root/web/bin/node-version.js"

cd "$repo_root/web"
npm ci --no-audit --no-fund
npm run build
