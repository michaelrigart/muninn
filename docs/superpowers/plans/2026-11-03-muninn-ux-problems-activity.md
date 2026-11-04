# Muninn UX pass, pull request 1: problems, Activity and processing status — Implementation Plan

**Status:** Implemented — [PR #3](https://github.com/michaelrigart/muninn/pull/3)

> **Execution complete (2026-11-04).** All 17 tasks are implemented, with the final whole-branch review's fixes. Do not run this plan again. The "Manual acceptance" checks are done by hand on the owner's Mac.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every failure Muninn shows becomes a sentence with actions and copyable details, an Activity window records what happened, and meetings say which step, queue position or model download they are on, in the meeting, the sidebar and the menu bar.

**Architecture:** MuninnCore gains a `Problem` model, a catalogue of problems (all user-facing copy), a translator from errors to problems, an Activity log (JSON lines under `$XDG_STATE_HOME`), a diagnostics builder, and pure presentation logic for processing status and attention. Engine and Graph errors are classified at the transport so they never carry response text. The pipeline publishes a snapshot of its current work and queue, waits instead of failing when This Mac's server is down, and stores problems instead of strings. The app gets design tokens, one status card component used by every channel, the Activity window, and lazy notifications.

**Tech Stack:** Swift 5 language mode, SwiftUI + AppKit, Swift Testing, SwiftPM packages `MuninnCore` (dependency-free) and `MuninnPlatform`, XcodeGen 2.46.0 via mise, Xcode 27.

**Spec:** `docs/superpowers/specs/2026-11-03-muninn-ux-pass-design.md` (sections "Design system", "Problems and the Activity log (pull request 1)", "Constraints", "Delivery" item 1, "Acceptance" 1–4 and 7). Read the spec before each task.

## Global Constraints

- macOS 26; Swift 5 language mode in every target; `MuninnCore` stays dependency-free (Foundation only).
- In the app target, the settings type is `MuninnCore.Settings` (`SwiftUI.Settings` is a scene).
- Swift uses `AppIdentity.bundleIdentifier`, never the bundle identifier literal.
- Copy: "Recap" everywhere in the interface (never "summary"); sentence case for every label, button, menu item and title; real ellipses (…) only where more input follows; "This Mac", "Network Mac", "Claude"; British spelling ("summarise", "colour"). Titles end without a full stop.
- Colours (spec, verbatim): Accent `#1D6779` light / `#5FB0C2` dark; Accent soft = accent at 10% light / 13% dark; Attention `#9A5B00` text and `#D68A00` fills light / `#E8A33A` dark; Problem `#C4302B` / `#FF6B63`; Success `#2E7D4F` / `#5CC489`; Recording `#ED1B2E` both. Red only for recording.
- The Activity log, problems and diagnostics never hold transcript text, recap text, email bodies, HTTP response bodies, API keys, tokens or full attendee address lists.
- Activity file: `$XDG_STATE_HOME/muninn/activity.jsonl`, default `~/.local/state/muninn/activity.jsonl`; 14 days; 5 MB cap.
- The public-repository rules hold: no personal details, machine paths or workflow-specific content in code, tests or docs.
- Implementers do not commit; the controller commits each task with the message given, after its review.
- `os.Logger` stays for development logging. User-facing text never comes from `localizedDescription` or `String(describing:)` of an error.

### Commands

Run all of these outside any agent sandbox. `X` stands for `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (this Mac's `xcode-select -p` points at the Command Line Tools).

- Core tests: `X swift test --package-path Packages/MuninnCore [--filter <Suite>]`
- Platform tests: `X swift test --package-path Packages/MuninnPlatform [--filter <Suite>]`
- Regenerate the project after adding app files: `mise exec -- xcodegen generate`
- App build (ad hoc, kept in one place): `X xcodebuild -project Muninn.xcodeproj -scheme Muninn -configuration Debug -derivedDataPath build/adhoc -quiet build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=`. Every task that touches the app ends with this build passing. `build/adhoc` is removed in Task 17.

## Review Focus

1. **A wait rewritten every 15 seconds** (This Mac's server off for an hour, or a Network Mac asleep) must not add an Activity entry or a notification on each retry; only entering the state counts. Pinned in Task 7 (`enteringAWaitIsRecordedOnce`) and Task 8 (`aWaitRewrittenEvery15SecondsIsNotRepeated`).
2. **Outside text that looks harmless**: a Graph or OAuth code Muninn doesn't know (a sentence, or a plausible identifier), a request path with a long event id or a key in a configured base URL, a `DecodingError` describing a reply. None reaches a problem, the Activity file or a copy. Pinned in Task 1 (`detailsRedactEveryStringField`), Task 2 (`graphHTTPErrorKeepsOnlyAKnownCode`, `requestFactsHideLongIdentifiers`, `decodingErrorKeepsNoText`) and Task 7 (`recordRedactsBeforeWriting`).
3. **A torn or oversized activity file** after a crash mid-write or a long-running Mac: unreadable lines are skipped, the file is trimmed, the window still opens. Pinned in Task 7 (`unreadableLinesAreSkipped`, `fileStaysUnderTheCap`).
4. **Launch with old failed meetings, and announcements during a recording**: no burst of "Needs attention" notifications at launch, and a meeting that recovers while the owner records is never announced. Pinned in Task 8 (`meetingsAlreadyNeedingAttentionAtLaunchAreNotAnnounced`, `aMeetingThatRecoversDuringTheRecordingIsNotAnnounced`).
5. **Try again on a failed meeting while another is processing**: it shows "Waiting its turn" with its position, not the old failure, a meeting's wait reason still wins over its queue position, and a wait that has cleared or changed reason is stored as such while another meeting runs, so the card, Needs attention and notifications agree. Pinned in Task 6 (`requeueingProbesWhileAnotherMeetingRuns`, `aWaitThatChangesReasonStoresTheNewReason`, `aStartedJobIsNotOverwritten`) and Task 8 (`retriedFailureShowsAsQueued`, `waitWinsOverQueue`, `aClearedWaitShowsItsQueuePosition`).

## Rulings made while planning

Decisions the spec leaves to the builder or does not settle. Record them under "Rulings" in the pull request.

1. A problem's severity reuses the Activity levels (info, warning, problem). Fallback notices ("Written on This Mac") and the diarisation notice are warnings; a regeneration that failed or could not run and kept the recap is a problem, so it counts for Needs attention.
2. `engineNotice` keeps the engine's notice; a new `transcriptNotice` holds the diarisation warning, so the two never overwrite each other. An old notice string is matched only against Muninn's own former sentences: a diarisation sentence becomes the transcript notice, an old "summarized on This Mac" fallback becomes the "Written on This Mac" warning, and anything else (an old failed or held regeneration) becomes a generic problem with Try again, so it stays in Needs attention. No text from the original is kept.
3. "Show in Activity" is always the problem card's second pair button, so it is not in a problem's action list.
4. Provider errors are classified at the transport. `LLMError` and `GraphError` hold a status, a category, a request (method, path, host) and, for Graph and OAuth, a code only when it is on a fixed list of known codes (others read `other` for Graph, `unrecognised` for OAuth). Request path segments longer than 32 characters become `{id}`; the query and any user info are dropped; the OAuth tenant becomes `{tenant}`. Every string field of a problem's details is redacted when it is shown, copied or written.
5. A This Mac address that does not parse counts as reachable, so the run reports "This Mac's model server address isn't valid" rather than "isn't running".
6. When the preferred Network Mac and This Mac's server are both down, the meeting waits for the Network Mac (the preferred engine).
7. The elapsed time on a progress card is the current step's.
8. "Waiting its turn" counts the running meeting as ahead. A meeting's wait reason wins over its queue position.
9. Meetings that already need attention at launch are not announced; a notification held during a recording is dropped if the meeting no longer needs attention when the recording stops.
10. The spec asks for the system label colours and for every text colour to meet 4.5:1; Apple's secondary and tertiary label colours fall below 4.5:1 on white, so Muninn uses its own secondary (`#5C5C5C` / `#A6A6A6`) and tertiary (`#6E6E6E` / `#8C8C8C`) text colours, close to Apple's, and the system primary label colour. The contrast test checks every text colour on every background it is used on: role text and tertiary text on the content background (`#FFFFFF` / `#1E1E1E`) only, primary and secondary text on the content background and on every soft fill. Role colours appear as text only on the plain content background.
11. Diagnostics mask account names and ids as whole words, show the home directory as `~`, and treat IPv4 addresses as hostnames.
12. The activity file is trimmed to its newest 4 MB whenever an append takes it over 5 MB.
13. A meeting's engine and transcript notices can be dismissed; dismissing a problem notice takes the meeting out of Needs attention.
14. Calendar fetch failures, server reachability and Keychain read failures are recorded when they change, not on every retry.
15. "Getting the speech model ready" shows for the first load of a model in each session, whether it downloads or loads from disk.
16. "Sign in again" opens the Accounts settings pane, where the sign-in sheet lives.
17. The 15-second loop probes the engines outside the processing queue, writes the result into each waiting meeting's stored status, and queues the meetings without waiting for them to run. A wait whose reason changed stores the new reason; a wait that cleared stores `waiting(.queued)`, shown as "Waiting its turn". The stored status stays the one truth for the card, Needs attention, notifications and Activity. The run's own decision stays authoritative, and a queued meeting is never queued twice.
18. Every channel uses the problem card; Settings, popovers and the recording surfaces use its compact layout, which keeps the actions, Copy details and Show in Activity. A field's validation message is a compact card with a title only. A channel whose context makes a catalogue action meaningless swaps the actions with `Problem.with(actions:)` and supplies a handler for each it shows.

## File map

MuninnCore (`Packages/MuninnCore/Sources/MuninnCore/`):

| File | Responsibility | Task |
|---|---|---|
| `Problems/Problem.swift` | `Problem`, `ProblemAction`, `ProblemDetails`, `RequestFacts`, `Provider`, `ProviderErrorCategory`, `ProblemStage`, `ProblemContext`, `SystemInfo`, `ProblemConvertible`, `ActivityLevel`, `ActivityArea` | 1 |
| `Problems/Problems.swift` | The catalogue: every problem's copy and actions | 1 (+6, 15) |
| `Problems/Redaction.swift` | Key and token redaction | 1 |
| `Problems/ProviderErrorClassifier.swift` | Category from status and body; known Graph and OAuth codes | 2 |
| `Problems/ProblemTranslator.swift` | Error + context → problem | 3 |
| `Engines/EngineClientError.swift` | Moved from MuninnSystem | 3 |
| `Pipeline/PipelineSnapshot.swift` | `PipelineStage`, `PipelineWork`, `PipelineSnapshot` | 4 |
| `Pipeline/WaitRetry.swift` | 15-second re-check cadence | 6 |
| `Activity/ActivityEntry.swift` | `ActivityEntry`, `ActivityMeeting`, `ActivityRecording`, `NoActivity`, `ActivityScope` | 7 |
| `Activity/ActivityLog.swift` | JSON-lines store, retention, cap, observer | 7 |
| `Activity/MeetingActivity.swift` | Entries from a meeting's state change; `DurationText` | 7 |
| `Pipeline/ProcessingDisplay.swift` | `MeetingProgress`, `SpeechModelPreparation`, menu lines, attention reason | 8 |
| `Pipeline/AttentionTracker.swift` | Which meetings to announce | 8 |
| `Activity/Diagnostics.swift` | Safe-to-paste diagnostics | 9 |
| `Engines/ReachabilityTracker.swift` | Entries when a server's reachability changes | 10 |
| `Design/Palette.swift` | Palette values and WCAG contrast maths | 12 |

MuninnPlatform: `MuninnSystem/StudioProbe.swift`, `MuninnSystem/KeychainStore.swift` (Task 10); `MuninnSpeech/SpeechModels.swift`, `MuninnSpeech/SpeechModelActivity.swift`, `MuninnSpeech/WhisperKitTranscriber.swift` (Task 11).

App (`Muninn/`): `Design/Theme.swift`, `Design/StatusCard.swift`, `Design/ProblemCard.swift` (Task 12); `Activity/ActivityCenter.swift`, `Activity/ActivityWindow.swift` (Task 13); `Views/MeetingStatusCards.swift` (Task 14); edits across `AppModel*.swift`, `Services.swift`, `RecordingController.swift`, `MuninnApp.swift` and `Views/*` (Tasks 5, 6, 13–16).

---

### Task 1: The problem model and its catalogue

**Depends on:** none

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Problems/Problem.swift`
- Create: `Packages/MuninnCore/Sources/MuninnCore/Problems/Problems.swift`
- Create: `Packages/MuninnCore/Sources/MuninnCore/Problems/Redaction.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/ProblemTests.swift`

**Interfaces:**
- Consumes: `EngineKind`, `EndpointAPI`, `Settings`, `WaitReason`, `CaptureMode`, `MuninnVersion`.
- Produces (all `public`, all value types `Codable, Hashable, Sendable` unless noted):
  - `enum ActivityLevel: String, CaseIterable { case info, warning, problem }`
  - `enum ActivityArea: String, CaseIterable { case recording, transcription, recap, outlook, obsidian, accounts, engines, app; var label: String }` — labels "Recording", "Transcription", "Recap", "Outlook", "Obsidian", "Accounts", "Engines", "App".
  - `enum ProblemAction: String, CaseIterable { case tryAgain, writeWithClaude, writeOnThisMac, writeWithAnotherEngine, engineSettings, changeKey, signInAgain, recordingSettings; var label: String }` — labels "Try again", "Write with Claude", "Write on This Mac", "Write with another engine", "Engine settings", "Change key…", "Sign in again", "Recording settings".
  - `enum ProviderErrorCategory: String, CaseIterable { case modelNotFound, unauthorized, rateLimited, overloaded, contextTooLong, badRequest, serverError, expiredSignIn, refused, incomplete, unknown }`
  - `enum Provider: String { case ollama, openAICompatible, anthropic, microsoftGraph, microsoftSignIn; var label: String; static func endpoint(_ api: EndpointAPI) -> Provider }` — labels "Ollama", "OpenAI-compatible server", "Anthropic", "Microsoft Graph", "Microsoft sign-in".
  - `struct RequestFacts { var method: String; var path: String; var host: String?; init(method:path:host:); init(method: String, url: URL) }` — the URL initialiser keeps only `url.path` and `url.host` (no query, no user info) and replaces every path segment longer than 32 characters with `{id}`.
  - `enum ProblemStage: String, CaseIterable` with `phrase: String` and `area: ActivityArea`, exactly:

    | case | phrase | area |
    |---|---|---|
    | `recording` | recording | recording |
    | `transcribing` | transcribing | transcription |
    | `identifyingSpeakers` | telling the speakers apart | transcription |
    | `cleaningUp` | cleaning up the transcript | transcription |
    | `writingRecap` | writing the recap | recap |
    | `preparingSpeechModel` | getting the speech model ready | transcription |
    | `liveTranscript` | transcribing live | transcription |
    | `creatingDraft` | creating the Outlook draft | outlook |
    | `searchingPeople` | searching for people | outlook |
    | `filingNote` | filing the note in Obsidian | obsidian |
    | `changingEvent` | changing the event | accounts |
    | `readingCalendar` | reading the calendar | accounts |
    | `signingIn` | signing in | accounts |
    | `savingSettings` | saving the settings | app |
    | `savingEdits` | saving your changes | recap |
    | `loadingMeetings` | loading the meetings | app |
    | `deletingMeeting` | deleting the meeting | app |
    | `other` | working | app |

  - `struct ProblemDetails` — all optional, all defaulted in `init`: `errorDomain: String?`, `errorCode: Int?`, `request: RequestFacts?`, `httpStatus: Int?`, `engine: EngineKind?`, `provider: Provider?`, `model: String?`, `category: ProviderErrorCategory?`, `graphCode: String?`, `path: String?`, `account: String?` (the display name of the Microsoft account involved, from Muninn's settings), `stage: ProblemStage?`, `elapsedSeconds: Double?`, `appVersion: String?`, `osVersion: String?`, `fromEarlierVersion: Bool = false`. Methods `redacted() -> ProblemDetails` (every string field, `request`'s three included, through `Redaction.redact`), `lines(includeHost: Bool) -> [String]` (built from `redacted()`) and `text(includeHost: Bool) -> String` (lines joined by `\n`). Line formats, each only when its field is set, in this order: `Error: <domain> <code>`; `Request: <METHOD> <path>` plus ` on <host>` when `includeHost`; `HTTP status: <n>`; `Engine: <engine.displayName>`; `Provider: <provider.label>`; `Model: <model>`; `Category: <category.rawValue>`; `Microsoft Graph code: <code>`; `File: <path>`; `Account: <account>`; `Stage: <stage.phrase>`; `Elapsed: <one decimal> s`; `From an earlier version of Muninn`; `Muninn <appVersion> · macOS <osVersion>` (when both set).
  - `public enum Redaction { static let marker = "[redacted]"; static func redact(_ text: String) -> String }` — replaces matches of `sk-ant-[A-Za-z0-9_\-]{8,}`, `sk-[A-Za-z0-9_\-]{16,}`, `(?i)bearer\s+[A-Za-z0-9._~+/=\-]{8,}`, `eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}` and `[A-Za-z0-9+/_]{40,}={0,2}` with the marker.
  - `struct Problem { var severity: ActivityLevel; var title: String; var explanation: String; var actions: [ProblemAction]; var details: ProblemDetails; init(severity:title:explanation:actions:details: = ProblemDetails()); func with(actions: [ProblemAction]) -> Problem }` — `with(actions:)` returns a copy with other actions, for a channel where the catalogue's actions don't apply (a card only shows actions it has a handler for).
  - `struct SystemInfo: Equatable, Sendable { var appVersion: String; var osVersion: String; static var current: SystemInfo }` — `appVersion` is `"<CFBundleShortVersionString> (<CFBundleVersion>)"` from `Bundle.main`, falling back to `MuninnVersion.current`; `osVersion` is `major.minor[.patch]` from `ProcessInfo`.
  - `struct ProblemContext: Sendable { var stage: ProblemStage; var engine: EngineKind?; var endpointAPI: EndpointAPI?; var model: String?; var claudeKeyPresent: Bool; var accountName: String?; var subject: String?; var elapsed: TimeInterval? }` with a memberwise `init` where everything but `stage` is defaulted (`claudeKeyPresent` to `false`), and `static func engine(_ engine: EngineKind, settings: Settings, stage: ProblemStage, claudeKeyPresent: Bool, elapsed: TimeInterval? = nil) -> ProblemContext` filling `endpointAPI` and `model` from `settings.macbook`/`settings.studio`, or `model` from `settings.claudeModel` for Claude.
  - `protocol ProblemConvertible: Error { func problem(in context: ProblemContext) -> Problem }`
  - `extension WaitReason { var needsYou: Bool }` — true for `studioNotConfigured` and `claudeKeyMissing`; false for the rest (Task 6 adds two cases, both true).
  - `enum Problems` — static factories, copy below. Every factory except `regenerationFailed` also takes `details: ProblemDetails = ProblemDetails()` as its last parameter and stores it.

**Catalogue copy** (severity · title · explanation · actions). `place` is "This Mac" for `.macbook` and "the Network Mac" for `.studio`.

| Factory | Sev. | Title | Explanation | Actions |
|---|---|---|---|---|
| `thisMacServerNotRunning(api:claudeKeyPresent:waiting:)` | problem | Ollama: "Ollama isn't running on This Mac"; other: "The model server on This Mac isn't running" | waiting: "Open Ollama and Muninn carries on within 15 seconds, or write this recap with another engine." / "Start the model server and Muninn carries on within 15 seconds, or write this recap with another engine."; not waiting: "Muninn writes recaps on This Mac with Ollama. Open Ollama, then try again, or write this recap with another engine." / "Muninn writes recaps on This Mac with its model server. Start it, then try again, or write this recap with another engine." | key: `writeWithClaude, tryAgain, engineSettings`; no key: `tryAgain, engineSettings` |
| `thisMacAddressInvalid()` | problem | "This Mac's model server address isn't valid" | "Fix the address in Engine settings, then try again." | `engineSettings, tryAgain` |
| `networkMacUnreachable()` | problem | "The Network Mac can't be reached" | "Check that it's awake and on the same network, then try again." | `tryAgain, engineSettings` |
| `networkMacNotSetUp()` | problem | "The Network Mac isn't set up" | "Add its address in Engine settings, or write this recap with another engine." | `tryAgain, engineSettings` |
| `claudeUnreachable()` | problem | "Claude can't be reached" | "Muninn couldn't connect to Anthropic. Check the network connection and that a firewall isn't blocking Muninn, then try again." | `tryAgain, writeOnThisMac` |
| `modelNotInstalled(model:engine:api:)` | problem | "The model \(model) isn't installed" | Ollama: "Install it on \(place) with `ollama pull \(model)`, then try again."; other: "Install it on the model server on \(place), then try again." | `tryAgain` |
| `claudeKeyRejected()` | problem | "Claude didn't accept the API key" | "The key may be mistyped or revoked. Change it in Engine settings, then try again." | `changeKey, tryAgain` |
| `claudeBusy()` | problem | "Claude is busy right now" | "Anthropic's servers are overloaded. Try again in a minute, or write this recap on This Mac." | `tryAgain, writeOnThisMac` |
| `claudeKeyMissing()` | problem | "There's no Claude API key" | "Add a key in Engine settings, or write this recap on This Mac." | `engineSettings, writeOnThisMac` |
| `recapIncomplete(engine:)` | problem | "The recap came back incomplete" | "\(engine.displayName)'s reply was cut off or couldn't be read. Try again, or write it with another engine." | `tryAgain, writeWithAnotherEngine` |
| `recapRefused(engine:)` | problem | "\(engine.displayName) declined to write this recap" | "Write it with another engine." | `writeWithAnotherEngine` |
| `transcriptTooLong(model:)` | problem | "The transcript is too long for \(model)" | "The model cut the transcript short. Write this recap on the Network Mac or with Claude." | `writeWithAnotherEngine` |
| `signInExpired(account:)` | problem | "Sign-in to \(account) expired" | "Sign in again so Muninn can read the calendar and create drafts." | `signInAgain`; `details.account = account` |
| `signInFailed(account:)` | problem | "Sign-in to \(account) didn't finish" | "Microsoft didn't accept the sign-in. Try again; if it keeps failing, copy the details." | `tryAgain`; `details.account = account` |
| `microsoftUnreachable()` | problem | "Microsoft can't be reached" | "Check the network connection and that a firewall isn't blocking Muninn, then try again." | `tryAgain` |
| `outlookDraftFailed()` | problem | "Outlook couldn't create the draft" | "Microsoft Graph refused the request. Try again; if it keeps failing, copy the details." | `tryAgain` |
| `calendarUnreadable(account:)` | problem | "Muninn couldn't read the \(account) calendar" | "Microsoft Graph refused the request. Muninn tries again in a minute." | `tryAgain`; `details.account = account` |
| `keychainUnreadable()` | problem | "Muninn couldn't read its saved key" | "The Keychain refused access. Save the key again in Engine settings." | `engineSettings` |
| `keychainUnwritable()` | problem | "Muninn couldn't save to the Keychain" | "The Keychain refused the change. Try again; if it keeps failing, check Muninn's items in Keychain Access." | `tryAgain` |
| `speechModelUnavailable(model:)` | problem | "The speech model couldn't be downloaded" | "Muninn downloads \(model) the first time it's used. Check the network connection and that a firewall isn't blocking Muninn, then try again." | `tryAgain` |
| `couldNotSave(what:)` | problem | "Muninn couldn't save \(what)" | "The disk may be full, or Muninn may not be allowed to write there. Free some space, then try again." | `tryAgain` |
| `hotkeyInUse(keys:)` | problem | "The shortcut \(keys) is used by another app" | "Choose another shortcut in Recording settings, or quit the app that uses it." | `recordingSettings` |
| `hotkeyUnsupported(keys:)` | problem | "The shortcut \(keys) can't be used" | "Choose another shortcut in Recording settings." | `recordingSettings` |
| `somethingWentWrong(stage:)` | problem | "Something went wrong while \(stage.phrase)" | "Try again. If it keeps happening, copy the details and include them when you report it." | `tryAgain` |
| `legacyFailure()` | problem | "This meeting couldn't be finished" | "An earlier version of Muninn stopped before it was done. Try again to finish it." | `tryAgain`; `details.fromEarlierVersion = true` |
| `legacyEngineNotice()` | problem | "An earlier recap attempt didn't finish" | "An earlier version of Muninn kept this recap when a newer attempt didn't finish. Try again to rewrite it." | `tryAgain, writeWithAnotherEngine`; `fromEarlierVersion = true` |
| `recordingUnreadable()` | problem | "The recording couldn't be read" | "Muninn quit while recording, and the audio files can't be opened." | none |
| `recordingDidNotStart()` | problem | "The recording didn't start" | "Check that Muninn may use the microphone and record system audio in System Settings, then try again." | none |
| `recordingPartlyUnsaved(tracks:)` | warning | "Part of the recording couldn't be saved" | "The \(tracks) recording couldn't be fully written. Muninn kept the meeting; its transcript may be incomplete." | none |
| `recordingTrackStopped(track:)` | problem | "\(Track) is no longer being saved" (first letter capitalised) | "The rest of this recording won't include the \(track)." | none |
| `noCallAudio(app:)` | warning | "No call audio for a minute" | "Check that \(app) plays through This Mac and that Muninn may record system audio." | none |
| `writtenOnThisMac(because:)` | warning | "Written on This Mac" | `.studioNotConfigured`: "The Network Mac isn't set up, so This Mac wrote the recap."; otherwise "The Network Mac couldn't be reached, so This Mac wrote the recap." | none |
| `keptRecap(_ reason: WaitReason, api:)` | problem | "The recap wasn't rewritten" | "\(sentence), so Muninn kept the recap you had." — sentences: studioUnreachable "The Network Mac couldn't be reached"; studioNotConfigured "The Network Mac isn't set up"; memoryPressure "This Mac was short of memory"; claudeKeyMissing "There's no Claude API key"; recording "A recording was running" | `tryAgain, writeWithAnotherEngine` |
| `regenerationFailed(_ cause: Problem)` | problem | `cause.title` | `cause.explanation + " Muninn kept the recap you had."` | `cause.actions`; details `cause.details` |
| `diarisationDegraded(mode:)` | warning | call: "Couldn't tell the other speakers apart"; mic only: "Couldn't tell the speakers apart" | call: "The call side of the transcript is one speaker."; mic only: "The whole conversation is one speaker in the transcript." | none |
| `eventNotChanged()` | info | "The event wasn't changed" | "A draft or a note already exists for this meeting." | none |
| `vaultNotChosen()` | warning | "Choose your Obsidian vault first" | "Pick the vault folder in Obsidian settings, then file the recap." | none |
| `notFiledAutomatically(unsourced:)` | warning | "Not filed automatically" | "1 recap item has no transcript source. Check it, then file the recap." / "\(n) recap items have no transcript source. Check them, then file the recap." | none |
| `draftWithoutLink()` | info | "Draft created in Outlook" | "Microsoft didn't return a link to it; find it in Outlook's Drafts." | none |
| `waiting(_ reason:api:claudeKeyPresent:)` | warning | see below | see below | see below |

`waiting` per reason (`+claude` means `writeWithClaude` appended only when `claudeKeyPresent`): `studioUnreachable` → "Waiting for the Network Mac" / "It isn't answering. Muninn tries again by itself, or write this recap with another engine." / `writeOnThisMac`+claude; `studioNotConfigured` → `networkMacNotSetUp` copy / `engineSettings, writeOnThisMac`+claude; `memoryPressure` → "Waiting for memory to free up" / "This Mac is short of memory, so Muninn waits before running the model here." / `writeOnThisMac`+claude; `claudeKeyMissing` → `claudeKeyMissing` copy and actions; `recording` → "Waiting for the recording to end" / "Muninn doesn't run the model on This Mac while it records." / none. Severity is `warning` for every wait.

- [ ] **Step 1: Write the failing tests** in `ProblemTests.swift` (`@Suite struct ProblemTests`):

```swift
@Test func thisMacServerTitleFollowsTheAPI() {
    #expect(Problems.thisMacServerNotRunning(api: .ollama, claudeKeyPresent: true, waiting: false).title == "Ollama isn't running on This Mac")
    #expect(Problems.thisMacServerNotRunning(api: .openAICompatible, claudeKeyPresent: true, waiting: false).title == "The model server on This Mac isn't running")
}
@Test func thisMacServerOffersClaudeOnlyWithAKey() {
    #expect(Problems.thisMacServerNotRunning(api: .ollama, claudeKeyPresent: true, waiting: true).actions == [.writeWithClaude, .tryAgain, .engineSettings])
    #expect(Problems.thisMacServerNotRunning(api: .ollama, claudeKeyPresent: false, waiting: true).actions == [.tryAgain, .engineSettings])
}
@Test func modelNotInstalledNamesThePullCommandForOllamaOnly() {
    #expect(Problems.modelNotInstalled(model: "qwen3:8b", engine: .macbook, api: .ollama).explanation.contains("ollama pull qwen3:8b"))
    #expect(!Problems.modelNotInstalled(model: "m", engine: .studio, api: .openAICompatible).explanation.contains("ollama"))
}
@Test func catalogueFollowsTheCopyRules() {
    // every factory, with representative arguments, including each `waiting` reason and `keptRecap` reason
    for problem in allSampleProblems {
        #expect(problem.actions.count <= 3)
        #expect(!problem.title.hasSuffix("."))
        #expect(problem.title.first?.isUppercase == true)
        #expect(!"\(problem.title) \(problem.explanation)".localizedCaseInsensitiveContains("summar"))
    }
}
@Test func detailsTextOmitsTheHostUnlessAsked() {
    let details = ProblemDetails(request: RequestFacts(method: "POST", path: "/api/chat", host: "studio.local"))
    #expect(!details.text(includeHost: false).contains("studio.local"))
    #expect(details.text(includeHost: true).contains("Request: POST /api/chat on studio.local"))
}
@Test func requestFactsHideLongPathSegments() {
    let url = URL(string: "https://graph.microsoft.com/v1.0/me/events/\(String(repeating: "A", count: 40))")!
    #expect(RequestFacts(method: "GET", url: url) == RequestFacts(method: "GET", path: "/v1.0/me/events/{id}", host: "graph.microsoft.com"))
}
@Test func problemsRoundTripThroughJSON() throws { /* encode/decode a problem with every details field set; expect equality */ }
@Test func redactionRemovesKeysAndTokens() {
    #expect(Redaction.redact("key sk-ant-api03-abcdefghijklmnop") == "key [redacted]")
    #expect(!Redaction.redact("Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.c2lnbmF0dXJlLXZhbHVl").contains("eyJ"))
    #expect(Redaction.redact(String(repeating: "aB3", count: 16)) == "[redacted]")
    #expect(Redaction.redact("2026-11-03-1400-supplier-call-about-the-quarterly-numbers") == "2026-11-03-1400-supplier-call-about-the-quarterly-numbers")
    #expect(Redaction.redact("qwen3:8b") == "qwen3:8b")
}
@Test func detailsRedactEveryStringField() {
    let details = ProblemDetails(request: RequestFacts(method: "POST", path: "/sk-ant-api03-abcdefgh/api/chat", host: "studio.local"), model: "sk-ant-api03-zzzzzzzz")
    #expect(!details.text(includeHost: true).contains("sk-ant-api03"))
    #expect(details.redacted().request?.path == "/[redacted]/api/chat")
}
@Test func requestFactsDropQueryAndUserInfo() {
    #expect(RequestFacts(method: "GET", url: URL(string: "http://me:secret@studio.local:11434/api/tags?key=abc")!) == RequestFacts(method: "GET", path: "/api/tags", host: "studio.local"))
}
@Test func stagePhrasesAndAreas() {
    #expect(ProblemStage.writingRecap.phrase == "writing the recap")
    #expect(ProblemStage.writingRecap.area == .recap)
    #expect(ProblemStage.creatingDraft.area == .outlook)
}
@Test func waitNeedsYouOnlyForReasonsThatDontClear() {
    #expect(WaitReason.studioNotConfigured.needsYou && WaitReason.claudeKeyMissing.needsYou)
    #expect(!WaitReason.studioUnreachable.needsYou && !WaitReason.memoryPressure.needsYou && !WaitReason.recording.needsYou)
}
@Test func engineContextTakesTheModelFromSettings() {
    let context = ProblemContext.engine(.studio, settings: .defaults, stage: .writingRecap, claudeKeyPresent: false)
    #expect(context.model == "gpt-oss:20b" && context.endpointAPI == .ollama)
    #expect(ProblemContext.engine(.claude, settings: .defaults, stage: .writingRecap, claudeKeyPresent: true).model == "claude-opus-5-5")
}
@Test func withActionsReplacesOnlyTheActions() {
    let problem = Problems.keychainUnreadable().with(actions: [.tryAgain])
    #expect(problem.actions == [.tryAgain] && problem.title == Problems.keychainUnreadable().title)
}
@Test func accountProblemsCarryTheAccount() { /* signInExpired, signInFailed, calendarUnreadable(account: "Work") → details.account == "Work" */ }
@Test func regenerationFailedKeepsTheCause() {
    let cause = Problems.claudeBusy()
    let kept = Problems.regenerationFailed(cause)
    #expect(kept.title == cause.title && kept.actions == cause.actions)
    #expect(kept.explanation.hasSuffix("Muninn kept the recap you had."))
}
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter ProblemTests` — expect a build failure (types missing).
- [ ] **Step 3: Implement** `Problem.swift` and `Problems.swift` with the interfaces and copy above.
- [ ] **Step 4: Run** the focused suite — expect PASS.
- [ ] **Step 5: Commit** — `Add the problem model and its catalogue`

---

### Task 2: Engine and Graph errors carry no outside text

**Depends on:** Task 1

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Problems/ProviderErrorClassifier.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Engines/LLMClient.swift` (`LLMError`, `LLMTransport.post`, `LLMTransport.decode`)
- Modify: `Engines/ClaudeClient.swift`, `Engines/OllamaClient.swift`, `Engines/OpenAICompatibleClient.swift` (pass their provider)
- Modify: `Graph/GraphClient.swift` (`send`, `decode`, `parseUTC`), `Graph/DeviceCodeAuthenticator.swift` (`GraphError`, `post`, `decode`, `failure`)
- Modify: `Summary/SummaryParser.swift` (`SummaryParseError`)
- Test: `Tests/MuninnCoreTests/LLMClientTests.swift`, `GraphTests.swift`, `SummaryTests.swift`

