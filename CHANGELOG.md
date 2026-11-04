# Changelog

All notable changes to Muninn are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versions are release times,
`YYYYMMDD-HHMM` in the maintainer's local time: a version says when a release was made, not
whether it is compatible with the one before. Each section says what changed.

## [Unreleased]

### Added

- Muninn records calls (Teams and others) and in-person conversations without a bot, transcribes
  them on your Mac in Dutch, French and English, and drafts a recap with action points that you
  send from Outlook.
- Meetings file into your Obsidian vault.
- Install with Homebrew: `brew install --cask michaelrigart/tap/muninn`.
- Releases are signed with a stable certificate, so the permissions you give Muninn survive
  updates.
- An app icon, and a Muninn raven in the menu bar in place of the waveform.
- Muninn has a Dock icon and opens its windows in front.
- An Activity window lists what Muninn did and what went wrong, with Copy diagnostics for bug
  reports. Open it from the menu bar or the Help menu.
- Meetings show their processing step, their place in the queue and speech model downloads, and
  the sidebar and the menu bar show work in progress.
- A "Needs attention" list, and a notification, for meetings you have to act on.

### Changed

- Errors say what happened and what to do next, with the technical details one click away.
- When Ollama isn't running on This Mac, a meeting waits instead of failing, and carries on
  within about 15 seconds of starting it.
- Muninn asks for permission to send notifications the first time it has one to send.

[Unreleased]: https://github.com/michaelrigart/muninn/commits/main
