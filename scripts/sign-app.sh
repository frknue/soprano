#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <absolute-app-path>" >&2
    exit 2
fi

app_path="$1"
if [[ "$app_path" != /* || "$app_path" != *.app || ! -d "$app_path" ]]; then
    echo "Soprano app signing: expected an existing absolute .app path: $app_path" >&2
    exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
signing_identity="${SOPRANO_CODESIGN_IDENTITY:-}"
signing_keychain=""

if [[ -z "$signing_identity" ]]; then
    if ! signing_resolution="$("$script_dir/ensure-local-signing-identity.sh")"; then
        echo "Soprano app signing: could not resolve a code-signing identity." >&2
        exit 1
    fi
    IFS=$'\t' read -r signing_identity signing_keychain <<< "$signing_resolution"
fi

codesign_arguments=(
    --force
    --sign "$signing_identity"
)
if [[ -n "$signing_keychain" ]]; then
    codesign_arguments+=(--keychain "$signing_keychain")
fi

if ! /usr/bin/codesign "${codesign_arguments[@]}" "$app_path"; then
    echo "Soprano app signing: could not sign $app_path with identity $signing_identity." >&2
    exit 1
fi
if ! /usr/bin/codesign --verify --deep --strict "$app_path"; then
    echo "Soprano app signing: strict signature verification failed for $app_path." >&2
    exit 1
fi
