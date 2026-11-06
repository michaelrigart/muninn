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
- Listen back to a meeting: a player under the meeting plays the recording, and the transcript
  follows along, highlighting the passage and the word being spoken. Click a sentence or a
  recap source to play from there.
- Every recap edit can be undone with ⌘Z, including removing a subject, bullet or action.
- Find in the transcript (⌘F) highlights every match, and Copy all copies the whole transcript.
- Move a transcript line, or a selection of lines, to another speaker or a new one: right-click
  and choose Change speaker.
- A meeting without a calendar event shows its speakers in the header; click one to rename it.

### Changed

- Errors say what happened and what to do next, with the technical details one click away.
- When Ollama isn't running on This Mac, a meeting waits instead of failing, and carries on
  within about 15 seconds of starting it.
- Muninn asks for permission to send notifications the first time it has one to send.
- The Meetings window has a toolbar for the recap, the transcript, the engine, the Outlook draft
  and Obsidian, and a calmer header, recap and transcript.
- Recipients are chosen in the Outlook draft sheet, which also shows the subject and a preview.
- Meetings move to the Trash instead of being deleted, so they can be put back from Finder, and
  they reappear in Muninn by themselves.
- Sidebar search also looks in recaps and transcripts, and each row shows the time, duration,
  client and status.
- Recap sources show the time in the transcript instead of a segment number.
- Renaming a speaker says that it renames them everywhere.
- Each speaker keeps their colour when lines move between speakers.

### Fixed

- Muninn's dialogs show the Muninn icon instead of a blank placeholder.

[Unreleased]: https://github.com/michaelrigart/muninn/commits/main
