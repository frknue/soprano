# Stable Local Code Signing Design

## Problem

Soprano's packaging script currently falls back to ad-hoc code signing. An
ad-hoc signature's designated requirement is its Code Directory hash, which
changes whenever the app binary or sealed resources change.

macOS attributes file access performed by processes inside Soprano's terminal
panes to Soprano. After a reinstall, TCC compares the updated app's code
requirement with the requirement stored alongside earlier Desktop, Documents,
Downloads, and Full Disk Access decisions. Because the hashes differ, macOS
treats the rebuilt app as a different identity and prompts again.

Local TCC logs confirmed this behavior by reporting that the old and new
Soprano CDHashes failed to match immediately before the folder-access prompts.

## Goal

Give locally packaged Soprano builds a stable, app-specific code identity so
macOS privacy decisions survive normal rebuilds and reinstalls.

The first build using the new identity can prompt once because it replaces the
current ad-hoc identity. Later builds signed with the same identity must satisfy
the same designated requirement.

## Non-goals

- Distributing or notarizing Soprano outside this Mac
- Bypassing or pre-authorizing macOS privacy controls
- Resetting or editing the user's TCC database
- Launching Soprano during automated verification

## Approaches Considered

### Persistent local self-signed identity

Create a dedicated code-signing identity once, store its private key in a
macOS keychain, and reuse it for every local package. The identity gives
Soprano a stable certificate-backed designated requirement without requiring
an Apple Developer account.

This is the selected approach because this Mac has no valid code-signing
identity installed, and it preserves identity across changing app payloads
without weakening the requirement to a bundle identifier alone.

### Apple Development or Developer ID identity

Signing with an Apple-issued identity also provides a stable requirement and
is appropriate when one is already configured. The package workflow will
continue to honor an explicitly supplied `SOPRANO_CODESIGN_IDENTITY`, but it
cannot require an Apple account for routine local installation.

### Explicit requirement with an ad-hoc signature

An explicit identifier-based designated requirement could remain textually
stable across ad-hoc builds. It is not selected because it provides no
certificate-backed ownership and ad-hoc signatures are known to interact
poorly with TCC identity tracking.

## Design

### Signing identity lifecycle

A small signing helper will resolve the identity before packaging:

1. If `SOPRANO_CODESIGN_IDENTITY` is non-empty, use it unchanged.
2. Otherwise, look for Soprano's dedicated local identity in its dedicated
   keychain.
3. If the identity does not exist, create the keychain and a self-signed
   code-signing certificate once.
4. Unlock only that keychain for the packaging operation and allow Apple's
   code-signing tool to use its private key non-interactively.
5. Return the identity and keychain path to the package script.

The keychain and the material needed to unlock it will live under the user's
Application Support directory, outside the repository and app bundle, with
user-only filesystem permissions. Reinstalling or replacing the app will not
replace the identity.

The certificate will have code-signing usage, a long but finite validity
period, and an app-specific name. Deleting the keychain, changing identities,
or allowing the certificate to expire will intentionally create a new app
identity and can cause macOS to prompt again.

### Packaging behavior

`scripts/package-app.sh` will sign the staged bundle with the resolved
certificate-backed identity. When using the managed identity, it will direct
`codesign` to the dedicated keychain. When using an explicitly supplied
identity, it will retain the existing caller-controlled behavior.

Packaging must not silently fall back to ad-hoc signing. Identity creation,
keychain access, signing, or verification failures will stop packaging with a
message that identifies the failed step and explains how to override the
identity.

The existing inside-out resource layout and strict signature verification
remain unchanged. Development and release bundles use distinct bundle
identifiers but may use the same signing certificate; macOS will still track
them as separate applications because their designated requirements include
their bundle identifiers.

### Security boundary

The private key remains in a dedicated macOS keychain and is authorized only
for the code-signing tool. The solution does not grant Soprano access to any
folder. It only allows macOS to recognize a rebuilt Soprano as the same app
when evaluating a permission the user already chose.

An explicitly supplied signing identity always takes precedence, so a future
Apple-issued identity can replace the local workflow deliberately.

## Verification

Automated verification will:

1. Exercise identity resolution and failure behavior without launching the
   app.
2. Sign two app payloads with different sealed content and confirm that both
   satisfy the same certificate-backed designated requirement.
3. Confirm the resulting signature is not ad-hoc and passes strict
   `codesign` verification.
4. Run `PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build`.
5. Run the repository's installation workflow as the final step.

The installed app will not be launched automatically. The user can confirm the
behavior on the next normal launch by accepting any one-time transition
prompts, reinstalling a later build, and accessing the same folders again.
