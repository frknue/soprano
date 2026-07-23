#!/bin/bash
set -euo pipefail

identity_name="Soprano Local Development"
signing_dir="${SOPRANO_LOCAL_SIGNING_DIR:-$HOME/Library/Application Support/Soprano/Signing}"
keychain_path="$signing_dir/SopranoLocalSigning.keychain-db"
password_path="$signing_dir/keychain-password"
security_bin="/usr/bin/security"
openssl_bin="/usr/bin/openssl"

fail() {
    echo "Soprano signing identity: $*" >&2
    exit 1
}

if [[ "$signing_dir" != /* || "$signing_dir" == "/" ]]; then
    fail "SOPRANO_LOCAL_SIGNING_DIR must be an absolute directory other than /."
fi

umask 077
mkdir -p "$signing_dir"
chmod 700 "$signing_dir"

creation_dir=""
created_keychain=false
trusted_certificate=false

cleanup_creation() {
    status=$?
    if [[ $status -ne 0 && "$created_keychain" == true ]]; then
        if [[ "$trusted_certificate" == true && -n "$creation_dir" ]]; then
            "$security_bin" remove-trusted-cert "$creation_dir/certificate.pem" \
                >/dev/null 2>&1 || true
        fi
        "$security_bin" delete-keychain "$keychain_path" >/dev/null 2>&1 || true
    fi
    if [[ -n "$creation_dir" && -d "$creation_dir" ]]; then
        find "$creation_dir" -depth -delete >/dev/null 2>&1 || true
    fi
    exit "$status"
}
trap cleanup_creation EXIT

add_keychain_to_search_list() {
    local line existing found
    local -a keychains
    found=false
    keychains=()

    while IFS= read -r line; do
        existing="${line#"${line%%[![:space:]]*}"}"
        existing="${existing#\"}"
        existing="${existing%\"}"
        [[ -z "$existing" ]] && continue
        keychains+=("$existing")
        [[ "$existing" == "$keychain_path" ]] && found=true
    done < <("$security_bin" list-keychains -d user)

    if [[ "$found" == false ]]; then
        "$security_bin" list-keychains \
            -d user \
            -s "$keychain_path" "${keychains[@]}" ||
            fail "could not add the managed keychain to the user search list."
    fi
}

find_identity_hash() {
    "$security_bin" find-identity -v -p codesigning "$keychain_path" |
        awk -v expected="\"$identity_name\"" \
            'index($0, expected) { print $2; exit }'
}

if [[ ! -e "$keychain_path" && ! -e "$password_path" ]]; then
    creation_dir="$(mktemp -d "$signing_dir/.identity.XXXXXX")"
    keychain_password="$("$openssl_bin" rand -hex 32)"

    "$openssl_bin" req \
        -x509 \
        -newkey rsa:2048 \
        -sha256 \
        -nodes \
        -days 3650 \
        -subj "/CN=$identity_name/O=Soprano" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -keyout "$creation_dir/private-key.pem" \
        -out "$creation_dir/certificate.pem" \
        >/dev/null 2>&1 ||
        fail "could not generate the local code-signing certificate."

    "$openssl_bin" pkcs12 \
        -export \
        -inkey "$creation_dir/private-key.pem" \
        -in "$creation_dir/certificate.pem" \
        -name "$identity_name" \
        -passout "pass:$keychain_password" \
        -out "$creation_dir/identity.p12" ||
        fail "could not package the local code-signing identity."

    "$security_bin" create-keychain -p "$keychain_password" "$keychain_path" ||
        fail "could not create the managed keychain."
    created_keychain=true
    "$security_bin" set-keychain-settings -lut 21600 "$keychain_path" ||
        fail "could not configure the managed keychain."
    "$security_bin" unlock-keychain -p "$keychain_password" "$keychain_path" ||
        fail "could not unlock the managed keychain."
    "$security_bin" import \
        "$creation_dir/identity.p12" \
        -k "$keychain_path" \
        -f pkcs12 \
        -P "$keychain_password" \
        -T /usr/bin/codesign \
        >/dev/null ||
        fail "could not import the local code-signing identity."
    "$security_bin" add-trusted-cert \
        -r trustRoot \
        -p codeSign \
        -k "$keychain_path" \
        "$creation_dir/certificate.pem" ||
        fail "could not trust the local certificate for code signing."
    trusted_certificate=true
    "$security_bin" set-key-partition-list \
        -S "apple-tool:,apple:" \
        -s \
        -k "$keychain_password" \
        "$keychain_path" \
        >/dev/null ||
        fail "could not authorize codesign to use the local identity."

    printf '%s\n' "$keychain_password" > "$password_path"
    chmod 600 "$password_path" "$keychain_path"
    created_keychain=false
elif [[ ! -e "$keychain_path" || ! -e "$password_path" ]]; then
    fail "managed signing state is incomplete at $signing_dir; restore both files or remove the directory to recreate it."
fi

IFS= read -r keychain_password < "$password_path"
[[ -n "$keychain_password" ]] ||
    fail "managed keychain password is empty."

"$security_bin" unlock-keychain -p "$keychain_password" "$keychain_path" ||
    fail "could not unlock the managed keychain."
add_keychain_to_search_list

identity_hash="$(find_identity_hash)"
if [[ -z "$identity_hash" ]]; then
    repair_certificate="$(mktemp "$signing_dir/.certificate.XXXXXX.pem")"
    "$security_bin" find-certificate \
        -c "$identity_name" \
        -p "$keychain_path" > "$repair_certificate" ||
        fail "managed keychain does not contain $identity_name."
    "$security_bin" add-trusted-cert \
        -r trustRoot \
        -p codeSign \
        -k "$keychain_path" \
        "$repair_certificate" ||
        fail "could not restore code-signing trust for the managed identity."
    find "$repair_certificate" -delete
    identity_hash="$(find_identity_hash)"
fi

if [[ ! "$identity_hash" =~ ^[0-9A-F]{40}$ ]]; then
    fail "could not resolve a valid certificate-backed identity."
fi

printf '%s\t%s\n' "$identity_hash" "$keychain_path"
