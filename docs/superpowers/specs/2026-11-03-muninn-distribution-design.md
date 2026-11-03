# Muninn build and distribution — design

**Date:** 2026-11-03
**Status:** Implemented — [PR #2](https://github.com/michaelrigart/muninn/pull/2)
**Template:** Hulder's distribution design (`michaelrigart/hulder`,
`docs/superpowers/specs/2026-11-03-hulder-distribution-design.md`), which follows Linger's
(`michaelrigart/linger`, `docs/superpowers/specs/2026-11-01-linger-distribution-design.md`).
This document repeats what applies to Muninn, so it can be planned on its own, and says where
Muninn differs.
**Canonical for:** the shared build recipe of Muninn, Hulder and Linger. The Hulder and Linger
changes under "Companion changes" reference this document.

## Why

The owner has three macOS menu bar apps and wants them built, installed and released the
same way, without extra steps.

Hulder and Linger already share a recipe: XcodeGen, `xcodebuild`, install into `/Applications`,
Personal Team signing, a release script, a Homebrew cask and CI. Muninn's first build relied on
Command Line Tools workarounds instead:

- a hand-rolled bundling script;
- a `swift` wrapper that adds the Swift Testing macro plugin path;
- FluidAudio vendored without its binary target, because the binary download failed in the
  build environment;
- an `@ViewState` typealias in place of `@State`;
- a self-signed "Muninn Local" certificate made by hand in Keychain Access.

With the full Xcode, none of these workarounds is needed. Muninn has had no release, so there
are no installs, settings or Keychain items to migrate.

## Goals

- Muninn builds, installs and runs with the same commands as Hulder and Linger, with only the
  name changed.
- `brew install --cask michaelrigart/tap/muninn` installs Muninn, and `brew upgrade` upgrades it.
- One command on the maintainer's Mac cuts a release, as for Hulder and Linger.
- The Microphone, System Audio Recording and Local Network permissions, the Keychain items and
  Little Snitch rules survive rebuilds and upgrades.
- CI tests and builds every pull request and every push to `main`.
- The build steps of the three are identical, except for the app name and the differences
  listed under "Allowed differences". The build steps are: the shared `project.yml` settings,
  `mise.toml`, the command list in `AGENTS.md`, the README's "Build and install" block, and CI.

## Non-goals

- Developer ID signing and notarization (paid Developer Program, declined for Linger).
- Mac App Store submission, automatic updates inside the app, signing in CI, Intel Macs.
- Changing how Muninn records, transcribes or summarises. Phase 1 behaviour stays as built. A
  phase 1 defect found while checking this work goes to the owner as its own change; it is not
  fixed on this branch.
- Bringing Linger's release script, verifier and their tests up to Hulder's newer versions.
  Release tooling is not a build step, and Linger's works *(a design call: the owner asked
  for equal build steps without extra complication)*. Muninn copies Hulder's, the newest.
- Other files that differ between Hulder and Linger but aren't build steps, such as the README's
  section order or Hulder's missing LICENSE.
- The meeting-capture spec's other non-goals still hold: multiple users, a cloud backend, no
  automatic contact with clients. This design adds Homebrew distribution, which that spec
  didn't plan; it does not make Muninn a shared or multi-user product.

## Anti-goals

- The cask must not strip the quarantine attribute or otherwise bypass Gatekeeper.
- No certificate, private key or token in the repository or in CI.
- No machine-specific paths or settings in the repository. It is public.
- The release script pushes to `main` only its own release commit, plus the tag. Only the maintainer
  runs it.
- No release contains `muninn-spike`. It stays a developer tool built from source.
- Uninstalling never deletes the user's meetings (see the cask).

## Decisions (the owner's)

- **Same recipe as Hulder and Linger** (2026-11-03), and not more complicated than theirs.
- **Bundle identifier `com.michaelrigart.muninn`** (2026-11-03), matching the other two. It
  replaces `be.netronix.muninn` everywhere, the Keychain service and log subsystem included.
- **The full release setup now** (2026-11-03): changelog, release script, verifier, Homebrew
  cask and CI, as Hulder and Linger have.
- **The designer's Muninn logo set, and a permanent Dock icon alongside the menu bar icon**
  (2026-11-03): the logo set is the app icon and the menu bar mark, integrated as Hulder and
  Linger do it. Muninn is a regular app: it has a Dock icon and appears in Command-Tab, and it
  keeps its menu bar icon. Windows open in front of other apps' windows.

## How it works

### Repository layout

Muninn takes Hulder's shape:

