# Muninn UX pass, pull request 2: the Meetings window — Implementation Plan

**Status:** In progress — [PR #4](https://github.com/michaelrigart/muninn/pull/4)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Meetings window gets a unified toolbar, a calmer sidebar and header, a recap editor whose every edit undoes, an Outlook draft sheet, one continuous transcript, and a docked player whose playback the transcript follows word by word.

**Architecture:** Everything with rules lives in MuninnCore and is unit tested: labels and the sidebar sign, search, which meeting commands are available and why not, speaker colours, the recap document and its undo history, word alignment, the transcript's text layout and the read-along lookup, the playback model and remembered positions, and moving a meeting to the Trash. MuninnAudio builds the two-track playback composition. The app adds the views: a toolbar, sidebar, header chips, recap editor, draft sheet, an AppKit text view for the transcript, and an `AVPlayer`-based player whose 30 Hz clock is observed only by the player bar and the transcript, never by the recap editor.

**Tech Stack:** Swift 5 language mode, SwiftUI + AppKit, AVFoundation, Swift Testing, SwiftPM packages `MuninnCore` (dependency-free) and `MuninnPlatform`, XcodeGen via mise, Xcode 27.

**Spec:** `docs/superpowers/specs/2026-11-03-muninn-ux-pass-design.md` (sections "Design system", "The Meetings window (pull request 2)", "Constraints", "Delivery" item 2, "Acceptance" 5–8). Read the spec before each task.

## Global Constraints

- macOS 26; Swift 5 language mode in every target; `MuninnCore` stays dependency-free (Foundation only).
- In the app target, the settings type is `MuninnCore.Settings` (`SwiftUI.Settings` is a scene).
- Swift uses `AppIdentity.bundleIdentifier`, never the bundle identifier literal.
- Copy: "Recap" everywhere in the interface (never "summary"); sentence case for every label, button, menu item and title; real ellipses (…) only where more input follows; "This Mac", "Network Mac", "Claude"; British spelling. Titles end without a full stop.
- Colours come from `Theme` / `Palette` only; red (`Theme.recording`) only for recording. Every text colour meets 4.5:1 on its background in light and dark.
- Type (spec): meeting title New York 27 pt semibold (`Theme.meetingTitle`); subjects 19 pt semibold serif (`Theme.subject`); reading 14.5 pt, interface 13 pt; meta 12.5 pt; labels 11 pt semibold uppercase (`SectionLabel`); mono 11.5 pt. Radii 6 (chips, tokens), 10 (cards, rows), 14 (panels). 8-pt grid (`Space`). Reading width at most 760 pt (`Theme.readingWidth`).
- Window: default 1180×780, minimum 820×560, sidebar column 220–320 pt. No fixed widths that truncate text.
- User-facing text never comes from `localizedDescription` or `String(describing:)` of an error; failures become problems through `ProblemTranslator` and are recorded in Activity.
- The Activity log never holds transcript text, recap text, email bodies or attendee address lists.
- Every icon-only control has an accessibility label and a `.help`; a disabled control says why in its `.help`.
- Public-repository rules: no personal details, machine paths or workflow-specific content in code, tests or docs; fixtures use `example.com`.
- Implementers do not commit; the controller commits each task with the message given, after its review. Every task's tests compile the shared MuninnCore sources, so tasks run one at a time.

### Commands

Run all of these outside any agent sandbox. `X` stands for `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (this Mac's `xcode-select -p` points at the Command Line Tools).

- Core tests: `X swift test --package-path Packages/MuninnCore [--filter <Suite>]`
- Platform tests: `X swift test --package-path Packages/MuninnPlatform [--filter <Suite>]`
- Regenerate the project after adding or removing app files: `mise exec -- xcodegen generate`
- App build (ad hoc, kept in one place): `X xcodebuild -project Muninn.xcodeproj -scheme Muninn -configuration Debug -derivedDataPath build/adhoc -quiet build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`. Every task that touches the app ends with this build passing with no new warnings. `build/adhoc` is removed in Task 19.

## Review Focus

1. **Transcript text whose words don't line up with its timings** (WhisperKit punctuation and segment text, vocabulary corrections, the mic de-duplication, cleanup that adds a word): the highlight never lands on the wrong word; a token without a matching word gets no word highlight and its segment still tints. Pinned in Task 5 (`mismatchedTokensAlignByForm`, `cleanWordsNotInTheVerbatimMapToNothing`) and Task 6 (`cleanModeSkipsRemovedWords`, `cleanModeHighlightsNothingDuringARemovedWord`, `segmentWithoutWordsHighlightsWhole`).
2. **Both sides talking at once, silences, and ⇧← early in a segment**: overlapping segments highlight the one that started last, a gap highlights nothing, and ⇧← within the first second of a segment goes to the one before. Pinned in Task 6 (`overlappingSegmentsPickTheLatestStart`, `gapHighlightsNothing`, `previousStartGoesBackWithinTheFirstSecond`).
3. **A recording that is partly missing or broken** (a mic-only meeting, a track that stopped writing early, a header-only file left by a crash, a corrupt file): the other track plays; no playable track shows "The recording for this meeting isn't available."; only unreadable files show a problem. Pinned in Task 9 (`micOnlyMeetingPlaysOneTrack`, `shorterTrackDoesNotShortenPlayback`, `emptyFileCountsAsMissing`, `unreadableFileIsSkipped`, `allUnreadableThrows`).
4. **A remembered position that no longer fits** (at or past the end, negative, or a damaged `playback.json`): playback starts at zero and the file is rewritten on the next save. Pinned in Task 7 (`resumeRule`, `damagedFileReadsEmpty`).
5. **Undo after the recap changed underneath it, and typing**: ⌘Z after a regeneration, a restore of the previous version or a reload never puts an older recap back over the new one; a field's typing is saved on every change and undoes as one step. Pinned in Task 4 (`replaceClearsHistory`, `typingSavesEveryChangeAndUndoesAsOneStep`, `typingUndoneBeforeEndingRegistersNothing`, `structuralEditEndsTyping`).

## Rulings made while planning

Decisions the spec leaves to the builder or does not settle. Record them under "Rulings" in the pull request.

1. Recording already keeps both tracks on the shared clock: `TrackPipeline` pads or trims a track that drifts more than 50 ms and cuts paused time from both. Playback therefore plays both files from time zero with no further alignment.
2. The player is `AVPlayer` over an `AVMutableComposition` of the two files, with the `.timeDomain` pitch algorithm, an `AVAudioMix` for the Mix menu, and a time observer every 1/30 s.
3. The transcript is one AppKit `NSTextView` (TextKit 1 with non-contiguous layout, so it stays lazy) so a selection can run across segments. Read-along uses temporary attributes, which never re-lay out the text. ⌘F and the toolbar's Search button open the system find bar, which highlights every match.
4. Recap text saves on every change, as today, so a draft or note never misses the last keystrokes. Undo groups one field's typing into one step when the field loses focus; every other edit is one step. The history is cleared when the recap is replaced (regenerated, previous version restored, reloaded) and when the meeting closes.
5. "Accent mid" (the current word) is the accent at 28% in light and 32% in dark.
6. Six speaker colours; "you" takes the first, other speakers the rest in order of first appearance; a person chip's colour comes from an FNV-1a hash of the name (or the address when there is no name).
7. Creating a draft closes the sheet and opens the draft in Outlook as today, so the path to sending stays as short as it was; the "Draft created · Open in Outlook" card stays on the meeting for later.
8. One sidebar sign, in this order: progress ring, waiting its turn, needs attention, recording, "Draft created", "Filed". "Draft created" wins over "Filed" because filing can be automatic.
9. A sidebar row's time adds the weekday in "This week" and the date in "Earlier", where the group heading doesn't say the day.
10. The read-along highlight starts once playback has started for the meeting in this session and stays at the paused position.
11. The position is saved on pause, seek, switching meeting, closing the window and every 10 s while playing; a position within 2 s of the end resumes at zero. Moving a meeting to the Trash forgets its position.
12. The Mix menu shows only when the meeting has both tracks.
13. "No event" asks first only when the meeting has an event or attendees to lose.
14. "Previous version" is in the toolbar's … menu and in the recap footer.
15. Copy all copies what the view shows (speaker lines, timestamps and text); in Changes that is the verbatim text.
16. Words removed by cleanup show in the secondary text colour with a strikethrough (the old 45% primary failed 4.5:1).
17. View › Reload has no shortcut: ⌘R is Regenerate in pull request 3.
18. The speaker lanes are the mic lane, then the call lane; a mic-only meeting has one lane.
19. The draft sheet's subject is editable and not stored; it starts as today's `RecapEmail.subject`.
20. A recap source whose segment isn't in the loaded transcript shows no mark; the item still counts as sourced.

## File map

MuninnCore (`Packages/MuninnCore/Sources/MuninnCore/`):

| File | Responsibility | Task |
|---|---|---|
| `Presentation/MeetingLabels.swift` | `DayGroup`, `MeetingGroup`, `MeetingGrouping`, `MeetingLabels`, `PersonLabel`, `Timestamp` | 1 |
| `Presentation/SidebarSign.swift`, `Presentation/MeetingSearch.swift` | The row's sign; search over a meeting's text | 1 |
| `Pipeline/ProcessingDisplay.swift` | gains `MeetingProgress.title` (moved from the app) | 1 |
| `Activity/ActivityEntry.swift` | gains `DurationText.minutes` | 1 |
| `Presentation/MeetingCommands.swift` | Which meeting commands are available, and why not | 2 |
| `Pipeline/MeetingActions.swift` | gains `accountChangeDropsEvent`, `clearingEventLosesDetails` | 2 |
| `Design/Palette.swift`, `Design/SpeakerColours.swift` | Speaker colours, accent mid | 3 |
| `Summary/RecapDocument.swift` | The recap being edited, with undo | 4 |
| `Cleanup/WordAlignment.swift`, `Cleanup/ChangeView.swift` | Tokens ↔ words; clean ↔ verbatim tokens | 5 |
| `ReadAlong/TranscriptLayout.swift`, `ReadAlong/SegmentTimeline.swift` | The transcript's text and ranges; time ↔ text lookup | 6 |
| `Playback/PlaybackModel.swift`, `Playback/PlaybackPositions.swift` | Lanes, mix, speeds, skip; remembered positions | 7 |
| `Storage/MeetingStore.swift`, `Storage/MuninnPaths.swift`, `Problems/Problem.swift` | Trash; `playbackFile`; two new stages | 7, 8 |

MuninnPlatform: `MuninnAudio/PlaybackComposition.swift` (Task 9).

App (`Muninn/`): `Design/Theme.swift` (3), `Design/Chips.swift` (12, 14), `Meetings/MeetingToolbar.swift` (11, 16), `Meetings/Sidebar.swift` (12), `Meetings/DraftSheet.swift` (13), `Meetings/MeetingHeader.swift`, `Meetings/HeaderChips.swift` (14), `Meetings/RecapEditor.swift`, `Meetings/RecapTokens.swift` (15, replacing `Views/SummaryEditor.swift`), `Meetings/TranscriptTextView.swift` (16, replacing `Views/TranscriptView.swift`), `Playback/MeetingPlayer.swift`, `Playback/PlayerBar.swift` (17), `Playback/PlaybackKeys.swift` (18); edits to `AppModel*.swift`, `MuninnApp.swift`, `Services.swift`, `Views/MainWindow.swift`, `Views/MeetingDetail.swift`, `Views/Formatting.swift`.

---

### Task 1: Labels, the sidebar sign and search

**Depends on:** none

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Presentation/MeetingLabels.swift`, `Presentation/SidebarSign.swift`, `Presentation/MeetingSearch.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Activity/ActivityEntry.swift`, `Pipeline/ProcessingDisplay.swift`
- Modify: `Muninn/Views/MainWindow.swift` (use Core's grouping), `Muninn/Views/Formatting.swift` (drop `MeetingProgress.title`)
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/PresentationTests.swift`

**Interfaces:**
- Consumes: `Meeting`, `Summary`, `MeetingProgress`, `PipelineStage.title`.
- Produces (all `public`):
  - `enum DayGroup: String, CaseIterable, Sendable { case today, yesterday, thisWeek, earlier; var title: String }` — "Today", "Yesterday", "This week", "Earlier".
  - `struct MeetingGroup: Identifiable { let group: DayGroup; let meetings: [Meeting]; var id: DayGroup }`; `enum MeetingGrouping { static func group(of date: Date, now: Date, calendar: Calendar) -> DayGroup; static func groups(_ meetings: [Meeting], now: Date = Date(), calendar: Calendar = .current) -> [MeetingGroup] }` — moved from `MainWindow.swift` with the same rules and order.
  - `enum Timestamp { static func format(_ seconds: TimeInterval) -> String }` — whole seconds, truncated; `mm:ss` under an hour, `h:mm:ss` from an hour; negative as zero.
  - `DurationText.minutes(_ seconds: TimeInterval) -> String` — `m = max(1, round(seconds / 60))`; "\(m) min" under 60, else "\(h) h" or "\(h) h \(rest) min".
  - `enum MeetingLabels`:
    - `static func meta(start: Date, end: Date?, language: String?, calendar: Calendar, locale: Locale) -> String` — joined with " · ": the date (`DateFormatter.setLocalizedDateFormatFromTemplate("EEEdMMMyyyy")`), the time range (template `"jmm"`, start "–" end; the start alone when `end` is nil or not after `start`), `DurationText.minutes` when there is an end after the start, and the language name (`locale.localizedString(forLanguageCode:)`, left out when nil or unknown). Every formatter uses the given calendar, its time zone and the locale.
    - `static func sidebarTime(start: Date, end: Date?, group: DayGroup, now: Date, calendar: Calendar, locale: Locale) -> String` — `today`, `yesterday`: the time; `thisWeek`: template `"EEE"` + " " + time; `earlier`: template `"dMMM"` (or `"dMMMyyyy"` when the year differs from `now`'s) + " " + time; then " · " + `DurationText.minutes` when there is an end after the start.
    - `static func detailsChip(accountName: String?, client: String?) -> String` — "Work · Acme", "Work", "Acme", or "Account and client".
  - `enum PersonLabel { static func initials(name: String, email: String) -> String; static func shortName(name: String, email: String) -> String }` — initials: first letters of the first and last words of the trimmed name, uppercased (one letter for a one-word name); with no name, the first letter of the address. Short name: the name's first word, else the address's local part.
  - `extension MeetingProgress { var title: String? }` — moved unchanged from `Muninn/Views/Formatting.swift`.
  - `enum SidebarSign: Equatable, Sendable { case progress(step: Int, label: String), queued, attention, recording, draftCreated, filed, none; static func sign(for meeting: Meeting, progress: MeetingProgress, needsAttention: Bool) -> SidebarSign }` — first match wins: `.working(w)` → `.progress(w.stage.step, w.stage.title)`; `.preparingSpeechModel` → `.progress(1, "Getting the speech model ready")`; `.queued` → `.queued`; `needsAttention` → `.attention`; status `.recording` → `.recording`; `draftID` or `draftWebLink` set → `.draftCreated`; `exportedNotePath` set → `.filed`; else `.none`.
  - `enum MeetingSearch { static func recapText(_ summary: Summary) -> String; static func matches(_ meeting: Meeting, term: String, recapText: String?, transcriptText: String?) -> Bool }` — `recapText` joins subject titles, bullet texts, action owners and texts with newlines (what `MainWindow.loadSummaryText` builds today). `matches` trims the term (empty matches everything) and uses `localizedStandardContains` over the title, client, attendee names and addresses, the recap text and the transcript text.

- [ ] **Step 1: Write the failing tests** (`PresentationTests`), with `t = Date(timeIntervalSince1970: 1_793_800_800)` (Wednesday 4 November 2026, 14:00 UTC), a Gregorian calendar in UTC and `Locale(identifier: "en_GB")`:

```swift
@Test func timestamps() {
    #expect(Timestamp.format(0) == "00:00")
    #expect(Timestamp.format(724.9) == "12:04")
    #expect(Timestamp.format(3725) == "1:02:05")
    #expect(Timestamp.format(-3) == "00:00")
}
@Test func durationInMinutes() {
    #expect(DurationText.minutes(20) == "1 min")
    #expect(DurationText.minutes(2700) == "45 min")
    #expect(DurationText.minutes(3900) == "1 h 5 min")
    #expect(DurationText.minutes(7200) == "2 h")
}
@Test func metaLine() {
    #expect(MeetingLabels.meta(start: t, end: t + 2700, language: "nl", calendar: utc, locale: gb) == "Wed, 4 Nov 2026 · 14:00–14:45 · 45 min · Dutch")
    #expect(MeetingLabels.meta(start: t, end: nil, language: nil, calendar: utc, locale: gb) == "Wed, 4 Nov 2026 · 14:00")
}
@Test func sidebarTimeSaysTheDayWhereTheGroupDoesNot() {
    let now = t + 3600
    #expect(MeetingLabels.sidebarTime(start: t, end: t + 2700, group: .today, now: now, calendar: utc, locale: gb) == "14:00 · 45 min")
    #expect(MeetingLabels.sidebarTime(start: t, end: t + 2700, group: .thisWeek, now: now, calendar: utc, locale: gb) == "Wed 14:00 · 45 min")
    #expect(MeetingLabels.sidebarTime(start: t, end: t + 2700, group: .earlier, now: now, calendar: utc, locale: gb) == "4 Nov 14:00 · 45 min")
    #expect(MeetingLabels.sidebarTime(start: t, end: t + 2700, group: .earlier, now: now + 400 * 86_400, calendar: utc, locale: gb) == "4 Nov 2026 14:00 · 45 min")
    #expect(MeetingLabels.sidebarTime(start: t, end: nil, group: .today, now: now, calendar: utc, locale: gb) == "14:00")
}
@Test func detailsChip() {
    #expect(MeetingLabels.detailsChip(accountName: "Work", client: "Acme") == "Work · Acme")
    #expect(MeetingLabels.detailsChip(accountName: "Work", client: nil) == "Work")
    #expect(MeetingLabels.detailsChip(accountName: nil, client: "Acme") == "Acme")
    #expect(MeetingLabels.detailsChip(accountName: nil, client: nil) == "Account and client")
}
@Test func personLabels() {
    #expect(PersonLabel.initials(name: "Ann van Example", email: "ann@example.com") == "AE")
    #expect(PersonLabel.initials(name: "Ann", email: "ann@example.com") == "A")
    #expect(PersonLabel.initials(name: " ", email: "bob@example.com") == "B")
    #expect(PersonLabel.shortName(name: "Ann Example", email: "ann@example.com") == "Ann")
    #expect(PersonLabel.shortName(name: "", email: "bob.example@example.com") == "bob.example")
}
@Test func groupingKeepsTheDayRules() // now = t + 3600: t → today, t − 1 day → yesterday, Monday 2 Nov → thisWeek, 25 Oct → earlier; groups come out in DayGroup order and skip empty ones
@Test func sidebarSignPrecedence() {
    // .working(transcribing) → .progress(step: 1, label: "Transcribing"); .preparingSpeechModel → .progress(step: 1, label: "Getting the speech model ready")
    // .queued(ahead: 1) with needsAttention true → .queued; a failed meeting, progress .failed, needsAttention → .attention
    // status .recording → .recording; ready with draftID and exportedNotePath → .draftCreated; exportedNotePath only → .filed; plain ready → .none
}
@Test func searchCoversEveryField() // title, client, attendee name, attendee address, recap text only, transcript text only: each matches its own term; "" matches; an absent term doesn't
@Test func searchFoldsCaseAndAccents() { /* a client "Café Noir" matches "cafe noir" */ }
@Test func recapTextHoldsTitlesBulletsAndActions() // a summary with one subject, a bullet and an action (owner "Ann") → contains each of the four strings
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter PresentationTests` — expect a build failure.
- [ ] **Step 3: Implement** the Core types; move `MeetingGrouping` out of `MainWindow.swift` (the sidebar uses `group.group.title` for the section heading) and `MeetingProgress.title` out of `Formatting.swift`. Any test whose expected text differs from what the formatter produces is reported to the controller, not changed.
- [ ] **Step 4: Run** the focused suite and the app build — expect PASS.
- [ ] **Step 5: Commit** — `Add labels, the sidebar sign and search to MuninnCore`

---

### Task 2: Which meeting commands are available, and why not

**Depends on:** Task 1

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Presentation/MeetingCommands.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Pipeline/MeetingActions.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/MeetingCommandsTests.swift`

**Interfaces:**
- Consumes: `Meeting`, `MeetingProgress`, `MeetingActions.canDelete`, `MeetingActions.canDraft`, `MeetingActions.accountRemoved`, `MeetingActions.accountRemovedLabel`, `AccountSettings`.
- Produces (all `public`):
  - `enum MeetingCommand: CaseIterable, Sendable { case regenerate, outlookDraft, obsidian, previousVersion, moveToTrash }`
  - `struct MeetingCommandContext: Sendable { var meeting: Meeting; var progress: MeetingProgress; var hasRecap: Bool; var hasPreviousRecap: Bool; var unsavedEdits: Bool; var eventChanging: Bool; init(...) }` — "busy" below means status `.transcribing`, `.diarizing`, `.cleaning` or `.summarizing`, or progress `.working`, `.preparingSpeechModel` or `.queued`.
  - `enum MeetingCommands { static func disabledReason(_ command: MeetingCommand, _ c: MeetingCommandContext) -> String?; static func draftRefusal(_ m: Meeting, accounts: [AccountSettings]) -> String? }` — first match wins:

    | Command | Condition → reason |
    |---|---|
    | `regenerate` | status `.recording` or `.waiting(.recording)` → "Choose an engine once the recording has ended"; busy → "Wait until Muninn has finished this meeting"; unsaved → "Save your recap edits first"; event changing → "Wait for the event change" |
    | `outlookDraft`, `obsidian` | status `.recording`, busy, or status not `.ready` → "The recap isn't ready yet"; no recap → "There's no recap yet"; unsaved → "Save your recap edits first"; event changing → "Wait for the event change"; candidate events → "Choose the event first" |
    | `previousVersion` | no previous recap → "There's no previous version"; busy → "Wait until Muninn has finished this meeting"; unsaved → "Save your recap edits first" |
    | `moveToTrash` | status `.recording` → "Stop the recording first"; `!MeetingActions.canDelete` or busy → "Wait until Muninn has finished this meeting" |

    `draftRefusal`: no account → "Choose an account in the meeting's details"; account removed → `MeetingActions.accountRemovedLabel`; no included recipient → "Choose at least one recipient"; else nil.
  - `MeetingActions.accountChangeDropsEvent(_ m: Meeting, to account: String?) -> Bool` — the meeting has an association whose account isn't `account`.
  - `MeetingActions.clearingEventLosesDetails(_ m: Meeting) -> Bool` — the meeting has an association or attendees.

- [ ] **Step 1: Write the failing tests** (`MeetingCommandsTests`): one `@Test(arguments:)` per row of the table, each case giving the context and the expected reason (including nil for a ready meeting with a recap and nothing pending), plus `draftRefusalNamesWhatIsMissing`, `accountChangeDropsOnlyAnotherAccountsEvent` (same account false, other account true, no association false) and `clearingAsksOnlyWhenSomethingIsLost` (association true, attendees only true, neither false).
- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter MeetingCommandsTests` — expect a build failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the focused suite — expect PASS.
- [ ] **Step 5: Commit** — `Say which meeting commands are available and why not`

---

### Task 3: Speaker colours and the read-along tint

**Depends on:** none

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Design/SpeakerColours.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Design/Palette.swift`, `Muninn/Design/Theme.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/PaletteTests.swift`

**Interfaces:**
- Produces (Core, `public`):
  - `Palette.speakerLight: [RGB]` = hex `0x2C5DB0, 0x7A3FA8, 0xA2461C, 0x5E6B12, 0xA8336F, 0x1D6779`; `Palette.speakerDark: [RGB]` = `0x8AB4F5, 0xC29BEA, 0xF0946A, 0xB8C75A, 0xF08DBE, 0x5FB0C2`; `Palette.midLight = 0.28`, `Palette.midDark = 0.32` (the accent's alpha for the current word).
  - `enum SpeakerColours { static let count = 6; static func indices(for transcript: Transcript) -> [String: Int]; static func personIndex(name: String, email: String) -> Int }` — `indices`: "you" → 0; every other speaker → `1 + (n % 5)`, where `n` counts distinct non-"you" speakers in order of first appearance. `personIndex`: FNV-1a 32-bit (offset `0x811C9DC5`, prime `0x01000193`) over the UTF-8 of the trimmed, lowercased name, or the address when the name is empty, modulo 6.
- Produces (app): `Theme.accentMid`; `Theme.speaker(_ index: Int) -> Color`; and `Theme.AppKit` — `NSColor` statics for the transcript view: `primaryText`, `secondaryText`, `tertiaryText`, `attentionText`, `accentSoft`, `accentMid`, and `speaker(_ index: Int) -> NSColor`. The SwiftUI colours wrap the same `NSColor`s, so each colour is defined once.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func speakerColoursMeetAA() {
    // each speakerLight on contentLight and on composite(accentLight, softLight, over: contentLight) ≥ 4.5
    // each speakerDark on contentDark and on composite(accentDark, softDark, over: contentDark) ≥ 4.5
}
@Test func primaryTextMeetsAAOnTheCurrentWord() {
    // composite(black, primaryTextAlpha, over: bg) on bg = composite(accentLight, midLight, over: contentLight) ≥ 4.5; white in dark on composite(accentDark, midDark, over: contentDark) ≥ 4.5
}
@Test func speakerIndicesFollowFirstAppearance() {
    // speakers in order: S2, you, S1, S3, S4, S5, S6 → you 0, S2 1, S1 2, S3 3, S4 4, S5 5, S6 1
}
@Test func personIndexIsStable() {
    #expect(SpeakerColours.personIndex(name: "Ann Example", email: "") == 2)
    #expect(SpeakerColours.personIndex(name: "ANN EXAMPLE ", email: "") == 2)
    #expect(SpeakerColours.personIndex(name: "Bob Example", email: "") == 4)
    #expect(SpeakerColours.personIndex(name: "", email: "ann.example@example.com") == 3)
}
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter PaletteTests` — expect a build failure.
- [ ] **Step 3: Implement.** A colour pair that fails is reported to the controller, not changed.
- [ ] **Step 4: Run** the focused suite and the app build — expect PASS.
- [ ] **Step 5: Commit** — `Add speaker colours and the read-along tint`

---

### Task 4: The recap document and its undo history

**Depends on:** none

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Summary/RecapDocument.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/RecapDocumentTests.swift`

**Interfaces:**
- Produces (`public`):
  - `enum RecapField: Hashable, Sendable { case subjectTitle(Int), bulletText(Int, Int), actionText(Int, Int), actionOwner(Int, Int) }`
  - `final class RecapDocument { private(set) var summary: Summary; init(summary: Summary, save: @escaping (Summary) -> Void); func edit(_ actionName: String, undoManager: UndoManager?, _ change: (inout Summary) -> Void); func type(_ field: RecapField, undoManager: UndoManager?, _ change: (inout Summary) -> Void); func endTyping(undoManager: UndoManager?); func replace(with summary: Summary, undoManager: UndoManager?) }`
  - `edit`: ends any typing, applies the change; when the summary changed, saves it and registers one undo step (inside its own `beginUndoGrouping`/`endUndoGrouping`) named `actionName`. Undoing restores and saves the earlier summary and registers the redo under the same name.
  - `type`: saves every change at once without registering an undo step; the summary before the first change of a run is kept. A change to a different field ends the open run first. `endTyping` registers the whole run as one step named "Typing" when the summary differs from the run's start (a run the field's own undo took back to its start registers nothing).
  - Undo routing (the app follows it): while a recap field has focus, ⌘Z and ⇧⌘Z are the field editor's own typing undo, whose changes reach the document through `type` and are saved; AppKit discards the field editor's actions when its editing ends, and `endTyping` then registers the run. The document's history therefore never holds a step for text that is still being typed, and the field editor's history never outlives the field's focus.
  - `replace`: drops the open run, removes every undo and redo action targeting the document (`removeAllActions(withTarget:)`) and takes the new summary without saving it.
  - Action names used by the app: "Remove subject", "Remove bullet", "Remove action", "Add subject", "Add bullet", "Add action", "Change due date"; the owner is typed, so it undoes as "Typing".

- [ ] **Step 1: Write the failing tests** (`RecapDocumentTests`), each with `let undo = UndoManager(); undo.groupsByEvent = false` and a document whose `save` appends to an array:

```swift
@Test func undoRestoresARemovedBullet()   // remove bullet 0 of subject 0; undo → the bullet is back and was saved
@Test func undoRestoresARemovedAction()
@Test func undoRestoresARemovedSubject()
@Test func redoRemovesItAgain()            // remove, undo, redo → removed and saved again
@Test func typingSavesEveryChangeAndUndoesAsOneStep() {
    // three type(.bulletText(0, 0)) changes → three saves; endTyping; undo.undo() → the original text; undo.canUndo == false
}
@Test func typingUndoneBeforeEndingRegistersNothing() // type "x" then type back to the original text; endTyping → undo.canUndo == false
@Test func structuralEditEndsTyping()      // type into bullet 0, then edit("Remove bullet") on bullet 1: undo → bullet 1 back, typed text kept; undo → text reverted
@Test func replaceClearsHistory()          // remove a bullet, replace(with: fresh) → undo.canUndo == false, summary == fresh, no save
@Test func unchangedEditRegistersNothing() // edit that changes nothing → no save, undo.canUndo == false
@Test func undoCarriesTheActionName()      // after edit("Remove bullet") → undo.undoActionName == "Remove bullet"
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter RecapDocumentTests` — expect a build failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the focused suite — expect PASS.
- [ ] **Step 5: Commit** — `Add the recap document with undo`

---

### Task 5: Word alignment for the three transcript views

**Depends on:** none

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Cleanup/WordAlignment.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Cleanup/ChangeView.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/WordAlignmentTests.swift`

**Interfaces:**
- Consumes: `Tokenizer.normalize`, `Word`.
- Produces (`public`):
  - `enum WordAlignment { static func tokenWords(text: String, words: [Word]) -> [Int?]; static func pairs(_ a: [String], _ b: [String]) -> [(Int, Int)] }` — `tokenWords` gives, for each whitespace-separated token of `text`, the index of its word: the identity when the counts match, otherwise the longest common subsequence of the tokens' and the words' `Tokenizer.normalize` forms (empty forms never match). `pairs` is that longest-common-subsequence over two lists of normalised forms, returning matched index pairs in order, empty forms excluded; it replaces the table inside `ChangeView.tokens`.
  - `ChangeView.alignment(verbatim: String, clean: String) -> [Int?]` — for each whitespace-separated token of `clean`, the index of the verbatim token it keeps, from the same `pairs` that decide `tokens(verbatim:clean:)`'s removed flags.

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func tokensMatchWordsOneToOne() // "we ship friday" with words we, ship, friday → [0, 1, 2]
@Test func mismatchedTokensAlignByForm() // "Well, we ship it Friday." with words well, we, ship, friday → [0, 1, 2, nil, 3]
@Test func noWordsMeansNoTimings() // "hello there", [] → [nil, nil]
@Test func cleanTokensMapToVerbatimTokens() // verbatim "um so we uh ship it", clean "So we ship it." → [1, 2, 4, 5]
@Test func cleanWordsNotInTheVerbatimMapToNothing() // verbatim "we ship friday", clean "We ship on Friday" → [0, 1, nil, 2]
@Test func punctuationTokensMapToNothing() // verbatim "yes — fine", clean "Yes — fine." → [0, nil, 2]
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter WordAlignmentTests` — expect a build failure.
- [ ] **Step 3: Implement.** `ChangeView`'s existing tests must pass unchanged.
- [ ] **Step 4: Run** `--filter WordAlignmentTests` and `--filter CleanupTests` — expect PASS.
- [ ] **Step 5: Commit** — `Align transcript tokens with word timings`

---

### Task 6: The transcript layout and the read-along lookup

**Depends on:** Tasks 1, 5

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/ReadAlong/TranscriptLayout.swift`, `ReadAlong/SegmentTimeline.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/TranscriptLayoutTests.swift`

**Interfaces:**
- Consumes: `Transcript`, `CleanTranscript.text(for:)`, `Flag`, `FlagCoverage.flaggedSegmentIDs`, `SummaryRequestBuilder.displayName(_:speakerNames:userName:)`, `Timestamp.format`, `WordAlignment.tokenWords`, `ChangeView.tokens`, `ChangeView.alignment`.
- Produces (`public`; ranges are `NSRange` in UTF-16 units of `string`):
  - `enum TranscriptMode: String, CaseIterable, Sendable { case clean, changes, verbatim; var label: String }` — "Clean", "Changes", "Verbatim".
  - `struct TranscriptLayout: Sendable` with `string: String`, `segments: [SegmentLayout]`, `speakerLines: [SpeakerLine]`, and `static func make(transcript: Transcript, clean: CleanTranscript?, mode: TranscriptMode, speakerNames: [String: String], userName: String, flags: [Flag]) -> TranscriptLayout`.
    - `struct SegmentLayout: Sendable { var segmentID: Int; var start: TimeInterval; var end: TimeInterval; var line: NSRange; var timestamp: NSRange; var flag: NSRange?; var text: NSRange; var words: [WordSpan]; var removed: [NSRange] }`, `struct WordSpan: Sendable { var range: NSRange?; var start: TimeInterval; var end: TimeInterval }`, `struct SpeakerLine: Sendable { var range: NSRange; var speaker: String; var name: String }` (`range` covers the name only).
    - The text, in transcript order: when a segment's speaker differs from the previous shown segment's, a speaker line `"\t" + name + "\n"`; then the segment line `timestamp + (flagged ? " ⚑\u{FE0E}" : "") + "\t" + text + "\n"`. `line` excludes the newline.
    - `words` holds one `WordSpan` per timed word of the segment, in order, in every mode; `range` is the shown token that word maps to, or nil when the shown text has no token for it. Verbatim: `text` is `segment.text`; a word's token comes from `tokenWords`. Changes: the verbatim tokens joined by single spaces; `removed` holds the tokens `ChangeView.tokens` marks removed; ranges as verbatim. Clean: `clean.text(for:)`; clean token `i` maps to the word `tokenWords[alignment[i]]`, so removed and unmapped words keep their timings with a nil range. A segment whose shown text is empty is left out.
    - `func position(at time: TimeInterval) -> ReadAlongPosition?` — among segments with `start <= time < end`, the one with the latest start (ties: the later in the list); its word is the last timed word with `start <= time`, or nil; the app highlights a word only when its `range` is not nil, so a removed or unmapped word being spoken highlights only the segment. Nil in a gap.
    - `func seekTime(atOffset offset: Int) -> TimeInterval?` — a word's start when the offset is inside a word's range; the segment's start anywhere else on its line; nil elsewhere (speaker lines included).
    - `func speakerLine(atOffset offset: Int) -> SpeakerLine?`
    - `func segmentIndex(forSegmentID id: Int) -> Int?`
  - `struct ReadAlongPosition: Equatable, Sendable { var segment: Int; var word: Int? }` — indices into `segments` and that segment's `words`.
  - `struct SegmentTimeline: Sendable { init(transcript: Transcript); func previousStart(before time: TimeInterval) -> TimeInterval; func nextStart(after time: TimeInterval) -> TimeInterval? }` — over the distinct segment starts, sorted: previous is the latest start before `time − 1.0`, or 0; next is the earliest start after `time + 0.05`, or nil.

- [ ] **Step 1: Write the failing tests** (`TranscriptLayoutTests`) over this fixture, with user name "Ann":

```swift
let transcript = Transcript(segments: [
    Segment(id: 0, track: .mic, speaker: "you", start: 0, end: 4, text: "um we uh ship friday",
            words: [Word(text: "um", start: 0, end: 0.5), Word(text: "we", start: 0.6, end: 0.9), Word(text: "uh", start: 1, end: 1.4),
                    Word(text: "ship", start: 1.5, end: 2), Word(text: "friday", start: 2.2, end: 3.8)]),
    Segment(id: 1, track: .system, speaker: "S1", start: 3, end: 8, text: "sounds good",
            words: [Word(text: "sounds", start: 3.2, end: 3.9), Word(text: "good", start: 4, end: 7.5)]),
    Segment(id: 2, track: .system, speaker: "S1", start: 10, end: 14, text: "next topic", words: []),
], language: "en")
let clean = CleanTranscript(segments: [CleanSegment(id: 0, text: "We ship Friday."), CleanSegment(id: 1, text: "Sounds good."), CleanSegment(id: 2, text: "Next topic.")])

@Test func verbatimLayoutPlacesSpeakersAndTimestamps() {
    // string == "\tAnn\n00:00\tum we uh ship friday\n\tS1\n00:03\tsounds good\n00:10\tnext topic\n"
    // speakerLines names == ["Ann", "S1"]; substring(segments[0].timestamp) == "00:00"; substring(segments[0].text) == "um we uh ship friday"
}
@Test func cleanModeSkipsRemovedWords()     // segments[0] text "We ship Friday."; words' range substrings == [nil, "We", nil, "ship", "Friday."]; starts == [0, 0.6, 1, 1.5, 2.2]
@Test func changesModeMarksRemovedTokens()  // segments[0] removed substrings == ["um", "uh"]; every word has a range
@Test func positionPicksTheWordBeingSpoken() // verbatim: at 1.6 → (0, 3); at 1.45 → (0, 2), whose range is "uh"
@Test func cleanModeHighlightsNothingDuringARemovedWord() // clean: at 1.2 → (0, 2) and segments[0].words[2].range == nil
@Test func overlappingSegmentsPickTheLatestStart() // at 3.5 → (1, 0)
@Test func gapHighlightsNothing()            // at 9 → nil
@Test func segmentWithoutWordsHighlightsWhole() // at 11 → (2, nil)
@Test func cleanModeBeforeTheFirstKeptWord() // clean: at 0.2 → (0, 0) and words[0].range == nil
@Test func seekTimeFromAClick()              // offset inside "ship" → 1.5; inside segment 1's timestamp → 3; inside the "S1" speaker line → nil, and speakerLine(atOffset:) is S1's
@Test func flaggedSegmentsCarryAMarker()     // flags [Flag(offset: 11)] → segment 2's line starts "00:10 ⚑\u{FE0E}\t" and flag != nil
@Test func emptyCleanTextLeavesTheSegmentOut() // clean text "" for id 1 → segments.map(\.segmentID) == [0, 2]
@Test func previousStartGoesBackWithinTheFirstSecond() {
    let timeline = SegmentTimeline(transcript: transcript)
    #expect(timeline.previousStart(before: 10.5) == 3)
    #expect(timeline.previousStart(before: 12) == 10)
    #expect(timeline.previousStart(before: 0.5) == 0)
    #expect(timeline.nextStart(after: 3) == 10)
    #expect(timeline.nextStart(after: 10) == nil)
}
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter TranscriptLayoutTests` — expect a build failure.
- [ ] **Step 3: Implement.** `position(at:)` must not scan every segment: keep the segments sorted by start and search.
- [ ] **Step 4: Run** the focused suite — expect PASS.
- [ ] **Step 5: Commit** — `Lay out the transcript and look up the spoken word`

---

### Task 7: The playback model and remembered positions

**Depends on:** none

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Playback/PlaybackModel.swift`, `Playback/PlaybackPositions.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Storage/MuninnPaths.swift`, `Problems/Problem.swift` (and the stage tests in `ProblemTests.swift`)
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/PlaybackTests.swift`

**Interfaces:**
- Produces (`public`):
  - `struct LaneSpan: Hashable, Sendable { var start: TimeInterval; var end: TimeInterval; var speaker: String }`, `struct PlaybackLane: Hashable, Sendable { var track: Track; var spans: [LaneSpan] }`, `enum PlaybackLanes { static func lanes(for transcript: Transcript) -> [PlaybackLane] }` — one lane per track that has segments, mic first; spans sorted by start; consecutive spans of one speaker less than 0.5 s apart are merged.
  - `enum PlaybackMix: String, CaseIterable, Sendable { case both, callOnly, meOnly; var label: String; func volume(for track: Track) -> Float }` — "Both", "Call only", "Me only"; `callOnly` silences the mic, `meOnly` the call.
  - `enum Playback { static let speeds: [Float] = [1, 1.25, 1.5, 2]; static func speedLabel(_ speed: Float) -> String; static let skipInterval: TimeInterval = 15; static func skip(from time: TimeInterval, by delta: TimeInterval, duration: TimeInterval) -> TimeInterval }` — labels "1×", "1.25×", "1.5×", "2×"; `skip` clamps to `0...duration`.
  - `final class PlaybackPositions: @unchecked Sendable { init(file: URL); func position(for id: MeetingID) -> TimeInterval?; func set(_ time: TimeInterval, for id: MeetingID); func remove(_ id: MeetingID); static func resumeTime(stored: TimeInterval?, duration: TimeInterval) -> TimeInterval }` — a JSON object of meeting id → seconds, read once at init (a missing or unreadable file reads as empty), written atomically on every `set` and `remove` (creating the directory), guarded by a lock. `resumeTime`: nil, negative, or within 2 s of the end → 0; else the stored time.
  - `MuninnPaths.playbackFile` = `state/playback.json`.
  - `ProblemStage.playingRecording`: phrase "playing the recording", area `.recording`.

- [ ] **Step 1: Write the failing tests** (`PlaybackTests`):

```swift
@Test func lanesMergeASpeakersCloseSpans() {
    // mic you 0–4; system S1 3–8, S1 8.3–9, S2 10–14 → [mic: [0–4 you], system: [3–9 S1, 10–14 S2]]
}
@Test func micOnlyMeetingHasOneLane()
@Test func mixVolumes() // both: 1/1; callOnly: mic 0, system 1; meOnly: mic 1, system 0; labels
@Test func speedLabels() // ["1×", "1.25×", "1.5×", "2×"]
@Test func skipClamps() // skip(from: 5, by: -15, duration: 100) == 0; skip(from: 95, by: 15, duration: 100) == 100
@Test func positionsPersistAcrossInstances() // set 42 for "a" → a new PlaybackPositions(file:) reads 42
@Test func removeForgetsAPosition()
@Test func damagedFileReadsEmpty() // file holds "{not json" → position(for:) nil; set(5) then a new instance reads 5
@Test func resumeRule() {
    #expect(PlaybackPositions.resumeTime(stored: 50, duration: 100) == 50)
    #expect(PlaybackPositions.resumeTime(stored: 99, duration: 100) == 0)
    #expect(PlaybackPositions.resumeTime(stored: 120, duration: 100) == 0)
    #expect(PlaybackPositions.resumeTime(stored: -4, duration: 100) == 0)
    #expect(PlaybackPositions.resumeTime(stored: nil, duration: 100) == 0)
}
@Test func playbackFileIsInTheStateDirectory()
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter PlaybackTests` — expect a build failure.
- [ ] **Step 3: Implement**, and add `playingRecording` wherever `ProblemTests` enumerates the stages.
- [ ] **Step 4: Run** `--filter PlaybackTests` and `--filter ProblemTests` — expect PASS.
- [ ] **Step 5: Commit** — `Add the playback model and remembered positions`

---

### Task 8: Move a meeting to the Trash in the store

**Depends on:** Task 7

**Files:**
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Storage/MeetingStore.swift`, `Problems/Problem.swift` (and `ProblemTests.swift`)
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/StorageTests.swift`

**Interfaces:**
- Produces (`public`):
  - `MeetingStore.moveToTrash(_ id: MeetingID) throws` — moves the whole meeting folder with `trashItem`; a missing folder is not an error. `var trashItem: (URL) throws -> Void` defaults to `{ try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }`; tests replace it.
  - `ProblemStage.trashingMeeting`: phrase "moving the meeting to the Trash", area `.app`.

- [ ] **Step 1: Write the failing tests** (in `StorageTests`; the fake `trashItem` moves the folder into a temporary "Trash" directory):

```swift
@Test func trashedMeetingLeavesTheList()   // create, save a transcript and a recap, write audio/mic.caf bytes; moveToTrash → list() hasn't it, exists(id) false
@Test func putBackMeetingIsListedIntact()  // move the folder back from the fake Trash → list() has it; loadTranscript, loadSummary non-nil; the audio file is there
@Test func trashingAMissingMeetingDoesNothing()
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter StorageTests` — expect a build failure.
- [ ] **Step 3: Implement**, and add `trashingMeeting` wherever `ProblemTests` enumerates the stages.
- [ ] **Step 4: Run** `--filter StorageTests` and `--filter ProblemTests` — expect PASS.
- [ ] **Step 5: Commit** — `Move meetings to the Trash in the store`

---

### Task 9: The playback composition

**Depends on:** Task 7

**Files:**
- Create: `Packages/MuninnPlatform/Sources/MuninnAudio/PlaybackComposition.swift`
- Test: `Packages/MuninnPlatform/Tests/MuninnAudioTests/PlaybackCompositionTests.swift`

**Interfaces:**
- Consumes: `PlaybackMix`, `Track`.
- Produces (`public`): `final class PlaybackComposition: @unchecked Sendable { let composition: AVComposition; let duration: TimeInterval; let tracks: [Track]; static func load(mic: URL?, system: URL?) async throws -> PlaybackComposition?; func audioMix(_ mix: PlaybackMix) -> AVAudioMix }`.
  - `load`: for each given URL whose file exists, loads its first audio track with `AVURLAsset` (`load(.tracks)`, `load(.duration)`); a file with no audio track or zero duration counts as missing; a file that fails to load is skipped (logged with `os.Logger`, subsystem `AppIdentity.bundleIdentifier`, category "playback"). Each kept track is inserted at time zero in its own composition track, mic first. Nil when no file is kept and none failed; throws the first load error when every existing file failed. `duration` is the longest kept track's.
  - `audioMix`: one `AVMutableAudioMixInputParameters` per composition track, volume `mix.volume(for:)`.

- [ ] **Step 1: Write the failing tests**, writing CAF files with `TrackWriter` (mic: 16 kHz mono, 2.0 s of a 440 Hz sine; system: 48 kHz stereo interleaved, 1.0 s):

```swift
@Test func bothTracksStartAtZero() async throws // tracks == [.mic, .system]; each composition track's first segment's target start == .zero
@Test func shorterTrackDoesNotShortenPlayback() async throws // duration ≈ 2.0 (± 0.01)
@Test func micOnlyMeetingPlaysOneTrack() async throws // system: nil → tracks == [.mic]
@Test func missingFilesMeanNoRecording() async throws // two URLs that don't exist → nil
@Test func emptyFileCountsAsMissing() async throws // a mic file with zero frames written, valid system → tracks == [.system]
@Test func unreadableFileIsSkipped() async throws // mic holds random bytes, valid system → tracks == [.system]
@Test func allUnreadableThrows() async throws // both hold random bytes → throws
@Test func mixSilencesTheOtherTrack() async throws // audioMix(.callOnly): the mic track's volume ramp at .zero is 0, the system's 1
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnPlatform --filter PlaybackCompositionTests` — expect a build failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the focused suite — expect PASS.
- [ ] **Step 5: Commit** — `Build the two-track playback composition`

---

### Task 10: Move to Trash and Reload in the app

**Depends on:** Tasks 2, 7, 8

**Files:**
- Modify: `Muninn/Services.swift` (`Alerts`), `Muninn/AppModel.swift`, `Muninn/AppModel+Meetings.swift`, `Muninn/AppModel+Obsidian.swift`, `Muninn/MuninnApp.swift`, `Muninn/Views/MainWindow.swift`, `Muninn/Views/MeetingDetail.swift`, `Muninn/Views/SettingsView.swift`

**Interfaces:**
- `Alerts.ask(_ message: String, _ detail: String, buttons: [String], destructive: Int? = nil) -> Int` replaces `destructiveFirst:`; the button at `destructive` gets `hasDestructiveAction`. Existing callers pass `destructive: 0`.
- `AppModel.playbackPositions: PlaybackPositions` (from `paths.playbackFile`, created in `init`).
- `AppModel.commandContext(for meeting: Meeting, hasRecap: Bool = false) -> MeetingCommandContext` (progress from `progress(for:)`, previous recap from `store.hasPreviousSummary`, unsaved edits from `unsavedSummaries`, event change from `eventChangesInFlight`).
- `AppModel.trashMeeting(_ id: MeetingID)` replaces `deleteMeeting`: the same refusal (`canDelete` and `pipeline.hasJob`), with the alert "This meeting can't be moved to the Trash yet" / "It is still recording or being processed. Try again once it has finished." Then it asks "Move “\(title)” to the Trash?" with "You can put it back from the Trash in Finder, with its recording, transcript and recap." plus, when `exportedNotePath` is set, " The note in Obsidian stays, but its links to the recording and transcript stop working until you put the meeting back." Buttons `["Cancel", "Move to Trash"]`, `destructive: 1`; only 1 proceeds, so Return and Escape cancel. It re-checks the refusal, calls `store.moveToTrash`, records info, area `.app`, "Moved to the Trash" for the meeting, and clears what `deleteMeeting` cleared plus `playbackPositions.remove(id)`. A failure is `report(error, stage: .trashingMeeting, for: id)`.
- `reloadMeetings()` removes every listed id from `deletedIDs`, so a meeting put back from the Trash takes edits and pipeline updates again, and bumps `@Published private(set) var reloadRevision = 0`. `MeetingDetail`'s load key and the sidebar's search key include `reloadRevision`, so a reload re-reads the selected meeting's recap, transcript and clean transcript and the search texts.
- `MeetingsCommands: Commands { let model: AppModel }` adds `CommandGroup(after: .toolbar) { Button("Reload") { model.reloadMeetings() } }`, attached to the Meetings window scene.
- The sidebar's context menu and the header's menu offer "Move to Trash…", disabled with `.help` from `MeetingCommands.disabledReason(.moveToTrash, …)`.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Run** `mise exec -- xcodegen generate` and the app build — expect PASS.
- [ ] **Step 3: Run** `rg -n 'deleteMeeting|Delete Meeting|destructiveFirst' Muninn` — expect no output.
- [ ] **Step 4: Commit** — `Move meetings to the Trash and reload them from the View menu`

---

### Task 11: The window, its toolbar and tabs

**Depends on:** Tasks 2, 10

**Files:**
- Create: `Muninn/Meetings/MeetingToolbar.swift`
- Modify: `Muninn/MuninnApp.swift`, `Muninn/Views/MainWindow.swift`, `Muninn/Views/MeetingDetail.swift`, `Muninn/Views/SummaryEditor.swift`, `Muninn/AppModel.swift`

**Interfaces:**
- Consumes: `MeetingCommands`, `AppModel.commandContext(for:hasRecap:)`, `TranscriptMode`.
- Produces:
  - The Meetings window: `.defaultSize(width: 1180, height: 780)`; `MainWindow` content `frame(minWidth: 820, minHeight: 560)`; sidebar `navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 320)`.
  - `enum DetailTab: String, CaseIterable, Identifiable { case recap, transcript; var label: String }` — "Recap", "Transcript". `MainWindow` owns `@State tab` and `@State transcriptMode = TranscriptMode.clean` and passes them to `MeetingDetail` as bindings, so they survive switching meetings.
  - `MeetingToolbar: ToolbarContent` (attached by `MeetingDetail` with `.toolbar`):
    - principal: a segmented `Picker` of `DetailTab` (accessibility label "View").
    - the engine `Menu`, labelled with the recap's engine (`summary?.engine ?? meeting.summaryEngine`)`.displayName`, or "Write recap" when there is none; its content is `Section("Write the recap with")` and one button per `EngineKind` calling `model.regenerate(id, engine:)`, Claude's with the second line "Sends the transcript off the Mac to Anthropic". Disabled with the `regenerate` reason; `.help` is the reason or "Write the recap again with another engine".
    - "Outlook draft" (`envelope`) → `model.createDraft(id)` (Task 13 makes it open the sheet), disabled with the `outlookDraft` reason.
    - "Obsidian" (`tray.and.arrow.down`) → `model.exportToObsidian(id)`, disabled with the `obsidian` reason.
    - a `…` `Menu` (`ellipsis.circle`, accessibility label and help "More"): "Previous version" (disabled with the `previousVersion` reason) and, after a divider, "Move to Trash…" (disabled with the `moveToTrash` reason).
  - `MeetingDetail`: `.navigationTitle(meeting.title)`; the empty state's title "Meetings". Its tab-picker row goes away, and so does `SummaryEditor`'s toolbar row (engine menu, Restore Previous Recap, draft and Obsidian buttons); "Previous version" calls the existing `restorePrevious`. The header's `…` menu goes away (its item is in the toolbar's). The "Unsaved summary changes" label becomes "Unsaved recap changes" at the top of the recap.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Run** `mise exec -- xcodegen generate` and the app build — expect PASS.
- [ ] **Step 3: Run** `rg -n 'Written by: |Restore Previous Recap|✉|◆' Muninn` — expect no output.
- [ ] **Step 4: Commit** — `Give the Meetings window a toolbar for the recap, transcript and actions`

---

### Task 12: The sidebar

**Depends on:** Tasks 1, 11

**Files:**
- Create: `Muninn/Meetings/Sidebar.swift`, `Muninn/Design/Chips.swift`
- Modify: `Muninn/Views/MainWindow.swift`

**Interfaces:**
- Consumes: `MeetingGrouping`, `MeetingLabels.sidebarTime`, `SidebarSign`, `MeetingSearch`, `ProcessingDisplay.needsAttention`.
- Produces:
  - `Chip(text: String)` in `Design/Chips.swift`: `Theme.meta` in `Theme.secondaryText` on `Theme.neutralSoft`, radius `Radius.chip`, one line.
  - `Sidebar` (the sidebar column, moved out of `MainWindow`):
    - Smart lists above the meetings: "All meetings" (`tray.full`) and "Needs attention" (`exclamationmark.circle`, with its count when above zero), as buttons setting `model.sidebarFilter`; the selected one on `Theme.accentSoft` (radius `Radius.card`) with `.accessibilityAddTraits(.isSelected)`. They replace the segmented picker.
    - Day sections titled `DayGroup.title`; each row: the title (`Theme.interface`, semibold, one line), then `MeetingLabels.sidebarTime(… group: …)` in `Theme.meta`/`Theme.secondaryText` and the client as a `Chip`, and one sign at the trailing edge: `.progress` → the mini circular ring of `step / 4`; `.queued` → the mini indeterminate spinner; `.attention` → the 8-pt `Theme.attentionFill` dot; `.recording` → `record.circle` in `Theme.recording`; `.draftCreated` / `.filed` → "Draft created" / "Filed" in `Theme.meta`/`Theme.tertiaryText`. Every sign has `.help` and an accessibility label (the stage title, "Waiting its turn", "Needs attention", "Recording", "Draft created", "Filed").
    - Search (`.searchable(placement: .sidebar, prompt: "Search meetings")`) filters with `MeetingSearch.matches`. While the query is not empty, a detached task loads for every meeting its recap text (`MeetingSearch.recapText`) and its transcript text (`transcript.clean.md`, else `transcript.md`, read as text), keyed as today by id, status and engine, plus `reloadRevision`; a file that can't be read counts as empty.
    - The context menu from Task 10.
    - The empty texts stay: "No matches", "Nothing needs attention", "No meetings yet".

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Run** `mise exec -- xcodegen generate` and the app build — expect PASS.
- [ ] **Step 3: Commit** — `Show smart lists, richer rows and full-text search in the sidebar`

---

### Task 13: The Outlook draft sheet and the success cards

**Depends on:** Tasks 2, 11

**Files:**
- Create: `Muninn/Meetings/DraftSheet.swift`
- Modify: `Muninn/AppModel.swift`, `Muninn/AppModel+Meetings.swift`, `Muninn/AppModel+Obsidian.swift`, `Muninn/Views/MeetingDetail.swift`, `Muninn/Meetings/MeetingToolbar.swift`

**Interfaces:**
- Consumes: `MeetingCommands.draftRefusal`, `RecapEmail.subject`, `MeetingActions.setIncluded`, `MeetingActions.addRecipient`, `StatusCard`, `ProblemCard`.
- Produces:
  - `enum ActionSuccess: Equatable { case draftCreated(URL?), filed(URL) }`; `@Published var actionSuccesses: [MeetingID: ActionSuccess]`, cleared when `perform` starts for the meeting, when dismissed, and by `trashMeeting`.
  - `enum UnsourcedChoice { case include, review, cancel }`; `confirmUnsourcedItems(_:for:) -> UnsourcedChoice` (export treats anything but `.include` as not filing, as today).
  - `enum DraftOutcome { case created, cancelled, review, failed }`; `func createDraft(_ id: MeetingID, subject: String? = nil) async -> DraftOutcome` replaces `createDraft(_:)`: the same checks, the same "A draft already exists" question and unsourced question; `subject` nil means `RecapEmail.subject`. On success it opens the link as today and sets `.draftCreated(link)`. `retryAction` runs it with no subject.
  - `export` sets `.filed(vault.appendingPathComponent(path))` once the note is written (manual and automatic filing).
  - `DraftSheet(meeting: Meeting, summary: Summary?)`, opened by the toolbar's "Outlook draft": the title "Outlook draft"; "From" and the account's display name, or "Choose an account in the meeting's details" in `Theme.attentionText`; the recipients as checkbox rows (name, address in secondary) with the search-or-type field and its candidates (the header's `RecipientsEditor`, moved here unchanged in behaviour, then removed from the header); a "Subject" field starting at `RecapEmail.subject(title:date:timeZone:)`; a read-only preview of the recap (subject titles, bullets, and "Owner: text (due)" action lines) in a scroll view; when `model.actionErrors[id]` is set, a compact `ProblemCard`; "Cancel" (`.cancelAction`) and "Create draft" (`.defaultAction`), disabled with `draftRefusal` as its `.help`, showing a small spinner and "Creating…" while it runs. `.created` and `.review` close the sheet; `.cancelled` and `.failed` keep it open. Minimum size 520×480.
  - `MeetingDetail` shows `actionSuccesses[id]` as `StatusCard(role: .success)`, dismissible: "Draft created" with "Open in Outlook" when there is a link; "Filed in Obsidian" with "Reveal" (`NSWorkspace.shared.activateFileViewerSelecting`).

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Run** `mise exec -- xcodegen generate` and the app build — expect PASS.
- [ ] **Step 3: Run** `rg -n 'RecipientsEditor' Muninn` — expect matches only in `Muninn/Meetings/DraftSheet.swift`.
- [ ] **Step 4: Commit** — `Choose recipients in an Outlook draft sheet, and confirm drafts and filed notes`

---

### Task 14: The header

**Depends on:** Tasks 1, 2, 3, 13

**Files:**
- Create: `Muninn/Meetings/MeetingHeader.swift`, `Muninn/Meetings/HeaderChips.swift`
- Modify: `Muninn/Views/MeetingDetail.swift` (the header and `ChangeEventButton` move out), `Muninn/Views/Formatting.swift` (`CommitTextField`), `Muninn/Design/Chips.swift`

**Interfaces:**
- Consumes: `MeetingLabels.meta`, `MeetingLabels.detailsChip`, `PersonLabel`, `SpeakerColours.personIndex`, `Theme.speaker`, `MeetingActions.accountChangeDropsEvent`, `MeetingActions.clearingEventLosesDetails`, `MeetingActions.canChangeEvent`, `model.eventsAround`, `model.chooseEvent`, `model.dismissEventChoice`.
- Produces:
  - `Token(label: String, systemImage: String?, role: Token.Role = .normal)` in `Design/Chips.swift` (`enum Role { case normal, attention, placeholder }`): `Theme.meta` on `Theme.neutralSoft` (attention: `Theme.attentionText` on `Theme.attentionSoft`; placeholder: `Theme.tertiaryText`), radius `Radius.chip`; a button style for opening popovers.
  - `PersonChip(name: String, email: String)`: an 18-pt circle in `Theme.speaker(SpeakerColours.personIndex(…))` with the initials (10 pt semibold, `Theme.contentBackground`), then the short name; `.help` the full name and address; accessibility label the full name.
  - `CommitTextField` also commits in `.onDisappear`.
  - `MeetingHeader`:
    - The title: a plain `CommitTextField` in `Theme.meetingTitle` (an empty title is ignored, as today).
    - One meta line: `MeetingLabels.meta(...)` (current calendar and locale) in `Theme.meta`/`Theme.secondaryText`, then the status label ("Needs attention" in `Theme.attentionText`, or the progress title), as today.
    - One row of chips:
      - `EventChip`: "Which event was this?" (attention) while there are candidate events; "Calendar event" (`calendar`) with an association; "No event" otherwise. A popover lists the candidate events first, then "Events around \(time)" from `eventsAround` without the candidates (the current one in semibold), each failure as a compact `ProblemCard` (as `ChangeEventButton` does today), and "No event". "No event" asks first when `clearingEventLosesDetails`: "Remove the event from this meeting?" / "The title and attendees came from the event and are cleared. Recipients you added stay." with `["Remove event", "Cancel"]`, `destructive: 0`. When `canChangeEvent` is false the chip doesn't open, with `.help` "The event can't be changed once a draft or note exists". It is disabled while the event is changing.
      - `DetailsChip`: `MeetingLabels.detailsChip(accountName:client:)`, where a removed account reads "Account removed" (attention role); a popover with the account `Picker` (None, the removed account, the accounts) and the client field. When `accountChangeDropsEvent(meeting, to: new)`, it asks first: "Change the account to \(new name)?" (or "Remove the account from this meeting?" for None) / "This meeting's calendar event is in \(old name). Changing the account removes the event from the meeting; its title and attendees stay." with `["Change account", "Cancel"]`; Cancel leaves the picker as it was.
      - Person chips for the attendees that are not resources, the first four, then "+\(n)" with `.help` listing the others' names.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Run** `mise exec -- xcodegen generate` and the app build — expect PASS.
- [ ] **Step 3: Commit** — `Show the meeting header as a title, a meta line and chips`

---

### Task 15: The recap editor with undo

**Depends on:** Tasks 1, 4, 11, 14

**Files:**
- Create: `Muninn/Meetings/RecapEditor.swift`, `Muninn/Meetings/RecapTokens.swift`
- Delete: `Muninn/Views/SummaryEditor.swift`
- Modify: `Muninn/Views/MeetingDetail.swift`, `Muninn/Views/Formatting.swift` (`DueDate.label`)

**Interfaces:**
- Consumes: `RecapDocument`, `RecapField`, `Timestamp.format`, `Token`, `SectionLabel`, `MeetingCommands` (`previousVersion`).
- Produces:
  - `MeetingDetail` holds `@State document: RecapDocument?`, created when the recap loads, with `save` calling the existing `saveSummary`; a later load from disk (the load task's key changed, `reloadRevision` included) or `restorePrevious` calls `document.replace(with:undoManager:)`. `@Environment(\.undoManager)` is passed to every document call. On disappear it calls `endTyping` and `undoManager?.removeAllActions(withTarget: document)`.
  - `RecapEditor(meeting:, document:, summary:, segmentStarts: [Int: TimeInterval], canPlay: Bool, onSource: (Int) -> Void, onPreviousVersion: () -> Void, previousVersionReason: String?)`, in a `ScrollView`, centred at most `Theme.readingWidth` wide:
    - A subject's title is a plain field in `Theme.subject`; its bullets are "•" and a plain multi-line field in `Theme.reading`; when it has actions, an "Actions" `SectionLabel` over them. An action row: a decorative `square` marker (hidden from accessibility), the text field, the owner token and the due token, then the source marks.
    - Text fields go through `RecapTextField(field: RecapField, …)`, calling `document.type` on every change and `document.endTyping` on submit, on losing focus and on disappearing.
    - A remove button (`minus.circle`, accessibility label and help "Remove subject" / "Remove bullet" / "Remove action") shows while the row is hovered; removing is immediate, through `document.edit` with the names from Task 4. "Add bullet", "Add action" and "Add subject" are quiet borderless buttons.
    - The owner token shows the owner, or "Owner" (placeholder role) while hovered; its popover edits it as `type(.actionOwner)`. The due token shows "Due \(day month)" for a valid date (`DueDate.label`), the text in the attention role ("“\(due)” isn't a date") for an invalid one, or "Due date" while hovered; its popover holds a graphical `DatePicker` and "No due date", each an `edit("Change due date")`.
    - `SourceMark` (mono `Timestamp.format(start)` on `Theme.accentSoft`, radius `Radius.chip`, with a `play.fill` glyph when `canPlay`): `.help` and accessibility label "Play from \(time)" when `canPlay`, else "Show in the transcript"; it calls `onSource(id)`. A source missing from `segmentStarts` shows no mark (ruling 20). An item with no sources shows "No source in the transcript" with `exclamationmark.triangle` in `Theme.attentionText`/`Theme.meta`.
    - A quiet footer: "Written by \(engine) · \(generatedAt, abbreviated date and short time)" and, when a previous version exists, " · " and a link-styled "Previous version" button, disabled with `previousVersionReason` as `.help`.
    - "No recap yet." when the meeting is ready without one.
  - `canPlay` is false in this task; `onSource` keeps today's behaviour (switch to the Transcript tab and scroll to the segment).

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Run** `mise exec -- xcodegen generate` and the app build — expect PASS.
- [ ] **Step 3: Run** `rg -n '(Text|Button|Label|help|TextField)\("[^"]*[Ss]ummar' Muninn` — expect no output.
- [ ] **Step 4: Commit** — `Edit the recap as text, with tokens, timestamps and undo`

---

### Task 16: The transcript as one text flow

**Depends on:** Tasks 3, 6, 11

**Files:**
- Create: `Muninn/Meetings/TranscriptTextView.swift`
- Delete: `Muninn/Views/TranscriptView.swift`
- Modify: `Muninn/Views/MeetingDetail.swift`, `Muninn/Meetings/MeetingToolbar.swift`, `Muninn/AppModel+Meetings.swift`

**Interfaces:**
- Consumes: `TranscriptLayout`, `TranscriptMode`, `SpeakerColours.indices`, `Theme.AppKit`, `FlagCoverage`.
- Produces:
  - `AppModel.renameSpeaker(_ speaker: String, to name: String, in id: MeetingID, transcript: Transcript, clean: CleanTranscript?) throws` — `TranscriptView.rename`'s logic, moved.
  - `@MainActor final class TranscriptController: ObservableObject { @Published var following = true; func showFind(); func copyAll(); func reveal(segmentID: Int) }` — owned by `MeetingDetail` (`@StateObject`), holding a weak reference to the text view and the current layout. `reveal` scrolls the segment to the centre and tints its text with `Theme.AppKit.accentSoft` for 2 s; called before the text view and its layout are attached (the tab has only just switched), it is kept as a pending request and carried out when they attach.
  - `TranscriptTextView: NSViewRepresentable` (`meeting`, `transcript`, `clean`, `mode`, `controller`, `onRename`, `onSeek: (TimeInterval) -> Void`):
    - An `NSScrollView` subclass that reports user scrolling (`scrollWheel(with:)` and `willStartLiveScrollNotification`) holding an `NSTextView` built on TextKit 1 (`NSTextStorage` → `NSLayoutManager` with `allowsNonContiguousLayout = true` → `NSTextContainer`): not editable, selectable, `usesFindBar = true`, `isIncrementalSearchingEnabled = true`, no background.
    - The string and ranges come from `TranscriptLayout.make`, rebuilt only when the transcript, clean transcript, mode, speaker names, user name or flags change. Attributes: the paragraph style puts the text column 64 pt in (a tab stop and `headIndent` at 64), 6 pt between paragraphs and 12 pt before a speaker line; speaker lines semibold 13 pt in `Theme.AppKit.speaker(index)`; timestamps `Theme.mono` in `secondaryText` (flagged: `attentionText`, with the flag marker); text `Theme.reading` in `primaryText`; removed tokens in `secondaryText` with a single strikethrough. The text column is at most `Theme.readingWidth` plus the margin, centred. After a rebuild, the segment that was at the top stays at the top.
    - A click that selects nothing (`mouseDown` after `super`, selection length 0) on a speaker line opens the rename popover at the name (an `NSPopover` hosting `SpeakerRenameForm`, the old `SpeakerButton` popover moved into this file: "Rename \(name)", the field, "Cancel" and "Save") calling `onRename`; anywhere else it calls `onSeek(layout.seekTime(atOffset:))` when that is not nil.
  - The toolbar, on the Transcript tab, adds before the engine menu: a segmented `Picker` of `TranscriptMode` (accessibility label "Transcript view"; "Changes" has `.help` "Show changes"), "Search" (`magnifyingglass`, `.keyboardShortcut("f")`, making the text view first responder, then `showFindInterface`) and "Copy all" (`doc.on.doc`; reads "Copied" for 2 s).
  - With no transcript: `ContentUnavailableView("No transcript yet", systemImage: "text.alignleft")`. `onSeek` does nothing in this task. The recap's `onSource` switches to the Transcript tab and calls `controller.reveal(segmentID:)`.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Run** `mise exec -- xcodegen generate` and the app build — expect PASS.
- [ ] **Step 3: Run** `rg -n '🚩|TranscriptView\(' Muninn` — expect no output.
- [ ] **Step 4: Commit** — `Show the transcript as one selectable text flow with find and copy all`

---

### Task 17: The player

**Depends on:** Tasks 7, 9, 12, 16

**Files:**
- Create: `Muninn/Playback/MeetingPlayer.swift`, `Muninn/Playback/PlayerBar.swift`
- Modify: `Muninn/AppModel.swift`, `Muninn/AppModel+Meetings.swift`, `Muninn/MuninnApp.swift`, `Muninn/Views/MainWindow.swift`, `Muninn/Views/MeetingDetail.swift`, `Muninn/Meetings/Sidebar.swift`

**Interfaces:**
- Consumes: `PlaybackComposition`, `PlaybackPositions`, `PlaybackMix`, `Playback`, `PlaybackLanes`, `SpeakerColours.indices`, `Timestamp.format`, `ProblemTranslator`, `ActivityCenter`.
- Produces:
  - `@MainActor final class PlaybackClock: ObservableObject { @Published private(set) var time: TimeInterval = 0; func update(_ time: TimeInterval) }` — the only thing published at 30 Hz; `update` publishes only when the value changed.
  - `@MainActor final class MeetingPlayer: ObservableObject` with `enum State: Equatable { case idle, loading, unavailable, failed(Problem), ready }`; published `meetingID: MeetingID?`, `state`, `isPlaying`, `duration`, `tracks: [Track]`, `hasStarted: Bool` (playback began for this meeting in this session), `speed: Float = 1`, `volume: Float = 1`, `mix = PlaybackMix.both`; `let clock = PlaybackClock()`; `var timeline: SegmentTimeline?`; `init(positions: PlaybackPositions, store: MeetingStore, activity: ActivityCenter)`; `func load(_ meeting: Meeting?)`, `play()`, `pause()`, `toggle()`, `seek(to: TimeInterval, play: Bool = false)`, `skip(by: TimeInterval)`, `stop()`, `unload(_ id: MeetingID)`.
    - `load`: a meeting that is recording leaves the player `.idle` with no composition (its files are still being written). A call for the meeting already loaded does nothing while that load is `.loading` or `.ready` and was not made while it recorded; in every other case it loads again, so a meeting selected during its recording loads once the recording stops, and an `.unavailable` or `.failed` one is retried. Loading another meeting first pauses and saves the current position, then loads `PlaybackComposition.load(mic:system:)` from `store.audioURL`; the newest load wins if several overlap. Nil → `.unavailable`; a throw → `.failed` with `ProblemTranslator.problem(for:in: ProblemContext(stage: .playingRecording))`, recorded once per meeting in Activity; success → an `AVPlayerItem` with `audioTimePitchAlgorithm = .timeDomain` and the mix, then a seek to `PlaybackPositions.resumeTime(stored:duration:)` and `.ready`.
    - A periodic time observer every 1/30 s calls `clock.update`, as do seeks and loads; every 10 s of playing the position is saved; reaching the end stops playing and saves.
    - `speed` sets `defaultRate` and, while playing, `rate`; `volume` sets the player's volume; `mix` sets the item's audio mix. Seeks use zero tolerance. `play` sets `hasStarted`.
    - `pause`, `seek` and `stop` save the position; `stop` also unloads.
  - `AppModel.player: MeetingPlayer`, created in `init`. `MainWindow` calls `player.load` for the selected meeting on appear, on selection change (switching meeting pauses) and when the selected meeting's status leaves `.recording` (a `.task(id:)` keyed by the id and whether it is recording), and `player.stop()` on disappear (closing the window stops). `trashMeeting` calls `player.unload(id)`. The player goes to the views with `.environmentObject(model.player)`.
  - `PlayerBar`, docked under the meeting with `.safeAreaInset(edge: .bottom)` on both tabs, unless the meeting is recording; on `.bar` material with a divider on top:
    - `.unavailable`: the quiet line "The recording for this meeting isn't available." (`Theme.meta`, `Theme.secondaryText`). `.failed`: a compact `ProblemCard` with Show in Activity. `.loading`: the controls, disabled.
    - Above the scrubber, the lanes in a `Canvas` (one 6-pt row per `PlaybackLanes` lane, spans in `Theme.speaker(index)`), with the flags as 2-pt ticks in `Theme.attentionFill` and the playhead; accessibility label "Speakers over time".
    - The scrubber (`Slider` over `0...duration`, seeking when a drag ends), the elapsed time and "−" remaining time in `Theme.mono`.
    - Buttons with accessibility labels and help: "Back 15 seconds" (`gobackward.15`), "Play" / "Pause" (`play.fill` / `pause.fill`), "Forward 15 seconds" (`goforward.15`); a speed `Menu` ("1×" … "2×", accessibility label "Speed"); the volume (`speaker.wave.2` and a `Slider`, accessibility label "Volume"); when both tracks exist, a Mix `Menu` ("Both", "Call only", "Me only", accessibility label "Mix").
    - Only the subviews showing the time observe `clock`; `PlayerBar` itself, `MeetingDetail` and the recap observe `player` only.
  - The sidebar row of `player.meetingID` shows, while `isPlaying`, `waveform` in `Theme.accent` with `.symbolEffect(.variableColor.iterative)`, accessibility label "Playing", before its sign.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Run** `mise exec -- xcodegen generate` and the app build — expect PASS.
- [ ] **Step 3: Run** `rg -n 'clock' Muninn/Meetings/RecapEditor.swift Muninn/Views/MeetingDetail.swift` — expect no output.
- [ ] **Step 4: Commit** — `Play a meeting's recording from a player docked under the meeting`

---

### Task 18: Read along, click to listen and the playback keys

**Depends on:** Tasks 15, 16, 17

**Files:**
- Create: `Muninn/Playback/PlaybackKeys.swift`
- Modify: `Muninn/Meetings/TranscriptTextView.swift`, `Muninn/Views/MeetingDetail.swift`, `Muninn/Views/MainWindow.swift`

**Interfaces:**
- Consumes: `TranscriptLayout.position(at:)`, `SegmentTimeline`, `MeetingPlayer`, `PlaybackClock`, `Playback.skip`, `Timestamp.format`.
- Produces:
  - Read along: while `player.meetingID == meeting.id` and `player.hasStarted`, the text view's coordinator follows `clock.$time` (a Combine sink, not a SwiftUI update) and, when `position(at:)` changes, moves two temporary background attributes: the segment's text range in `Theme.AppKit.accentSoft` and, when the word has a range, that range in `Theme.AppKit.accentMid`. Nothing else is redrawn. When the text view attaches or its layout is rebuilt, it applies the current position at once.
  - Following: while `controller.following`, a current segment outside the middle of the visible rect is scrolled to the centre. A user scroll while playing sets `following = false`, and a "Back to \(Timestamp.format(time))" button appears at the bottom trailing corner of the transcript (a small view in `TranscriptTextView.swift`, the only one there observing `clock`); it sets `following = true` and scrolls. Any seek sets `following = true`.
  - Click to listen: `onSeek` calls `player.seek(to: time, play: true)` when the player is `.ready` for this meeting.
  - Source marks: `canPlay` is true when the player is `.ready` for this meeting; a click then switches to the Transcript tab, seeks to the segment's start, plays and follows. Without audio it keeps Task 16's reveal.
  - `MeetingDetail` sets `player.timeline = SegmentTimeline(transcript:)` when the transcript loads.
  - `PlaybackKeys`: a background `NSViewRepresentable` in `MainWindow` that, while its window exists, installs a local `keyDown` monitor. It acts only on events for that window, only while the player is `.ready`, never with ⌘, ⌥ or ⌃ held, and not when the first responder is editable text (an `NSTextView` with `isEditable`, which covers every field editor). Space toggles playback; ← and → skip ∓15 s; ⇧← seeks to `timeline.previousStart(before:)`, ⇧→ to `timeline.nextStart(after:)` when there is one. It returns nil for the events it handled.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Run** the app build — expect PASS.
- [ ] **Step 3: Commit** — `Follow playback in the transcript, play from a click, and add the playback keys`

---

### Task 19: Changelog, records and final verification

**Depends on:** Tasks 1–18

**Files:**
- Modify: `CHANGELOG.md`, `docs/superpowers/plans/2026-11-04-muninn-ux-meetings-window.md` (tick boxes)

- [ ] **Step 1:** Add under `## [Unreleased]`:

```markdown
### Added

- Listen back to a meeting: a player under the meeting plays the recording, and the transcript
  follows along, highlighting the passage and the word being spoken. Click a sentence or a
  recap source to play from there.
- Every recap edit can be undone with ⌘Z, including removing a subject, bullet or action.
- Find in the transcript (⌘F) highlights every match, and Copy all copies the whole transcript.

### Changed

- The Meetings window has a toolbar for the recap, the transcript, the engine, the Outlook draft
  and Obsidian, and a calmer header, recap and transcript.
- Recipients are chosen in the Outlook draft sheet, which also shows the subject and a preview.
- Meetings move to the Trash instead of being deleted, so they can be put back from Finder;
  View › Reload picks them up again.
- Sidebar search also looks in recaps and transcripts, and each row shows the time, duration,
  client and status.
- Recap sources show the time in the transcript instead of a segment number.
```

- [ ] **Step 2: Run** the full verification, all must pass, and record the totals as passed/total: the Core suite, the Platform suite, `mise exec -- xcodegen generate`, the app build, the searches from Tasks 10, 11, 15, 16 and 17, `rg -n 'localizedDescription|String\(describing: error\)' Muninn | rg -v 'logger\.'` (expect no output), and `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'`.
- [ ] **Step 3:** `rm -rf build/adhoc` (no ad hoc copy may outlive the run: see AGENTS.md on permissions).
- [ ] **Step 4: Commit** — `Add the changelog entries for the Meetings window`

## Manual acceptance (the owner, on his Mac)

Signed Debug build installed in `/Applications`, started with `open`:

1. Record a call with both sides talking; open it: the player plays both tracks in sync; at 1× and 2× the highlighted word matches the audio within about 150 ms; the speed keeps natural pitch; Call only and Me only each silence the other side (acceptance 5).
2. Click a recap source mark: the Transcript tab opens at that moment and plays. Click a sentence: it plays from there. Scroll away while playing: "Back to …" appears and playback continues. Space, ←, →, ⇧← and ⇧→ work, and don't while typing in a recap field (acceptance 5).
3. Switch tabs while playing: playback continues. Switch meetings: it pauses; come back: it resumes from the same place, also after quitting and reopening Muninn. Keep a meeting selected while it records: when the recording stops, its player appears.
4. Remove a bullet, an action and a subject; ⌘Z three times restores each. Type into a bullet: ⌘Z while still in the field undoes the typing; type again, click elsewhere, ⌘Z: the typing undoes as one step, and the next ⌘Z undoes the edit before it (acceptance 6).
5. Move a meeting to the Trash, put it back from Finder, choose View › Reload: it is back with its recording, transcript and recap; edit its recap: the edit is kept (acceptance 6).
6. Outlook draft: the sheet shows the account, the recipients and a preview; Create draft shows progress, opens the draft and leaves "Draft created · Open in Outlook". Obsidian files in one click and shows "Filed in Obsidian · Reveal".
7. ⌘F in the transcript highlights every match; a selection can run across speakers; Copy all pastes the whole transcript.
8. Light and dark: the header, recap, transcript highlight, speaker colours and player read well. Shrink the window to 820×560: no control or label is cut off. With Accessibility Inspector, every icon-only control added here reads a label (acceptance 7, 8).
