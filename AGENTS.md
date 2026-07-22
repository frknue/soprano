# Soprano repository instructions

## Build and verification

- Homebrew Swift is required. Prefix direct Swift commands with
  `PATH="/opt/homebrew/opt/swift/bin:$PATH"`.
- Verify source changes with `swift build`. Do not launch the Soprano GUI during
  automated verification; launching terminal panes can trigger macOS permission
  prompts through the user's shell startup files.
- `./dev.sh` builds, packages, and launches the isolated `Soprano Dev.app` with
  bundle identifier `com.soprano.dev`. It is for user-driven GUI testing. Agents
  must not run it unless the user explicitly requests a launch. Use
  `./dev.sh --build-only` only when the development bundle itself needs testing.

## Installing completed changes

- After completing and successfully verifying a task that changes the app or its
  packaging, run `./install.sh` as the final step unless the user asks not to.
- The user has explicitly authorized this installation. The script builds the
  release configuration and replaces `/Applications/Soprano.app`, but does not
  terminate or launch Soprano. The running instance remains untouched and the
  installed update is used on the next launch.
- Do not use `sudo` if installation fails. Report the permission problem instead.
- Documentation-only or read-only tasks do not require installation.
