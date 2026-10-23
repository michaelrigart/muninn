# Muninn

Native macOS 26 menu bar app for meeting capture. Swift 6 toolchain (Command Line Tools only, no Xcode), Swift 5 language mode in every target, Swift Testing.

## Design records

Design specs live in `docs/superpowers/specs/` and implementation plans in `docs/superpowers/plans/`. Both are tracked with the code.

## Build and test

- `scripts/vendor-fluidaudio.sh` vendors FluidAudio into `Vendor/` (run once; skips when present).
- `scripts/swiftpm.sh test --package-path Packages/MuninnCore` tests the dependency-free core.
- `scripts/swiftpm.sh build` builds everything; `scripts/swiftpm.sh test` runs the root test targets.
- `scripts/bundle-app.sh` assembles the app bundle.
- With the Command Line Tools macOS 27 SDK, `@State` resolves to a SwiftUI macro whose plugin isn't shipped, so views use `@ViewState` (a typealias for `SwiftUICore.State`, in `Sources/MuninnApp/Views/ViewState.swift`) instead of `@State`.
- In the app target, refer to the settings type as `MuninnCore.Settings`, because `SwiftUI.Settings` is a scene type.

SwiftPM builds must run outside an agent sandbox: inside it SwiftPM fails writing temp files and starting its own sandbox.

Every SwiftPM build and test goes through `scripts/swiftpm.sh` (it forwards to `swift`). On Command Line Tools it adds the Swift Testing macro plugin path; a plain `swift test` can fail with "plugin for module 'TestingMacros' not found", and mixing wrapped and plain runs flips the build description, so never call `swift build`/`swift test` directly.

`Vendor/` is generated and gitignored; never edit or commit it.