| Path | Holds |
|---|---|
| `project.yml` | the XcodeGen project; `Muninn.xcodeproj` is generated and not tracked |
| `mise.toml` | the pinned XcodeGen (and the tools the other two pin) |
| `Muninn/` | the app target: today's `Sources/MuninnApp`, its entitlements and Info.plist |
| `Packages/MuninnCore` | unchanged: the dependency-free core |
| `Packages/MuninnPlatform` | today's root package: the `MuninnAudio`, `MuninnSpeech` and `MuninnSystem` libraries, the `muninn-spike` executable and their tests |
| `scripts/` | `release`, `verify-app`, `changelog.py`, `muninn.rb.template`, `tests/` |
| `CHANGELOG.md`, `README.md` | as in the other two |

- The root `Package.swift`, `Package.resolved` and `Sources/`, `Tests/` move into
  `Packages/MuninnPlatform`. Module names don't change, so no `import` changes.
- FluidAudio becomes an ordinary dependency by URL, pinned to `0.17.7`, beside WhisperKit
  `1.1.1` and swift-argument-parser. `scripts/vendor-fluidaudio.sh` and `Vendor/` go.
- `scripts/bundle-app.sh`, `scripts/swiftpm.sh`, `scripts/Info.plist` and
  `scripts/Muninn.entitlements` go; their content moves into `project.yml` and `Muninn/`.
- `Sources/MuninnApp/Views/ViewState.swift` goes, and every `@ViewState` becomes `@State`.
- **First check for the builder:** the upstream FluidAudio package resolves and builds,
  including its binary `NemoTextProcessing` target, with Xcode 27.2 and
  with the Xcode CI selects. If it doesn't, stop and bring it to the owner rather than keeping
  the vendoring.

### The app target

- Deployment target macOS 26.0, Apple silicon only (`ARCHS: arm64` in `project.yml`, as Linger).
- Swift 5 language mode in the app target and in both packages, as today. Moving to Swift 6 is
  out of scope.
- No App Sandbox. Hardened Runtime on. Entitlements: exactly
  `com.apple.security.device.audio-input`, which Hardened Runtime needs for the microphone.
- Info.plist keys stay as today, from `project.yml`, except that `LSUIElement` is gone (Muninn
  is a regular app): `LSMultipleInstancesProhibited`, the Microphone, Audio Capture and Local Network usage
  descriptions, and `NSAllowsLocalNetworking`. The version keys become
  `$(MARKETING_VERSION)` and `$(CURRENT_PROJECT_VERSION)`; builds outside the release script
  are `dev`, build `0`.
