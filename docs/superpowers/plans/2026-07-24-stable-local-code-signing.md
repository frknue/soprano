# Stable Local Code Signing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Package every local Soprano rebuild with a persistent certificate-backed identity so macOS privacy grants survive reinstalls.

**Architecture:** A focused shell helper owns the lifecycle of a Soprano-only self-signed code-signing identity in a dedicated keychain under Application Support. A second helper signs and verifies one app bundle, honoring `SOPRANO_CODESIGN_IDENTITY` before resolving the managed identity; the existing package script delegates its final signing step to that helper.

**Tech Stack:** Bash 3.2, macOS `security`, LibreSSL `openssl`, macOS `codesign`, Swift Package Manager

## Global Constraints

- Homebrew Swift is required; prefix direct Swift commands with `PATH="/opt/homebrew/opt/swift/bin:$PATH"`.
- Do not launch Soprano during automated verification.
- Use `./dev.sh --build-only` only when the development bundle needs testing.
- Do not reset or edit the user's TCC database.
- An explicitly supplied `SOPRANO_CODESIGN_IDENTITY` takes precedence.
- Packaging must never silently fall back to ad-hoc signing.
- Run `./install.sh` as the final step after successful verification.

## File Map

- Create `scripts/ensure-local-signing-identity.sh`: create, unlock, trust, locate, and return the managed identity and keychain path.
- Create `scripts/sign-app.sh`: select the explicit or managed identity, sign one app bundle, and verify it.
- Create `Tests/Signing/LocalCodeSigningTests.sh`: exercise the real keychain and code-signing lifecycle with disposable paths and app fixtures.
- Modify `scripts/package-app.sh`: delegate staged-bundle signing to `scripts/sign-app.sh`.

---

### Task 1: Managed local signing identity

**Files:**
- Create: `scripts/ensure-local-signing-identity.sh`
- Create: `Tests/Signing/LocalCodeSigningTests.sh`

**Interfaces:**
- Consumes: optional `SOPRANO_LOCAL_SIGNING_DIR`; defaults to `$HOME/Library/Application Support/Soprano/Signing`.
- Produces: one stdout record in the form `<40-character certificate SHA-1><TAB><absolute keychain path>`.
- Side effects: creates `SopranoLocalSigning.keychain-db` and `keychain-password` with user-only permissions; adds the keychain to the user search list; trusts only its certificate for the code-signing policy.

- [ ] **Step 1: Write the failing integration test**

Create `Tests/Signing/LocalCodeSigningTests.sh`:

```bash
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

echo "Local code signing identity is stable."
```

Make the test executable:

```bash
chmod +x Tests/Signing/LocalCodeSigningTests.sh
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
Tests/Signing/LocalCodeSigningTests.sh
```

Expected: non-zero exit because `scripts/ensure-local-signing-identity.sh` does not exist.

- [ ] **Step 3: Implement the identity helper**

Create `scripts/ensure-local-signing-identity.sh`:

```bash
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
```

Make the helper executable:

```bash
chmod +x scripts/ensure-local-signing-identity.sh
```

- [ ] **Step 4: Run the test to verify it passes**

Run:

```bash
Tests/Signing/LocalCodeSigningTests.sh
```

Expected:

```text
Local code signing identity is stable.
```

- [ ] **Step 5: Check shell syntax and commit**

Run:

```bash
bash -n scripts/ensure-local-signing-identity.sh
bash -n Tests/Signing/LocalCodeSigningTests.sh
git diff --check
git add scripts/ensure-local-signing-identity.sh Tests/Signing/LocalCodeSigningTests.sh
git commit -m "Add persistent local signing identity"
```

Expected: both syntax checks and `git diff --check` exit zero; commit succeeds.

---

### Task 2: App signing boundary and packaging integration

**Files:**
- Create: `scripts/sign-app.sh`
- Modify: `Tests/Signing/LocalCodeSigningTests.sh`
- Modify: `scripts/package-app.sh:89-90`