**Interfaces:**
- Consumes: `RequestFacts`, `Provider`, `ProviderErrorCategory` (Task 1).
- Produces:
  - `enum LLMError: Error, Equatable { case http(status: Int, category: ProviderErrorCategory, request: RequestFacts); case connection(code: Int, request: RequestFacts); case refused(String?); case emptyResponse; case truncated; case decoding; case promptTruncated(model: String, contextTokens: Int) }` — keep the existing `LocalizedError` conformance for `promptTruncated` until Task 5 removes it.
  - `LLMTransport.post(_ url: URL, headers: [String: String], body: JSONValue, provider: Provider, session: URLSession) async throws -> Data` — a `URLError` other than `.cancelled` becomes `.connection(code: error.code.rawValue, request: RequestFacts(method: "POST", url: url))`; `.cancelled` is rethrown unchanged; a non-2xx reply becomes `.http(status:category: ProviderErrorClassifier.category(status:body:provider:), request:)`; the body is not kept.
  - `enum ProviderErrorClassifier { static func category(status: Int, body: Data, provider: Provider) -> ProviderErrorCategory; static let knownGraphCodes: Set<String>; static let knownOAuthCodes: Set<String>; static func graphCode(in body: Data) -> String?; static func oauthCode(_ code: String?) -> String }` — `graphCode` reads `error.code`: nil when there is none, the code when it is in `knownGraphCodes`, otherwise `"other"`; `oauthCode` returns the code when it is in `knownOAuthCodes`, otherwise `"unrecognised"`.
    - `knownGraphCodes`: `ErrorAccessDenied`, `ErrorItemNotFound`, `ErrorInvalidRequest`, `ErrorInvalidIdMalformed`, `ErrorInvalidRecipients`, `ErrorQuotaExceeded`, `ErrorSendAsDenied`, `ErrorMessageSizeExceeded`, `ErrorExceededMessageLimit`, `ErrorMailboxNotEnabledForRESTAPI`, `MailboxNotEnabledForRESTAPI`, `ErrorNonExistentMailbox`, `ErrorInternalServerError`, `ErrorServerBusy`, `ErrorTimeoutExpired`, `InvalidAuthenticationToken`, `AuthenticationError`, `Authorization_RequestDenied`, `Request_ResourceNotFound`, `Request_BadRequest`, `Forbidden`, `Unauthorized`, `BadRequest`, `TooManyRequests`, `ApplicationThrottled`, `ServiceUnavailable`, `generalException`, `itemNotFound`, `accessDenied`, `invalidRequest`, `activityLimitReached`, `serviceNotAvailable`, `unauthenticated`, `quotaLimitReached`.
    - `knownOAuthCodes`: `invalid_request`, `invalid_client`, `invalid_grant`, `unauthorized_client`, `unsupported_grant_type`, `invalid_scope`, `authorization_pending`, `slow_down`, `access_denied`, `expired_token`, `authorization_declined`, `bad_verification_code`, `interaction_required`, `consent_required`, `login_required`, `temporarily_unavailable`, `server_error`.
  - Classification, first match wins:
    - Ollama: 404 with an `error` string containing "not found" (case-insensitive) → `modelNotFound`.
    - Anthropic `error.type`: `authentication_error`, `permission_error` → `unauthorized`; `rate_limit_error` → `rateLimited`; `overloaded_error` → `overloaded`; `not_found_error` → `modelNotFound`; `invalid_request_error` whose message contains "prompt is too long" → `contextTooLong`, otherwise → `badRequest`; `api_error` → `serverError`.
    - OpenAI-compatible `error.code`: `model_not_found` → `modelNotFound`; `context_length_exceeded` → `contextTooLong`; `invalid_api_key` → `unauthorized`.
    - Status fallback for every provider: 401, 403 → `unauthorized`; 404 → `modelNotFound` for Ollama and OpenAI-compatible, `unknown` otherwise; 429 → `rateLimited`; 503, 529 → `overloaded`; 400, 413, 422 → `badRequest`; other 5xx → `serverError`; anything else → `unknown`.
  - `enum GraphError: Error, Equatable { case notSignedIn; case auth(String); case http(status: Int, code: String?, request: RequestFacts); case connection(code: Int, request: RequestFacts); case decoding }` — `auth` holds `ProviderErrorClassifier.oauthCode` of the OAuth `error` (the device-code poll still reads `authorization_pending` and `slow_down` from the body as today); `isExpiredSignIn` is true for `auth`, `notSignedIn` and `http(status: 401, …)`; `errorDescription` keeps no body: `http` → "Microsoft Graph returned HTTP \(status).", `decoding` → "Unexpected response from Microsoft.", `connection` → "Microsoft can't be reached." (the app stops using these in Task 15).
  - `GraphClient.send` and the authenticator's `post` turn a `URLError` other than `.cancelled` into `.connection(code:request:)`. Graph requests use `RequestFacts(method:url:)`; OAuth requests use `RequestFacts(method: "POST", path: "/{tenant}/oauth2/v2.0/\(name)", host: "login.microsoftonline.com")`. `parseUTC` throws `.decoding` without the date text.
  - `enum SummaryParseError: Error, Equatable { case notJSON; case schemaMismatch }` (payloads dropped).
