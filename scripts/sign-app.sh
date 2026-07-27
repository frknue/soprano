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
signing_keychain="${SOPRANO_CODESIGN_KEYCHAIN:-}"
distribution_signing="${SOPRANO_DISTRIBUTION_SIGNING:-0}"

if [[ "$distribution_signing" != "0" && "$distribution_signing" != "1" ]]; then
    echo "SOPRANO_DISTRIBUTION_SIGNING must be 0 or 1." >&2
    exit 2
fi

if [[ -n "$signing_keychain" && "$signing_keychain" != /* ]]; then
    echo "SOPRANO_CODESIGN_KEYCHAIN must be an absolute path." >&2
    exit 2
fi

if [[ "$distribution_signing" == "1" && -z "$signing_identity" ]]; then
    echo "Distribution signing requires SOPRANO_CODESIGN_IDENTITY." >&2
    exit 2
fi

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
if [[ "$distribution_signing" == "1" ]]; then
    codesign_arguments+=(--options runtime --timestamp)
fi
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
