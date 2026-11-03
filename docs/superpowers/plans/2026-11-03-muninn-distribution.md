# Muninn build and distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Muninn builds, installs, verifies and releases with the same recipe as Hulder and Linger, and the three repositories' build steps become identical apart from the name.

**Architecture:** Muninn moves from a Command Line Tools SwiftPM build to XcodeGen + `xcodebuild` with Personal Team signing. The app target moves to `Muninn/`, the libraries to `Packages/MuninnPlatform`. The release tooling (verifier, changelog, release script, cask, CI) is ported from Hulder, renamed. Hulder and Linger get small alignment changes on their own branches.

**Tech Stack:** Swift (5 language mode), SwiftPM, XcodeGen 2.46.0 via mise, Xcode 27.2, bash, Python 3 (`/usr/bin/python3`), GitHub Actions, Homebrew casks.

**Spec:** `docs/superpowers/specs/2026-11-03-muninn-distribution-design.md` (Approved). Templates it copies: `/Users/michael/Code/hulder` (`scripts/`, `.github/workflows/ci.yml`, `project.yml`, `README.md`, `AGENTS.md`) and `/Users/michael/Code/linger`.

## Global Constraints

- Every `swift`, `xcodebuild` and script command runs **outside the agent sandbox**, prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (written `$X` below). `xcode-select -p` points at the Command Line Tools on this Mac.
- Muninn's bundle identifier: `com.michaelrigart.muninn`. Personal Team: `CX4MWR5579`. Identity `Apple Development`, manual signing, no provisioning profile.
- Deployment target macOS `26.0`; Apple silicon only; Swift 5 language mode in the app target and both packages.
- Muninn's entitlements: exactly `com.apple.security.device.audio-input` = true. No App Sandbox. Hardened Runtime on.
- Versions: `MARKETING_VERSION` `dev` and `CURRENT_PROJECT_VERSION` `0` outside releases; releases are `date +%Y%m%d-%H%M`, build number = its digits.
- FluidAudio by URL, `exact: "0.17.7"`; WhisperKit `exact: "1.1.1"`; swift-argument-parser `from: "1.5.0"`.
- CI: `runs-on: xcode-27`, `sudo xcode-select -s /Applications/Xcode_27.1.app`, `timeout-minutes: 30`, actions pinned as in Hulder's `ci.yml` (`actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1`, `jdx/mise-action@6612f0ef07ed2a736cd1e00a94a065522dd41195 # v5.2.5`).
- `mise.toml` in all three repositories:
  ```toml
  [tools]
  actionlint = "1.7.12"
  xcodegen = "2.46.0"
  ```
- The meeting-capture spec and plan are completed records: never edit them. Nothing under `Vendor/` is edited.
- Implementers do not commit. The controller commits each task with the message given.
- The repositories are public: no machine paths, no personal data beyond the Team ID, no secrets.

### The shared recipe (used by Tasks 6, 7 and 8)

**Shared `project.yml` target settings**, identical in all three (`<x>` the lowercase name):

```yaml
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.michaelrigart.<x>
        ARCHS: arm64
        CODE_SIGN_IDENTITY: "Apple Development"
        CODE_SIGN_STYLE: Manual
        CURRENT_PROJECT_VERSION: "0"
        DEVELOPMENT_TEAM: CX4MWR5579
        ENABLE_DEBUG_DYLIB: NO
        ENABLE_HARDENED_RUNTIME: YES
        MARKETING_VERSION: dev
        OTHER_CODE_SIGN_FLAGS: "--options=runtime"
      configs:
        Release:
          CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO
```

App-specific settings (Swift version, concurrency, app icon) follow the spec's "Allowed differences".