- Add to `StubURLProtocol.Reply` an optional `failure: URLError?`; when set, `startLoading` calls `client?.urlProtocol(self, didFailWithError:)` instead of replying.

- [ ] **Step 1: Write the failing tests.** `SEED` is `"We agreed to move the Henderson launch to March."`.

```swift
// LLMClientTests
@Test func httpErrorKeepsNoBodyText() async {
    StubURLProtocol.reset([.init(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"\#(SEED)"}}"#)])
    let error = await #expect(throws: LLMError.self) { try await claude().complete(request) }
    #expect(error == .http(status: 400, category: .badRequest, request: RequestFacts(method: "POST", path: "/v1/messages", host: "api.anthropic.com")))
    #expect(!String(reflecting: error!).contains("Henderson"))
}
@Test func ollamaModelNotFoundIsClassified() async {
    // 404 {"error":"model 'qwen3:8b' not found, try pulling it first. \(SEED)"} on base http://127.0.0.1:11434
    // expect .http(status: 404, category: .modelNotFound, request: RequestFacts(method: "POST", path: "/api/chat", host: "127.0.0.1")), no "Henderson"
}
@Test(arguments: [
    (401, "authentication_error", ProviderErrorCategory.unauthorized), (403, "permission_error", .unauthorized),
    (429, "rate_limit_error", .rateLimited), (529, "overloaded_error", .overloaded), (500, "api_error", .serverError),
])
func anthropicErrorTypesMapToCategories(status: Int, type: String, category: ProviderErrorCategory) {
    let body = Data(#"{"type":"error","error":{"type":"\#(type)","message":"x"}}"#.utf8)
    #expect(ProviderErrorClassifier.category(status: status, body: body, provider: .anthropic) == category)
}
@Test func promptTooLongIsContextTooLong() { /* 400 invalid_request_error "prompt is too long: 250000 tokens" → .contextTooLong */ }
@Test func openAICompatibleCodesMapToCategories() { /* model_not_found → .modelNotFound, context_length_exceeded → .contextTooLong, invalid_api_key → .unauthorized */ }
@Test(arguments: [(401, ProviderErrorCategory.unauthorized), (429, .rateLimited), (503, .overloaded), (500, .serverError), (418, .unknown)])
func statusFallbacks(status: Int, category: ProviderErrorCategory) {
    #expect(ProviderErrorClassifier.category(status: status, body: Data("<html>".utf8), provider: .anthropic) == category)
}
@Test func connectionFailureCarriesCodeAndRequest() async { /* Reply(failure: URLError(.cannotConnectToHost)) → .connection(code: -1004, request: POST /api/chat on 127.0.0.1) */ }
@Test func cancellationStaysACancellation() async { /* Reply(failure: URLError(.cancelled)) → thrown error is URLError with code .cancelled */ }
@Test func decodingErrorKeepsNoText() async { /* 200 with body "not json \(SEED)" → LLMError.decoding */ }

// GraphTests
@Test func graphHTTPErrorKeepsOnlyAKnownCode() async {
    // createDraft against a stub: 403 {"error":{"code":"ErrorAccessDenied","message":"\(SEED)"}}
    // → .http(status: 403, code: "ErrorAccessDenied", request: RequestFacts(method: "POST", path: "/v1.0/me/messages", host: "graph.microsoft.com"))
    // code "ConfidentialAcquisition" → code "other"; code "Access denied \(SEED)" → code "other"; no error object → code nil
}
@Test func authFailureKeepsOnlyAKnownOAuthCode() async { /* {"error":"weird_code"} and {"error":"\(SEED)"} on refresh → .auth("unrecognised"); {"error":"invalid_grant"} → .auth("invalid_grant") */ }
@Test func requestFactsHideLongIdentifiers() async { /* event(id: 60-char id) failing with 404 → request.path == "/v1.0/me/events/{id}" */ }
```

