# Muninn transcript speakers — Implementation Plan

**Status:** Implemented — [PR #5](https://github.com/michaelrigart/muninn/pull/5)

> **Execution complete (2026-11-06).** All 6 tasks are implemented, with the final whole-branch review's fixes (see "Changes during execution"). Do not run this plan again. The "Manual acceptance" checks are done by hand on the owner's Mac.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move one transcript line, or a run of lines, to another speaker or a new one; say that a rename applies everywhere; show a meeting's speakers in the header when it has no calendar event.

**Architecture:** Every rule lives in MuninnCore and is unit tested: speaker labels and their order, the next new label, applying a change, the menu's and the header's speaker lists, the label-number colour rule, which segments a selection chooses, when a change is allowed, and the store's save order (commit first, Markdown after) with its failure cases. The app adds a "Change speaker" submenu to the transcript's context menu, wires the change and the rename through `AppModel` to the store, shows speaker problems on their own card, and adds speaker chips to the header.

**Tech Stack:** Swift 5 language mode, SwiftUI + AppKit, Swift Testing, SwiftPM package `MuninnCore` (dependency-free), XcodeGen via mise, Xcode 27.

**Spec:** `docs/superpowers/specs/2026-11-06-muninn-transcript-speakers-design.md`. Read it before each task; the UX pass spec (`2026-11-03-muninn-ux-pass-design.md`) holds the design system and copy rules it builds on.

## Global Constraints

- macOS 26; Swift 5 language mode in every target; `MuninnCore` stays dependency-free (Foundation only).
- In the app target, the settings type is `MuninnCore.Settings`.
- Copy: sentence case; "…" only where more input follows; no full stop in titles; British spelling. Exact strings in this plan are final.
- A speaker change never alters the audio, the timings, the words, the track or the recap; no other speaker's colour shifts because a line moved.
- No undo (⌘Z) for speaker changes or renames; the recap and exported notes are not rewritten.
- User-facing text never comes from `localizedDescription` or `String(describing:)` of an error; failures become problems through `ProblemTranslator` and are recorded in Activity.
- The Activity log never holds transcript text.
- A disabled control says why (menu item: `toolTip`; SwiftUI: `.help`).
- Public-repository rules: no personal details, machine paths or workflow-specific content; fixtures use `example.com`.
- Implementers do not commit; the controller commits each task with the message given, after its review. Tasks run one at a time (each one's tests compile the shared MuninnCore sources, or the app).

### Commands

Run outside any agent sandbox. `X` stands for `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

- Core tests: `X swift test --package-path Packages/MuninnCore [--filter <Suite>]`
- Regenerate the project after adding app files: `mise exec -- xcodegen generate`
- App build (ad hoc): `X xcodebuild -project Muninn.xcodeproj -scheme Muninn -configuration Debug -derivedDataPath build/adhoc -quiet build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=` — every task that touches the app ends with this build passing with no new warnings. `build/adhoc` is removed in Task 6.

## Review Focus

1. **A selection whose ends sit on a speaker name, a timestamp or the newline between lines**: it chooses exactly the segments whose lines it overlaps; a selection only over a name chooses none, and the menu then has no "Change speaker". Pinned in Task 2 (`selectionChoosesEveryLineItTouches`, `selectionOnlyOnANameChoosesNothing`).
2. **Two speakers with the same shown name**, including an `S` label named after the owner: the menu tells them apart by label, and the tick still lands on the right one. Pinned in Task 1 (`menuOffersYouAlwaysAndTellsTwinsApart`).
3. **A pipeline job that starts after the menu opened** (Regenerate clicked, or a waiting meeting released when its engine comes back): the change is checked again, and committed, in one step on the pipeline actor, so no job is admitted or reads the transcript in between; refused, a warning card shows and nothing is written. Pinned in Task 2 (`speakerChangesWaitForProcessing`, `jobStateHoldsOffJobsWhileItRuns`).
4. **A full disk or a read-only meeting folder** at either step: a failed commit changes nothing and leaves the Markdown alone; a failed Markdown write keeps the change and offers "Try again", which catches the files up, and a later no-op change never hides that the files are behind. A pipeline run that failed after its JSON was written repairs the Markdown on its retry. Pinned in Task 3 (`failedSpeakerCommitChangesNothing`, `failedMarkdownKeepsTheSpeakerChange`, `failedRenameCommitChangesNothing`, `failedMarkdownKeepsTheRename`, `rewritingMarkdownCatchesUp`, `choosingTheSameSpeakerOnlyRewritesTheMarkdown`, `aRetryRepairsTheTranscriptMarkdown`).
5. **Keyboard and the Clean view**: an insertion point at the end of a line (after End) chooses that line; in Clean, segments the clean transcript leaves out are never chosen. Pinned in Task 2 (`noSelectionChoosesTheLineAtTheOffset`, `cleanViewNeverChoosesHiddenSegments`).

## Rulings made while planning

Record these under "Rulings" in the pull request.

1. "Change speaker" sits above "Rename speaker…" at the top of the context menu. Its submenu lists the speakers, a separator, then "New speaker". Refused, it is a plain disabled item (no submenu) whose `toolTip` is the reason.
2. With a non-empty selection, the selection decides. Otherwise a menu opened by the mouse uses the character under the pointer only (off the text: no item), and one opened another way (keyboard, VoiceOver) uses the insertion point. An insertion point at the end of a line counts as that line. "Rename speaker…" keeps today's resolution.
3. Waiting meetings (status `.waiting`, any reason) are refused, as acceptance 5 asks, although Move to Trash allows them. Reasons: "Stop the recording first" while recording, otherwise Move to Trash's "Wait until Muninn has finished this meeting".
4. The rule is checked when the menu opens (status and the pipeline snapshot) and again when the change is applied: the reloaded status and whether the meeting has a job are checked and the change committed in one step on the pipeline actor (`ProcessingPipeline.withJobState`), so no job can be admitted or read the transcript between the check and the commit. Refused at that point, a warning card says "The speaker wasn't changed".
5. A label that is neither `you` nor `S<n>` takes colours after the numbered ones: the k-th such label (from 0, by first appearance) takes `1 + (m + k) mod 5`, where m is the highest `S` number in the transcript (0 when none).
6. The menu tells speakers apart when their shown names are exactly equal, by appending " (label)"; "you" counts as a label ("Sarah (you)"). Labels with lines that are neither `you` nor `S<n>` (none exist today) are offered after the numbered ones.
7. `saveClean` also writes its JSON before its Markdown, so every Markdown file is written after what it derives from. In the pipeline a Markdown failure still fails the job; its retry keeps the JSON already written instead of transcribing or cleaning again, and a run that reuses an existing `transcript.json` rewrites the Markdown files from it, so the retry repairs them.
8. A missing current or previous recap names no owners; one that exists but can't be read refuses "New speaker" (its read error is the problem shown), because its owners can't be ruled out. Moving lines to an existing speaker never reads the recaps.
9. Speaker problems show on two cards of their own above the meeting, both recorded in Activity under Transcription: one for a refused or failed change or rename (no "Try again"), cleared by the next one that commits; one for Markdown files that are behind, with "Try again", set or cleared by every result that reports on the files and never by a failure that didn't reach them.
10. Choosing the speaker every chosen line already has leaves `transcript.json` alone but still rewrites the Markdown files, so a change's result always says whether the files are current and the card never clears on a repair that didn't happen.
11. The transcript's speaker-name tooltip becomes "Rename this speaker everywhere", the header chips' help text.

## Changes during execution

Decided in the final whole-branch review; record these under "Rulings" in the pull request with the ones above.

1. `ProcessingPipeline.withJobState` gave way to `ProcessingPipeline.changeSpeaker(of:to:in:userName:)`: the reload, the refusal and the commit run in one actor-isolated step in MuninnCore, where they are tested (`speakerChangeIsRefusedWhileAJobIsHeld`, `speakerChangeIsRefusedWhileRecording`, `aJobWaitsForTheSpeakerEditToCommit`). `AppModel.changeSpeaker` only calls it.
2. A menu opened through accessibility (VoiceOver, Full Keyboard Access) is recognised by overriding `accessibilityPerformShowMenu()`, and uses the insertion point whatever event AppKit synthesises; mouse-downs keep using the pointer (ruling 2).
3. The "files behind" card can be dismissed like every other card; Activity keeps the record and the next result that reports on the files sets it again (amends ruling 9).
4. `Token` takes a leading mark (a symbol or a dot), and `SpeakerChip` is built on it, so the chip look lives in one place.
5. The header names same-named speakers by their shown name only, as the spec says; their colours tell them apart.
6. `PipelineSnapshot` lists the meetings with a job queued or running (`jobs`), and the menu's refusal uses it, so "Change speaker" is disabled with its reason also while a job holds its turn before its first stage (pre-merge review).

## File map

MuninnCore (`Packages/MuninnCore/Sources/MuninnCore/`):

| File | Responsibility | Task |
|---|---|---|
| `Model/TranscriptSpeakers.swift` (new) | Labels, order, new label, applying a change, menu and header lists | 1 |
| `Design/SpeakerColours.swift` | The label-number colour rule | 1 |
| `ReadAlong/TranscriptLayout.swift` | Which segments a selection or offset chooses | 2 |
| `Presentation/MeetingCommands.swift` | When a speaker change is allowed; `SpeakerChangeRefused` | 2 |
| `Pipeline/ProcessingPipeline.swift` | `withJobState` (2); Markdown repair on a reused transcript (3) | 2, 3 |
| `Storage/MeetingStore.swift`, `Storage/MeetingStore+Speakers.swift` (new) | Save order; change, rename and Markdown rewrite | 3 |
| `Problems/Problems.swift` | `transcriptFilesNotUpdated` copy | 3 |

App (`Muninn/`): `AppModel+Meetings.swift`, `Meetings/TranscriptTextView.swift`, `Views/MeetingDetail.swift` (Task 4); `Meetings/MeetingHeader.swift`, `Meetings/HeaderChips.swift`, `Views/MeetingDetail.swift` (Task 5).

---

### Task 1: Speaker labels, lists and colours

**Depends on:** none

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Model/TranscriptSpeakers.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Design/SpeakerColours.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/TranscriptSpeakersTests.swift` (new), `PaletteTests.swift` (replace `speakerIndicesFollowFirstAppearance`)

**Interfaces:**
- Consumes: `Transcript`, `Segment`, `Meeting.attendees`, `Attendee.isResource`, `SummaryRequestBuilder.displayName(_:speakerNames:userName:)`.
- Produces (all `public`):
  - `struct SpeakerChoice: Equatable, Sendable { var label: String; var title: String; init(label:title:) }`
  - `enum TranscriptSpeakers`:
    - `static func number(of label: String) -> Int?` — n for a label matching `S[1-9][0-9]*` (ASCII digits, value fits `Int`), else nil.
    - `static func ordered(in transcript: Transcript) -> [String]` — every label with at least one segment, once: `you` first, then numbered labels by number, then other labels by first appearance.
    - `static func newLabel(transcript: Transcript, speakerNames: [String: String], recapOwners: [String]) -> String` — `"S\(m + 1)"`, m the highest `number(of:)` over the segments' labels, the `speakerNames` keys and `recapOwners` (0 when none).
    - `static func changing(_ segmentIDs: Set<Int>, to speaker: String, in transcript: Transcript) -> Transcript` — sets `speaker` on each segment whose id is in the set; nothing else changes; unknown ids are ignored.
    - `static func commonSpeaker(of segmentIDs: Set<Int>, in transcript: Transcript) -> String?` — the speaker every listed segment found in the transcript has; nil when they differ or none is found.
    - `static func menuChoices(transcript: Transcript, speakerNames: [String: String], userName: String) -> [SpeakerChoice]` — `you` always first, then `ordered(in:)` without `you`; title = `displayName`; every title that occurs more than once becomes `"\(title) (\(label))"`.
    - `static func headerSpeakers(meeting: Meeting, transcript: Transcript?, userName: String) -> [SpeakerChoice]` — empty when `transcript` is nil or any attendee is not a resource; else `ordered(in:)` with title = `displayName` (no disambiguation).
  - `SpeakerColours.indices(for: Transcript) -> [String: Int]` (same signature): `you` → 0; a numbered label → `1 + (n − 1) % 5`; other labels per ruling 5.

- [x] **Step 1: Write the failing tests**

```swift
// TranscriptSpeakersTests — segment(_ id, _ speaker, track: .system) helper; times = id…id+1
@Test func labelNumbers() {
    #expect(TranscriptSpeakers.number(of: "S1") == 1)
    #expect(TranscriptSpeakers.number(of: "S12") == 12)
    for label in ["S0", "S01", "s1", "S", "you", "S1a", "S\u{0663}", "S99999999999999999999"] {
        #expect(TranscriptSpeakers.number(of: label) == nil)
    }
}
@Test func orderPutsYouFirstThenByNumber() {
    // speakers ["S3", "you", "S10", "S2", "Guest", "S3"]
    #expect(TranscriptSpeakers.ordered(in: t) == ["you", "S2", "S3", "S10", "Guest"])
}
@Test func newLabelSkipsEveryLabelThatStillCarriesMeaning() {
    // transcript S1, S2
    #expect(TranscriptSpeakers.newLabel(transcript: t, speakerNames: [:], recapOwners: []) == "S3")
    #expect(TranscriptSpeakers.newLabel(transcript: t, speakerNames: ["S5": "Ann"], recapOwners: ["you", "Ann"]) == "S6")
    #expect(TranscriptSpeakers.newLabel(transcript: t, speakerNames: ["S5": "Ann"], recapOwners: ["S7"]) == "S8")
    #expect(TranscriptSpeakers.newLabel(transcript: Transcript(segments: [], language: nil), speakerNames: [:], recapOwners: []) == "S1")
}
@Test func changeTouchesOnlyTheChosenSegments() {
    // four segments with words, mixed tracks; change [1, 2, 99] to "S9"
    // → segments 1 and 2 have speaker "S9"; every other field of every segment, the order and the language are equal to before
    // changing([], …) == t
}
@Test func commonSpeakerTicksOnlyWhenAllAgree() {
    // speakers ["S1", "S1", "S2"]: [0, 1] → "S1"; [1, 2] → nil; [99] → nil; [0, 99] → "S1"
}
@Test func menuOffersYouAlwaysAndTellsTwinsApart() {
    // mic-only: speakers ["S1", "S2", "S1"]; names ["S1": "Sarah", "S2": "Sarah", "S3": "Old"]; userName "Me"
    #expect(TranscriptSpeakers.menuChoices(transcript: t, speakerNames: names, userName: "Me") == [
        SpeakerChoice(label: "you", title: "Me"), SpeakerChoice(label: "S1", title: "Sarah (S1)"), SpeakerChoice(label: "S2", title: "Sarah (S2)"),
    ])
    // names ["S1": "Me"] → titles "Me (you)", "Me (S1)", "S2"
}
@Test func headerSpeakersOnlyWithoutPeople() {
    // speakers ["S2", "you", "S1"], names ["S2": "Bea"], userName "Me"
    // attendees [] → [("you","Me"), ("S1","S1"), ("S2","Bea")]
    // attendees [a room with type "resource"] → the same list
    // attendees [Attendee(name: "Ann", email: "ann@example.com")] → []
    // transcript nil → []
}

// PaletteTests, replacing speakerIndicesFollowFirstAppearance
@Test func speakerColoursFollowTheLabelNumber() {
    // ["S2", "you", "S1", "S3", "S4", "S5", "S6", "S2"]
    #expect(SpeakerColours.indices(for: t) == ["you": 0, "S1": 1, "S2": 2, "S3": 3, "S4": 4, "S5": 5, "S6": 1])
}
@Test func movingALineKeepsEveryOtherColour() {
    // ["S1", "S2", "S3", "S2"]; move segment 1 to "S3" with TranscriptSpeakers.changing
    // → indices before and after agree on every label present in both
}
@Test func unnumberedLabelsFollowTheNumberedOnes() {
    #expect(SpeakerColours.indices(for: transcript(["Guest", "S2", "Host"])) == ["you": 0, "S2": 2, "Guest": 3, "Host": 4])
}
```

- [x] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter "TranscriptSpeakersTests|PaletteTests"` — expect a build failure, then (after a stub) the colour tests failing on the old rule.
- [x] **Step 3: Implement** `TranscriptSpeakers` and the new `SpeakerColours.indices` rule; update its doc comment.
- [x] **Step 4: Run** the same filter, then the whole Core suite — expect PASS.
- [x] **Step 5: Commit** — `Add transcript speaker labels and colour speakers by their number`

---

### Task 2: Which lines a change applies to, and when it is allowed

**Depends on:** Task 1

**Files:**
- Modify: `Packages/MuninnCore/Sources/MuninnCore/ReadAlong/TranscriptLayout.swift`, `Presentation/MeetingCommands.swift`, `Pipeline/ProcessingPipeline.swift`
- Test: `TranscriptLayoutTests.swift`, `MeetingCommandsTests.swift`, `ProblemTranslatorTests.swift`, `PipelineTests.swift`

**Interfaces:**
- Consumes: `TranscriptLayout.segments[].line`, `ProcessingStatus`, `MeetingProgress`, `ProblemConvertible`.
- Produces (all `public`):
  - `TranscriptLayout.segmentIDs(selection: NSRange, offset: Int?) -> [Int]` — with `selection.length > 0`: the ids of the segments whose `line` overlaps the selection (`line.location < NSMaxRange(selection) && selection.location < NSMaxRange(line)`), in layout order. Otherwise the id of the segment with `line.location <= offset <= NSMaxRange(line)`, or `[]` (nil offset, a speaker name line, past the end).
  - `MeetingCommands.speakerChangeRefusal(status: ProcessingStatus, progress: MeetingProgress, hasJob: Bool) -> String?` — first match wins: status `.recording` → "Stop the recording first"; status `.transcribing`, `.diarizing`, `.cleaning`, `.summarizing` or `.waiting(_)`, progress `.working`, `.preparingSpeechModel`, `.queued` or `.waiting`, or `hasJob` → "Wait until Muninn has finished this meeting" (the existing private `wait` constant; move the inline "Stop the recording first" into a constant shared with `.moveToTrash`); else nil.
  - `struct SpeakerChangeRefused: ProblemConvertible, Sendable { let reason: String; init(reason:) }` — `Problem(severity: .warning, title: "The speaker wasn't changed", explanation: "\(reason).", actions: [], details: ProblemDetails())`.
  - `ProcessingPipeline.withJobState<T: Sendable>(for id: MeetingID, _ body: @Sendable (_ hasJob: Bool) throws -> T) rethrows -> T` — an actor-isolated, synchronous method (neither `async` nor `nonisolated`) that runs `body` on the actor with `hasJob(for: id)`; since it never suspends, no job is admitted, started or reads the meeting's files while it runs.

- [x] **Step 1: Write the failing tests**

```swift
// TranscriptLayoutTests (the suite's three-segment transcript; `layout(.verbatim)`)
@Test func selectionChoosesEveryLineItTouches() {
    let l = layout(.verbatim)
    let fromMiddleOfFirst = l.segments[0].text.location + 3
    #expect(l.segmentIDs(selection: NSRange(location: fromMiddleOfFirst, length: l.segments[2].line.location + 1 - fromMiddleOfFirst), offset: nil) == [0, 1, 2])
    #expect(l.segmentIDs(selection: NSRange(location: l.segments[1].text.location, length: 2), offset: nil) == [1])
    // from the newline after segment 0's line to the end of the "S1" name line: no segment, whatever the offset says
    let gap = NSMaxRange(l.segments[0].line)
    #expect(l.segmentIDs(selection: NSRange(location: gap, length: l.segments[1].line.location - gap), offset: l.segments[2].text.location) == [])
}
@Test func selectionOnlyOnANameChoosesNothing() {
    let l = layout(.verbatim)
    #expect(l.segmentIDs(selection: l.speakerLines[1].range, offset: nil) == [])
}
@Test func noSelectionChoosesTheLineAtTheOffset() {
    let l = layout(.verbatim)
    let empty = NSRange(location: 0, length: 0)
    #expect(l.segmentIDs(selection: empty, offset: l.segments[1].text.location + 1) == [1])
    #expect(l.segmentIDs(selection: empty, offset: NSMaxRange(l.segments[1].line)) == [1])
    #expect(l.segmentIDs(selection: empty, offset: l.speakerLines[1].range.location) == [])
    #expect(l.segmentIDs(selection: empty, offset: nil) == [])
}
@Test func cleanViewNeverChoosesHiddenSegments() {
    // clean with segment 1's text "" → layout(.clean) shows segments 0 and 2;
    // a selection from segment 0's text to the end of the string → [0, 2]
}

// MeetingCommandsTests
@Test func speakerChangesWaitForProcessing() {
    #expect(MeetingCommands.speakerChangeRefusal(status: .recording, progress: .none, hasJob: false) == "Stop the recording first")
    for status: ProcessingStatus in [.transcribing, .diarizing, .cleaning, .summarizing, .waiting(.studioUnreachable), .waiting(.queued), .waiting(.recording)] {
        #expect(MeetingCommands.speakerChangeRefusal(status: status, progress: .none, hasJob: false) == Self.wait)
    }
    for progress: MeetingProgress in [.working(Self.work), .queued(ahead: 0), .waiting(.memoryPressure)] {
        #expect(MeetingCommands.speakerChangeRefusal(status: .ready, progress: progress, hasJob: false) == Self.wait)
    }
    #expect(MeetingCommands.speakerChangeRefusal(status: .ready, progress: .none, hasJob: true) == Self.wait)
    #expect(MeetingCommands.speakerChangeRefusal(status: .ready, progress: .none, hasJob: false) == nil)
    // a .failed meeting with progress .failed → nil
}

// PipelineTests (the Harness; summarizer.holdFirstCall / entered / released as in aMeetingWithAQueuedOrRunningJobReportsIt)
@Test(.timeLimit(.minutes(1))) func jobStateHoldsOffJobsWhileItRuns() async throws {
    #expect(await h.pipeline.withJobState(for: h.id) { $0 } == false)
    // hold a job in the summarizer (holdFirstCall, entered): the body gets true; release it, await the run: false again
    // a body that throws: withJobState rethrows the same error
}
@Test(.timeLimit(.minutes(1))) func aJobWaitsForTheSpeakerEditToCommit() async throws {
    // FakeSummarizer also records the transcript it was given (`transcripts`). A ready meeting with a stored recap and a
    // one-segment "you" transcript. The edit's body reaches a Milestone, then blocks on a DispatchSemaphore, then saves
    // the transcript with segment 0 moved to "S1".
    // start the edit; await its milestone; start regenerate(h.id, engine: .claude) in a Task; sleep 500 ms
    // → the summarizer has not been called; signal the semaphore; await both
    // → the summarizer's last transcript has segment 0 spoken by "S1"
    // (Checked by revert: running the body after leaving the actor lets the regeneration read "you" and fails this test.)
}

// ProblemTranslatorTests
@Test func refusedSpeakerChangeSaysWhy() {
    let problem = ProblemTranslator.problem(for: SpeakerChangeRefused(reason: "Wait until Muninn has finished this meeting"), in: ProblemContext(stage: .savingEdits))
    #expect(problem.severity == .warning)
    #expect(problem.title == "The speaker wasn't changed")
    #expect(problem.explanation == "Wait until Muninn has finished this meeting.")
    #expect(problem.actions.isEmpty)
}
```

- [x] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter "TranscriptLayoutTests|MeetingCommandsTests|ProblemTranslatorTests|PipelineTests"` — expect a build failure.
- [x] **Step 3: Implement** the four interfaces.
- [x] **Step 4: Run** the same filter, then the whole Core suite — expect PASS.
- [x] **Step 5: Commit** — `Choose the lines a speaker change applies to, and refuse it while Muninn works on the meeting`

---

### Task 3: Save a speaker change and a rename in the store

**Depends on:** Task 1

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Storage/MeetingStore+Speakers.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Storage/MeetingStore.swift`, `Problems/Problems.swift`, `Pipeline/ProcessingPipeline.swift`
- Test: `StorageTests.swift` (replace `failedMarkdownWriteLeavesNoTranscriptJSON`), `ProblemTranslatorTests.swift`, `PipelineTests.swift`

**Interfaces:**
- Consumes: `TranscriptSpeakers.newLabel`, `.changing`, `TranscriptMarkdown.render`, `SummaryRequestBuilder.displayName`, `MeetingStore.update`, `loadSummary`, `loadPreviousSummary`, `loadClean`.
- Produces (all `public`):
  - `enum SpeakerTarget: Equatable, Sendable { case speaker(String), new }`
  - `struct SpeakerChangeResult: Equatable, Sendable { var transcript: Transcript; var filesError: TranscriptFilesNotUpdated? }` — `filesError` nil means both Markdown files now match `transcript.json`.
  - `struct SpeakerRenameResult: Equatable, Sendable { var meeting: Meeting; var filesError: TranscriptFilesNotUpdated? }`
  - `struct TranscriptFilesNotUpdated: ProblemConvertible, Equatable, Sendable { var details: ProblemDetails; init(_ error: Error) }` — `init` keeps the error's `errorDomain`, `errorCode` and `path` (`NSFilePathErrorKey`, else `NSURLErrorKey`'s path); its problem is `Problems.transcriptFilesNotUpdated(details: details)`.
  - `Problems.transcriptFilesNotUpdated(details: ProblemDetails = ProblemDetails()) -> Problem` — severity `.problem`, title "Muninn couldn't update all the transcript files", explanation "Your change is saved in Muninn, but the Markdown transcript in the meeting's folder may still show the earlier speakers. Try again to update it.", actions `[.tryAgain]`.
  - `MeetingStoreError.noTranscript` — `errorDescription` "There is no transcript to change".
  - On `MeetingStore`:
    - `var beforeSpeakerEditWrite: ((URL) throws -> Void)?` (declared in the class body, internal) — called with each file the methods below are about to write: `meeting.json` (rename), `transcript.json`, `transcript.md`, `transcript.clean.md`.
    - `func changeSpeaker(of segmentIDs: Set<Int>, to target: SpeakerTarget, in id: MeetingID, userName: String) throws -> SpeakerChangeResult` — under a new `static let transcriptLock = NSLock()` (taken before, never inside, `writeLock` and `summaryLock`): load `transcript.json` (missing → `MeetingStoreError.noTranscript`) and the meeting; resolve `.new` with `newLabel` over the meeting's `speakerNames` and the action owners of the current and previous recap (`loadSummary`, `loadPreviousSummary`: nil → no owners, a throw propagates and nothing is written; ruling 8); apply `changing`; unless the result equals what was loaded, write `transcript.json` (the commit; a throw leaves everything as it was). Then, in both cases, the Markdown files (below); return the transcript as stored and the files error (ruling 10).
    - `func renameSpeaker(_ speaker: String, to name: String, in id: MeetingID, userName: String) throws -> SpeakerRenameResult` — under `transcriptLock`: trim `name`; commit with `update(id)` (blank removes the key, else sets it); then, when `transcript.json` exists, the Markdown files from it and the committed meeting (a transcript that can't be read is a files error); `transcript.json` is never written.
    - `func rewriteTranscriptMarkdown(_ id: MeetingID, userName: String) throws` — under `transcriptLock`: the Markdown files from the stored meeting, transcript and clean transcript; the first error is thrown as it came (the app wraps it in `TranscriptFilesNotUpdated`; the pipeline lets it fail the job as a save failure); no transcript → nothing to do.
    - The Markdown files (private helper): `transcript.md` from the transcript, then, when `transcript.clean.json` exists, `transcript.clean.md` from it; both are attempted, the first error is kept. Rendering is today's `saveTranscript`/`saveClean` rendering (title from the meeting, names via `displayName`).
  - `saveTranscript` writes `transcript.json` before `transcript.md`; `saveClean` writes `transcript.clean.json` before `transcript.clean.md` (ruling 7). Signatures unchanged. Relax `file(_:_:)`, `write(_:to:)`, `writeText(_:to:)` and `readIfPresent<T>` from `private` to internal so the extension can use them.
  - `ProcessingPipeline.stages`: when it reuses an existing `transcript.json`, it calls `store.rewriteTranscriptMarkdown(id, userName: settings.userName)` once the clean transcript is settled (reused or newly saved) and before the engine decision is acted on; a throw fails the job like any save failure (ruling 7).

- [x] **Step 1: Write the failing tests** (`StorageTests`; a helper stores `meeting` with `speakerNames: ["S1": "Ada"]`, a three-segment transcript `you` / `S1` / `S1` with words, and a clean transcript, through `saveTranscript` and `saveClean`; `md(id)` and `cleanMD(id)` read the two Markdown files)

```swift
@Test func transcriptJSONIsWrittenBeforeItsMarkdown() {
    // a directory at transcript.md and at transcript.clean.md: saveTranscript and saveClean each throw,
    // and loadTranscript / loadClean return what was saved
}
@Test func speakerChangeWritesOnlyTheChosenSegments() {
    let result = try store.changeSpeaker(of: [1], to: .speaker("you"), in: id, userName: "Me")
    #expect(result.filesError == nil)
    #expect(try store.loadTranscript(id) == result.transcript)
    #expect(result.transcript.segments.map(\.speaker) == ["you", "you", "S1"])
    // tracks, times, words and texts equal to before; md(id) and cleanMD(id) show "Me:" on segment 1's line
}
@Test func newSpeakerTakesTheNextFreeLabel() {
    // speakerNames ["S1": "Ada", "S4": "Old"]; current recap with an action owned by "S6"; previous recap owned by "S7"
    #expect(try store.changeSpeaker(of: [2], to: .new, in: id, userName: "Me").transcript.segments[2].speaker == "S8")
    // a fresh meeting with names ["S1": "Ada", "S4": "Old"] and neither recap: .new gives "S5"
}
@Test func anUnreadableRecapRefusesANewSpeaker() {
    // summary.json holds "{": .new throws and transcript.json's bytes are unchanged; .speaker("you") on the same meeting succeeds
}
@Test func choosingTheSameSpeakerOnlyRewritesTheMarkdown() {
    // beforeSpeakerEditWrite records URLs; change [1] to .speaker("S1") → transcript.md and transcript.clean.md recorded,
    // transcript.json not; result.transcript == stored; result.filesError == nil
}
@Test func failedSpeakerCommitChangesNothing() {
    // hook throws CocoaError(.fileWriteNoPermission) for transcript.json
    #expect(throws: CocoaError.self) { try store.changeSpeaker(of: [1], to: .speaker("you"), in: id, userName: "Me") }
    // transcript.json, transcript.md and transcript.clean.md bytes equal to before; the hook saw no Markdown URL
}
@Test func failedMarkdownKeepsTheSpeakerChange() {
    // hook throws for transcript.md only
    let result = try store.changeSpeaker(of: [1], to: .speaker("you"), in: id, userName: "Me")
    #expect(result.filesError != nil)
    #expect(try store.loadTranscript(id)?.segments[1].speaker == "you")
    // transcript.clean.md was still rewritten (shows "Me:" on segment 1's line)
    // a no-op change ([1] to .speaker("you")) while the hook still throws: filesError != nil;
    // with the hook removed: filesError == nil and md(id) shows "Me:" on segment 1's line
}
@Test func renameCommitsWithTheNames() {
    let before = try Data(contentsOf: transcriptJSON)
    let result = try store.renameSpeaker("S1", to: "  Bea ", in: id, userName: "Me")
    #expect(result.meeting.speakerNames["S1"] == "Bea" && result.filesError == nil)
    #expect(try store.load(id).speakerNames["S1"] == "Bea")
    #expect(try Data(contentsOf: transcriptJSON) == before)
    // md(id) and cleanMD(id) show "Bea:"; renaming to "  " removes the key and the files show "S1:"
}
@Test func failedRenameCommitChangesNothing() {
    // hook throws for meeting.json → renameSpeaker throws; speakerNames still ["S1": "Ada"]; Markdown bytes unchanged
}
@Test func failedMarkdownKeepsTheRename() {
    // hook throws for transcript.md → result.filesError != nil; stored speakerNames["S1"] == "Bea"
}
@Test func rewritingMarkdownCatchesUp() {
    // after failedMarkdownKeepsTheSpeakerChange's state: hook removed; rewriteTranscriptMarkdown(id, userName: "Me")
    // → md(id) shows the change; with the hook throwing CocoaError(.fileWriteNoPermission) for transcript.md it throws that error
}

// PipelineTests (the Harness)
@Test func aRetryRepairsTheTranscriptMarkdown() async throws {
    // a directory at transcript.md: process(h.id) → status .failed, transcript.json exists
    // remove the directory, process(h.id) again → status .ready, transcript.md exists, the transcriber ran once in all
    // the same with a directory at transcript.clean.md: the retry leaves transcript.clean.md in place
}

// ProblemTranslatorTests
@Test func transcriptFilesProblemOffersTryAgain() {
    let error = TranscriptFilesNotUpdated(CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: "/tmp/m/transcript.md"]))
    let problem = ProblemTranslator.problem(for: error, in: ProblemContext(stage: .savingEdits))
    #expect(problem.title == "Muninn couldn't update all the transcript files")
    #expect(problem.actions == [.tryAgain])
    #expect(problem.details.errorDomain == NSCocoaErrorDomain && problem.details.errorCode == CocoaError.fileWriteNoPermission.rawValue)
    #expect(problem.details.path == "/tmp/m/transcript.md")
}
```

- [x] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter "StorageTests|ProblemTranslatorTests|PipelineTests"` — expect a build failure.
- [x] **Step 3: Implement** the interfaces; reorder `saveTranscript` and `saveClean`; add the pipeline's repair.
- [x] **Step 4: Run** the same filter, then the whole Core suite (the pipeline tests cover `saveTranscript`'s callers) — expect PASS.
- [x] **Step 5: Commit** — `Commit speaker changes and renames before rewriting the transcript Markdown`

---

### Task 4: Change speaker in the transcript

**Depends on:** Tasks 1–3

**Files:**
- Modify: `Muninn/AppModel+Meetings.swift`, `Muninn/Meetings/TranscriptTextView.swift`, `Muninn/Views/MeetingDetail.swift`

**Interfaces:**
- Consumes: Tasks 1–3's interfaces; `AppModel.progress(for:)`, `pipeline.withJobState(for:_:)`, `apply(_:)`, `resolvedUserName`, `activity.record(_:area:meeting:)`.
- Produces:
  - `AppModel.renameSpeaker(_ speaker: String, to name: String, in id: MeetingID) throws -> SpeakerRenameResult` — replaces today's version (the transcript and clean parameters go): `store.renameSpeaker(…, userName: resolvedUserName)`, then `apply(result.meeting)`.
  - `AppModel.changeSpeaker(of segmentIDs: Set<Int>, to target: SpeakerTarget, in id: MeetingID) async throws -> SpeakerChangeResult` — `try await pipeline.withJobState(for: id) { hasJob in … }` whose body reloads the meeting, throws `SpeakerChangeRefused(reason:)` when `MeetingCommands.speakerChangeRefusal(status: current.status, progress: .none, hasJob: hasJob)` is not nil, and else returns `store.changeSpeaker(…, userName:)` (the user name read before the call; the closure captures only Sendable values).
  - `TranscriptTextView` gains `speakerChangeRefusal: String?` (`MeetingDetail` passes `MeetingCommands.speakerChangeRefusal(status: meeting.status, progress: model.progress(for: meeting), hasJob: false)`) and `onChangeSpeaker: (_ segmentIDs: Set<Int>, _ target: SpeakerTarget) -> Void`.
  - `TranscriptNSTextView.contextItems: ((NSEvent) -> [NSMenuItem])?` replaces `renameAction` and `menuRename`: `menu(for:)` inserts the items at the top of a copy of `super`'s menu, then a separator when that menu has items; no items → `super`'s menu unchanged.
  - `final class ActionMenuItem: NSMenuItem` — `init(title: String, handler: @escaping () -> Void)`, its own target, runs `handler`.
  - The coordinator's `contextItems(for event:)` returns, in order:
    1. "Change speaker", when `layout.segmentIDs(selection: textView.selectedRange(), offset:)` is not empty, with `offset` = `textView.characterIndex(at: event)` for `.rightMouseDown`, `.leftMouseDown` and `.otherMouseDown` events, else `textView.selectedRange().location` (ruling 2). Refused: no submenu, `action` nil, `toolTip` = the reason. Allowed: a submenu of `TranscriptSpeakers.menuChoices(transcript:speakerNames:userName:)` as `ActionMenuItem`s (state `.on` for `commonSpeaker`), a separator, "New speaker"; each calls `onChangeSpeaker(ids, .speaker(label))` or `onChangeSpeaker(ids, .new)`.
    2. "Rename speaker…", resolved as today.
  - `SpeakerRenameForm` title: "Rename \(name) everywhere"; the speaker-name tooltip in `TranscriptStyle.text`: "Rename this speaker everywhere".
  - `MeetingDetail`:
    - Two states, shown as the first problem cards (ruling 9), each recorded with `model.activity.record(problem, area: .transcription, meeting: meeting)` when it is set to a problem different from the one shown. Problems come from `ProblemTranslator.problem(for: error, in: ProblemContext(stage: .savingEdits, subject: "your changes"))` (a failed commit reads "Muninn couldn't save your changes"; a refusal is its warning).
      - `@State private var speakerError: Problem?` — a refused or failed change or rename; dismissible, no "Try again"; cleared when a change or rename commits.
      - `@State private var transcriptFilesProblem: Problem?` — set from a result's `filesError`, cleared by a result whose `filesError` is nil; a throw never touches it. Its "Try again" calls `model.store.rewriteTranscriptMarkdown(meeting.id, userName: model.resolvedUserName)`: success clears it, a throw sets `TranscriptFilesNotUpdated(error)`'s problem.
    - `changeSpeaker(_:to:)` runs `model.changeSpeaker` in a `Task`; on success it sets `transcript`, `lanes = PlaybackLanes.lanes(for:)` and `speakerIndices = SpeakerColours.indices(for:)` and applies the result to both states; a throw sets `speakerError` and leaves the view's transcript as it was.
    - `renameSpeaker(_:to:)` uses the new `model.renameSpeaker` with the same result and error handling (no longer through `report`/`saveError`).

- [x] **Step 1: Implement.**
- [x] **Step 2: Run** the app build — expect PASS with no new warnings.
- [x] **Step 3: Run** `rg -n 'renameAction =|var renameAction|menuRename|Rename \\\(name\)"' Muninn` — expect no output.
- [x] **Step 4: Commit** — `Change the speaker of transcript lines from the context menu`

---

### Task 5: Speakers in the header

**Depends on:** Task 4

**Files:**
- Modify: `Muninn/Meetings/MeetingHeader.swift`, `Muninn/Meetings/HeaderChips.swift`, `Muninn/Views/MeetingDetail.swift`

**Interfaces:**
- Consumes: `TranscriptSpeakers.headerSpeakers`, `SpeakerRenameForm`, `Theme.speaker(_:)`, `TokenButtonStyle` (`.token`), `ChipRow`.
- Produces:
  - `MeetingHeader` gains `transcript: Transcript?`, `speakerIndices: [String: Int]` and `onRename: (_ speaker: String, _ name: String) -> Void`; `MeetingDetail` passes its state and `renameSpeaker`. The chip row shows `SpeakerChip`s for `TranscriptSpeakers.headerSpeakers(meeting:transcript:userName: model.resolvedUserName)` after the details chip; attendee chips stay as today (the two never show together).
  - `struct SpeakerChip: View` (in `HeaderChips.swift`; `choice: SpeakerChoice`, `colourIndex: Int`, `initialName: String`, `onRename`): a `Button` with `.buttonStyle(.token)` whose label is an 8 pt circle in `Theme.speaker(colourIndex)` (accessibility hidden) and the title in `Theme.meta`, on the `Token` fill and padding; `.help("Rename this speaker everywhere")`; `.accessibilityLabel(choice.title)`; it opens a popover (arrow edge `.bottom`) with `SpeakerRenameForm(name: choice.title, initial: initialName, …)` whose save calls `onRename(choice.label, name)` and closes it. `initialName` is `meeting.speakerNames[label] ?? ""`.

- [x] **Step 1: Implement.**
- [x] **Step 2: Run** the app build — expect PASS with no new warnings.
- [x] **Step 3: Commit** — `Show a meeting's speakers in the header when it has no event`

---

### Task 6: Changelog, records and final verification

**Depends on:** Tasks 1–5

**Files:**
- Modify: `CHANGELOG.md`, this plan (tick boxes), `docs/superpowers/specs/2026-11-06-muninn-transcript-speakers-design.md` (Status)

- [x] **Step 1:** Add under `## [Unreleased]`, at the end of the existing sections:

```markdown
### Added

- Move a transcript line, or a selection of lines, to another speaker or a new one: right-click
  and choose Change speaker.
- A meeting without a calendar event shows its speakers in the header; click one to rename it.

### Changed

- Renaming a speaker says that it renames them everywhere.
- Each speaker keeps their colour when lines move between speakers.
```

- [x] **Step 2: Run** the full verification and record the totals as passed/total: the Core suite, `X swift test --package-path Packages/MuninnPlatform`, `mise exec -- xcodegen generate`, the app build, Task 4's search, `rg -n 'localizedDescription|String\(describing: error\)' Muninn | rg -v 'logger\.'` (expect no output) and `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'`.
- [x] **Step 3:** `rm -rf build/adhoc` (no ad hoc copy may outlive the run).
- [x] **Step 4: Commit** — `Add the changelog entries for transcript speakers`

## Manual acceptance (the owner, on his Mac)

Signed Debug build installed in `/Applications`, started with `open`:

1. Right-click one line, choose another speaker: only that line changes in the transcript, the player's lanes and `transcript.md`; it survives View › Reload and a relaunch (acceptance 1).
2. Select across three lines and change their speaker: all three change (acceptance 2).
3. "New speaker" creates the next `S` label; renaming it changes only its lines (acceptance 3).
4. Moving a line changes no other speaker's colour (acceptance 4).
5. While a meeting is processed, queued or waiting for an engine, "Change speaker" is disabled and its tooltip says why (acceptance 5).
6. In an in-person meeting, lines can be marked "You"; in a call, moving the last "You" line away and back works (acceptance 6).
7. A meeting without a calendar event shows its speakers in the header; clicking one renames it everywhere. A meeting with an event shows its attendees (acceptance 7).
8. The rename popover, from the transcript and the header, says "everywhere" (acceptance 8).
9. Changing a line's speaker, paused and while playing, keeps the transcript where it was and the read-along highlight on the playing word; on a speaker name the menu has "Rename speaker…" and no "Change speaker".
10. In the header, "You" comes first, then S1, S2… in their transcript colours, wrapping like attendee chips; renaming from a chip updates the chip, the transcript and the player.
11. With the keyboard (⇧F10 or VoiceOver's menu) on a line, "Change speaker" applies to the line holding the insertion point; in the Clean view a selection never moves a hidden segment.