**Interfaces:**
- Consumes: `scripts/sign-app.sh <absolute-app-path>`, optional `SOPRANO_CODESIGN_IDENTITY`, and the Task 1 resolver output.
- Produces: a strictly verified signed app bundle or a non-zero exit with a signing-stage error.
- Package integration: `scripts/package-app.sh` invokes `scripts/sign-app.sh "$staged_app"` once after finalizing `Info.plist`.

- [ ] **Step 1: Extend the test with failing signing-boundary cases**

Insert before the final success message in `Tests/Signing/LocalCodeSigningTests.sh`:

```bash
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```bash
Tests/Signing/LocalCodeSigningTests.sh
```

Expected: non-zero exit because `scripts/sign-app.sh` does not exist.

- [ ] **Step 3: Implement the signing boundary**

Create `scripts/sign-app.sh`:

```bash
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
```

Make it executable:

```bash
chmod +x scripts/sign-app.sh
```

- [ ] **Step 4: Delegate packaging to the signing boundary**

Replace:

```bash
codesign --force --sign "${SOPRANO_CODESIGN_IDENTITY:--}" "$staged_app"
codesign --verify --deep --strict "$staged_app"
```

with:

```bash
"$script_dir/sign-app.sh" "$staged_app"
```

in `scripts/package-app.sh`.

- [ ] **Step 5: Run the focused test and syntax checks**

Run:

```bash
Tests/Signing/LocalCodeSigningTests.sh
bash -n scripts/sign-app.sh
bash -n scripts/package-app.sh
git diff --check
```

Expected: the test prints `Local code signing identity is stable.`; all other commands exit zero.

- [ ] **Step 6: Commit the packaging integration**

Run:

```bash
git add scripts/sign-app.sh scripts/package-app.sh Tests/Signing/LocalCodeSigningTests.sh
git commit -m "Sign packaged apps with stable identity"
```

Expected: commit succeeds.

---

### Task 3: Full verification and installation

**Files:**
- Verify: `scripts/ensure-local-signing-identity.sh`
- Verify: `scripts/sign-app.sh`
- Verify: `scripts/package-app.sh`
- Verify: `Tests/Signing/LocalCodeSigningTests.sh`
- Verify: `.build/debug/Soprano Dev.app`
- Install: `/Applications/Soprano.app`

**Interfaces:**
- Consumes: the repository build and install workflows.
- Produces: passing source and signing checks plus an installed certificate-signed Soprano update; does not launch either app.

- [ ] **Step 1: Run focused and repository tests**

Run:

```bash
Tests/Signing/LocalCodeSigningTests.sh
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift test
```

Expected: the signing test prints `Local code signing identity is stable.` and the Swift test suite passes.

- [ ] **Step 2: Run the required source build**

Run:

```bash
PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build
```

Expected: exit zero.

- [ ] **Step 3: Build the development bundle without launching it**

Run:

```bash
./dev.sh --build-only
```

Expected: prints `Created Soprano Dev at ...` and does not launch the GUI.

- [ ] **Step 4: Inspect the development bundle's stable signature**

Run:

```bash
codesign --verify --deep --strict ".build/debug/Soprano Dev.app"
codesign -dv --verbose=4 ".build/debug/Soprano Dev.app" 2>&1 |
    grep -E 'Authority=Soprano Local Development|TeamIdentifier|flags='
codesign -d -r- ".build/debug/Soprano Dev.app" 2>&1
```

Expected:

- strict verification exits zero;
- output contains `Authority=Soprano Local Development`;
- signature flags do not contain `adhoc`;
- the designated requirement contains `identifier "com.soprano.dev"` and a certificate hash.

- [ ] **Step 5: Review the final diff**

Run:

```bash
git status --short
git diff --check HEAD~2
git log -3 --oneline
```

Expected: only the planned files differ from the pre-task baseline, the diff check exits zero, and the two implementation commits follow the plan commit.

- [ ] **Step 6: Install the verified update as the final action**

Run:

```bash
./install.sh
```

Expected: release build and signing succeed, `/Applications/Soprano.app` is replaced, and the script states that the running app was not restarted.