Update the existing tests that construct `GraphError.http(Int, String)`, `.decoding(String)`, `LLMError.http(Int, String)`, `.decoding(String)` and `SummaryParseError` payloads, and the `localizedDescription` expectations at `GraphTests.swift:519-522`, to the new shapes.

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter "LLMClientTests|GraphTests|SummaryTests"` — expect failures.
- [ ] **Step 3: Implement** the interfaces above.
- [ ] **Step 4: Run** the same suites, then the whole Core suite — expect PASS.
- [ ] **Step 5: Commit** — `Classify engine and Graph errors without keeping response text`

---

### Task 3: The translator

**Depends on:** Tasks 1, 2

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Problems/ProblemTranslator.swift`
- Move: `Packages/MuninnPlatform/Sources/MuninnSystem/EngineClients.swift` `EngineClientError` → `Packages/MuninnCore/Sources/MuninnCore/Engines/EngineClientError.swift` (same cases, still `public`, `Error, Equatable`, its `LocalizedError` strings dropped); remove the two `errorDescription` expectations at `SystemTests.swift:269-270`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/ProblemTranslatorTests.swift`

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces: `enum ProblemTranslator { static func problem(for error: Error, in context: ProblemContext, system: SystemInfo = .current) -> Problem }`.
- Rules, first match wins. "Engine" means `context.engine`.
  1. `ProblemConvertible` → `error.problem(in: context)`.
  2. `LLMError.connection` (and a bare `URLError`, using `NSURLErrorFailingURLErrorKey` for the request, method `GET`): engine `.macbook` → `thisMacServerNotRunning(api: context.endpointAPI ?? .ollama, claudeKeyPresent: context.claudeKeyPresent, waiting: false)`; `.studio` → `networkMacUnreachable`; `.claude` → `claudeUnreachable`; no engine and stage `creatingDraft`, `readingCalendar`, `searchingPeople`, `signingIn` or `changingEvent` → `microsoftUnreachable`; stage `preparingSpeechModel` → `speechModelUnavailable(model: context.model ?? "the speech model")`; otherwise `somethingWentWrong`.
  3. `LLMError.http`: `modelNotFound` → `modelNotInstalled(model: context.model ?? "", engine: engine ?? .macbook, api: context.endpointAPI ?? .ollama)`; `unauthorized` with engine `.claude` → `claudeKeyRejected`; `rateLimited` or `overloaded` with `.claude` → `claudeBusy`; `contextTooLong` → `transcriptTooLong(model:)`; otherwise `somethingWentWrong`.
  4. `LLMError.truncated`, `.emptyResponse`, `.decoding`, `SummaryParseError` → `recapIncomplete(engine: engine ?? .macbook)` when stage is `writingRecap` or `cleaningUp`, else `somethingWentWrong`. `LLMError.refused` → `recapRefused`. `LLMError.promptTruncated(model, _)` → `transcriptTooLong(model:)`.
  5. `GraphError`: stage `signingIn` and `.auth`/`.http` → `signInFailed(account:)`; otherwise `.notSignedIn`, `.auth`, `.http(401)` → `signInExpired(account:)`; `.http` at `creatingDraft` → `outlookDraftFailed`; `.http` at `readingCalendar` or `changingEvent` → `calendarUnreadable(account:)`; `.connection` → `microsoftUnreachable`; otherwise `somethingWentWrong`. The account is `context.accountName ?? "your Microsoft account"`.
  6. `EngineClientError.invalidBaseURL(.studio)` → `networkMacNotSetUp`; `.invalidBaseURL(.macbook)` → `thisMacAddressInvalid`; `.missingClaudeKey` → `claudeKeyMissing`.
  7. `NSError` in `NSCocoaErrorDomain` with code 512–642, or `NSPOSIXErrorDomain` with `ENOSPC`, `EACCES`, `EROFS`, `EDQUOT` → `couldNotSave(what: context.subject ?? "the meeting")`, `details.path` from `NSFilePathErrorKey` or `NSURLErrorKey`.
  8. Anything else → `somethingWentWrong(stage: context.stage)`.
- Every result's details are completed, keeping a field the rule already set, then `redacted()`: `errorDomain` and `errorCode` — for `LLMError.connection` and `GraphError.connection` `NSURLErrorDomain` and the associated code; for the other cases of Muninn's own error enums (`LLMError`, `GraphError`, `SummaryParseError`, `EngineClientError`) the type name and no code; for any other error the domain and code of `error as NSError` (never its description); `request`, `httpStatus`, `category`, `graphCode` from the error; `engine`, `model` and `account` (from `accountName`) from the context; `provider` from the engine (`Provider.endpoint(api)` for This Mac and the Network Mac, `.anthropic` for Claude) or `.microsoftGraph` / `.microsoftSignIn` for Graph and OAuth; `stage`, `elapsedSeconds` from the context; `appVersion`, `osVersion` from `system`.

- [ ] **Step 1: Write the failing tests**, one per rule, with `let system = SystemInfo(appVersion: "test (1)", osVersion: "26.1")`:

```swift
@Test func connectionRefusedOnThisMacWithAKey() {
    let error = LLMError.connection(code: -1004, request: RequestFacts(method: "POST", path: "/api/chat", host: "127.0.0.1"))
    let problem = ProblemTranslator.problem(for: error, in: .engine(.macbook, settings: .defaults, stage: .writingRecap, claudeKeyPresent: true), system: system)
    #expect(problem.title == "Ollama isn't running on This Mac")
    #expect(problem.actions == [.writeWithClaude, .tryAgain, .engineSettings])
    #expect(problem.details.errorCode == -1004 && problem.details.request?.path == "/api/chat")
    #expect(problem.details.stage == .writingRecap && problem.details.engine == .macbook && problem.details.provider == .ollama && problem.details.model == "qwen3:8b")
    #expect(problem.details.appVersion == "test (1)" && problem.details.osVersion == "26.1")
}
@Test func timeoutOnAnOpenAICompatibleThisMacWithoutAKey() { /* URLError(.timedOut) code -1001, api .openAICompatible → "The model server on This Mac isn't running", [.tryAgain, .engineSettings] */ }
@Test func networkMacUnreachable() { /* .connection on .studio → "The Network Mac can't be reached", errorDomain NSURLErrorDomain, errorCode -1004 */ }
@Test func muninnErrorsDontReportBridgedCodes() { /* LLMError.http(429, …) on .claude → errorDomain "LLMError", errorCode nil, httpStatus 429 */ }
@Test func modelNotFoundOnTheNetworkMac() { /* .http(404, .modelNotFound) on .studio → "The model gpt-oss:20b isn't installed", explanation contains "ollama pull gpt-oss:20b", [.tryAgain] */ }
@Test(arguments: [401, 403]) func claudeRejectsTheKey(status: Int) { /* → "Claude didn't accept the API key", [.changeKey, .tryAgain] */ }
@Test(arguments: [ProviderErrorCategory.rateLimited, .overloaded]) func claudeIsBusy(category: ProviderErrorCategory) { /* → "Claude is busy right now", [.tryAgain, .writeOnThisMac] */ }
@Test func incompleteRepliesAtTheRecapStage() { /* .truncated, .emptyResponse, .decoding, SummaryParseError.notJSON → "The recap came back incomplete", [.tryAgain, .writeWithAnotherEngine] */ }
@Test func promptTruncatedIsTooLong() { /* → "The transcript is too long for qwen3:8b" */ }
@Test func refusalNamesTheEngine() { /* .refused(nil) on .claude → "Claude declined to write this recap" */ }
@Test func expiredSignIn() { /* .auth("invalid_grant"), .notSignedIn, .http(401) at .readingCalendar, accountName "Work" → "Sign-in to Work expired", [.signInAgain] */ }
@Test func signInThatFails() { /* .auth("authorization_declined") at .signingIn → "Sign-in to Work didn't finish" */ }
@Test func graphErrorWhileDrafting() { /* .http(500, code "ErrorInternalServerError") at .creatingDraft → "Outlook couldn't create the draft", details.httpStatus 500, graphCode "ErrorInternalServerError", provider .microsoftGraph */ }
@Test func microsoftUnreachableWhileDrafting() { /* GraphError.connection at .creatingDraft → "Microsoft can't be reached" */ }
@Test func engineClientErrors() { /* invalidBaseURL(.studio) → "The Network Mac isn't set up"; (.macbook) → "This Mac's model server address isn't valid"; missingClaudeKey → "There's no Claude API key" */ }
@Test func diskWriteFailures() {
    // CocoaError(.fileWriteOutOfSpace, userInfo: [NSFilePathErrorKey: "/x/summary.json"]) and POSIXError(.ENOSPC), subject "the recap"
    // → "Muninn couldn't save the recap", details.path "/x/summary.json" for the first
}
@Test func anythingElseNamesTheStage() { /* struct Boom: Error at .identifyingSpeakers → "Something went wrong while telling the speakers apart", [.tryAgain], details.errorDomain contains "Boom" */ }
@Test func convertibleErrorsSpeakForThemselves() { /* a test-local ProblemConvertible returning Problems.hotkeyInUse(keys: "⌃⌥⌘F") → that title, with stage and versions filled */ }
@Test func translatedProblemsNeverCarryErrorText() {
    let error = NSError(domain: "Test", code: 7, userInfo: [NSLocalizedDescriptionKey: SEED, NSLocalizedFailureReasonErrorKey: SEED])
    let problem = ProblemTranslator.problem(for: error, in: ProblemContext(stage: .writingRecap), system: system)
    let encoded = String(decoding: try! JSONEncoder().encode(problem), as: UTF8.self)
    #expect(!encoded.contains("Henderson"))
}
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter ProblemTranslatorTests` — expect a build failure.
- [ ] **Step 3: Implement** the translator and move `EngineClientError`. Build MuninnPlatform: `X swift build --package-path Packages/MuninnPlatform`.
- [ ] **Step 4: Run** the focused suite, the whole Core suite and `X swift test --package-path Packages/MuninnPlatform --filter MuninnSystemTests` — expect PASS.
- [ ] **Step 5: Commit** — `Translate errors into problems`

---

### Task 4: The pipeline publishes its current work and queue

**Depends on:** Task 1

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Pipeline/PipelineSnapshot.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Pipeline/ProcessingPipeline.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/PipelineTests.swift`

**Interfaces:**
- Produces:
  - `public enum PipelineStage: String, Codable, Hashable, Sendable, CaseIterable { case transcribing, identifyingSpeakers, cleaningUp, writingRecap }` with `step: Int` (1–4), `title: String` ("Transcribing", "Telling the speakers apart", "Cleaning up the transcript", "Writing the recap"), `stepLabel: String` ("Transcribed", "Speakers", "Cleaned up", "Recap"), `problemStage: ProblemStage` (the same-named case), `savedThing: String` ("the transcript", "the transcript", "the clean transcript", "the recap").
  - `public struct PipelineWork: Equatable, Sendable { var meetingID: MeetingID; var stage: PipelineStage; var engine: EngineKind?; var stageStartedAt: Date }`
  - `public struct PipelineSnapshot: Equatable, Sendable { var current: PipelineWork?; var queued: [MeetingID]; static let idle }`
  - `ProcessingPipeline.setOnSnapshot(_ handler: (@Sendable (PipelineSnapshot) -> Void)?)` and `ProcessingPipeline.snapshot() -> PipelineSnapshot`. The handler is called on every change of the snapshot, never with an unchanged one.
- Behaviour: `Job` gets `let id: MeetingID`. `queued` is the ids of jobs in `turnOrder`, oldest first. A job leaves `queued` when it gets its turn. `current` is set where the pipeline writes `.transcribing` (engine nil), `.diarizing` (`identifyingSpeakers`, nil), `.cleaning` (`cleaningUp`; the decision's engine when `settings.useLLMCleanup` and the decision is `.run`, else nil) and `.summarizing` (`writingRecap`, the decision's engine), with `stageStartedAt = clock()`. `current` returns to nil when the job ends, however it ends.

- [ ] **Step 1: Write the failing tests** in `PipelineTests` using the existing harness:

```swift
@Test func snapshotListsQueuedMeetingsInOrder() async throws {
    // transcriber blocks until released; process A, then B and C without awaiting
    // wait until A's transcriber has started, then:
    #expect(await pipeline.snapshot().current?.meetingID == a && pipeline.snapshot().current?.stage == .transcribing)
    #expect(await pipeline.snapshot().queued == [b, c])
}
@Test func snapshotFollowsTheStages() async throws {
    // collect snapshots via setOnSnapshot during one full run with default engine .macbook
    // stages, deduplicated in order == [.transcribing, .identifyingSpeakers, .cleaningUp, .writingRecap]
    // the writingRecap work has engine .macbook; the last snapshot == .idle
}
@Test func ruleCleanupHasNoEngine() async throws { /* useLLMCleanup false → the cleaningUp work's engine is nil */ }
@Test func aMeetingQueuedTwiceAppearsOnce() async throws { /* process B twice while A runs → queued == [b] */ }
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter PipelineTests` — expect failures.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `PipelineTests`, then the Core suite — expect PASS.
- [ ] **Step 5: Commit** — `Publish the pipeline's current work and queue`

---

### Task 5: Meetings store problems, not strings

**Depends on:** Tasks 3, 4

**Files:**
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Model/Meeting.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Pipeline/ProcessingPipeline.swift`, `Pipeline/LaunchRecovery.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Engines/LLMClient.swift` (drop the `LocalizedError` conformance)
- Modify (compile only): `Packages/MuninnPlatform/Sources/MuninnSpike/Commands/EndToEnd.swift`, `Muninn/AppModel.swift`, `Muninn/RecordingController.swift`, `Muninn/Views/SummaryEditor.swift`
- Test: `ModelTests.swift`, `PipelineTests.swift`, and every Core test constructing `.failed("…")` (`RecordingGuardTests`, `AccountManagementTests`, `ModelTests`, `PipelineTests`)

**Interfaces:**
- Consumes: Tasks 1, 3, 4.
- Produces:
  - `ProcessingStatus.failed(Problem)`, encoded `{"type":"failed","problem":{…}}`. Decoding `{"type":"failed","message":<any string>}` gives `.failed(Problems.legacyFailure())`; the string is discarded.
  - `Meeting.engineNotice: Problem?` and a new `Meeting.transcriptNotice: Problem?` (key `transcriptNotice`; `Meeting.init` takes `transcriptNotice: Problem? = nil` as its last parameter). Decoding `engineNotice` tries `Problem`, then `String`: a string containing "Couldn't tell the other speakers apart; the call side is one speaker." or "Couldn't tell the speakers apart; the conversation is one speaker." sets `transcriptNotice` (when that key is absent) to `Problems.diarisationDegraded(mode: captureMode)`; the rest of the string, with the diarisation sentence removed and trimmed, sets `engineNotice`: empty → nil; containing "summarized on This Mac" → `Problems.writtenOnThisMac(because: <contains "not set up" ? .studioNotConfigured : .studioUnreachable>)`; anything else → `Problems.legacyEngineNotice()`.
  - `extension Meeting { public var needsAttention: Bool }` — `.failed` → true; `.waiting(r)` → `r.needsYou`; otherwise `engineNotice?.severity == .problem`.
  - Pipeline: `fail(_:fallback:problem:metrics:)` stores `.failed(problem)`. `execute` builds the problem with `ProblemTranslator.problem(for:in:)` and a context from the current `PipelineWork` (stage, engine, elapsed since `stageStartedAt`, `subject` = `stage.savedThing`), `settings` (via `ProblemContext.engine` when there is an engine) and the last `EngineEnvironment` the job probed (`claudeKeyPresent`); with no current work, `ProblemContext(stage: .other)`.
  - Notices: a run that fell back from the Network Mac sets `engineNotice = Problems.writtenOnThisMac(because:)`; a regeneration held by a wait sets `Problems.keptRecap(reason, api: settings.macbook.api)`; a regeneration whose summariser throws sets `Problems.regenerationFailed(translated)`; any other successful run clears `engineNotice`. A diarisation failure sets `transcriptNotice = Problems.diarisationDegraded(mode:details:)` with `errorDomain` and `errorCode` of the diarizer's error; a successful diarisation clears it. `notice(_:keeping:)`, the notice string constants, `keptSummaryNotice` and `message(_:)` are removed.
  - `LaunchRecovery.unreadableMessage` is removed; `AppModel` stores `.failed(Problems.recordingUnreadable())`.
  - App and spike, compile only (Task 14 replaces them): `SummaryEditor` shows `problem.title` for `.failed`, and `engineNotice?.title` and `transcriptNotice?.title` in its existing banners; `RecordingController.fail` stores `.failed(ProblemTranslator.problem(for: error, in: ProblemContext(stage: .recording)))`; `EndToEnd` prints `notice.title`.

- [ ] **Step 1: Write the failing tests.**

```swift
// ModelTests
@Test func failedStatusRoundTripsItsProblem() throws { /* .failed(Problems.claudeBusy()) encode/decode equal */ }
@Test func legacyFailureStringLoadsAsAGenericProblem() throws {
    // meeting JSON with "status":{"type":"failed","message":"Error Domain=NSURLErrorDomain Code=-1004 \(SEED)"}
    guard case .failed(let problem) = meeting.status else { Issue.record(); return }
    #expect(problem.title == "This meeting couldn't be finished" && problem.actions == [.tryAgain] && problem.details.fromEarlierVersion)
    #expect(!String(decoding: try JSONEncoder().encode(meeting), as: UTF8.self).contains("Henderson"))
}
@Test func legacyEngineNoticeLoadsWithoutItsText() throws {
    // "engineNotice":"Claude failed: \(SEED) — kept the existing summary"
    #expect(meeting.engineNotice?.title == "An earlier recap attempt didn't finish" && meeting.engineNotice?.severity == .problem)
    #expect(meeting.engineNotice?.actions == [.tryAgain, .writeWithAnotherEngine] && meeting.needsAttention)
    // re-encoded JSON has no "Henderson"
}
@Test func legacyFallbackNoticeStaysAWarning() throws {
    // "engineNotice":"Network Mac unreachable — summarized on This Mac" on a ready meeting
    #expect(meeting.engineNotice == Problems.writtenOnThisMac(because: .studioUnreachable) && !meeting.needsAttention)
    // "Network Mac not set up — summarized on This Mac" → (because: .studioNotConfigured)
}
@Test func legacyDiarisationNoticeBecomesATranscriptNotice() throws {
    // "engineNotice":"Couldn't tell the other speakers apart; the call side is one speaker." on a call meeting
    #expect(meeting.transcriptNotice?.title == "Couldn't tell the other speakers apart" && meeting.engineNotice == nil)
}
@Test func needsAttention() {
    // failed → true; waiting(.claudeKeyMissing) → true; waiting(.studioUnreachable) → false;
    // ready + engineNotice keptRecap(…) → true; ready + writtenOnThisMac → false; recording → false
}

// PipelineTests
@Test func failureCarriesTheStageAndEngine() async throws {
    // summariser throws LLMError.connection(code: -1004, request: POST /api/chat on 127.0.0.1), default engine .macbook
    guard case .failed(let problem) = try h.meetingNow().status else { Issue.record(); return }
    #expect(problem.title == "Ollama isn't running on This Mac")
    #expect(problem.details.stage == .writingRecap && problem.details.engine == .macbook)
}
@Test func diarisationNoticeSurvivesAFailedRegeneration() async throws { /* transcriptNotice set; regenerate fails → transcriptNotice unchanged, engineNotice severity .problem */ }
```

Rewrite the existing notice expectations to the new values: `fallbackNoticeSet` → `Problems.writtenOnThisMac(because: .studioUnreachable)`; `fallbackNoticeSaysWhenTheNetworkMacIsNotSetUp` → `(because: .studioNotConfigured)`; the kept-summary tests → `Problems.keptRecap(<reason>, api: .ollama)`; the diarisation tests → `transcriptNotice`; the failed-regeneration test (around line 1189) → `engineNotice?.severity == .problem` and `engineNotice?.explanation.hasSuffix("Muninn kept the recap you had.") == true`; the failure test around line 764 → `.failed(let problem)` with the translator's title.

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore` — expect failures.
- [ ] **Step 3: Implement**, then fix the spike and app call sites.
- [ ] **Step 4: Run** the Core suite, the Platform suite, then `mise exec -- xcodegen generate` and the app build — expect PASS.
- [ ] **Step 5: Commit** — `Store problems instead of error strings on meetings`

---

### Task 6: Wait when This Mac's server is down, and re-check every 15 seconds

**Depends on:** Task 5

