#!/bin/bash
# Prints Soprano's version: `[workspace.package] version` in the root Cargo.toml, the single
# source of truth for the app, its bundle Info.plist, release tags and artifact names.
set -euo pipefail

if [[ $# -ne 0 ]]; then
    echo "Usage: $0" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$script_dir/../Cargo.toml"

version="$(
    sed -n '/^\[workspace\.package\]/,/^\[/{s/^version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p;}' \
        "$manifest"
)"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]; then
    echo "Could not read [workspace.package] version from $manifest (got: '$version')." >&2
    exit 1
fi

printf '%s\n' "$version"
