# Releasing Soprano

Pushing a version tag runs `.github/workflows/release.yml`. The workflow builds Soprano
and libghostty natively on arm64 and x86_64 runners, merges the executables into a
universal app, signs it with Developer ID and hardened runtime, notarizes the app and
disk image, publishes both the DMG and its SHA-256 checksum to GitHub Releases, then
updates `Casks/soprano.rb` in
[`frknue/homebrew-tap`](https://github.com/frknue/homebrew-tap).

## One-time repository setup

Direct distribution requires an
[Apple Developer Program](https://developer.apple.com/programs/) membership, a
**Developer ID Application** certificate exported as a password-protected PKCS #12
file, and an App Store Connect API key with notarization access.

Configure these GitHub Actions secrets in `frknue/soprano`:

| Secret | Value |
|---|---|
| `MACOS_DEVELOPER_ID_CERTIFICATE` | Base64-encoded Developer ID Application `.p12` |
| `MACOS_DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password used when exporting the `.p12` |
| `APPLE_NOTARY_API_KEY` | Base64-encoded App Store Connect `AuthKey_…p8` file |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect API issuer ID |
| `HOMEBREW_TAP_TOKEN` | Fine-grained GitHub token with Contents read/write access to `frknue/homebrew-tap` |

Encode the two files and send them directly to GitHub without putting their contents on
the command line:

```bash
base64 -i DeveloperIDApplication.p12 |
  gh secret set MACOS_DEVELOPER_ID_CERTIFICATE --repo frknue/soprano
base64 -i AuthKey_KEYID.p8 |
  gh secret set APPLE_NOTARY_API_KEY --repo frknue/soprano
```

Set the four text secrets with `gh secret set SECRET_NAME --repo frknue/soprano` and
enter the value at the prompt. Never commit certificates, private keys, passwords, or
tokens.

## Cut a release

1. Replace `## [Unreleased]` in `CHANGELOG.md` with
   `## [X.Y.Z] - YYYY-MM-DD`, then add a new empty `## [Unreleased]` above it.
2. Set both `CFBundleShortVersionString` and `CFBundleVersion` in
   `Support/Info.plist` to `X.Y.Z`.
3. Run:

   ```bash
   PATH="/opt/homebrew/opt/swift/bin:$PATH" swift build
   PATH="/opt/homebrew/opt/swift/bin:$PATH" swift test
   ./scripts/install.sh
   ```

4. Commit with `release: vX.Y.Z`, then push the commit and tag:

   ```bash
   git tag vX.Y.Z
   git push origin main vX.Y.Z
   ```

The workflow rejects a tag that disagrees with `Support/Info.plist`, a version without
a matching changelog heading, or a release missing any required secret. It publishes
only after both architectures build and test successfully and Apple accepts both
notarization submissions.