**Files:**
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Model/Meeting.swift` (`WaitReason`)
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Engines/EngineSelector.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Problems/Problems.swift`, `Problem.swift` (`needsYou`)
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Pipeline/ProcessingPipeline.swift`
- Create: `Packages/MuninnCore/Sources/MuninnCore/Pipeline/WaitRetry.swift`
- Modify (compile only): `Muninn/Views/Formatting.swift` (`WaitReason.text`), `Muninn/Views/SummaryEditor.swift`
- Test: `EngineSelectorTests.swift`, `PipelineTests.swift` (give `FakeProbe` a `calls` counter), `ProblemTests.swift`

**Interfaces:**
- Produces:
  - `WaitReason` gains `thisMacUnreachable` and `claudeKeyUnreadable`, both `needsYou`, and `queued` (not `needsYou`): the meeting's wait has cleared and it is waiting its turn. `EngineSelector` never returns `.queued`.
  - `EngineEnvironment` gains `thisMacReachable: Bool` and `claudeKeyUnreadable: Bool`, as `init` parameters defaulted to `true` and `false`.
  - `EngineSelector` rules: any decision that would run `.macbook` (preferred, forced, or the fallback from the Network Mac) becomes `.wait(.thisMacUnreachable)` when `!thisMacReachable`, except that a preferred Network Mac that is down keeps its own wait (`studioUnreachable` / `studioNotConfigured`). Reachability is checked before memory pressure. Claude (preferred or forced) waits `.claudeKeyUnreadable` when `claudeKeyUnreadable`, before checking `claudeKeyPresent`. A running recording still turns a `.macbook` run into `.wait(.recording)`.
  - `Problems.waiting` covers the new reasons: `thisMacUnreachable` → `thisMacServerNotRunning(api:claudeKeyPresent:waiting: true)` with severity `warning`; `claudeKeyUnreadable` → `keychainUnreadable` copy, severity `warning`, actions `engineSettings, writeOnThisMac`; `queued` → "Waiting its turn" / "Muninn carries on once the meetings ahead are done.", severity `info`, no actions. `Problems.keptRecap` sentences: `thisMacUnreachable` → "Ollama isn't running on This Mac" / "The model server on This Mac isn't running" by `api`; `claudeKeyUnreadable` → "Muninn couldn't read the Claude key"; `queued` → "Another meeting was being processed".
  - `ProcessingPipeline.resumeWaiting(only reasons: Set<WaitReason>? = nil)` resubmits only meetings waiting for one of `reasons` (all waiting meetings when nil) and awaits them, as today.
  - `ProcessingPipeline.requeueWaiting(only reasons: Set<WaitReason>? = nil)` probes the environment once (`probe.environment(settings:)` plus `isRecording()`), without taking a turn. For each meeting waiting for one of `reasons`, oldest first, it decides with `EngineSelector.decide(preferred: settings.defaultEngine, forced: meeting.requestedEngine, environment:)` and computes the reason to store: `.queued` for `.run`, `r` for `.wait(r)`. When that differs from the stored reason it writes it through `update` (so `onChange` fires), but only if, after the probe's suspension, the meeting is not the pipeline's current work and its stored status is still the `.waiting` it read (checked inside the store's update closure); a meeting whose job has started is left alone. It then queues the meeting; a meeting already queued is not queued again (the existing `enqueue` deduplication). It returns without awaiting the jobs. The lifecycle loop uses it (Task 14).
  - `public enum WaitRetry { static let interval: Duration = .seconds(15); static let quickReasons: Set<WaitReason> = [.thisMacUnreachable, .studioUnreachable, .queued]; static func reasons(forTick tick: Int) -> Set<WaitReason>? }` — nil (everything) when `tick % 4 == 0`, else `quickReasons`.

- [ ] **Step 1: Write the failing tests.**

```swift
// EngineSelectorTests
@Test func thisMacDownWaits() {
    let down = EngineEnvironment(studioConfigured: true, studioReachable: false, memoryPressure: .normal, claudeKeyPresent: true, thisMacReachable: false)
    #expect(EngineSelector.decide(preferred: .macbook, forced: nil, environment: down) == .wait(.thisMacUnreachable))
    #expect(EngineSelector.decide(preferred: .claude, forced: .macbook, environment: down) == .wait(.thisMacUnreachable))
    #expect(EngineSelector.decide(preferred: .studio, forced: nil, environment: down) == .wait(.studioUnreachable))
}
@Test func reachabilityComesBeforeMemoryPressure() { /* macbook preferred, pressure .critical, unreachable → .wait(.thisMacUnreachable) */ }
@Test func unreadableKeyWaits() { /* preferred .claude and forced .claude with claudeKeyUnreadable → .wait(.claudeKeyUnreadable) */ }
@Test func recordingStillHoldsThisMac() { /* reachable, isRecording → .wait(.recording) */ }

// PipelineTests
@Test func resumeWaitingCanBeLimitedToReasons() async throws {
    // A waiting(.thisMacUnreachable), B waiting(.claudeKeyMissing); environment now lets both run
    await pipeline.resumeWaiting(only: [.thisMacUnreachable])
    // A is .ready, B still .waiting(.claudeKeyMissing)
}
@Test func requeueingProbesWhileAnotherMeetingRuns() async throws {
    // A blocked in the summariser; B .waiting(.thisMacUnreachable); the probe now says This Mac is reachable
    let probesBefore = probe.calls.get()
    await pipeline.requeueWaiting(only: WaitRetry.quickReasons)   // returns while A is still blocked
    await pipeline.requeueWaiting(only: WaitRetry.quickReasons)
    #expect(probe.calls.get() >= probesBefore + 2)
    #expect(await pipeline.snapshot().queued == [b])
    #expect(try h.meeting(b).status == .waiting(.queued))
    #expect(!(try h.meeting(b).needsAttention))
    // release A → B runs and ends .ready
}
@Test func aWaitThatHasNotClearedKeepsItsReason() async throws { /* A blocked; This Mac still down → queued == [b], B still .waiting(.thisMacUnreachable), no onChange for B */ }
@Test func aWaitThatChangesReasonStoresTheNewReason() async throws {
    // A blocked; B .waiting(.memoryPressure) (not needsYou); This Mac now down → B .waiting(.thisMacUnreachable), needsAttention, one onChange
    // then This Mac up and pressure normal → B .waiting(.queued), not needsAttention
}
@Test func aStartedJobIsNotOverwritten() async throws { /* the probe suspends (FakeProbe gate) while B's job takes its turn and writes .summarizing → B is not set to .waiting(.queued) */ }
@Test func aQueuedWaitRunsAfterARelaunch() async throws { /* a stored .waiting(.queued) meeting and a fresh pipeline → requeueWaiting(only: WaitRetry.reasons(forTick: 1)) → .ready */ }
@Test func startingTheServerClearsTheWait() async throws {
    // probe thisMacReachable false → process → .waiting(.thisMacUnreachable)
    // probe thisMacReachable true → resumeWaiting(only: WaitRetry.reasons(forTick: 1)) → .ready
}
@Test func waitRetryCadence() {
    #expect(WaitRetry.reasons(forTick: 0) == nil && WaitRetry.reasons(forTick: 4) == nil)
    #expect(WaitRetry.reasons(forTick: 1) == [.thisMacUnreachable, .studioUnreachable, .queued])
    #expect(!WaitReason.queued.needsYou)
    #expect(WaitRetry.interval == .seconds(15))
}
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter "EngineSelectorTests|PipelineTests|ProblemTests"` — expect failures.
- [ ] **Step 3: Implement**; give `WaitReason.text` in `Formatting.swift` a line for each new reason (Task 14 removes it).
- [ ] **Step 4: Run** the Core suite and the app build — expect PASS.
- [ ] **Step 5: Commit** — `Wait instead of failing when This Mac's model server is down`

---

### Task 7: The Activity log

**Depends on:** Task 6

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Activity/ActivityEntry.swift`, `ActivityLog.swift`, `MeetingActivity.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Storage/MuninnPaths.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Engines/LLMSummarizer.swift`, `LLMTranscriptCleaner.swift`
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Pipeline/ProcessingPipeline.swift` (scope)
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/ActivityTests.swift`, `SummaryTests.swift`, `CleanupTests.swift`

**Interfaces:**
- Produces:
  - `MuninnPaths.state: URL` (`$XDG_STATE_HOME` when absolute, else `~/.local/state`, plus `muninn`) and `MuninnPaths.activityFile: URL` (`state/activity.jsonl`).
  - `public struct ActivityMeeting: Codable, Hashable, Sendable { var id: MeetingID; var title: String }`
  - `public struct ActivityEntry: Codable, Hashable, Sendable, Identifiable { var id: UUID; var time: Date; var level: ActivityLevel; var area: ActivityArea; var meeting: ActivityMeeting?; var message: String; var details: ProblemDetails?; init(id: UUID = UUID(), time:level:area:meeting: = nil, message:details: = nil); static func problem(_ problem: Problem, area: ActivityArea, meeting: ActivityMeeting?, time: Date) -> ActivityEntry }` — `problem` uses `problem.severity`, `problem.title`, `problem.details`.
  - `public protocol ActivityRecording: Sendable { func record(_ entry: ActivityEntry) }`; `public struct NoActivity: ActivityRecording`.
  - `public enum ActivityScope { @TaskLocal public static var meeting: ActivityMeeting? }` — `ProcessingPipeline.run` wraps `execute` in `ActivityScope.$meeting.withValue(ActivityMeeting(id:title:))` using the stored title.
  - `ActivityEntry.redacted() -> ActivityEntry` — `Redaction.redact` over `message` and `meeting?.title`, and `details?.redacted()`.
  - `public final class ActivityLog: ActivityRecording, @unchecked Sendable { static let retention: TimeInterval = 14 * 24 * 3600; static let maxBytes = 5_000_000; static let trimmedBytes = 4_000_000; let file: URL; init(file: URL, clock: @escaping @Sendable () -> Date = { Date() }); func record(_ entry: ActivityEntry); func entries() -> [ActivityEntry]; func prune(); func setObserver(_ handler: (@Sendable (ActivityEntry) -> Void)?) }` — guarded by a lock; `record` redacts, creates the folder, appends one JSON line (ISO 8601 dates), trims to the newest `trimmedBytes` of whole lines when the file passes `maxBytes`, then calls the observer with the redacted entry; `entries()` is newest first and skips lines that don't decode; `prune()` drops entries older than `retention` and applies the cap. Failures to write are logged with `os.Logger` and otherwise ignored.
  - `public enum DurationText { static func short(_ seconds: TimeInterval) -> String }` — under a minute "12 s"; under an hour "3 min 10 s" (seconds dropped when 0: "42 min"); else "1 h 5 min".
  - `public enum MeetingActivity { static func entries(from old: Meeting?, to new: Meeting, settings: Settings, time: Date) -> [ActivityEntry] }` — every entry carries `ActivityMeeting(id: new.id, title: new.title)`. Nil `old` → `[]`. When the status changed: to `.failed(p)` → `.problem(p, area: p.details.stage?.area ?? .app, …)`; to `.waiting(r)` with `r != .queued` → warning, area `.engines` (`.recording` for `r == .recording`), message `Problems.waiting(r, api: settings.macbook.api, claudeKeyPresent: false).title`; `.transcribing` → `.diarizing` → info, `.transcription`, "Transcribed \(DurationText.short(meeting length)) of audio in \(DurationText.short(metrics.transcribeSeconds))" (only when both are known); `.summarizing` → `.ready` → info, `.recap`, "Recap written by \(engine.displayName) · \(model) · \(DurationText.short(metrics.summarizeSeconds))" with the engine from `summaryEngine` and the model from `settings`. When `engineNotice` changed to a non-nil value → `.problem(notice, area: .recap, …)`; when `transcriptNotice` changed to a non-nil value → `.problem(notice, area: .transcription, …)`.
  - `LLMSummarizer.init(…, activity: ActivityRecording = NoActivity())` records, with `ActivityScope.meeting`: before the retry, info, `.recap`, "Asked \(engine.displayName) again: the first recap missed flagged moments or sources"; when the retry throws, warning, `.recap`, "The second attempt failed; Muninn kept the first recap", details from `ProblemTranslator.problem(for:in: .engine(engine, settings:, stage: .writingRecap, claudeKeyPresent: false)).details`.
  - `LLMTranscriptCleaner.init(client:batchSize:budget:clock:activity: ActivityRecording = NoActivity())` records, with `ActivityScope.meeting`: when the engine fails, warning, `.transcription`, "Cleanup fell back to the rule cleaner", details translated at stage `.cleaningUp`; when the budget runs out, info, `.transcription`, "Cleanup took too long; the rest used the rule cleaner". Each at most once per `clean(_:)` call.

- [ ] **Step 1: Write the failing tests** (`ActivityTests`, a temporary folder per test, a fixed clock):

```swift
@Test func pathsFollowXDGState() { /* XDG_STATE_HOME=/s → /s/muninn/activity.jsonl; unset → <home>/.local/state/muninn/activity.jsonl; relative value ignored */ }
@Test func recordAppendsAndListsNewestFirst() { /* record 3, entries() times descending */ }
@Test func pruneDropsEntriesOlderThan14Days() { /* entries at now-15d and now-13d → prune → only now-13d */ }
@Test func fileStaysUnderTheCap() {
    // record 6000 entries with ~1 KB messages and increasing times
    #expect(size(of: log.file) <= ActivityLog.maxBytes)
    #expect(log.entries().first?.message == newestMessage)
    #expect(!log.entries().contains { $0.message == oldestMessage })
}
@Test func unreadableLinesAreSkipped() { /* file "garbage\n{partial" + one valid line → entries().count == 1 */ }
@Test func recordRedactsBeforeWriting() { /* message "sk-ant-api03-SECRETSECRET" and details.request.path "/sk-ant-api03-PATHSECRET/api" → file text lacks "SECRETSECRET" and "PATHSECRET" */ }
@Test func observerSeesRecordedEntries() {}
@Test func noEntriesWithoutAnEarlierState() { /* MeetingActivity.entries(from: nil, …) == [] */ }
@Test func failureBecomesAProblemEntry() { /* .summarizing → .failed(Problems.claudeBusy(details: stage .writingRecap)) → one entry, level .problem, area .recap, message "Claude is busy right now", meeting id/title */ }
@Test func enteringAWaitIsRecordedOnce() {
    // .summarizing → .waiting(.thisMacUnreachable): one warning, message "Ollama isn't running on This Mac"
    // .waiting(.thisMacUnreachable) → .waiting(.thisMacUnreachable): []; → .waiting(.queued): []
}
@Test func recapWrittenNamesEngineModelAndTime() { /* .summarizing → .ready, summaryEngine .claude, summarizeSeconds 42 → "Recap written by Claude · claude-opus-5-5 · 42 s" */ }
@Test func transcriptionDoneNamesTheDuration() { /* 42-minute meeting, transcribeSeconds 190, .transcribing → .diarizing → "Transcribed 42 min of audio in 3 min 10 s" */ }
@Test func newNoticesAreRecorded() { /* engineNotice nil → keptRecap → one .problem entry, area .recap; unchanged → [] */ }
@Test func durationText() { /* 12 → "12 s"; 190 → "3 min 10 s"; 2520 → "42 min"; 3900 → "1 h 5 min" */ }

// SummaryTests
@Test func retryIsRecordedWithTheMeeting() async throws { /* a client whose first reply leaves an item unsourced; ActivityScope.meeting set; a recording fake sees "Asked This Mac again: …" with that meeting */ }
// CleanupTests
@Test func cleanupFallbackIsRecordedOnce() async throws { /* client throws LLMError.connection twice over two batches → one warning "Cleanup fell back to the rule cleaner" */ }
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter "ActivityTests|SummaryTests|CleanupTests"` — expect failures.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the Core suite — expect PASS.
- [ ] **Step 5: Commit** — `Add the Activity log`

---

### Task 8: Processing display and attention logic

**Depends on:** Tasks 4, 6

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Pipeline/ProcessingDisplay.swift`, `Pipeline/AttentionTracker.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/ProcessingDisplayTests.swift`

