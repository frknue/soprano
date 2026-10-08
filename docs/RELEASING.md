# Releasing Soprano

Pushing a version tag runs `.github/workflows/release.yml`. The workflow builds Soprano
and libghostty natively on arm64 and x86_64 runners, merges the executables into a
universal app, applies an ad-hoc code signature, and publishes these GitHub Release
assets:

- `Soprano-X.Y.Z.dmg`
- `Soprano-X.Y.Z.dmg.sha256`
- `soprano.rb`

The workflow requires no Apple credentials or repository secrets. The updater in
[`frknue/homebrew-tap`](https://github.com/frknue/homebrew-tap) imports `soprano.rb`
from the latest release, making it available as:

```bash
brew install --cask frknue/tap/soprano
```

The packaging job installs Node.js 24 and builds the editable `web/` source with
`npm ci` and `npm run build` through `scripts/build-web.sh`. The app ships the Next.js
standalone JavaScript server, assets, local launcher, and dependency closure; it does
not ship Node.js or omp. `omp web` therefore requires Node.js >= 22.19.0 and the
separately installed omp CLI on the user's machine. Image optimization is disabled
and native-only web dependencies are excluded from tracing so the same packaged
server can run with either architecture's Node.js.
Packaging merges traced runtime directories with the editable source without nesting
duplicate directories, and excludes web tests and Windows executables. Root ignore
rules `/lib/` and `/build/` apply only to Soprano's generated artifacts; `web/lib/`
is not ignored.

## Gatekeeper limitation

The release is ad-hoc signed but not notarized because Soprano does not have a paid
Apple Developer membership. This preserves code-signature integrity but does not give
Gatekeeper an Apple-trusted publisher identity. On first launch, users may need to open
**System Settings → Privacy & Security**, scroll to **Security**, click **Open Anyway**
for Soprano, and confirm **Open**.

Never suppress quarantine in the cask or tell users to disable Gatekeeper globally.
Keep this limitation visible in the README, GitHub release notes, and cask caveat.

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

The release workflow rejects a tag that disagrees with `Support/Info.plist` or lacks a
matching changelog heading. It publishes only after both architectures build, all tests
pass, the merged executable contains arm64 and x86_64, the app and DMG carry valid
ad-hoc signatures, and Gatekeeper rejects the image as expected for an unnotarized
release.