- `CallDetector.ownBundleID` (Muninn's own process, left out of call detection) must keep
  matching the bundle identifier.

### Signing

As Hulder and Linger:

- `DEVELOPMENT_TEAM` is the maintainer's Personal Team, `CODE_SIGN_STYLE: Manual`,
  `CODE_SIGN_IDENTITY: Apple Development`, for Debug and Release, with no provisioning profile.
  The Team ID is public: it is embedded in every signed build.
- Release builds carry no `get-task-allow` (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO`).
- Anyone without the certificate (CI, contributors) adds `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`
  to `xcodebuild` and gets an ad hoc build, which macOS treats as a new app on every rebuild.
- Scripts pick the identity by Team ID, never by the bare name `Apple Development`.
- macOS ties the privacy permissions, Keychain item access and (in Little Snitch) firewall rules
  to the designated requirement. With the team certificate it names the certificate, not one
  build, so they are expected to survive rebuilds. Acceptance measures it for Muninn.
- The certificate's subject, the Apple ID's email, is embedded in every public release. The owner
  accepted this for Linger (2026-11-01); the same certificate signs Muninn.
- The "Muninn Local" certificate is never made. `docs/setup.md` loses its section.

### Commands

The same list as Hulder and Linger, in this order, in `AGENTS.md` and (the user-facing ones) in
the README. All are prefixed with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` unless `xcode-select -p` already
points at Xcode:

```sh
swift test --package-path Packages/MuninnCore
swift test --package-path Packages/MuninnPlatform
mise exec -- xcodegen generate
xcodebuild -project Muninn.xcodeproj -scheme Muninn -configuration Debug -derivedDataPath build -quiet build
rm -rf /Applications/Muninn.app && ditto build/Build/Products/Debug/Muninn.app /Applications/Muninn.app
open /Applications/Muninn.app
```

- The Release build is the same `xcodebuild` line with `-configuration Release`; the README's
  build-from-source block uses Release with the ad hoc override, as the others' do.
- The spike CLI: `swift build -c release --product muninn-spike --package-path Packages/MuninnPlatform`,
  then `Packages/MuninnPlatform/.build/release/muninn-spike`. `docs/spike.md` follows.
- Start Muninn with `open` or Finder. Started from a terminal, macOS gives the Microphone
  permission to the terminal.
- Muninn may run from anywhere; the cask installs it into `/Applications` (see Allowed
  differences).

### Verifying a built app

`scripts/verify-app [--team <ID>] <Muninn.app> [<version>]`, used by CI and the release script.
It fails unless:

- the signature verifies (`codesign --verify --strict`);
- the entitlements are exactly `com.apple.security.device.audio-input` = true, so a Debug build
  (which carries `get-task-allow`) fails, as Linger's does;
- there is no `LSUIElement` key (Muninn is a regular app) and the bundle identifier is
  `com.michaelrigart.muninn`;
- the Microphone and Audio Capture usage descriptions are present (without them macOS ends the
  app at the first recording);
- the bundle contains no `muninn-spike`;
- with `--team`, the `TeamIdentifier` matches; with a version, `CFBundleShortVersionString`
  equals it and `CFBundleVersion` equals its digits.

Muninn's verifier is Hulder's, with the probe check replaced by the `muninn-spike` check, and the
entitlement and usage-description checks adapted. `scripts/tests/test-verify-app` checks that it
rejects tampered copies, as the others' do.

### CI

`.github/workflows/ci.yml`, the same file as Hulder's with the name changed:

- on pull requests and pushes to `main`, `permissions: contents: read`, a concurrency group
  that cancels superseded runs, actions pinned to full commit SHAs;
- `runs-on: xcode-27`, selecting the same Xcode as Hulder's CI: the newest released Xcode 27 on
  the image, 27.1 today *(a design call: the three CIs stay equal, and the maintainer builds
  all three with Xcode 27)*. Hulder's rule applies to all three together: if one of them doesn't
  build or pass its tests with 27.1, all three CIs select the 27.2 release candidate, and the
  workflow says why;
- steps: the changelog tool's tests, both package suites, `xcodegen generate`, a Release build
  signed ad hoc, `scripts/verify-app`, then the verifier's test.

The runner has no microphone, no permissions and no network models. A test that needs any of
them is a defect in the test: fix it so it doesn't depend on the machine, rather than skipping
it in CI.

### Versions, changelog and releasing

Exactly as Hulder's design, with the name changed:

- the version is `date +%Y%m%d-%H%M` at the start of the release, with no `v`; it is the tag,
  the release title, the asset name `Muninn-<version>.zip` and the cask's `version`;
- `CHANGELOG.md` in Keep a Changelog format, with the same preamble and link definitions. The
  first `## [Unreleased]` records phase 1 (meeting capture) and this work;
- `scripts/release [--dry-run] [--version <YYYYMMDD-HHMM>]` and `scripts/changelog.py` come over
  from Hulder, renamed, with their tests, including resuming and recovering an unpushed release
  commit.

### Homebrew cask

`Casks/muninn.rb` in `michaelrigart/homebrew-tap`, from `scripts/muninn.rb.template`:

- `version`, `sha256`, `url` on the release asset, `name`, a generic `desc`, the repository as
  `homepage`, `livecheck` as the others;
- `depends_on arch: :arm64` and `depends_on macos: :tahoe`;
- `app "Muninn.app"`;
- `uninstall quit: "com.michaelrigart.muninn"`;
- `zap` removes `~/.config/muninn` (settings) only *(a design call)*. It never removes
  `~/.local/share/muninn` (the user's recordings, transcripts and summaries), and it leaves the
  shared model caches (`~/Library/Application Support/FluidAudio`, `~/Documents/huggingface`)
  alone, since other apps can use them;
- `caveats`:
  - "Open Anyway" in System Settings › Privacy & Security, because the app isn't notarized;
  - macOS asks for the Microphone at the first recording and for System Audio Recording at the
    first call recording;
  - the speech models download from Hugging Face the first time they are used;
  - the rest of the setup (engines, Microsoft accounts, Obsidian) is in `docs/setup.md`.

### Documentation

- **README** (Muninn has none; the repository is public): what Muninn does, Requirements
  (macOS 26, Apple silicon), Install (Homebrew, first-run steps), Build and install, Tests,
  Releasing, Limitations (from `docs/setup.md`'s Known limitations), License.
- **AGENTS.md** in the others' shape: the command list above, Releases and CI, and the rules an
  agent gets wrong. Rules that go: `@ViewState`, `scripts/swiftpm.sh`, `Vendor/`. Rules that
  stay: `MuninnCore` stays dependency-free, `MuninnCore.Settings` in the app target, Swift 5
  mode. New: `/usr/bin/log` with subsystem `com.michaelrigart.muninn`; start the app with
  `open`.
- **`docs/setup.md`:** steps 1 and 2 become a pointer to the README's Install and Build and
  install; the firewall table, permissions and data tables use the new identifier and the
  `/Applications` path.
- **`docs/spike.md`:** the build step and the Keychain service follow.
- The meeting-capture spec and plan stay as they are: they are completed records, and their
  point-in-time facts (`be.netronix.muninn`, `scripts/bundle-app.sh`) are not rewritten.

## Companion changes in Hulder and Linger

Each is a small change on its own branch with its own pull request, referencing this document.
They make the build steps identical where nothing justifies a difference:

- **`ARCHS: arm64` in `project.yml`** in Hulder too (Linger has it), and dropped from every
  command line: both READMEs, Hulder's CI, both release scripts.
- **README "Build and install":** the same block in all three, always `rm -rf` before `ditto`
  (Linger's first install copies over without it).
- **AGENTS.md command list:** the same entries in the same order in all three: Linger gains
  Install and Run, Hulder gains the Release build and the ad hoc override, and all three use
  Linger's `DEVELOPER_DIR` wording ("unless `xcode-select -p` already points at Xcode").
- **`mise.toml`:** the same tools and versions in all three (Linger pins `actionlint`, Hulder
  doesn't).
- **CI:** Linger moves from `macos-26` with Xcode 26.6 to `xcode-27` with the same Xcode as
  Hulder, under the rule in Muninn's CI section *(a design call, as for Muninn's CI)*.
  If that rule moves the three to the 27.2 release candidate, Hulder's workflow changes too.

## Allowed differences

Apart from the name, the build steps of the three read the same. These differences stay, each
for its reason:

| | Muninn | Hulder | Linger |
|---|---|---|---|
| Minimum macOS | 26 | 27 (its v1 spec) | 26 |
| Packages | `MuninnCore`, `MuninnPlatform` | `HulderCore`, `HulderPlatform27` | `LingerCore` |
| Entitlements | microphone | none | App Sandbox |
| Swift language mode | 5 | 6, strict concurrency | 6 |
| Install location | anywhere (`/Applications` by default) | `/Applications` only (status item attribution) | anywhere |
| Debug-only probe | no (the spike CLI is separate) | yes | yes |
| Extra tool | `muninn-spike`, `design/render` | `design/render` | `design/render` |
| Dock icon | always | never | never |

## Constraints

- Pushes from the maintainer's Mac use the maintainer's existing git and `gh` credentials.
- The Personal Team certificate and Apple's WWDR G3 intermediate are already in the maintainer's login
  keychain for Linger and Hulder.

## Delivery

- **Branch:** `feat/distribution` in Muninn, draft pull request to `main`.
- **Companion branches:** one per repository for the Hulder and Linger changes.
- Open all three pull requests before merging any, and merge Muninn's first, since it holds this
  document.

## Acceptance

1. CI passes on Muninn's pull request: both suites, the Release build and the verifier.
2. **The owner checks, on a team-signed Debug build installed into `/Applications`:** "Record a
   conversation…" triggers the Microphone prompt, the Claude key saves, and a Claude summary
   gets Little Snitch's prompt for `api.anthropic.com`, which the owner allows. After quitting, a rebuild
   and reinstall, and relaunching with `open`, a new recording doesn't ask for the Microphone
   again, the key is read without a Keychain prompt, and a Claude summary raises no new Little
   Snitch prompt. This checks the signing, not phase 1: if the recording itself fails, that is
   a phase 1 defect (see Non-goals).
3. **Checked when first used, the same way** (grant, then quit, rebuild, reinstall, relaunch):
   System Audio Recording at the first call recording, and Local Network at the first contact
   with the Network Mac. The owner tests the Network Mac later, so these may land after the merge.
4. `scripts/release --dry-run` builds, verifies and packages an Apple silicon zip, and prints
   the changelog section it would commit.
5. The README's build-from-source block, run as written with the ad hoc override, produces an
   app that launches.
6. **After merging,** the first real release creates the tag, the GitHub release with the zip,
   and the cask. Then `brew install --cask michaelrigart/tap/muninn` installs Muninn, and after
   "Open Anyway" it launches and records.
7. **At the second release,** after `brew upgrade`, Muninn asks again for none of what was
   granted before: the Microphone, the Keychain item, the Little Snitch rule, and System Audio
   Recording and Local Network if they were granted by then. Separately, whether the upgrade
   launches without "Open Anyway" is recorded; if it doesn't, the caveats and the README say so.
8. Hulder's and Linger's CI pass on their companion pull requests.

**A failed persistence check** (in 2, 3 or 7, a permission, the Keychain item or a Little Snitch
rule asked for again) fails acceptance and goes to the owner, because it means a goal can't be met
as designed. Documentation never stands in for it. Only the "Open Anyway" outcome may be
documented instead.

## Left to the builder

- `project.yml` details within the settings above, and which Info.plist keys come from it;
- how the three moves are split into commits (moves first, so history follows the files);
- the scripts' language (shell is fine, as in the others);
- the pinned action versions and the exact Xcode on the runner, within the rule under CI;
- the README and cask wording.