**Interfaces:**
- Produces:
  - `public struct SpeechModelPreparation: Equatable, Sendable { var model: String; var fraction: Double? }` (nil fraction = indeterminate).
  - `public enum MeetingProgress: Equatable, Sendable { case none; case queued(ahead: Int); case working(PipelineWork); case preparingSpeechModel(SpeechModelPreparation); case waiting(WaitReason); case failed(Problem) }`
  - `public enum ProcessingDisplay`:
    - `static func progress(for meeting: Meeting, snapshot: PipelineSnapshot, speechModel: SpeechModelPreparation?) -> MeetingProgress`. In order: `current?.meetingID == meeting.id` → `.preparingSpeechModel` when the stage is `.transcribing` and `speechModel` is set, else `.working(current)`; status `.waiting(r)` with `r != .queued` → `.waiting(r)` (`.waiting(.queued)` falls through to the next rules); id in `queued` → `.queued(ahead: index + (current == nil ? 0 : 1))`; status `.failed(p)` → `.failed(p)`; status `.transcribing`, `.diarizing`, `.cleaning`, `.summarizing` or `.waiting(.queued)` → `.queued(ahead: queued.count + (current == nil ? 0 : 1))`; otherwise `.none`.
    - `static func workLine(meetings: [Meeting], snapshot: PipelineSnapshot) -> String?` — "\(stage.title) · \(meeting title) · step \(step) of 4", nil when idle or the meeting is unknown.
    - `static func attentionLine(count: Int) -> String?` — nil for 0, "1 meeting needs attention", "\(n) meetings need attention".
    - `static func attentionReason(_ meeting: Meeting, api: EndpointAPI) -> String?` — the failure's title, the wait's `Problems.waiting(…).title`, or the problem notice's title; nil when the meeting doesn't need attention.
  - `public struct AttentionTracker: Sendable { init(seed meetings: [Meeting]); mutating func update(_ meetings: [Meeting], isRecording: Bool) -> [MeetingID] }` — returns the meetings to announce now: those that entered `needsAttention` since the last update (never those in it at `seed`), held while `isRecording` and released on the first update with `isRecording == false` if they still need attention; a meeting that leaves the state is forgotten, so entering again announces again.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func queuedMeetingShowsItsPosition() {
    let snapshot = PipelineSnapshot(current: PipelineWork(meetingID: a, stage: .transcribing, engine: nil, stageStartedAt: t), queued: [b, c])
    #expect(ProcessingDisplay.progress(for: meeting(c, .transcribing), snapshot: snapshot, speechModel: nil) == .queued(ahead: 2))
    #expect(ProcessingDisplay.progress(for: meeting(b, .ready), snapshot: snapshot, speechModel: nil) == .queued(ahead: 1))
}
@Test func retriedFailureShowsAsQueued() { /* c .failed(p) in queued → .queued(ahead: 2); not queued → .failed(p) */ }
@Test func waitWinsOverQueue() { /* c .waiting(.thisMacUnreachable) in queued → .waiting(.thisMacUnreachable) */ }
@Test func aClearedWaitShowsItsQueuePosition() { /* c .waiting(.queued) in queued, a running → .queued(ahead: 2); not in queued → .queued(ahead: queued.count + 1) */ }
@Test func currentWorkShowsTheStage() { /* a, stage .writingRecap, engine .claude → .working(that work) */ }
@Test func speechModelPreparationShowsWhileTranscribing() { /* a at .transcribing with SpeechModelPreparation(model: "Parakeet v3", fraction: 0.4) → .preparingSpeechModel; at .writingRecap → .working */ }
@Test func processingStatusOutsideTheQueueReadsAsWaitingItsTurn() { /* .transcribing, snapshot .idle → .queued(ahead: 0) */ }
@Test func readyAndRecordingShowNothing() {}
@Test func menuLines() {
    #expect(ProcessingDisplay.workLine(meetings: [meeting(a, .summarizing, title: "Supplier call")], snapshot: writingRecapSnapshot) == "Writing the recap · Supplier call · step 4 of 4")
    #expect(ProcessingDisplay.attentionLine(count: 0) == nil)
    #expect(ProcessingDisplay.attentionLine(count: 1) == "1 meeting needs attention")
    #expect(ProcessingDisplay.attentionLine(count: 3) == "3 meetings need attention")
}
@Test func attentionReasonNamesTheCause() { /* waiting(.thisMacUnreachable) → "Ollama isn't running on This Mac"; ready → nil */ }
@Test func meetingsAlreadyNeedingAttentionAtLaunchAreNotAnnounced() { /* seed [A failed]; update([A failed]) == [] */ }
@Test func enteringAttentionAnnouncesOnce() { /* A ready → failed: [A]; failed again: []; ready: []; failed: [A] */ }
@Test func aWaitRewrittenEvery15SecondsIsNotRepeated() { /* waiting(.thisMacUnreachable) over 5 updates → [A] then [] ×4 */ }
@Test func announcementsWaitForTheRecordingToStop() { /* A fails while recording → []; update not recording → [A] */ }
@Test func aMeetingThatRecoversDuringTheRecordingIsNotAnnounced() { /* fails while recording → []; ready while recording → []; stop → [] */ }
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter ProcessingDisplayTests` — expect a build failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the Core suite — expect PASS.
- [ ] **Step 5: Commit** — `Add processing display and attention logic`

---

### Task 9: Copy diagnostics, and the transcript-leak tests

**Depends on:** Task 7

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Activity/Diagnostics.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/DiagnosticsTests.swift`, `Packages/MuninnCore/Tests/MuninnCoreTests/TranscriptLeakTests.swift`

**Interfaces:**
- Produces:
  - `public struct PermissionReport: Equatable, Sendable { var name: String; var state: String }`
  - `public struct DiagnosticsInput: Sendable { var system: SystemInfo; var macClass: String; var settings: Settings; var permissions: [PermissionReport]; var entries: [ActivityEntry]; var homeDirectory: String }`
  - `public enum Diagnostics { static let entryLimit = 200; static func text(_ input: DiagnosticsInput) -> String }`
- Text layout:

```
Muninn diagnostics
Muninn <appVersion> · macOS <osVersion> · <macClass>

Engines
Default engine: <displayName>
This Mac: <Ollama|OpenAI-compatible server> · model <model> · address <scheme>, port <port>   ("no address" when the URL doesn't parse; the port is the URL's or the scheme's default)
Network Mac: …same…
Claude: model <claudeModel> · effort <claudeEffort>
LLM cleanup: <on|off>

Permissions
<name>: <state>   (one line each, in the given order)

Activity (last <n> entries, newest first)
<yyyy-MM-dd HH:mm:ss> · <level> · <area.label>[ · <meeting label>] · <message>
    <each details line, includeHost: false>
```

- Masking, applied to the Engines and Activity sections after they are built, longest strings first: each distinct meeting (by id, in order of first appearance among the entries) → "meeting A", "meeting B", … replacing both its id and its title anywhere; email addresses (`[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}`) → `<email>`; each account's `displayName` and `id` from the settings, then each further distinct `details.account` among the entries (an account renamed or removed since), whole words, case-sensitive → "account 1", "account 2", … in that order; every host from the settings' base URLs and from entries' `details.request.host`, plus IPv4 addresses → `<host>`; `homeDirectory` prefix → `~`; finally `Redaction.redact`.

- [ ] **Step 1: Write the failing tests.** `SEED` as in Task 2.

```swift
@Test func diagnosticsLeakNothingSeeded() {
    // settings: studio base "http://studio.secret-lab.local:11434"; account displayName "Acme Corp", id "acme", selfAddresses ["me@acme.example"]
    // entries: meeting ActivityMeeting(id: "2026-11-03-1400-quarterly-review", title: SEED) with message "Sign-in to Acme Corp expired";
    //          message "Draft for ann@client.example failed"; message "token sk-ant-api03-SECRETSECRETSECRET";
    //          details request host "studio.secret-lab.local", path "/Users/tester/.local/share/muninn/meetings/2026-11-03-1400-quarterly-review/summary.json"
    // homeDirectory "/Users/tester"
    let text = Diagnostics.text(input)
    for secret in ["Henderson", "quarterly-review", "Acme Corp", "me@acme.example", "ann@client.example", "studio.secret-lab.local", "sk-ant-", "SECRETSECRET", "/Users/tester"] {
        #expect(!text.contains(secret), "\(secret)")
    }
    for label in ["meeting A", "account 1", "<email>", "~/.local/share/muninn/meetings/meeting A/summary.json"] { #expect(text.contains(label)) }
}
@Test func sameMeetingGetsTheSameLabel() { /* two entries for one meeting, one for another → "meeting A" twice, "meeting B" once */ }
@Test func onlyTheLast200Entries() { /* 250 entries → "Activity (last 200 entries, newest first)" and 200 entry lines */ }
@Test func engineSectionShowsSchemeAndPortOnly() { /* "This Mac: Ollama · model qwen3:8b · address http, port 11434"; "Network Mac: Ollama · model gpt-oss:20b · no address" */ }
@Test func permissionsAreListed() { /* "System Audio Recording: not reported by macOS" */ }
@Test func accountIdsAreMaskedAsWholeWordsOnly() { /* account id "work": "Network Mac" survives */ }
@Test func renamedAndRemovedAccountsAreMasked() { /* entries "Sign-in to Acme Corp expired" and "Signed in to Old Name" with details.account set; settings hold neither name → neither appears; both read "account <n>" */ }

// TranscriptLeakTests: each path ends in the problem (as JSON), the activity file's bytes and the diagnostics text, none containing "Henderson"
@Test func engineErrorBodyEchoingTheTranscript() async throws { /* Claude 400 with SEED in error.message → translate → ActivityEntry.problem → ActivityLog → Diagnostics */ }
@Test func ollamaErrorMessageEchoingTheTranscript() async throws { /* Ollama 404 {"error":"model … \(SEED)"} → same chain */ }
@Test func earlierVersionFailureStringWithTheTranscript() throws { /* legacy meeting JSON with SEED in status.message → MeetingActivity.entries(from: same meeting at .summarizing, to: decoded) → log → diagnostics */ }
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter "DiagnosticsTests|TranscriptLeakTests"` — expect a build failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the Core suite — expect PASS.
- [ ] **Step 5: Commit** — `Add safe-to-paste diagnostics`

---

### Task 10: The probe checks This Mac and reports Keychain failures

**Depends on:** Tasks 6, 7

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Engines/ReachabilityTracker.swift`
- Modify: `Packages/MuninnPlatform/Sources/MuninnSystem/StudioProbe.swift`, `KeychainStore.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/ReachabilityTrackerTests.swift`, `Packages/MuninnPlatform/Tests/MuninnSystemTests/SystemTests.swift`

**Interfaces:**
- Produces:
  - `public struct ReachabilityTracker: Sendable { init(); mutating func entries(thisMac: Bool, networkMac: Bool?, keyReadable: Bool, api: EndpointAPI, time: Date) -> [ActivityEntry] }` — `networkMac` nil means not configured (no entries). Each signal starts unknown. Unknown → down, or up → down: warning, area `.engines`; down → up: info; unknown → up: nothing. Messages: This Mac down = `Problems.thisMacServerNotRunning(api:claudeKeyPresent: false, waiting: true).title`, back = "Ollama on This Mac is answering again" / "The model server on This Mac is answering again"; Network Mac down "The Network Mac isn't answering", back "The Network Mac is answering again"; key unreadable "Muninn couldn't read its saved key", readable again "Muninn can read its saved key again".
  - `LiveEnvironmentProbe.init(secrets: KeychainSecrets, activity: ActivityRecording = NoActivity(), session: URLSession = makeSession())` (and the internal test initialiser with `activity`). `environment(settings:)` also probes This Mac with the same request as the Network Mac; a This Mac address that doesn't parse gives `thisMacReachable: true`. A key read that throws gives `claudeKeyUnreadable: true, claudeKeyPresent: false`. Entries from a `ReachabilityTracker` held under a lock in a private final class are recorded through `activity`.
  - `extension KeychainError: ProblemConvertible` → `Problems.keychainUnreadable(details:)` with `errorDomain: "Keychain"` and `errorCode` the `OSStatus` (`invalidData` → code nil).

- [ ] **Step 1: Write the failing tests.**

```swift
// ReachabilityTrackerTests
@Test func firstDownIsRecordedFirstUpIsNot() {}
@Test func onlyChangesAreRecorded() { /* down, down, up, up, down → warning, info, warning */ }
@Test func unconfiguredNetworkMacRecordsNothing() {}
@Test func keyReadFailuresAreRecordedOnChange() {}
// SystemTests
@Test func probeReportsThisMacDown() async { /* stub fails for 127.0.0.1/api/tags → thisMacReachable false */ }
@Test func probeTreatsAnUnparseableThisMacAddressAsReachable() async {}
@Test func keychainReadFailureIsUnreadableNotMissing() async { /* secrets throws KeychainError.status(-25308) → claudeKeyUnreadable, !claudeKeyPresent */ }
@Test func probeRecordsTransitionsOnce() async { /* two probes with This Mac down → one warning entry */ }
@Test func keychainErrorBecomesAnUnreadableKey() {
    let problem = ProblemTranslator.problem(for: KeychainError.status(-25308), in: ProblemContext(stage: .writingRecap))
    #expect(problem.title == "Muninn couldn't read its saved key" && problem.details.errorCode == -25308)
}
```

- [ ] **Step 2: Run** the focused Core and Platform suites — expect failures.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both full suites — expect PASS.
- [ ] **Step 5: Commit** — `Probe This Mac's model server and report Keychain read failures`

---

### Task 11: Speech model preparation reports progress

**Depends on:** Tasks 7, 8

**Files:**
- Create: `Packages/MuninnPlatform/Sources/MuninnSpeech/SpeechModelActivity.swift`
- Modify: `Packages/MuninnPlatform/Sources/MuninnSpeech/SpeechModels.swift` (`SpeechModelID.displayName`, `ParakeetModels`), `WhisperKitTranscriber.swift`
- Test: `Packages/MuninnPlatform/Tests/MuninnSpeechTests/SpeechModelActivityTests.swift`

**Interfaces:**
- Consumes: `SpeechModelPreparation` (Task 8), `ActivityRecording`, `ActivityEntry`, `Problems.speechModelUnavailable`, `DurationText`.
- Produces:
  - `SpeechModelID.displayName`: "Parakeet v3", "Parakeet Ultra", "Whisper large v3 turbo"; the CTC vocabulary model is named "the vocabulary model".
  - `public struct SpeechModelError: ProblemConvertible, Equatable { var model: String; var domain: String; var code: Int }` → `Problems.speechModelUnavailable(model:details:)` with `errorDomain`, `errorCode`.
  - `public final class SpeechModelActivity: @unchecked Sendable { static let shared: SpeechModelActivity; init(); var preparing: [SpeechModelPreparation] { get }; func setObserver(_ handler: (@Sendable ([SpeechModelPreparation]) -> Void)?); func setActivity(_ activity: ActivityRecording); func run<T>(_ model: String, _ load: (_ report: @escaping @Sendable (Double?) -> Void) async throws -> T) async throws -> T }` — `run` adds the model with a nil fraction, passes a reporter that updates its fraction (clamped to 0…1), removes it when `load` returns or throws, and calls the observer after each change. It records: info, `.transcription`, "Getting \(model) ready" at the start; info "\(model) is ready (\(DurationText.short(elapsed)))" on success; on a non-cancellation error, `ActivityEntry.problem(Problems.speechModelUnavailable(…), area: .transcription, …)` and throws `SpeechModelError(model:domain:code:)` from the error's `NSError` domain and code. Cancellation (`CancellationError` or `URLError(.cancelled)`) passes through unchanged and records nothing.
  - `ParakeetModels.models(for:)` and `ctcModels()` load inside `SpeechModelActivity.shared.run`, passing FluidAudio's `progressHandler: { report($0.fractionCompleted) }` (for `CtcModels`, the `progressHandler` parameter if its `downloadAndLoad` has one, otherwise no reports).
  - WhisperKit: inside `run`, `WhisperKit.download(variant: model, progressCallback: { report($0.fractionCompleted) })`, then `report(nil)`, then `WhisperKit(WhisperKitConfig(model: model, modelFolder: folder.path, verbose: false, logLevel: .none, load: true, download: false))`. Before changing it, read `WhisperKit.setupModels` in the checked-out package (`build/SourcePackages/checkouts/WhisperKit`) and pass the same download arguments it uses, so a cached model loads as it does today.

