#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 <absolute-app-path> <absolute-output.dmg>" >&2
}

if [[ $# -ne 2 ]]; then
    usage
    exit 2
fi

app_path="$1"
output_dmg="$2"
signing_identity="${SOPRANO_CODESIGN_IDENTITY:-}"
signing_keychain="${SOPRANO_CODESIGN_KEYCHAIN:-}"
notary_profile="${SOPRANO_NOTARY_KEYCHAIN_PROFILE:-}"
notary_keychain="${SOPRANO_NOTARY_KEYCHAIN:-}"
notary_key_path="${SOPRANO_NOTARY_KEY_PATH:-}"
notary_key_id="${SOPRANO_NOTARY_KEY_ID:-}"
notary_issuer_id="${SOPRANO_NOTARY_ISSUER_ID:-}"
unnotarized_release="${SOPRANO_UNNOTARIZED_RELEASE:-0}"

if [[ "$app_path" != /* || ! -d "$app_path" || "$app_path" != *.app ]]; then
    echo "Expected an existing absolute .app path: $app_path" >&2
    exit 2
fi
if [[ "$output_dmg" != /* || "$output_dmg" != *.dmg ]]; then
    echo "Expected an absolute .dmg output path: $output_dmg" >&2
    exit 2
fi
if [[ -z "$signing_identity" ]]; then
    echo "SOPRANO_CODESIGN_IDENTITY is required." >&2
    exit 2
fi
if [[ "$unnotarized_release" != "0" && "$unnotarized_release" != "1" ]]; then
    echo "SOPRANO_UNNOTARIZED_RELEASE must be 0 or 1." >&2
    exit 2
fi
if [[ -n "$signing_keychain" && "$signing_keychain" != /* ]]; then
    echo "SOPRANO_CODESIGN_KEYCHAIN must be an absolute path." >&2
    exit 2
fi
if [[ -n "$notary_keychain" && "$notary_keychain" != /* ]]; then
    echo "SOPRANO_NOTARY_KEYCHAIN must be an absolute path." >&2
    exit 2
fi
if [[ -n "$notary_key_path" && "$notary_key_path" != /* ]]; then
    echo "SOPRANO_NOTARY_KEY_PATH must be an absolute path." >&2
    exit 2
fi

notary_arguments=()
if [[ "$unnotarized_release" == "1" ]]; then
    if [[ "$signing_identity" != "-" ]]; then
        echo "Unnotarized releases must use the ad-hoc signing identity '-'." >&2
        exit 2
    fi
else
    if [[ -n "$notary_profile" ]]; then
        if [[ -n "$notary_key_path" || -n "$notary_key_id" || -n "$notary_issuer_id" ]]; then
            echo "Use either a notary keychain profile or an App Store Connect API key, not both." >&2
            exit 2
        fi
        notary_arguments+=(--keychain-profile "$notary_profile")
        if [[ -n "$notary_keychain" ]]; then
            notary_arguments+=(--keychain "$notary_keychain")
        fi
    elif [[ -n "$notary_key_path" && -n "$notary_key_id" && -n "$notary_issuer_id" ]]; then
        if [[ ! -f "$notary_key_path" ]]; then
            echo "Notary API key does not exist: $notary_key_path" >&2
            exit 2
        fi
        notary_arguments+=(
            --key "$notary_key_path"
            --key-id "$notary_key_id"
            --issuer "$notary_issuer_id"
        )
    elif [[ -n "$notary_key_path" || -n "$notary_key_id" || -n "$notary_issuer_id" ]]; then
        echo "API-key notarization requires SOPRANO_NOTARY_KEY_PATH, _KEY_ID, and _ISSUER_ID." >&2
        exit 2
    else
        echo "Configure SOPRANO_NOTARY_KEYCHAIN_PROFILE or the three API-key variables." >&2
        exit 2
    fi
fi

app_binary="$app_path/Contents/MacOS/Soprano"
if [[ ! -f "$app_binary" ]]; then
    echo "Missing Soprano executable: $app_binary" >&2
    exit 1
fi

bundle_identifier="$(
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$app_path/Contents/Info.plist"
)"
if [[ "$bundle_identifier" != "com.soprano.app" ]]; then
    echo "Public releases must use bundle identifier com.soprano.app, got $bundle_identifier." >&2
    exit 1
fi

architectures="$(lipo -archs "$app_binary")"
for required_architecture in arm64 x86_64; do
    if [[ " $architectures " != *" $required_architecture "* ]]; then
        echo "Public releases must be universal; missing $required_architecture in $app_binary." >&2
        exit 1
    fi
done

if ! /usr/bin/codesign --verify --deep --strict "$app_path"; then
    echo "The app does not have a valid code signature." >&2
    exit 1
fi

signature_details="$(/usr/bin/codesign --display --verbose=4 "$app_path" 2>&1)"
if [[ "$unnotarized_release" == "1" ]]; then
    if [[ "$signature_details" != *"Signature=adhoc"* ]]; then
        echo "The unnotarized app must carry an ad-hoc code signature." >&2
        exit 1
    fi
else
    if [[ "$signature_details" != *"Authority=Developer ID Application:"* ]]; then
        echo "The app must be signed with a Developer ID Application certificate." >&2
        exit 1
    fi
    if [[ "$signature_details" != *"flags=0x10000(runtime)"* ]]; then
        echo "The app signature must enable the hardened runtime." >&2
        exit 1
    fi
    if [[ "$signature_details" != *"Timestamp="* ]]; then
        echo "The app signature must include a secure timestamp." >&2
        exit 1
    fi
fi

output_parent="$(dirname "$output_dmg")"
mkdir -p "$output_parent"
stage_dir="$(mktemp -d "$output_parent/.soprano-release.XXXXXX")"

cleanup() {
    rm -rf "$stage_dir"
}
trap cleanup EXIT

if [[ "$unnotarized_release" == "0" ]]; then
    notarization_zip="$stage_dir/Soprano.zip"
    echo "Submitting Soprano.app for notarization..."
    /usr/bin/ditto -c -k --keepParent "$app_path" "$notarization_zip"
    xcrun notarytool submit "$notarization_zip" "${notary_arguments[@]}" --wait
    xcrun stapler staple "$app_path"
    xcrun stapler validate "$app_path"
fi

dmg_root="$stage_dir/dmg-root"
unsigned_dmg="$stage_dir/Soprano.dmg"
mkdir -p "$dmg_root"
/usr/bin/ditto "$app_path" "$dmg_root/Soprano.app"
ln -s /Applications "$dmg_root/Applications"

echo "Creating $(basename "$output_dmg")..."
hdiutil create \
    -volname "Soprano" \
    -srcfolder "$dmg_root" \
    -format UDZO \
    -ov \
    "$unsigned_dmg"

codesign_arguments=(
    --force
    --sign "$signing_identity"
)
if [[ "$unnotarized_release" == "0" ]]; then
    codesign_arguments+=(--timestamp)
fi
if [[ -n "$signing_keychain" ]]; then
    codesign_arguments+=(--keychain "$signing_keychain")
fi
/usr/bin/codesign "${codesign_arguments[@]}" "$unsigned_dmg"
/usr/bin/codesign --verify --strict "$unsigned_dmg"

if [[ "$unnotarized_release" == "0" ]]; then
    echo "Submitting the disk image for notarization..."
    xcrun notarytool submit "$unsigned_dmg" "${notary_arguments[@]}" --wait
    xcrun stapler staple "$unsigned_dmg"
    xcrun stapler validate "$unsigned_dmg"
else
    if /usr/sbin/spctl \
        --assess \
        --type open \
        --context context:primary-signature \
        "$unsigned_dmg" >/dev/null 2>&1; then
        echo "The unnotarized disk image unexpectedly passed Gatekeeper assessment." >&2
        exit 1
    fi
    echo "Verified that Gatekeeper requires explicit user approval for this release."
fi

rm -f "$output_dmg"
mv "$unsigned_dmg" "$output_dmg"

if [[ "$unnotarized_release" == "0" ]]; then
    /usr/sbin/spctl \
        --assess \
        --type open \
        --context context:primary-signature \
        --verbose=2 \
        "$output_dmg"
fi

if [[ "$unnotarized_release" == "1" ]]; then
    echo "Created unnotarized release image at $output_dmg"
else
    echo "Created notarized release image at $output_dmg"
fi