**`AGENTS.md` "Commands" section**, the same entries in this order in all three (`<X>` the app name; leave out lines that don't apply, marked):

1. Opening paragraph: "Run all of these outside any agent sandbox: SwiftPM's nested `sandbox-exec`, the module cache under `/var/folders` and the Xcode build service fail inside it. Prefix each with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` unless `xcode-select -p` already points at Xcode." (Linger may keep its extra clause about the app's own event and log access.)
2. Core tests: `swift test --package-path Packages/<X>Core`
3. Platform tests: `swift test --package-path Packages/<X>Platform…` (Hulder, Muninn)
4. Generate the project: `mise exec -- xcodegen generate` (`<X>.xcodeproj` is not tracked)
5. Build: `xcodebuild -project <X>.xcodeproj -scheme <X> -configuration Debug -derivedDataPath build -quiet build`
6. Release build: the same with `-configuration Release`; `scripts/verify-app` accepts only Release builds.
7. Without the signing certificate (ad hoc): add `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to either build.
8. Install: `rm -rf /Applications/<X>.app && ditto build/Build/Products/Debug/<X>.app /Applications/<X>.app` (`ditto` merges into an existing bundle and would keep stale files)
9. Run: `open /Applications/<X>.app`
10. Script tests: `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'`, `scripts/tests/test-release-dry-run`, `scripts/tests/test-verify-app <args>`
11. Verify a built app: `scripts/verify-app [--team <ID>] <X.app> [<version>]` and what it fails on.
12. Release: `scripts/release [--dry-run] [--version <YYYYMMDD-HHMM>]`, Michael's Mac only, never run for real by an agent unless Michael asks.
13. App-specific tools after that (Hulder and Linger: `design/render`, the probe; Muninn: the spike CLI).

**README "Build and install" block**, identical in all three apart from the name, with app-specific paragraphs only after it:

````markdown
## Build and install

To build it yourself, you need the full Xcode. If `xcode-select -p` points at the Command
Line Tools, prefix the `xcodebuild` and `swift` commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

The project is set up to sign with the maintainer's certificate, which you won't have.
Add `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to `xcodebuild` to sign ad hoc instead.

```sh
mise trust mise.toml
mise exec -- xcodegen generate
xcodebuild -project <X>.xcodeproj -scheme <X> -configuration Release -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -quiet build
rm -rf /Applications/<X>.app
ditto build/Build/Products/Release/<X>.app /Applications/<X>.app
open /Applications/<X>.app
```

Remove the old app first: `ditto` merges into an existing bundle and would keep stale
files. Quit <X> before you replace it, so that `open` starts the new build instead of
bringing the old one forward.
````

**CI steps**, in this order: checkout, mise action, select Xcode, the changelog tool's tests, each package's `swift test`, `mise exec -- xcodegen generate`, the Release build signed ad hoc, `scripts/verify-app` on it, the verifier's test (Hulder adds its Debug build before the verifier's test, for its probe case).

## Review Focus

1. **A contributor's ad hoc Debug build must launch.** Hardened Runtime with Xcode's debug dylib stops an ad hoc Debug app from launching (Hulder `5e8856d`). `ENABLE_DEBUG_DYLIB: NO` prevents it. Pinned in Task 1, Step 7.
2. **A leftover ad hoc copy can take Michael's permission grants.** macOS may record the signature of any copy Launch Services knows (Linger's AGENTS.md). The README-block install and the old `build/Muninn.app` are ad hoc. Pinned in Task 6, Step 6: every ad hoc copy is gone before Michael grants anything.
3. **`brew uninstall --zap` must never delete the user's meetings.** Pinned in Task 4, Step 4: the release test asserts the rendered cask's `zap` list.
4. **A release without a usage description dies at the first recording.** Pinned in Task 3, Step 1: verifier cases for both descriptions.
5. **The old identifier left anywhere makes logs, Keychain items or call detection disagree with the bundle.** Pinned in Task 2, Step 6 and Task 6, Step 5: no `be.netronix` outside the completed records.

---

### Task 1: Build Muninn with XcodeGen and team signing

**Depends on:** none

**Files:**
- Move (`git mv`): `Sources/MuninnAudio`, `Sources/MuninnSpeech`, `Sources/MuninnSystem`, `Sources/MuninnSpike` → `Packages/MuninnPlatform/Sources/`; `Tests/MuninnAudioTests`, `Tests/MuninnSpeechTests`, `Tests/MuninnSystemTests` → `Packages/MuninnPlatform/Tests/`; `Package.swift` → `Packages/MuninnPlatform/Package.swift`; `Package.resolved` → `Packages/MuninnPlatform/Package.resolved`
- Move: `Sources/MuninnApp` → `Muninn` (the whole folder, `Views/` included); `scripts/Info.plist` → `Muninn/Info.plist`; `scripts/Muninn.entitlements` → `Muninn/Muninn.entitlements`
- Create: `project.yml`, `mise.toml`
- Modify: `Packages/MuninnPlatform/Package.swift`, `.gitignore`
- Delete: `scripts/bundle-app.sh`, `scripts/swiftpm.sh`, `scripts/vendor-fluidaudio.sh`

**Interfaces:**
- Produces: `Muninn.xcodeproj` (generated), scheme `Muninn`, products `build/Build/Products/{Debug,Release}/Muninn.app`; package `Packages/MuninnPlatform` with library products `MuninnAudio`, `MuninnSpeech`, `MuninnSystem` and executable product `muninn-spike`.

- [ ] **Step 1: Make the moves** with `git mv` (moves first, so history follows the files).

- [ ] **Step 2: Rewrite `Packages/MuninnPlatform/Package.swift`**

Keep the `swift5` settings and every remaining target as today. Remove the `Muninn` product and the `MuninnApp` target. Dependencies:

```swift
dependencies: [
    .package(path: "../MuninnCore"),
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
],
```

Package name `MuninnPlatform`. The executable product stays named `muninn-spike`.

- [ ] **Step 3: First check — FluidAudio upstream resolves and builds**

Run: `$X swift build --package-path Packages/MuninnPlatform`
Expected: builds, including FluidAudio's binary `NemoTextProcessing` target.
If FluidAudio fails to resolve or build (a binary artifact, `unsafeFlags`, its `Package@swift-6.2.swift`), **stop and report it with the error**. Do not restore the vendoring.

- [ ] **Step 4: Run both package suites**

Run: `$X swift test --package-path Packages/MuninnCore` and `$X swift test --package-path Packages/MuninnPlatform`
Expected: all pass. Report passed/total for each.

- [ ] **Step 5: Write `project.yml`, `mise.toml` and `.gitignore`**

`project.yml` follows Hulder's shape:
- `name: Muninn`, `bundleIdPrefix: com.michaelrigart`, `deploymentTarget: macOS: "26.0"`.
- `packages:` `MuninnCore` (`path: Packages/MuninnCore`) and `MuninnPlatform` (`path: Packages/MuninnPlatform`).
- Target `Muninn`, `type: application`, `platform: macOS`, `sources: [Muninn]`. Dependencies: `package: MuninnCore`, and `package: MuninnPlatform` with `products: [MuninnAudio, MuninnSpeech, MuninnSystem]`.
- `info: path: Muninn/Info.plist`, with `properties` carrying every key of today's `scripts/Info.plist`, except `CFBundleIdentifier`, `CFBundleExecutable`, `CFBundleName` and `CFBundlePackageType`, which Xcode supplies. Also `CFBundleDisplayName: Muninn`, `CFBundleShortVersionString: $(MARKETING_VERSION)` and `CFBundleVersion: $(CURRENT_PROJECT_VERSION)`. `LSMinimumSystemVersion` comes from the deployment target.
- `entitlements: path: Muninn/Muninn.entitlements`, `properties: {com.apple.security.device.audio-input: true}`.
- `settings:` the shared settings block from "The shared recipe", with `<x>` = `muninn`, plus `SWIFT_VERSION: "5.0"`. No asset catalog and no `ASSETCATALOG_COMPILER_APPICON_NAME`.

`mise.toml`: exactly the block in Global Constraints.

`.gitignore`: keep `.DS_Store`, `.build/`, `.swiftpm/`, `.superpowers/`, `docs/superpowers/runs/`, `.claude/.cc-writes/`. Replace `/build/` with `build/`, add `Muninn.xcodeproj/`, and drop `Vendor/`.

- [ ] **Step 6: Generate the project and build**

Run: `mise trust mise.toml`, then `$X mise exec -- xcodegen generate`, then:
- `$X xcodebuild -project Muninn.xcodeproj -scheme Muninn -configuration Debug -derivedDataPath build -quiet build`
- the same with `-configuration Release`
- the Release build again with `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`, into `-derivedDataPath build/adhoc`

Expected: all three succeed. If Debug fails on the `MuninnApp`→`Muninn` module rename, fix the references in `Muninn/`.

- [ ] **Step 7: Check the products**

On the team-signed `build/Build/Products/Release/Muninn.app`:
- `codesign -dvv` shows `TeamIdentifier=CX4MWR5579` and the `runtime` flag;
- `codesign -d --entitlements - --xml` shows only `com.apple.security.device.audio-input`;
- `plutil -p Contents/Info.plist` shows `CFBundleIdentifier` `com.michaelrigart.muninn`, `CFBundleShortVersionString` `dev`, `CFBundleVersion` `0`, `LSMinimumSystemVersion` `26.0`, `LSUIElement` 1, and the three usage descriptions;
- `lipo -archs Contents/MacOS/Muninn` prints `arm64`.

Review Focus 1: build Debug ad hoc into `-derivedDataPath build/adhoc`, then run `open build/adhoc/Build/Products/Debug/Muninn.app`. `pgrep -x Muninn` finds it within 5 s. Then `pkill -x Muninn` and `rm -rf build/adhoc`, which also deletes this ad hoc copy (Review Focus 2).

- [ ] **Step 8: Check the spike CLI builds**

Run: `$X swift build -c release --product muninn-spike --package-path Packages/MuninnPlatform && Packages/MuninnPlatform/.build/release/muninn-spike --help`
Expected: usage text.

- [ ] **Step 9: Delete the three scripts**, then repeat Steps 4 and 6 (Debug only). Expected: unchanged.

- [ ] **Step 10: Commit** — `Build Muninn with XcodeGen and team signing`

---

### Task 2: One bundle identifier, and plain `@State`

**Depends on:** Task 1

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/AppIdentity.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/AppIdentityTests.swift`
- Modify: every file with `be.netronix.muninn` under `Muninn/` and `Packages/` (14 logger subsystems, `CallDetector`, `KeychainStore`, `MeetingStore`)
- Modify: the 7 files under `Muninn/Views/` that use `@ViewState`
- Delete: `Muninn/Views/ViewState.swift`

**Interfaces:**
- Produces: `public enum AppIdentity { public static let bundleIdentifier: String }` in `MuninnCore`, with the value `"com.michaelrigart.muninn"`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MuninnCore

@Test func bundleIdentifierIsTheAppsIdentifier() {
    #expect(AppIdentity.bundleIdentifier == "com.michaelrigart.muninn")
}
```

It pins the one value that the Keychain service, the log subsystem and call detection all derive from. It catches a rename that misses one of them.

- [ ] **Step 2: Run it to see it fail**

Run: `$X swift test --package-path Packages/MuninnCore --filter bundleIdentifierIsTheAppsIdentifier`
Expected: FAIL, `AppIdentity` not found.

- [ ] **Step 3: Add `AppIdentity`** in `AppIdentity.swift`.

- [ ] **Step 4: Derive every identifier from it**
- Each `Logger(subsystem: "be.netronix.muninn", …)` becomes `Logger(subsystem: AppIdentity.bundleIdentifier, …)`.
- `KeychainStore.init(service:)` defaults to `AppIdentity.bundleIdentifier`.
- The call detector's queue label becomes `"\(AppIdentity.bundleIdentifier).call-detector"`.
- `CallDetector.ownBundleID` is removed, and its uses read `AppIdentity.bundleIdentifier`.

- [ ] **Step 5: Replace `@ViewState` with `@State`** in every file, and delete `ViewState.swift`.

- [ ] **Step 6: Verify**

Run:
- `rg -n "be\.netronix|ViewState" Muninn Packages --glob '!**/.build/**'`: no output.
- Both package suites: all pass (report passed/total).
- `$X mise exec -- xcodegen generate`, then the Debug build: succeeds.

- [ ] **Step 7: Commit** — `Derive every identifier from com.michaelrigart.muninn, and use plain @State`

---

### Task 3: The app verifier

**Depends on:** Task 2

**Files:**
- Create: `scripts/verify-app`, `scripts/tests/test-verify-app` (both executable)

**Interfaces:**
- Consumes: a Release `Muninn.app` from Task 1's build command.
- Produces: `scripts/verify-app [--team <ID>] <Muninn.app> [<version>]`, exit 0 on pass, 1 on failure (one `FAIL: …` line per failed check on stderr), 2 on usage. `scripts/tests/test-verify-app <Release Muninn.app>`.

Start from Hulder's `scripts/verify-app` and `scripts/tests/test-verify-app`. Rename them to Muninn and change these checks:
- **Entitlements:** they must be exactly `{"com.apple.security.device.audio-input":true}`, compared as JSON as Hulder compares `{}`. The failure message is `entitlements are not exactly com.apple.security.device.audio-input: <json>`. An empty or unreadable entitlements set fails too.
- **Probe check replaced:** fail `bundle contains muninn-spike` when `find "$app" -name muninn-spike` finds anything.
- **New usage-description checks:** fail `NSMicrophoneUsageDescription is missing` or `NSAudioCaptureUsageDescription is missing` when the key is absent or empty.
- **Test arguments:** the test takes one argument, a Release app, as Linger's does. The resigning entitlements file is `Muninn/Muninn.entitlements`.

- [ ] **Step 1: Write `test-verify-app`**

Keep Hulder's cases a, c–j, n and o, renamed. Replace b and k, drop m, and add p:
- `b: an added get-task-allow entitlement fails`: resign with audio-input plus get-task-allow, and expect status 1 with "entitlements are not exactly".
- `b: no entitlements fails`: resign with an empty entitlements dict, same expectation.
- `k: a bundle with muninn-spike fails`: copy any small file to `Contents/Resources/muninn-spike`, resign, and expect "bundle contains muninn-spike".
- `p: a missing microphone description fails`: delete `:NSMicrophoneUsageDescription`, resign, and expect "NSMicrophoneUsageDescription is missing".
- `p: a missing audio capture description fails`: the same for `:NSAudioCaptureUsageDescription`.

- [ ] **Step 2: Run it on a Release build to see it fail**

Run: `$X xcodebuild … -configuration Release …` (Task 1), then `scripts/tests/test-verify-app build/Build/Products/Release/Muninn.app`
Expected: fails, because `scripts/verify-app` doesn't exist yet.

- [ ] **Step 3: Write `scripts/verify-app`** as described above.

- [ ] **Step 4: Run the checks**

Run:
- `scripts/tests/test-verify-app build/Build/Products/Release/Muninn.app`: every case passes, and n runs its team-signed branch.
- the same on an ad hoc Release build: every case passes, with n's team case skipped.
- `scripts/verify-app --team CX4MWR5579 build/Build/Products/Release/Muninn.app`: exit 0.
- `scripts/verify-app build/Build/Products/Debug/Muninn.app`: exit 1 with "entitlements are not exactly" (`get-task-allow`).

- [ ] **Step 5: Commit** — `Add the app verifier`

---

### Task 4: Changelog, release script and cask

**Depends on:** Task 3

**Files:**
- Create: `CHANGELOG.md`, `scripts/changelog.py`, `scripts/tests/test_changelog.py`, `scripts/release`, `scripts/tests/test-release-dry-run`, `scripts/muninn.rb.template`

**Interfaces:**
- Consumes: `scripts/verify-app` (Task 3).
- Produces: `scripts/release [--dry-run] [--version <YYYYMMDD-HHMM>]`. A dry run writes `build/release/Muninn-<version>.zip` and `build/release/muninn.rb`.

Port Hulder's six files, renamed: `repo=michaelrigart/muninn`, `Muninn.app`, `Muninn-<version>.zip`, `Casks/muninn.rb`, the tap commit `muninn <version>`, and `muninn-release` temporary names. Every step and every recovery path stays as in Hulder. The one other change: the release build line drops `ARCHS=arm64`, because `project.yml` sets it.

- [ ] **Step 1: Write `CHANGELOG.md`**

Use Hulder's preamble, with Muninn named. Then `## [Unreleased]` with `### Added` and these entries:
- Muninn records calls (Teams and others) and in-person conversations without a bot, transcribes them on your Mac in Dutch, French and English, and drafts a recap with action points that you send from Outlook.
- Meetings file into your Obsidian vault.
- Install with Homebrew: `brew install --cask michaelrigart/tap/muninn`.
- Releases are signed with a stable certificate, so the permissions you give Muninn survive updates.

End with the pre-first-release link `[Unreleased]: https://github.com/michaelrigart/muninn/commits/main`, as Hulder had before its first release.

- [ ] **Step 2: Write `scripts/muninn.rb.template`**

```ruby
cask "muninn" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/michaelrigart/muninn/releases/download/#{version}/Muninn-#{version}.zip"
  name "Muninn"
  desc "Records, transcribes and summarises meetings on your Mac"
  homepage "https://github.com/michaelrigart/muninn"

  livecheck do
    url :url
    regex(/^(\d{8}-\d{4})$/i)
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Muninn.app"

  uninstall quit: "com.michaelrigart.muninn"

  zap trash: "~/.config/muninn"

  caveats <<~EOS
    Muninn is signed but not notarized, so macOS blocks its first launch.
    After the first install, open System Settings > Privacy & Security and
    choose "Open Anyway" for Muninn. Upgrades should not need this again.

    macOS asks for the Microphone at your first recording, and for System
    Audio Recording the first time you record a call. The speech models
    download from Hugging Face the first time they are used.

    Engines, Microsoft accounts and Obsidian are set up in Settings; see
    https://github.com/michaelrigart/muninn/blob/main/docs/setup.md
  EOS
end
```

- [ ] **Step 3: Port `changelog.py`, its test, `release` and `test-release-dry-run`** from Hulder, renamed. In `test-release-dry-run`, replace the check that the release section omits Hulder's own changelog text (`lacks "$output" "Hulder v1: hide other apps"`) with the first words of Muninn's first entry.

- [ ] **Step 4: Add the zap assertion** (Review Focus 3) to `test-release-dry-run` case a, after the cask is written:
  - `a: the cask zaps only the settings`: the rendered cask contains `zap trash: "~/.config/muninn"`;
  - `a: the cask never zaps the meetings`: the rendered cask doesn't contain `.local/share/muninn`.

- [ ] **Step 5: Run the script tests**

Run: `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'` and `scripts/tests/test-release-dry-run`
Expected: all pass. Report passed/total. The release test builds and signs, so it needs the certificate and `brew`; run it outside the sandbox.

- [ ] **Step 6: Commit** — `Add the changelog, release script and Homebrew cask`

---

### Task 5: CI

**Depends on:** Task 4

**Files:**
- Create: `.github/workflows/ci.yml`

Hulder's `ci.yml`, with Muninn's names. It follows the "CI steps" in the shared recipe, without the Debug build:
- `Test the changelog tool`;
- `Test MuninnCore` and `Test MuninnPlatform`;
- `Generate the project`;
- `Build Release, signed ad hoc`: `xcodebuild -project Muninn.xcodeproj -scheme Muninn -configuration Release -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -quiet build`;
- `Verify the app`;
- `Test the verifier`: `scripts/tests/test-verify-app build/Build/Products/Release/Muninn.app`.

- [ ] **Step 1: Write the workflow.**
- [ ] **Step 2: Lint it.** Run `mise exec -- actionlint .github/workflows/ci.yml`. Expected: no output.
- [ ] **Step 3: Run each `run:` step locally, in order,** from a clean `build/`, with `$X` in place of the `xcode-select` step. Expected: each passes.
- [ ] **Step 4: Commit** — `Add CI`

---

### Task 6: Documentation, and a clean install for Michael's checks

**Depends on:** Task 5

**Files:**
- Create: `README.md`
- Modify: `AGENTS.md`, `docs/setup.md`, `docs/spike.md`

- [ ] **Step 1: Write `README.md`**

Sections in this order:
- what Muninn does, from the meeting-capture spec's Intent: two short paragraphs, no workflow-specific or personal detail;
- `## Requirements`: macOS 26 or later, Apple silicon;
- `## Install`: `brew install --cask michaelrigart/tap/muninn`, then the first-run steps (Open Anyway; the Microphone and System Audio Recording prompts), then a pointer to `docs/setup.md` for engines, Microsoft accounts, Obsidian and the spike. Add a note: if you built Muninn yourself, quit it and delete every copy first, including `build/` in your checkout;
- `## Build and install`: the shared block. After it, one paragraph: an ad hoc build is a new app to macOS on every rebuild, so the Microphone and System Audio Recording permissions are asked again; and start Muninn with `open` or Finder, since started from a terminal, macOS gives the Microphone to the terminal;
- `## Tests`: both `swift test` lines and the script tests;
- `## Releasing`: as Hulder's;
- `## Limitations`: `docs/setup.md`'s "Known limitations", moved;
- `## License`: MIT, see `LICENSE`.

- [ ] **Step 2: Rewrite `AGENTS.md`**

Keep the title and the design-records paragraph.

Replace "Build and test" with `## Commands`, following the shared recipe:
- the Platform tests line: `swift test --package-path Packages/MuninnPlatform`;
- the spike CLI as entry 13: `swift build -c release --product muninn-spike --package-path Packages/MuninnPlatform`, then `Packages/MuninnPlatform/.build/release/muninn-spike`.

Add `## Releases and CI`, as Hulder's.

Add `## Rules an agent gets wrong`:
- `MuninnCore` stays dependency-free;
- in the app target, refer to `MuninnCore.Settings`, because `SwiftUI.Settings` is a scene type;
- Swift 5 language mode everywhere;
- every identifier derives from `AppIdentity.bundleIdentifier`;
- builds are signed with the Personal Team, and ad hoc builds need the permissions again after every rebuild;
- start the app with `open`;
- a bare `log` is a zsh builtin: use `/usr/bin/log`, subsystem `com.michaelrigart.muninn`.

Drop the `@ViewState`, `scripts/swiftpm.sh` and `Vendor/` rules.

- [ ] **Step 3: Update `docs/setup.md`**

- Steps 1 and 2 become one step, "Install or build", pointing to the README's Install and Build and install. Renumber the steps after it.
- Remove every mention of the "Muninn Local" certificate, `MUNINN_SIGN_IDENTITY`, `scripts/bundle-app.sh`, `scripts/vendor-fluidaudio.sh` and the ad hoc signing warning.
- The firewall table names `/Applications/Muninn.app` and the spike at `Packages/MuninnPlatform/.build/release/muninn-spike`.
- `be.netronix.muninn` becomes `com.michaelrigart.muninn` in the bundle id, permissions and data tables.
- The Keychain step 6 note about ad hoc items now refers to builds without the certificate.
- "Known limitations" moves to the README, and a one-line pointer to it stays.

- [ ] **Step 4: Update `docs/spike.md`**

- "Before the first run", step 1: drop the vendor script. The build becomes `swift build -c release --product muninn-spike --package-path Packages/MuninnPlatform`, with `S=Packages/MuninnPlatform/.build/release/muninn-spike`.
- The Keychain service becomes `com.michaelrigart.muninn`.

- [ ] **Step 5: Check for stale references** (Review Focus 5)

Run: `rg -n "swiftpm\.sh|bundle-app|vendor-fluidaudio|Vendor/|be\.netronix|MUNINN_SIGN_IDENTITY|Muninn Local|ViewState|\.build/release/muninn-spike" --glob '!docs/superpowers/**' --glob '!**/.build/**' AGENTS.md README.md docs Muninn Packages scripts`
Expected: the only hits are `Packages/MuninnPlatform/.build/release/muninn-spike`.

- [ ] **Step 6: Run the README block as written, then leave only the team-signed build** (acceptance 5, Review Focus 2)

Run the README's "Build and install" commands exactly as written. `pgrep -x Muninn` finds Muninn within 5 s. Then:
- `pkill -x Muninn`;
- `rm -rf /Applications/Muninn.app build/Muninn.app` (the latter is the old ad hoc bundle from 2026-10-23);
- the team-signed Debug build, the Install and the Run commands from `AGENTS.md`;
- `pkill -x Muninn`.

Check: `mdfind "kMDItemCFBundleIdentifier == 'com.michaelrigart.muninn'"` lists only `/Applications/Muninn.app` and `build/Build/Products/Debug/Muninn.app`, and both show `TeamIdentifier=CX4MWR5579`. `mdfind "kMDItemCFBundleIdentifier == 'be.netronix.muninn'"` lists nothing. Leave Muninn quit: Michael grants the permissions himself.

- [ ] **Step 7: Commit** — `Document the new build, install and release steps`

---

### Task 7: Hulder: equal build steps

**Depends on:** none (separate repository). Can run beside Tasks 1–6.

**Repository:** `/Users/michael/Code/hulder`, new branch `chore/equal-build-steps` from `main`.

**Files:** `project.yml`, `mise.toml`, `README.md`, `AGENTS.md`, `.github/workflows/ci.yml`, `scripts/release`

- [ ] **Step 1: Make the changes**
- `project.yml`: add `ARCHS: arm64` to the shared settings block. Everything else in it already matches.
- Drop `ARCHS=arm64` from every command line: both `README.md` lines, both CI builds and `scripts/release`.
- `mise.toml`: add `actionlint = "1.7.12"`.
- `README.md`: the "Build and install" block becomes the shared block exactly. Hulder's own paragraphs (Accessibility, `tccutil`) follow it.
- `AGENTS.md`: the Commands list follows the shared recipe. That adds the Release build line and the ad hoc override line, and uses the shared opening paragraph.

- [ ] **Step 2: Verify**

Run:
- `mise exec -- actionlint .github/workflows/ci.yml`: no output.
- `$X mise exec -- xcodegen generate`, the ad hoc Release and Debug builds: both succeed, and `lipo -archs` on the Release executable prints `arm64`.
- `scripts/verify-app` on the Release build, and `scripts/tests/test-verify-app <Release> <Debug>`.
- `scripts/tests/test-release-dry-run` and the changelog tests.

Expected: all pass. Report the totals.

- [ ] **Step 3: Commit** in Hulder — `Keep the build steps equal to Muninn's and Linger's`

---

### Task 8: Linger: equal build steps

**Depends on:** none (separate repository). Can run beside Tasks 1–7.

**Repository:** `/Users/michael/Code/linger`, new branch `chore/equal-build-steps` from `main`.

**Files:** `project.yml`, `README.md`, `AGENTS.md`, `.github/workflows/ci.yml`, `scripts/release`

- [ ] **Step 1: Make the changes**
- `project.yml`: add `ENABLE_DEBUG_DYLIB: NO` and `OTHER_CODE_SIGN_FLAGS: "--options=runtime"`, so the shared settings block matches.
- `scripts/release`: drop `ARCHS=arm64`.
- CI: change to `runs-on: xcode-27`, add `timeout-minutes: 30`, and select `/Applications/Xcode_27.1.app`. Step order and names follow the shared recipe.
- `README.md`: the first-install and upgrade blocks become the shared block. Linger's own paragraphs (Allow…, `tccutil reset All com.michaelrigart.linger`) follow it.
- `AGENTS.md`: the Commands list follows the shared recipe. That adds Install and Run.

- [ ] **Step 2: Verify**

Run:
- `mise exec -- actionlint .github/workflows/ci.yml`: no output.
- `$X mise exec -- xcodegen generate`, the ad hoc Release build: succeeds, and `lipo -archs` prints `arm64`.
- `scripts/verify-app` and `scripts/tests/test-verify-app` on it.
- `scripts/tests/test-release-dry-run` and the changelog tests.
- An ad hoc Debug build that launches with `open`. Then quit it and delete it, so no ad hoc copy is left (Linger's AGENTS.md).

Expected: all pass. Report the totals.

- [ ] **Step 3: Commit** in Linger — `Keep the build steps equal to Muninn's and Hulder's`

---

## After the tasks (controller)

1. Run the full checks once on each final commit: both Muninn suites, the script tests, `actionlint`, and the Release build plus verifier. Do the same for Hulder and Linger. In Muninn, on the clean committed tree, run `scripts/release --dry-run` (acceptance 4).
2. Run a whole-branch review across the three repositories. Then run Codex's pre-merge review with `--diff main...feat/distribution`, `--diff /Users/michael/Code/hulder:main...chore/equal-build-steps` and `--diff /Users/michael/Code/linger:main...chore/equal-build-steps`.
3. Push the three branches and open draft pull requests, Muninn's first. The companions reference the spec by forge link.
4. In Muninn, commit the spec's and this plan's Status as `Implemented`, citing the pull request. Run another full-range pre-merge round on that commit, then push.
5. CI on all three is acceptance 1 and 8. If any repository fails to build or test with Xcode 27.1, the CI rule moves all three to the 27.2 release candidate, in each branch.
6. Hand Michael acceptance 2 and 3, against the installed team-signed Debug build. Acceptance 6 and 7 follow the first and second releases.
7. List in the final report, for Michael to run: `rm -rf Vendor .build` in Muninn (generated leftovers of the old build).
