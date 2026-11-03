# Muninn

Native macOS 26 menu bar app for meeting capture. Built with Xcode from an XcodeGen project, Swift 5 language mode in every target, Swift Testing.

## Design records

Design specs live in `docs/superpowers/specs/` and implementation plans in `docs/superpowers/plans/`. Both are tracked with the code.

## Commands

Run all of these outside any agent sandbox: SwiftPM's nested `sandbox-exec`, the module cache
under `/var/folders` and the Xcode build service fail inside it. Prefix each with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` unless `xcode-select -p` already
points at Xcode.

- Core tests: `swift test --package-path Packages/MuninnCore`
- Platform tests: `swift test --package-path Packages/MuninnPlatform`
- Generate the project: `mise exec -- xcodegen generate` (`Muninn.xcodeproj` is not tracked)
- Build: `xcodebuild -project Muninn.xcodeproj -scheme Muninn -configuration Debug -derivedDataPath build -quiet build`
- Release build: the same with `-configuration Release`; `scripts/verify-app` accepts only
  Release builds.
- Without the signing certificate (ad hoc): add `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to
  either build.
- Install: `rm -rf /Applications/Muninn.app && ditto build/Build/Products/Debug/Muninn.app /Applications/Muninn.app`
  (`ditto` merges into an existing bundle and would keep stale files)
- Run: `open /Applications/Muninn.app`
- Script tests: `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'` (the
  changelog tool), `scripts/tests/test-release-dry-run` and
  `scripts/tests/test-verify-app <Release Muninn.app>`
- Verify a built app: `scripts/verify-app [--team <ID>] <Muninn.app> [<version>]`. It fails on a
  bad signature, entitlements other than exactly `com.apple.security.device.audio-input` (so on
  every Debug build), `LSUIElement` not true, a wrong bundle identifier or version, a missing or
  empty Microphone or Audio Capture usage description, a `muninn-spike` inside the bundle, or
  (with `--team`) a different `TeamIdentifier`.
- Release: `scripts/release [--dry-run] [--version <YYYYMMDD-HHMM>]`, on the maintainer's Mac only (it
  needs the signing certificate and pushes). Use `--dry-run` to check it; never run it for real
  unless the maintainer asks. `--version` resumes a failed release.
- Spike CLI (`docs/spike.md`): `swift build -c release --product muninn-spike --package-path Packages/MuninnPlatform`,
  then run `Packages/MuninnPlatform/.build/release/muninn-spike`.

## Releases and CI

- A user-visible change adds an entry to `CHANGELOG.md` under `## [Unreleased]`, under `Added`,
  `Changed`, `Fixed` or `Removed`. `scripts/release` moves it into the release.
- CI (`.github/workflows/ci.yml`) runs on `xcode-27` and signs ad hoc, because the certificate
  stays on the maintainer's Mac. It builds with `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`, as anyone
  without the certificate does.
- Distribution design: `docs/superpowers/specs/2026-11-03-muninn-distribution-design.md`.

## Rules an agent gets wrong

- `MuninnCore` stays dependency-free.
- In the app target, refer to the settings type as `MuninnCore.Settings`, because
  `SwiftUI.Settings` is a scene type.
- Swift 5 language mode in every target.
- Swift code uses `AppIdentity.bundleIdentifier` (`com.michaelrigart.muninn`) for the Keychain
  service, the log subsystem and the call detector's queue label, never the literal.
  `project.yml`, `scripts/verify-app` and the cask template carry the literal too;
  `AppIdentityTests` and the verifier fail if they drift.
- Builds are signed with the maintainer's Personal Team. Ad hoc builds (`CODE_SIGN_IDENTITY=-
  DEVELOPMENT_TEAM=`, which CI and contributors use) are a new app to macOS after every rebuild,
  so the Microphone and System Audio Recording permissions are asked again.
- When a permission is granted, macOS may record the signature of any copy of Muninn that Launch
  Services knows, not the one running. Before granting, delete every ad hoc copy, including
  `build/adhoc` and any ad hoc build under `build/`.
- Start the app with `open`: launched from a terminal, macOS gives the Microphone permission to
  the terminal.
- A bare `log` is a zsh builtin. Use `/usr/bin/log`; the subsystem is
  `com.michaelrigart.muninn`.
