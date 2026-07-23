#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
helper="$repo_root/scripts/ensure-local-signing-identity.sh"
test_root="$(mktemp -d /tmp/soprano-local-signing-tests.XXXXXX)"
signing_dir="$test_root/signing"
keychain_path="$signing_dir/SopranoLocalSigning.keychain-db"
certificate_path="$test_root/certificate.pem"
identity_name="Soprano Local Development"
original_keychains=()

while IFS= read -r keychain_line; do
    keychain_path_entry="${keychain_line#"${keychain_line%%[![:space:]]*}"}"
    keychain_path_entry="${keychain_path_entry#\"}"
    keychain_path_entry="${keychain_path_entry%\"}"
    [[ -n "$keychain_path_entry" ]] && original_keychains+=("$keychain_path_entry")
done < <(/usr/bin/security list-keychains -d user)

cleanup() {
    /usr/bin/security list-keychains -d user -s "${original_keychains[@]}" \
        >/dev/null 2>&1 || true
    if [[ -e "$keychain_path" ]]; then
        /usr/bin/security find-certificate \
            -c "$identity_name" \
            -p "$keychain_path" > "$certificate_path" 2>/dev/null || true
        if [[ -s "$certificate_path" ]]; then
            /usr/bin/security remove-trusted-cert "$certificate_path" \
                >/dev/null 2>&1 || true
        fi
        /usr/bin/security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
    fi
    /usr/bin/trash "$test_root" >/dev/null 2>&1 || true
}
trap cleanup EXIT

invalid_directory_log="$test_root/invalid-directory.log"
if SOPRANO_LOCAL_SIGNING_DIR="/" "$helper" 2> "$invalid_directory_log"; then
    echo "Identity resolution unexpectedly accepted /" >&2
    exit 1
fi
if ! grep -q 'absolute directory other than /' "$invalid_directory_log"; then
    echo "Invalid directory failure was not actionable" >&2
    exit 1
fi

first_resolution="$(
    SOPRANO_LOCAL_SIGNING_DIR="$signing_dir" "$helper"
)"
second_resolution="$(
    SOPRANO_LOCAL_SIGNING_DIR="$signing_dir" "$helper"
)"

if [[ "$first_resolution" != "$second_resolution" ]]; then
    echo "Identity resolution changed between calls" >&2
    exit 1
fi

IFS=$'\t' read -r identity_hash resolved_keychain <<< "$first_resolution"
if [[ ! "$identity_hash" =~ ^[0-9A-F]{40}$ ]]; then
    echo "Expected a certificate SHA-1, got: $identity_hash" >&2
    exit 1
fi
if [[ "$resolved_keychain" != "$keychain_path" ]]; then
    echo "Unexpected keychain path: $resolved_keychain" >&2
    exit 1
fi

for variant in one two; do
    app_path="$test_root/$variant.app"
    mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
    cp /usr/bin/true "$app_path/Contents/MacOS/signing-test"
    /usr/bin/plutil -create xml1 "$app_path/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleExecutable \
        -string signing-test "$app_path/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier \
        -string com.soprano.signing-test "$app_path/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundlePackageType \
        -string APPL "$app_path/Contents/Info.plist"
    printf '%s\n' "$variant" > "$app_path/Contents/Resources/variant.txt"
    /usr/bin/codesign \
        --force \
        --sign "$identity_hash" \
        --keychain "$resolved_keychain" \
        "$app_path"
    /usr/bin/codesign --verify --deep --strict "$app_path"
done

requirement_one="$(
    /usr/bin/codesign -d -r- "$test_root/one.app" 2>&1 |
        sed -n 's/^designated => //p'
)"
requirement_two="$(
    /usr/bin/codesign -d -r- "$test_root/two.app" 2>&1 |
        sed -n 's/^designated => //p'
)"

if [[ "$requirement_one" != "$requirement_two" ]]; then
    echo "Designated requirements differ:" >&2
    printf 'one: %s\ntwo: %s\n' "$requirement_one" "$requirement_two" >&2
    exit 1
fi
if [[ "$requirement_one" != *'certificate root = H"'* ]]; then
    echo "Requirement is not certificate-backed: $requirement_one" >&2
    exit 1
fi
/usr/bin/codesign \
    --verify \
    --deep \
    --strict \
    --test-requirement "=$requirement_one" \
    "$test_root/two.app"

if /usr/bin/codesign -dv --verbose=4 "$test_root/two.app" 2>&1 |
    grep -q 'flags=.*adhoc'
then
    echo "Managed signature is unexpectedly ad-hoc" >&2
    exit 1
fi

sign_app="$repo_root/scripts/sign-app.sh"
managed_app="$test_root/managed.app"
cp -R "$test_root/one.app" "$managed_app"
/usr/bin/codesign --remove-signature "$managed_app"

SOPRANO_LOCAL_SIGNING_DIR="$signing_dir" "$sign_app" "$managed_app"
/usr/bin/codesign --verify --deep --strict "$managed_app"

explicit_app="$test_root/explicit.app"
cp -R "$test_root/two.app" "$explicit_app"
/usr/bin/codesign --remove-signature "$explicit_app"
SOPRANO_CODESIGN_IDENTITY="$identity_hash" \
SOPRANO_LOCAL_SIGNING_DIR="/must-not-be-used" \
    "$sign_app" "$explicit_app"
/usr/bin/codesign --verify --deep --strict "$explicit_app"

missing_identity_log="$test_root/missing-identity.log"
if SOPRANO_CODESIGN_IDENTITY="Soprano Missing Identity" \
    "$sign_app" "$explicit_app" 2> "$missing_identity_log"
then
    echo "Signing unexpectedly accepted a missing identity" >&2
    exit 1
fi
if ! grep -q 'could not sign' "$missing_identity_log"; then
    echo "Missing identity failure did not identify the signing step" >&2
    exit 1
fi

echo "Local code signing identity is stable."