- [ ] **Step 1: Write the failing tests.**

```swift
@Test func runReportsProgressThenEnds() async throws {
    let activity = SpeechModelActivity()
    // observer collects snapshots
    _ = try await activity.run("Parakeet v3") { report in report(0.5); return 1 }
    #expect(snapshots == [[.init(model: "Parakeet v3", fraction: nil)], [.init(model: "Parakeet v3", fraction: 0.5)], []])
}
@Test func failedLoadEndsAndBecomesAModelProblem() async {
    // load throws URLError(.notConnectedToInternet)
    // thrown == SpeechModelError(model: "Parakeet v3", domain: NSURLErrorDomain, code: -1009); activity.preparing == []
    // a recording fake saw "Getting Parakeet v3 ready" then a .problem entry "The speech model couldn't be downloaded"
}
@Test func cancellationPassesThrough() async { /* load throws CancellationError → CancellationError, no problem entry */ }
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnPlatform --filter SpeechModelActivityTests` — expect a build failure.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the Platform suite — expect PASS.
- [ ] **Step 5: Commit** — `Report speech model downloads and their failures`

---

### Task 12: Design tokens and the status card

**Depends on:** Task 1

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Design/Palette.swift`
- Create: `Muninn/Design/Theme.swift`, `Muninn/Design/StatusCard.swift`, `Muninn/Design/ProblemCard.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/PaletteTests.swift`

**Interfaces:**
- Produces (Core):
  - `public struct RGB: Equatable, Sendable { var red, green, blue: Double; init(hex: UInt32) }` (components 0…1).
  - `public enum Palette` — `static let` values from Global Constraints: `accentLight`, `accentDark`, `attentionTextLight`, `attentionFillLight`, `attentionDark`, `problemLight`, `problemDark`, `successLight`, `successDark`, `recording`, `contentLight = RGB(hex: 0xFFFFFF)`, `contentDark = RGB(hex: 0x1E1E1E)`; text: `primaryTextAlpha = 0.85` (the system label colour: black or white at 85%), `secondaryTextLight = 0x5C5C5C`, `secondaryTextDark = 0xA6A6A6`, `tertiaryTextLight = 0x6E6E6E`, `tertiaryTextDark = 0x8C8C8C`; `softLight = 0.10`, `softDark = 0.13`, `neutralSoftAlpha = 0.08` (a grey `0x808080` fill for the waiting role).
  - `public enum Contrast { static func luminance(_ c: RGB) -> Double; static func ratio(_ a: RGB, _ b: RGB) -> Double; static func composite(_ top: RGB, alpha: Double, over bottom: RGB) -> RGB }` (WCAG 2 relative luminance).
- Produces (app):
  - `enum Theme` — `Color` statics built from `Palette` with `NSColor(name:dynamicProvider:)` choosing by `bestMatch(from: [.aqua, .darkAqua])`: `accent`, `accentSoft`, `attentionText`, `attentionFill`, `attentionSoft`, `problem`, `problemSoft`, `success`, `successSoft`, `neutralSoft`, `recording`, `primaryText` (`NSColor.labelColor`), `secondaryText`, `tertiaryText`, `contentBackground` (`NSColor.textBackgroundColor`). Fonts: `meetingTitle` = `.system(size: 27, weight: .semibold, design: .serif)`, `subject` = 19 semibold serif, `reading` 14.5, `interface` 13, `meta` 12.5, `label` 11 semibold (a `ViewModifier` `SectionLabel` applying uppercase and `Theme.tertiaryText`), `mono` = `.system(size: 11.5, design: .monospaced)`. `enum Space { xs = 4, s = 8, m = 16, l = 24, xl = 32 }`, `enum Radius { chip = 6, card = 10, panel = 14 }`, `readingWidth: CGFloat = 760`.
  - `struct StatusCard: View` with `enum Role { case progress, waiting, attention, problem, success }`, `struct Action: Identifiable { label, run, menu: [(String, () -> Void)] = [], disabledReason: String? }`, and stored properties `role`, `title`, `explanation: String?`, `meta: String?`, `since: Date?` (shown as `Text(since, style: .timer)` after `meta`), `steps: (current: Int, labels: [String])?`, `progress: Progress?` (`enum Progress { case indeterminate, fraction(Double) }`), `actions: [Action]` (only the first three are shown), `copyDetails: String?`, `showInActivity: (() -> Void)?`, `onDismiss: (() -> Void)?`; every property but `role` and `title` defaults to nil (`actions` to `[]`). Layout: icon (progress: a small `ProgressView`; waiting `clock`; attention `exclamationmark.circle.fill` in `attentionFill`; problem `exclamationmark.triangle.fill` in `problem`; success `checkmark.circle.fill` in `success`), title (13 pt semibold, `primaryText`), explanation (13 pt, `secondaryText`), meta (mono, `secondaryText`), the step bar (four segments filled up to `current` in `accent`, labels in meta style under them), a linear progress bar, then the action buttons, then "Copy details" (copies to `NSPasteboard.general` and reads "Copied" for two seconds) and "Show in Activity" when given. Background: role soft fill (`accentSoft`, `neutralSoft`, `attentionSoft`, `problemSoft`, `successSoft`) in a `RoundedRectangle(cornerRadius: Radius.card)`. Text uses `primaryText` and `secondaryText` only. `compact: Bool = false`: one tighter row of title and explanation, the actions as small borderless buttons, and "Copy details" and "Show in Activity" in a `…` menu; same roles and colours. The dismiss button is icon-only with accessibility label "Dismiss". A disabled action shows its reason with `.help`.
  - `struct ProblemHandlers { var tryAgain, engineSettings, changeKey, signInAgain, recordingSettings: (() -> Void)?; var write: ((EngineKind) -> Void)?; var failedEngine: EngineKind?; var disabledReason: String? }` (all defaulted nil).
  - `struct ProblemCard: View { let problem: Problem; var role: StatusCard.Role? = nil; var compact = false; let handlers: ProblemHandlers; var showInActivity: (() -> Void)? = nil; var onDismiss: (() -> Void)? = nil }` — role defaults from severity (problem → `.problem`, warning and info → `.waiting`); actions from `problem.actions` that have a handler (`writeWithClaude` → `write(.claude)`, `writeOnThisMac` → `write(.macbook)`, `writeWithAnotherEngine` → a menu of `EngineKind.allCases` minus `failedEngine`, labelled with `displayName`); `copyDetails` and `showInActivity` only for severity `.problem`, copying `"\(title)\n\(explanation)\n\n\(details.text(includeHost: true))"`.
  - `extension Problem { static func notice(_ title: String) -> Problem }` (app-side): a warning with that title, no explanation, no actions — for a field's validation message, shown as a compact `ProblemCard`.

- [ ] **Step 1: Write the failing tests** (`PaletteTests`):

```swift
@Test func contrastMaths() {
    #expect(abs(Contrast.ratio(RGB(hex: 0x000000), RGB(hex: 0xFFFFFF)) - 21) < 0.01)
    #expect(abs(Contrast.luminance(RGB(hex: 0xFFFFFF)) - 1) < 0.0001)
}
@Test(arguments: [Palette.accentLight, Palette.attentionTextLight, Palette.problemLight, Palette.successLight])
func lightRoleTextMeetsAA(_ colour: RGB) { #expect(Contrast.ratio(colour, Palette.contentLight) >= 4.5) }
@Test(arguments: [Palette.accentDark, Palette.attentionDark, Palette.problemDark, Palette.successDark])
func darkRoleTextMeetsAA(_ colour: RGB) { #expect(Contrast.ratio(colour, Palette.contentDark) >= 4.5) }
@Test func tertiaryTextMeetsAAOnContent() { /* tertiaryTextLight on contentLight, tertiaryTextDark on contentDark ≥ 4.5 */ }
@Test func primaryAndSecondaryTextMeetAAEverywhere() {
    // backgrounds: contentLight, and composite(role, softLight, over: contentLight) for accentLight, attentionFillLight, problemLight,
    //   successLight, plus composite(0x808080, neutralSoftAlpha, over: contentLight); the same in dark with softDark over contentDark
    // light text: composite(black, primaryTextAlpha, over: background) and secondaryTextLight; dark: white at primaryTextAlpha and secondaryTextDark
    // every pair ≥ 4.5
}
```

- [ ] **Step 2: Run** `X swift test --package-path Packages/MuninnCore --filter PaletteTests` — expect a build failure.
- [ ] **Step 3: Implement** the Core palette, then the three app files. A colour pair that fails is reported to the controller, not changed (the spec fixes the values).
- [ ] **Step 4: Run** the focused suite, `mise exec -- xcodegen generate`, and the app build — expect PASS.
- [ ] **Step 5: Commit** — `Add design tokens and the status card`

---

### Task 13: The Activity window and what records into it

**Depends on:** Tasks 9, 10, 11, 12

**Files:**
- Create: `Muninn/Activity/ActivityCenter.swift`, `Muninn/Activity/ActivityWindow.swift`
- Modify: `Muninn/AppModel.swift`, `AppModel+Meetings.swift`, `AppModel+Obsidian.swift`, `Muninn/Services.swift` (`CalendarCache`), `Muninn/RecordingController.swift`, `Muninn/MuninnApp.swift`, `Muninn/Views/MenuBarContent.swift`, `Muninn/Views/SignInSheet.swift`, `Muninn/Views/SettingsView.swift` (accounts sign-out)

**Interfaces:**
- Consumes: `ActivityLog`, `ActivityEntry`, `MeetingActivity`, `Diagnostics`, `LiveEnvironmentProbe(activity:)`, `SpeechModelActivity.shared.setActivity`, `LLMSummarizer(activity:)`, `LLMTranscriptCleaner(activity:)`, `StatusCard`.
- Produces:
  - `@MainActor final class ActivityCenter: ObservableObject { @Published private(set) var entries: [ActivityEntry]; @Published var focusedEntryID: UUID?; let log: ActivityLog; init(log: ActivityLog); func record(_ level: ActivityLevel, _ area: ActivityArea, _ message: String, meeting: Meeting? = nil, details: ProblemDetails? = nil); func record(_ problem: Problem, area: ActivityArea, meeting: Meeting? = nil); func focus(problemTitle: String, meetingID: MeetingID?); func revealLogFile(); func diagnostics(settings: MuninnCore.Settings) async -> String }`. `init` calls `log.prune()`, loads `log.entries()`, and sets the log's observer to insert each recorded entry at the front on the main actor, so every writer (pipeline, probe, speech, app) reaches the window through one path. `focus` selects the newest entry with that message (and meeting, when given). `diagnostics` builds `DiagnosticsInput` with `SystemInfo.current`, `macClass` "Apple silicon" under `#if arch(arm64)` else "Intel", permissions Microphone (from `AVCaptureDevice.authorizationStatus(for: .audio)`: "allowed", "denied", "restricted", "not asked"), Notifications (from `UNUserNotificationCenter.current().notificationSettings()`: "allowed", "denied", "provisional", "not asked"; "not available" outside an app bundle), "System Audio Recording" and "Local Network" as "not reported by macOS", `entries`, and `NSHomeDirectory()`.
  - `AppModel.activity: ActivityCenter`, created first in `init` from `ActivityLog(file: paths.activityFile)` and handed to the probe, summariser, cleaner and `SpeechModelActivity.shared`.
  - Recorded by the app:
    - `apply(_:)`: `MeetingActivity.entries(from: previous, to: meeting, settings: settings, time: Date())`, where `previous` is the meeting's earlier copy in `meetings`.
    - `reloadMeetings` failure → `Problem` at stage `.loadingMeetings`; a failure to load a meeting's recap, transcript or clean transcript in `MeetingDetail` (today `try?`) → the same, recorded once per meeting and file per session.
    - The cleaner factory's fallback in `AppModel.init` (no client for LLM cleanup) → warning, `.transcription`, "Cleanup used the rule cleaner", details translated at `.cleaningUp`.
    - `saveSettings` failure → `Problem` at stage `.savingSettings`.
    - `searchPeople` failure → warning, area `.outlook`, "People search failed", details translated at stage `.searchingPeople`.
    - Calendar: `CalendarCache.onFetchFailure: ((String, Error) -> Void)?`, called only when an account goes from fetching fine (or unknown) to failing; the model records the problem translated at `.readingCalendar` with the account's display name.
    - `calendar.onSignInState` turning on → the `signInExpired` problem; the sign-in sheet finishing → info, `.accounts`, "Signed in to \(account)"; signing out in Settings → info, "Signed out of \(account)"; both with `details: ProblemDetails(account: account)`. Any other entry whose message names an account carries it in `details.account` the same way.
    - Launch recovery: `.transcribe` → info, `.recording`, "Recovered an interrupted recording"; `.markUnreadable` → `Problems.recordingUnreadable()`; `.delete` → info, "Removed an empty interrupted recording".
    - Draft created → info, `.outlook`, "Draft created in Outlook"; note filed (manual or automatic) → info, `.obsidian`, "Filed in Obsidian".
    - `RecordingController`: recording started → info, `.recording`, "Recording started"; stopped → info, "Recording stopped · \(DurationText.short(length))"; every notice it posts → recorded at its severity, area `.recording`.
  - `Window("Activity", id: "activity")` in `MuninnApp`, `.defaultSize(width: 760, height: 520)`, `.defaultLaunchBehavior(.suppressed)`, content `frame(minWidth: 560, minHeight: 360)`, with `ActivityWindow` (environment objects `model` and `model.activity`). Opened by "Activity" in the menu bar menu (above "Settings…") and in the Help menu (`CommandGroup(after: .help)`), both through `WindowPresenter.present`.
  - `ActivityWindow`: toolbar with a segmented "All" / "Problems" filter (Problems = level `.problem`), `.searchable` (message, area label, meeting title, details text), and "Copy diagnostics" (copies `diagnostics(settings:)`, then reads "Copied" for two seconds). A `List` with selection, newest first; a row shows the time (`HH:mm:ss`, mono; a day header per date), a level icon with accessibility label "Info", "Warning" or "Problem", the area label, the message and, when the meeting still exists, its title as a link button calling `model.showMeeting(id)`. The selected row expands to its details text (`includeHost: true`, mono, selectable) and a "Copy" button copying time, level, area, meeting title, message and details. Footer: "Show log file in Finder" and the note "Muninn keeps 14 days of activity." An empty list says "No activity yet" (All) or "No problems" (Problems). It scrolls to and selects `focusedEntryID` when set.

- [ ] **Step 1: Implement** (no app test target; the logic is covered by Tasks 7–11).
- [ ] **Step 2: Run** `mise exec -- xcodegen generate` and the app build — expect PASS.
- [ ] **Step 3: Run** the Core and Platform suites — expect PASS.
- [ ] **Step 4: Commit** — `Add the Activity window and record what Muninn does`

---

### Task 14: Processing status in the meeting, sidebar and menu bar

**Depends on:** Tasks 8, 13

**Files:**
- Create: `Muninn/Views/MeetingStatusCards.swift`
- Modify: `Muninn/AppModel.swift`, `Muninn/Views/MeetingDetail.swift`, `SummaryEditor.swift`, `MainWindow.swift`, `MenuBarContent.swift`, `SettingsView.swift`, `Formatting.swift`

**Interfaces:**
- Consumes: `PipelineSnapshot`, `ProcessingDisplay`, `MeetingProgress`, `SpeechModelActivity.shared.setObserver`, `WaitRetry`, `ProblemCard`, `StatusCard`.
- Produces on `AppModel`:
  - `@Published private(set) var pipelineSnapshot = PipelineSnapshot.idle` (from `pipeline.setOnSnapshot`, hopping to the main actor), `@Published private(set) var speechModels: [SpeechModelPreparation] = []` (from `SpeechModelActivity.shared.setObserver`), `@Published private(set) var claudeKeyPresent: Bool` (read from the Keychain at launch, on every lifecycle tick and after the key is saved or removed in Settings; a read failure counts as absent), `@Published var sidebarFilter: SidebarFilter = .all` (`enum SidebarFilter { case all, needsAttention }`), `@Published var settingsTab: SettingsTab = .engines` (`enum SettingsTab: Hashable { case engines, accounts, obsidian, recording, dictionary, permissions }`).
  - `func progress(for meeting: Meeting) -> MeetingProgress` (`ProcessingDisplay.progress(for:snapshot:speechModel: speechModels.first)`), `func dismissEngineNotice(_ id: MeetingID)`, `func dismissTranscriptNotice(_ id: MeetingID)` (both through `mutate`).
  - The lifecycle loop becomes `var tick = 0; while !Task.isCancelled { await pipeline.requeueWaiting(only: WaitRetry.reasons(forTick: tick)); tick += 1; try? await Task.sleep(for: WaitRetry.interval) }`.
- `MeetingStatusCards(meeting:)`, placed in `MeetingDetail` between the banners and the header so it shows on both tabs; it replaces `SummaryEditor`'s `banners`:
  - `.queued(ahead)` → `StatusCard(role: .waiting, title: "Waiting its turn", explanation: ahead == 0 ? "Muninn starts on it next." : ahead == 1 ? "1 meeting ahead." : "\(ahead) meetings ahead.")`.
  - `.working(work)` → `StatusCard(role: .progress, title: work.stage.title, meta: work.engine.map { "\($0.displayName) · " } ?? "", since: work.stageStartedAt, steps: (work.stage.step, PipelineStage.allCases.map(\.stepLabel)))`.
  - `.preparingSpeechModel(p)` → `StatusCard(role: .progress, title: "Getting the speech model ready", explanation: p.fraction == nil ? "This can take a few minutes the first time." : "\(p.model) · \(Int(p.fraction! * 100))%", steps: (1, labels), progress: p.fraction.map(.fraction) ?? .indeterminate)`.
  - `.waiting(r)` → `ProblemCard(problem: Problems.waiting(r, api: settings.macbook.api, claudeKeyPresent: claudeKeyPresent), role: r.needsYou ? .attention : .waiting, handlers:)`.
  - `.failed(p)` → `ProblemCard(problem: p, handlers:, showInActivity:)`.
  - then `transcriptNotice` and `engineNotice` as `ProblemCard`s with `onDismiss` calling the dismiss methods.
  - Handlers: `tryAgain` → `model.process(id)` for a failure or wait, and `model.regenerate(id, engine: meeting.requestedEngine ?? model.settings.defaultEngine)` for an engine notice; `write` → `model.regenerate(id, engine:)`; `failedEngine` → `p.details.engine`; `engineSettings` and `changeKey` → `settingsTab = .engines` then `WindowPresenter.present { openSettings() }`; `signInAgain` → `.accounts`; `recordingSettings` → `.recording`; `showInActivity` → `model.activity.focus(problemTitle:meetingID:)` then `WindowPresenter.present { openWindow(id: "activity") }`; `disabledReason` → "Save your recap edits first" while edits are unsaved, "Wait for the event change" while one is running, else nil.
- `SettingsView`'s `TabView(selection: $model.settingsTab)` with a `.tag` per tab.
- Sidebar (`MainWindow`): a segmented picker at the top, "All meetings" / "Needs attention (\(n))", filtering by `needsAttention`, with the empty text "Nothing needs attention". `SidebarRow` replaces its status symbol: `.working` and `.preparingSpeechModel` → a mini circular `ProgressView(value: Double(step) / 4)`; `.queued` → a mini indeterminate `ProgressView`; otherwise, `needsAttention` → an 8-pt `Circle` in `Theme.attentionFill`; `.recording` → `record.circle` in `Theme.recording`. Each sign has `.help` and an accessibility label (the stage title, "Waiting its turn", "Needs attention", "Recording").
- Menu bar menu: first, `Text(workLine)` when there is one; then `Button(attentionLine)` setting `sidebarFilter = .needsAttention` and opening Meetings; a `Divider` after the block when either is shown.
- `Formatting.swift`: remove `WaitReason.text`, `ProcessingStatus.label` and `.symbol`; the header's status label shows `"Needs attention"` when `needsAttention`, else the progress title (stage title, "Waiting its turn", "Getting the speech model ready"), else nothing.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Run** `mise exec -- xcodegen generate` and the app build — expect PASS.
- [ ] **Step 3: Run** `rg -n "WaitReason.text|status.label|status.symbol" Muninn` — expect no output.
- [ ] **Step 4: Commit** — `Show processing status in the meeting, sidebar and menu bar`

---

### Task 15: Every other channel shows problems

**Depends on:** Task 14

**Files:**
- Modify: `Packages/MuninnCore/Sources/MuninnCore/Pipeline/MeetingActions.swift` (and `StorageTests.swift`)
- Modify: `Muninn/AppModel.swift`, `AppModel+Meetings.swift`, `AppModel+Obsidian.swift`, `RecordingController.swift`, `MuninnApp.swift`
- Modify: `Muninn/Views/MeetingDetail.swift`, `SummaryEditor.swift`, `SettingsView.swift`, `SettingsFields.swift`, `SignInSheet.swift`, `CallPromptPanel.swift`, `RecordingPill.swift`, `MenuBarContent.swift`, `LiveTranscriptWindow.swift`

**Interfaces:**
- Core: `MeetingActions.exportRefusal(settings:) -> Problem?` (`Problems.vaultNotChosen()`); `vaultNotChosenNotice` and `eventNotChangedNotice` are removed in favour of `Problems.vaultNotChosen()` and `Problems.eventNotChanged()`; update `StorageTests` to expect `Problems.vaultNotChosen().title`.
- `AppModel.actionErrors: [MeetingID: Problem]`, `actionNotices: [MeetingID: Problem]`, `hotkeyError: Problem?`, `settingsProblem: Problem?`; `UnsavedSummary.problem: Problem` replaces `error: String`.
- `perform(_ stage: ProblemStage, for id: MeetingID, _ body:)` replaces the action strings (`.creatingDraft`, `.filingNote`, `.changingEvent`); its in-flight key is `"\(stage.rawValue)|\(id.rawValue)"` and `isDraftOrExportRunning` checks the `creatingDraft` and `filingNote` keys. A failure becomes `ProblemTranslator.problem(for:in:)` with the meeting's account display name and, for `.filingNote`, subject "the note"; it is stored in `actionErrors` and recorded in Activity. Deleting failures use stage `.deletingMeeting`.
- `MeetingActionError: ProblemConvertible`, severity `warning` except `linkNotSaved` (`problem`):

  | Case | Title | Explanation |
  |---|---|---|
  | `eventUnsettled` | Choose the event first | Muninn needs the calendar event before it can draft or file the recap. |
  | `notReady` | The meeting isn't processed yet | Wait for the recap, then try again. |
  | `noSummary` | There's no recap yet | Write the recap first. |
  | `noRecipients` | Choose an account and at least one recipient | The draft needs an account to send from and someone to send to. |
  | `unknownAccount` | This meeting's account is no longer in Settings | Choose another account for the meeting. |
  | `vaultNotChosen` | `Problems.vaultNotChosen()` | |
  | `vaultMissing(path)` | The Obsidian vault folder is missing | Muninn can't find the vault folder. Choose it again in Obsidian settings. (`details.path`) |
  | `unsavedEdits` | Save your recap edits first | Muninn couldn't save your last changes. Save them, then try again. |
  | `eventChangeInProgress` | The event is being changed | Try again in a moment. |
  | `draftOrExportInProgress` | A draft or note is being made | Change the event once it has finished. |
  | `linkNotSaved(error)` | The draft was created, but Muninn couldn't save its link | Find the draft in Outlook's Drafts. (details translated from `error`) |

- Notices: auto-file `.unsourced(n)` → `Problems.notFiledAutomatically(unsourced: n)`; `.vaultNotChosen` → `Problems.vaultNotChosen()`; a draft without a link → `Problems.draftWithoutLink()`; an event left unchanged → `Problems.eventNotChanged()`.
- Retrying a meeting action: `perform` remembers the stage of a failed draft or export in `failedActions: [MeetingID: ProblemStage]`; `retryAction(_ id:)` runs `createDraft` or `exportToObsidian` again. The `actionErrors` card's handlers: `tryAgain` → `retryAction` (none for a failed event change: the popover is the retry), `signInAgain` → the Accounts pane, `engineSettings` → the Engines pane.
- `MeetingDetail`: `saveError: Problem?` (summary and meeting edits translated at stage `.savingEdits`, subject "your changes"); the three banners become `ProblemCard`s (`actionErrors` and notices dismissible; the save error's `tryAgain` is the existing `saveRetry`).
- Settings (every card compact, each problem with `showInActivity`): `saveSettings` sets `settingsProblem` (translated at `.savingSettings`), keeps the settings it failed to save in `failedSettings: MuninnCore.Settings?` and records the problem; `SettingsView` shows the card above the tabs with `tryAgain` → `saveSettings(failedSettings)` and a dismiss. `ClaudeSection`: key read → `Problems.keychainUnreadable(details:).with(actions: [.tryAgain])` with `tryAgain` → read again; save and remove → `Problems.keychainUnwritable(details:)` with `tryAgain` → repeat the save or removal; each with the `KeychainError` status as `errorCode`. `AccountsTab`: token removal → `keychainUnwritable` with `tryAgain` → remove again; an unreadable account status `.unreadable(Problem)` (the translated `KeychainError`, `.with(actions: [.tryAgain])`) with `tryAgain` → reload the statuses; missing client ID or tenant → `Problem.notice("Enter a client ID and tenant for \(name) first")`; removal refusals → `Problem.notice(AccountManagement.removalRefusal(…))`. `DebouncedText` shows its validation message as `Problem.notice`. `RecordingTab` shows `hotkeyError` (no actions: the explanation points at the field above it).
- Sign-in: `SignInFlow.Phase.failed(Problem)` — device-code and polling failures translated at `.signingIn` with the account's display name; storing the tokens → `Problems.keychainUnwritable(details:)`; the profile read → translated at `.signingIn`. The sheet shows a `ProblemCard` whose `tryAgain` is `retry()`. `SignInFlow.describe` and `keychainMessage` are removed.
- Change-event popover: `eventsAround` returns `failures: [Problem]` (translated per account at `.readingCalendar`); each shows as a compact `ProblemCard` with `tryAgain` → reload the events, `signInAgain` → the Accounts settings pane, and `showInActivity`.
- Recording: `RecordingNotice { var problems: [Problem]; var isError: Bool { problems.contains { $0.severity == .problem } } }`; `post(_ problem: Problem)` appends unless a problem with the same title is already there. Call sites: start failure → `Problems.recordingDidNotStart(details:)` with the translated details (stage `.recording`), stored both as the meeting's `.failed` status and in the notice; flag save → translated, subject "the flag"; saving the meeting end → translated, subject "the end of the recording"; removing an unused meeting → translated at `.deletingMeeting`; write errors at stop → `Problems.recordingPartlyUnsaved(tracks:)`; a `.writeFailed` interruption → `Problems.recordingTrackStopped(track:)` ("microphone" or "call audio"); no call audio → `Problems.noCallAudio(app:)`; hotkey → `Problems.hotkeyInUse(keys:)` for `HotkeyError.status`, `Problems.hotkeyUnsupported(keys:)` for `.unsupported`, with `HotkeyText.format`. The interruption reason strings stay in `os.Logger` only. The call prompt shows the first problem as a compact `ProblemCard` (with `recordingSettings` → the Recording settings pane, and `showInActivity`), "+\(n) more" when there are more, and "Dismiss"; the pill shows the titles; the menu shows each title as `Text`, then "Show in Activity" when any is a problem, and "Dismiss".
- Live transcript: `liveStatus: Problem?` (translated at `.liveTranscript`), shown with `ProblemCard`; while `model.speechModels` contains the live model's display name, a `StatusCard` "Getting the speech model ready" as in Task 14. The `Window("Live transcript")` scene also gets `.environmentObject(model)`.

- [ ] **Step 1: Implement**, then run `X swift test --package-path Packages/MuninnCore --filter StorageTests` — expect PASS.
- [ ] **Step 2: Run** `mise exec -- xcodegen generate` and the app build — expect PASS.
- [ ] **Step 3: Run** `rg -n 'localizedDescription|String\(describing: error\)|describe\(' Muninn | rg -v 'logger\.'` — expect no output (acceptance 2's search).
- [ ] **Step 4: Run** the Core suite — expect PASS.
- [ ] **Step 5: Commit** — `Show problems in every channel that reports an error`

---

### Task 16: Notifications for meetings that need attention

**Depends on:** Tasks 8, 15

**Files:**
- Modify: `Muninn/Services.swift` (`RecapNotifications`), `Muninn/AppModel.swift`

**Interfaces:**
- `RecapNotifications.start(onOpen:)` sets the delegate only. A private `post(_ content: UNMutableNotificationContent, id: String)` calls `requestAuthorization(options: [.alert, .sound])` on its first use in the session, then adds the request (logging failures with `os.Logger`). `recapReady(_:)` uses it unchanged in copy. New `needsAttention(_ meeting: Meeting, reason: String)`: title "Needs attention: \(meeting.title)", body `reason`, identifier `"attention-\(meeting.id.rawValue)"`, `userInfo` `["meeting": id]` so a click opens the meeting.
- `AppModel`: `private var attention: AttentionTracker`, seeded with the meetings loaded in `init`. After every `apply(_:)`, every `reloadMeetings()` and every change of `isRecording`, `for id in attention.update(meetings, isRecording: isRecording)` posts `needsAttention(meeting, reason: ProcessingDisplay.attentionReason(meeting, api: settings.macbook.api) ?? "")`.

- [ ] **Step 1: Implement.**
- [ ] **Step 2: Run** the app build — expect PASS.
- [ ] **Step 3: Run** `rg -n "requestAuthorization" Muninn` — expect exactly one match, inside the posting helper.
- [ ] **Step 4: Commit** — `Notify when a meeting needs attention, and ask for permission on first use`

---

### Task 17: Changelog, records and final verification

**Depends on:** Tasks 1–16

**Files:**
- Modify: `CHANGELOG.md`, `docs/superpowers/plans/2026-11-03-muninn-ux-problems-activity.md` (tick boxes)

- [ ] **Step 1:** Add under `## [Unreleased]`:

```markdown
### Added

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
```

- [ ] **Step 2: Run** the full verification, all must pass, and record the totals as passed/total: the Core suite, the Platform suite, `mise exec -- xcodegen generate`, the app build, the Task 15 search, and `/usr/bin/python3 -m unittest discover -s scripts/tests -p 'test_*.py'`.
- [ ] **Step 3:** `rm -rf build/adhoc` (no ad hoc copy may outlive the run: see AGENTS.md on permissions).
- [ ] **Step 4: Commit** — `Add the changelog entries for problems, Activity and processing status`

## Manual acceptance (the owner, on his Mac)

Signed Debug build installed in `/Applications`, started with `open`:

1. Quit Ollama, set This Mac as the default engine, record a short conversation: the meeting waits with "Ollama isn't running on This Mac" and its actions; "Write with Claude" writes the recap. Record another; start Ollama: the wait clears within about 15 seconds (acceptance 1).
2. Record two meetings back to back: the second shows "Waiting its turn · 1 meeting ahead"; the sidebar shows rings; the menu bar menu leads with "… · step n of 4" (acceptance 4).
3. Open Activity: the session's milestones and problems are there; "Copy diagnostics" pastes text with no meeting titles, email addresses or hostnames (acceptance 3).
4. Light and dark: the status cards, the sidebar signs and the Activity window read well (acceptance 7, 8).
5. Shrink the Meetings, Activity and Settings windows to their minimum sizes: no control or label is cut off. With Accessibility Inspector, every icon-only control added here (dismiss buttons, level icons, sidebar signs, the progress ring) reads a label (acceptance 7).
