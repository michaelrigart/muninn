# Muninn

Muninn is a macOS app, with a Dock icon and a menu bar icon, that records your calls and
conversations without a bot joining. It captures your microphone and the call audio on separate
tracks, transcribes them on your Mac, and turns the transcript into a draft recap: a bullet
summary per subject, with action points. You review the draft and send it, and you no longer need
to take notes during calls.

The recap can be written by a model on your Mac, on another Mac on your network, or by Claude.
Finished meetings can be filed into an Obsidian vault.

## Requirements

- macOS 26 or later, on Apple silicon.
- To build: Xcode 27 and [mise](https://mise.jdx.dev) for XcodeGen.

## Install

```sh
brew install --cask michaelrigart/tap/muninn
```

Muninn is signed with a free developer certificate and is not notarized, so macOS blocks it
the first time you open it. After the first install:

1. Open System Settings > Privacy & Security, find the message about Muninn and click
   **Open Anyway**.
2. macOS asks for the Microphone when you start your first recording, and for System Audio
   Recording the first time you record a call. Allow both.

Upgrade with `brew upgrade --cask muninn`. Releases are signed with the same certificate, so an
upgrade should need neither step again. If macOS asks anyway, repeat them.

[`docs/setup.md`](docs/setup.md) covers the rest: the summary engines, Microsoft accounts,
Obsidian, where the data lives, and the spike that checks capture on your hardware.

If you built Muninn yourself before, quit it and delete every copy first, including the build in
your checkout's `build/`. A copy left on disk can take the permissions you grant to the new one.

## Build and install

To build it yourself, you need the full Xcode. If `xcode-select -p` points at the Command
Line Tools, prefix the `xcodebuild` and `swift` commands with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

The project is set up to sign with the maintainer's certificate, which you won't have.
Add `CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` to `xcodebuild` to sign ad hoc instead.

```sh
mise trust mise.toml
mise exec -- xcodegen generate
xcodebuild -project Muninn.xcodeproj -scheme Muninn -configuration Release -derivedDataPath build/dd.noindex CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= -quiet build
rm -rf /Applications/Muninn.app
ditto build/dd.noindex/Build/Products/Release/Muninn.app /Applications/Muninn.app
open /Applications/Muninn.app
```

Remove the old app first: `ditto` merges into an existing bundle and would keep stale
files. Quit Muninn before you replace it, so that `open` starts the new build instead of
bringing the old one forward.

An ad hoc build is a different app to macOS every time you rebuild it, so the Microphone and
System Audio Recording permissions are asked again. Start Muninn with `open` or Finder: started
from a terminal, macOS gives the Microphone permission to the terminal.

## Tests

```sh
swift test --package-path Packages/MuninnCore
swift test --package-path Packages/MuninnPlatform
/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'
scripts/tests/test-release-dry-run   # (needs the maintainer's signing certificate and brew)
scripts/tests/test-verify-app <Release Muninn.app>
```

## Releasing

The maintainer cuts a release with `scripts/release`. It needs the signing certificate,
so it runs on the maintainer's Mac, not in CI. It sets the version (the time it starts,
`YYYYMMDD-HHMM`), moves the `Unreleased` entries of `CHANGELOG.md` into that version,
builds, signs, runs `scripts/verify-app`, packages `Muninn-<version>.zip`, tags, publishes
the GitHub release and updates the cask. `scripts/release --dry-run` does everything up to
the package and prints the changelog section; `--version <version>` resumes a release that
failed part way. `design/render` regenerates the app icon and menu bar PNGs from
`design/app-icon.svg` and `design/menubar.svg`; it needs `rsvg-convert` (Homebrew `librsvg`).

## Limitations

Not yet tested on real hardware, so expect surprises in:

- process taps on the system-audio path (per-app isolation, and the "all audio" fallback),
- Continuity (iPhone) calls taken on the Mac,
- live transcription during a real call,
- AirPods and Bluetooth hands-free (HFP) sample-rate switches mid-call,
- the first model download: each model downloads from Hugging Face the first time it is used,
  so the first transcription after install depends on the network and on any outbound firewall;
  run `muninn-spike transcribe` on a short file first to get it over with. That is the spike CLI,
  built from source: see [`docs/spike.md`](docs/spike.md).

The full list of what the spike must settle is in [`docs/spike.md`](docs/spike.md).

## License

MIT, see [`LICENSE`](LICENSE).
