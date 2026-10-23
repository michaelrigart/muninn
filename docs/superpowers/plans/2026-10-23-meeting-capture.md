# Muninn meeting capture: implementation plan

**Status:** In progress

> **Execution complete (2026-10-23).** All 25 tasks are implemented. Do not run this plan again.

**Goal:** Build Muninn phase 1: a macOS menu bar app that records calls (mic plus call audio on separate tracks), transcribes and cleans them locally, drafts a per-subject recap with action points on a chosen engine (This Mac, Network Mac or Claude), and hands it to Outlook as a Graph draft and to Obsidian as a note. Also build the spike kit (`muninn-spike`) the spec's first step needs.

**Architecture:**
- **`Packages/MuninnCore`** is a dependency-free Swift package holding all domain logic. It covers models, cleanup, the summary schema, engine selection, LLM clients, calendar matching, Graph, email, Obsidian, storage, settings, the processing pipeline and metrics, and it is fast to build and test.
- **The root package** adds the platform layers on top of MuninnCore:
  - `MuninnAudio`: Core Audio capture and call detection
  - `MuninnSpeech`: FluidAudio and WhisperKit adapters
  - `MuninnSystem`: Keychain, memory pressure, network-Mac probe, global hotkey
  - two executables: the SwiftUI app `Muninn`, and the `muninn-spike` CLI.

**Tech Stack:**
- Swift 6.4 toolchain, Command Line Tools only (no Xcode), tools-version 6.0, Swift 5 language mode.
- Swift Testing (`import Testing`). SwiftUI and AppKit, Core Audio process taps, AVFoundation.
- FluidAudio v0.17.7, vendored by `scripts/vendor-fluidaudio.sh`.
- WhisperKit 1.1.1 and swift-argument-parser.
- URLSession for the Claude, Ollama/OpenAI-compatible and Microsoft Graph APIs.

**Spec:** `docs/superpowers/specs/2026-10-22-meeting-capture-design.md`

## Build notes

- **Spike and app are built side by side.** The spec puts the spike first. This plan builds the spike kit (Task 18) and the app together. Every model choice stays a setting, so the spike's results can still pick the models without code changes.
- **Real model runs are deferred to the spike.** Model downloads (Hugging Face), real recordings and the macOS permission prompts can't happen in the build environment. Speech and capture code is verified by build plus unit tests of the pure parts; real runs happen in the spike (`docs/spike.md`).
- **SwiftPM needs an unsandboxed shell.** It writes temporary files under `/var/folders` and starts its own sandbox, and both fail inside a sandboxed shell.
- **Run `scripts/vendor-fluidaudio.sh` once** before the first root-package build. `Vendor/` is gitignored.

## Global Constraints

- Platform `macOS 15` (later raised to macOS 26; see the spec); bundle id `be.netronix.muninn`; app name `Muninn`; menu bar only (`LSUIElement`).
- Data lives in `$XDG_DATA_HOME/muninn` (default `~/.local/share/muninn`) and config in `$XDG_CONFIG_HOME/muninn/settings.json` (default `~/.config/muninn`). Secrets (Claude key, Graph tokens) go in the Keychain only.
- Processing is local by default. The shipped default engine is `macbook`, never `claude`. The Swift identifiers stay `macbook`, `studio` and `claude`; the labels users see are This Mac, Network Mac and Claude. Claude runs only when it is the default in settings or picked for a meeting.
- Muninn never sends email. It creates Outlook drafts only.
- Claude: `POST https://api.anthropic.com/v1/messages` with these headers:
  - `x-api-key`
  - `anthropic-version: 2026-10-21`
  - `anthropic-beta: server-side-fallback-2026-07-01`

  and this body:
  - model `claude-opus-5-5`
  - `max_tokens` 16000
  - `"fallbacks": "default"`
  - `output_config: {effort: "medium", format: {type: "json_schema", schema}}`

  Never send `temperature`, `top_p` or `top_k`.
- Cleanup removes words and changes punctuation and capitalisation only. It never rephrases.
- Hard constraints, which the owner rules on if they fail:
  - from hanging up to a draft takes about 1 minute for a typical call and at most 5 minutes for a 90-minute one;
  - the Mac stays usable.
- Email subject: `Recap: <title>, <dd/MM/yyyy>`.
- Obsidian:
  - default pattern `Meetings/{client}/{date} {title}.md` (`{area}` is also available), falling back to `Inbox/{date} {title}.md` only when a placeholder the pattern uses has no value;
  - action points are written as `- [ ] <text> [owner:: <owner>]`, with ` [due:: <yyyy-MM-dd>]` appended when there is a due date.
- Every target uses `swiftSettings: [.swiftLanguageMode(.v5)]`.
- Commits use imperative mood.

## Review Focus

1. **A meeting with no calendar event:** the title becomes `<App> call, HH:mm`, there are no recipients, the account must be picked, and the draft button stays disabled until it is. Tests in Tasks 7 and 25.
2. **A mic-only recording** must never label anyone "You", and a call recording must label every mic segment "You". Tests in Task 12 (`SpeakerAttribution`).
3. **An LLM returning invalid output:**
   - unknown source IDs are dropped;
   - due dates that aren't `yyyy-MM-dd` become nil;
   - flags left uncovered get a "Flagged moments" subject;
   - non-JSON output fails with a readable error and the meeting does not get stuck mid-stage.

   Tests in Tasks 4 and 12.
4. **Settings files** written by an older build, or hand-edited with missing keys, still load with defaults and are never wiped. Test in Task 11.
5. **A vault note** whose file already exists must never be overwritten silently. Its path must be sanitized: titles containing `/` or `:` must not create folders. Tests in Task 10.

---

## File structure

```
Package.swift                         root: platform targets + executables
Packages/MuninnCore/Package.swift     dependency-free core
Packages/MuninnCore/Sources/MuninnCore/
  Model/        Meeting.swift Transcript.swift Summary.swift JSONValue.swift
  Cleanup/      Tokenizer.swift RuleCleaner.swift CleanupVerifier.swift ChangeView.swift TranscriptCleaners.swift
  Summary/      SummaryRequestBuilder.swift SummarySchema.swift SummaryParser.swift FlagCoverage.swift
  Engines/      EngineSelector.swift LLMClient.swift ClaudeClient.swift OllamaClient.swift OpenAICompatibleClient.swift LLMSummarizer.swift
  Calendar/     CalendarEvent.swift EventMatcher.swift RecipientBuilder.swift
  Graph/        DeviceCodeAuthenticator.swift GraphClient.swift TokenStore.swift
  Email/        RecapEmail.swift
  Obsidian/     ClientMapper.swift NotePathResolver.swift MeetingNoteRenderer.swift ObsidianExporter.swift
  Storage/      MuninnPaths.swift MeetingStore.swift TranscriptMarkdown.swift Settings.swift SettingsStore.swift
  Pipeline/     Protocols.swift SpeakerAttribution.swift ProcessingPipeline.swift
  Metrics/      WordErrorRate.swift LoadSampler.swift
Packages/MuninnCore/Tests/MuninnCoreTests/   one test file per source area
Sources/MuninnAudio/     AudioProcessList.swift CallDetector.swift RecordingSession.swift TrackWriter.swift LiveAudioStream.swift LevelMeter.swift
Sources/MuninnSpeech/    SegmentBuilder.swift ParakeetTranscriber.swift ParakeetLiveTranscriber.swift WhisperKitTranscriber.swift FluidDiarizer.swift SpeechModels.swift
Sources/MuninnSystem/    KeychainStore.swift SystemMemoryPressure.swift StudioProbe.swift GlobalHotkey.swift
Sources/MuninnApp/       MuninnApp.swift AppModel.swift + Views/ (MenuBar, Prompt, Pill, LiveTranscript, MainWindow, MeetingDetail, SummaryView, TranscriptView, SettingsView, SignInView)
Sources/MuninnSpike/     main.swift + Commands/ (Detect, Record, Transcribe, Live, Diarize, Summarize, EndToEnd, Measure, WER)
Tests/MuninnAudioTests Tests/MuninnSpeechTests Tests/MuninnSystemTests
scripts/vendor-fluidaudio.sh scripts/bundle-app.sh scripts/Info.plist scripts/Muninn.entitlements
AGENTS.md docs/setup.md docs/spike.md
```

---

### Task 1: Scaffolding

**Depends on:** none

**Files:**
- Create: `Package.swift`, `Packages/MuninnCore/Package.swift`, `Packages/MuninnCore/Sources/MuninnCore/MuninnCore.swift`, `Packages/MuninnCore/Tests/MuninnCoreTests/SmokeTests.swift`, `Sources/{MuninnAudio,MuninnSpeech,MuninnSystem}/Placeholder.swift`, `Sources/MuninnApp/MuninnApp.swift`, `Sources/MuninnSpike/main.swift`, `Tests/{MuninnAudioTests,MuninnSpeechTests,MuninnSystemTests}/SmokeTests.swift`, `AGENTS.md`
- Already present: `scripts/vendor-fluidaudio.sh`, `.gitignore`

**Interfaces:**
- Produces:
  - library products `MuninnCore`, `MuninnAudio`, `MuninnSpeech`, `MuninnSystem`;
  - executables `Muninn` (target `MuninnApp`) and `muninn-spike` (target `MuninnSpike`);
  - `public enum MuninnCore { public static let version = "0.1.0" }`.

- [ ] **Step 1:** Write `Packages/MuninnCore/Package.swift` with:
  - tools 6.0, platform `.macOS(.v15)`;
  - library `MuninnCore`, test target `MuninnCoreTests`;
  - no dependencies, Swift 5 language mode.
- [ ] **Step 2:** Write the root `Package.swift` with:
  - tools 6.0, `.macOS(.v15)`;
  - dependencies:
    - `.package(path: "Packages/MuninnCore")`
    - `.package(path: "Vendor/FluidAudio")`
    - `.package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1")`
    - `.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0")`
  - targets:
    - `MuninnAudio` → MuninnCore
    - `MuninnSpeech` → MuninnCore, FluidAudio, WhisperKit
    - `MuninnSystem` → MuninnCore
    - `MuninnApp` executable, product name `Muninn` → all four libraries
    - `MuninnSpike` executable, product name `muninn-spike` → all four plus ArgumentParser
    - the three test targets.
- [ ] **Step 3:** Add a smoke test in each test target, `@Test func builds() { #expect(MuninnCore.version == "0.1.0") }`, and placeholder sources.
- [ ] **Step 4:** Write `AGENTS.md`:
  - point to the design-record locations (`docs/superpowers/specs/` and `docs/superpowers/plans/`);
  - the build commands (`scripts/vendor-fluidaudio.sh`; `swift test --package-path Packages/MuninnCore`; `swift build`; `swift test`; `scripts/bundle-app.sh`);
  - that SwiftPM builds need an unsandboxed shell;
  - that `Vendor/` is generated.
- [ ] **Step 5:** Run `scripts/vendor-fluidaudio.sh && swift test --package-path Packages/MuninnCore && swift build && swift test`. Expected: all smoke tests pass and both executables link.
- [ ] **Step 6:** Commit with the message `Scaffold packages and targets`.

### Task 2: Core model

**Depends on:** 1

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Model/{Meeting,Transcript,Summary,JSONValue}.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/ModelTests.swift`

**Interfaces (Produces, all `public`, `Codable, Hashable, Sendable` unless noted):**
```swift
struct MeetingID: RawRepresentable { let rawValue: String
  static func make(startedAt: Date, title: String, timeZone: TimeZone, existing: Set<String>) -> MeetingID } // "2026-10-22-1400-acme-monthly-sync", "-2" suffix on clash
struct Attendee { var name: String; var email: String }
struct Recipient { var attendee: Attendee; var included: Bool }
enum CaptureMode { case call(appBundleID: String), micOnly }
enum EngineKind: String, CaseIterable { case macbook, studio, claude }
enum WaitReason: String { case studioUnreachable, memoryPressure, claudeKeyMissing }
enum ProcessingStatus { case recording, transcribing, diarizing, cleaning, summarizing, waiting(WaitReason), ready, failed(String) }
struct EventAssociation { var accountID: String; var eventID: String; var iCalUID: String? }
struct Flag { var offset: TimeInterval }                       // seconds since recording start
struct ProcessingMetrics { var transcribeSeconds, diarizeSeconds, cleanSeconds, summarizeSeconds: Double? }
struct Meeting: Identifiable { var id: MeetingID; var title: String; var startedAt: Date; var endedAt: Date?
  var captureMode: CaptureMode; var language: String?; var accountID: String?; var association: EventAssociation?
  var client: String?                                          // independent of the calendar association
  var candidateEvents: [CalendarEventRef]; var attendees: [Attendee]; var recipients: [Recipient]; var flags: [Flag]
  var speakerNames: [String: String]; var status: ProcessingStatus; var summaryEngine: EngineKind?
  var engineNotice: String?; var exportedNotePath: String?; var draftWebLink: String?; var metrics: ProcessingMetrics }
struct CalendarEventRef { var accountID: String; var eventID: String; var subject: String; var start: Date }
enum Track: String { case mic, system }
struct Word { var text: String; var start: TimeInterval; var end: TimeInterval }
struct Segment: Identifiable { var id: Int; var track: Track; var speaker: String; var start: TimeInterval; var end: TimeInterval; var text: String; var words: [Word] }
struct Transcript { var segments: [Segment]; var language: String?; static let youSpeaker = "you" }
struct LiveAudioChunk: Sendable { var track: Track; var samples: [Float]; var time: TimeInterval }   // 16 kHz mono; not Codable
struct CleanTranscript { var segments: [CleanSegment] }         // same ids as the verbatim transcript
struct CleanSegment { var id: Int; var text: String }
struct Bullet { var text: String; var sources: [Int] }
struct ActionPoint { var owner: String; var text: String; var due: String?; var sources: [Int] } // due "yyyy-MM-dd"
struct Subject { var title: String; var bullets: [Bullet]; var actions: [ActionPoint] }
struct Summary { var language: String; var subjects: [Subject]; var engine: EngineKind; var generatedAt: Date }
indirect enum JSONValue { case string(String), number(Double), bool(Bool), null, array([JSONValue]), object([String: JSONValue]) } // Codable as plain JSON
```

- [ ] **Step 1: Write the failing tests:**
  - `meetingRoundTrips`: JSON encode/decode equality for a `Meeting` with `.call`, `.waiting(.memoryPressure)` and two flags;
  - `clientWithoutAssociationRoundTrips`: `association == nil`, `client == "Acme"` and `accountID == "work"` survive a round trip;
  - `idSlug`: `MeetingID.make(startedAt: 2026-10-22 14:00 Europe/Brussels, title: "Acme: monthly sync!", …, existing: [])` gives `"2026-10-22-1400-acme-monthly-sync"`, and with that id in `existing` gives `"…-sync-2"`;
  - `jsonValueEncodesPlain`: `JSONValue.object(["a": .array([.number(1), .null])])` encodes to `{"a":[1,null]}`.
- [ ] **Step 2:** Run `swift test --package-path Packages/MuninnCore --filter ModelTests`. Expected: the tests fail to compile.
- [ ] **Step 3:** Implement the types. Slugs are lowercased ASCII (diacritics folded), with runs of non-alphanumerics replaced by `-`, trimmed and capped at 40 characters.
- [ ] **Step 4:** Run the tests again. Expected: PASS.
- [ ] **Step 5:** Commit with the message `Add core model types`.

### Task 3: Cleanup (rules, verifier, change view)

**Depends on:** 2

**Files:**
- Create: `Cleanup/{Tokenizer,RuleCleaner,CleanupVerifier,ChangeView,TranscriptCleaners}.swift`
- Test: `CleanupTests.swift`

**Interfaces:**
```swift
enum Tokenizer { static func normalizedWords(_ s: String) -> [String] }   // lowercased, punctuation stripped (inner apostrophes/hyphens kept), diacritics kept
enum RuleCleaner { static let fillers: Set<String>  // euh euhm eh ehm uh uhm um umm hmm hm mm mmm
  static func clean(_ text: String) -> String }
enum CleanupVerifier { static func isDeletionOnly(verbatim: String, clean: String) -> Bool } // normalized clean words are a subsequence
struct ChangeToken: Hashable, Sendable { var text: String; var removed: Bool }
enum ChangeView { static func tokens(verbatim: String, clean: String) -> [ChangeToken] } // surface tokens of verbatim, LCS on normalized forms
protocol TranscriptCleaning: Sendable { func clean(_ transcript: Transcript) async throws -> CleanTranscript }
struct RuleTranscriptCleaner: TranscriptCleaning
struct LLMTranscriptCleaner: TranscriptCleaning { init(client: LLMClient, fallback: RuleTranscriptCleaner = .init(), batchSize: Int = 40) }
```
`LLMTranscriptCleaner` depends on `LLMClient` from Task 6. Put it in Task 6's file `Engines/LLMTranscriptCleaner.swift` instead; this task ships only `RuleTranscriptCleaner`.

- [ ] **Step 1: Write the failing tests:**
  - `cleansFillersAndRepeats`: `RuleCleaner.clean("Euh, ja, dus we could do the cutover on the on the 14th, hmm, if the backup is done by then.") == "Ja, dus we could do the cutover on the 14th, if the backup is done by then."`
  - `keepsMeaningfulWords`: `RuleCleaner.clean("Allez, bon, we doen dat.") == "Allez, bon, we doen dat."`
  - `verifierAcceptsDeletions`: true for (`"I mean, it, it should."`, `"It should."`)
  - `verifierRejectsRephrase`: false for (`"we doen dat morgen"`, `"we doen het morgen"`)
  - `ruleOutputAlwaysVerifies`: holds for the four example sentences above
  - `changeViewMarksRemoved`: `ChangeView.tokens(verbatim: "Euh, ja, dus we", clean: "Ja, dus we").map(\.removed) == [true, false, false, false]`
  - `ruleCleanerTranscript`: keeps segment ids and counts
- [ ] **Step 2:** Run with `--filter CleanupTests`. Expected: the tests fail to compile.
- [ ] **Step 3:** Implement:
  - filler removal also removes one adjacent comma;
  - repeat removal collapses immediate repeats of 1–3 word n-grams, compared on normalized forms;
  - the first letter of the result is capitalised;
  - whitespace is collapsed.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit with the message `Add deletion-only transcript cleanup`.

### Task 4: Summary schema, prompt, parser and flag coverage

**Depends on:** 2

**Files:**
- Create: `Summary/{SummarySchema,SummaryRequestBuilder,SummaryParser,FlagCoverage}.swift`
- Test: `SummaryTests.swift`

**Interfaces:**
```swift
enum SummarySchema { static var jsonSchema: JSONValue }  // object{language:string, subjects:[{title, bullets:[{text, sources:[integer]}], actions:[{owner, text, due:string|null, sources:[integer]}]}]}, additionalProperties false + required everywhere
struct LLMRequest: Sendable { var system: String; var user: String; var jsonSchema: JSONValue?; var maxTokens: Int }
enum SummaryRequestBuilder { static func build(meeting: Meeting, transcript: Transcript, clean: CleanTranscript, retryNote: String? = nil) -> LLMRequest }
struct SummaryParseResult { var summary: Summary; var uncoveredFlagSegments: [Int] }
enum SummaryParseError: Error, Equatable { case notJSON(String), schemaMismatch(String) }
enum SummaryParser { static func parse(_ text: String, transcript: Transcript, flags: [Flag], engine: EngineKind, now: Date) throws -> SummaryParseResult }
enum FlagCoverage { static func flaggedSegmentIDs(_ flags: [Flag], in transcript: Transcript) -> [Int]
  static func ensureCovered(_ summary: Summary, uncovered: [Int], clean: CleanTranscript) -> Summary }
```
Prompt rules for the system text, which tests check by substring:
- write in the call's language;
- group by subject;
- give every action point an owner as named in the call (`You` → the user's name, which defaults to the first word of the macOS full name, else `Me`), plus a due date only when one was said;
- cite segment ids in `sources`;
- cover every flagged segment;
- never invent facts.

The user text renders each segment as `[S<id> <mm:ss> <speaker display name>] <clean text>`, and adds a final line `Flagged segments: S3, S7` when there are flags.

- [ ] **Step 1: Write the failing tests:**
  - `userTextFormat`: segment 3 at 62 s, speaker "jan" → `"Jan"` via `speakerNames`, renders as `[S3 01:02 Jan] …`
  - `flaggedLine`: listed when flags fall inside segments 3 and 7
  - `parserDropsUnknownSources`
  - `parserNullsBadDue`: `"next week"` becomes nil, `"2026-11-07"` is kept
  - `parserThrowsOnProse`
  - `uncoveredFlagsReported`
  - `ensureCoveredAppendsSubject`: the title is `"Gemarkeerde momenten"` for `nl`, `"Moments signalés"` for `fr`, `"Flagged moments"` otherwise; bullets quote the clean text with `sources == [id]`
  - `schemaIsStrict`: every object node has `additionalProperties == false`
- [ ] **Step 2:** Run with `--filter SummaryTests`. Expected: the tests fail to compile.
- [ ] **Step 3:** Implement. The parser tolerates a JSON object wrapped in prose or code fences by extracting the outermost `{…}`.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit with the message `Add summary schema, prompt and parser`.

### Task 5: Engine selection

**Depends on:** 2

**Files:**
- Create: `Engines/EngineSelector.swift`
- Test: `EngineSelectorTests.swift`

**Interfaces:**
```swift
enum MemoryPressureLevel: Int, Codable, Sendable { case normal = 1, warning = 2, critical = 4 }
struct EngineEnvironment: Sendable { var studioConfigured: Bool; var studioReachable: Bool; var memoryPressure: MemoryPressureLevel; var claudeKeyPresent: Bool }
enum EngineDecision: Equatable, Sendable { case run(EngineKind, fallbackFrom: EngineKind?), wait(WaitReason) }
enum EngineSelector { static func decide(preferred: EngineKind, forced: EngineKind?, environment: EngineEnvironment) -> EngineDecision }
```
The table, one parameterised test (`decisionTable`):

| preferred | forced | studio reachable | pressure | claude key | decision |
|---|---|---|---|---|---|
| macbook | nil | – | normal | – | run(macbook, nil) |
| macbook | nil | – | warning | – | wait(memoryPressure) |
| studio | nil | yes | critical | – | run(studio, nil) |
| studio | nil | no | normal | – | run(macbook, fallbackFrom: studio) |
| studio | nil | no | warning | – | wait(studioUnreachable) |
| claude | nil | – | – | yes | run(claude, nil) |
| claude | nil | – | – | no | wait(claudeKeyMissing) |
| studio | macbook | no | critical | – | run(macbook, nil) |
| macbook | claude | – | critical | yes | run(claude, nil) |
| macbook | studio | no | normal | – | wait(studioUnreachable) |

A network Mac that is not configured waits as `studioNotConfigured` (not `studioUnreachable`). When it is the fallback source, the notice reads "Network Mac not set up — summarized on This Mac".

- [ ] **Steps 1–5:** write the failing test (the table above), run it and see it fail, implement, run it and see it pass, then commit with the message `Add engine selection rules`.

### Task 6: LLM clients and the LLM summarizer

**Depends on:** 2, 4, 3

**Files:**
- Create: `Engines/{LLMClient,ClaudeClient,OllamaClient,OpenAICompatibleClient,LLMSummarizer,LLMTranscriptCleaner}.swift`
- Test: `LLMClientTests.swift` (with a `StubURLProtocol` test helper in the same file)

**Interfaces:**
```swift
protocol LLMClient: Sendable { func complete(_ request: LLMRequest) async throws -> String }
enum LLMError: Error, Equatable { case http(Int, String), refused(String?), emptyResponse, decoding(String) }
struct ClaudeClient: LLMClient { init(apiKey: String, model: String = "claude-opus-5-5", effort: String = "medium", session: URLSession = .shared) }
struct OllamaClient: LLMClient { init(baseURL: URL, model: String, keepAlive: String, contextTokens: Int = 32768, session: URLSession = .shared) } // POST {base}/api/chat
struct OpenAICompatibleClient: LLMClient { init(baseURL: URL, model: String, apiKey: String?, session: URLSession = .shared) } // POST {base}/v1/chat/completions
protocol Summarizing: Sendable { func summarize(meeting: Meeting, transcript: Transcript, clean: CleanTranscript, engine: EngineKind) async throws -> Summary }
struct LLMSummarizer: Summarizing { init(clientFor: @Sendable (EngineKind) throws -> LLMClient, now: @Sendable () -> Date = Date.init) }
struct LLMTranscriptCleaner: TranscriptCleaning { init(client: LLMClient, batchSize: Int = 40) }
```

- [ ] **Step 1: Write the failing tests** (with a stubbed URLSession):
  - `claudeRequestShape`:
    - URL `https://api.anthropic.com/v1/messages`;
    - headers `x-api-key`, `anthropic-version: 2026-10-21`, `anthropic-beta: server-side-fallback-2026-07-01`;
    - body `model == "claude-opus-5-5"`, `max_tokens == 16000`, `fallbacks == "default"`, `output_config.effort == "medium"`, `output_config.format.type == "json_schema"`;
    - none of `temperature`, `top_p` or `top_k`.
  - `claudeJoinsTextBlocksSkipsThinking`: content `[thinking, text "{", text "}"]` gives `"{}"`.
  - `claudeRefusal`: `stop_reason: "refusal"` with `stop_details.category: "cyber"` throws `.refused("cyber")`.
  - `claudeHTTPError`: a 401 throws `.http(401, …)`.
  - `ollamaRequestShape`: path `/api/chat`, `stream == false`, `keep_alive == "0"`, `format` equal to the schema, `options.num_ctx == 32768`; reads `message.content`.
  - `openAIRequestShape`: path `/v1/chat/completions`, `response_format.type == "json_schema"`, `response_format.json_schema.strict == true`; reads `choices[0].message.content`.
  - `summarizerRetriesOnceForUncoveredFlags`: the first reply misses the flag and the second covers it, so 2 requests are made, the second with a retry note.
  - `summarizerFallsBackToCoverage`: both replies miss the flag, so a "Flagged moments" subject is present.
  - `llmCleanerRejectsRephrase`: a segment whose LLM text fails the verifier keeps `RuleCleaner` output.
- [ ] **Step 2:** Run the tests and see them fail.
- [ ] **Step 3:** Implement:
  - request timeouts are 300 s;
  - `LLMTranscriptCleaner` sends segments in batches as JSON `{"segments":[{"id":1,"text":"…"}]}`, with a schema-constrained reply holding the same ids, and verifies each segment.
- [ ] **Step 4:** Run the tests. Expected: PASS.
- [ ] **Step 5:** Commit with the message `Add Claude, Ollama and OpenAI-compatible clients`.

### Task 7: Calendar matching and recipients

**Depends on:** 2

**Files:**
- Create: `Calendar/{CalendarEvent,EventMatcher,RecipientBuilder}.swift`
- Test: `CalendarTests.swift`

**Interfaces:**
```swift
struct CalendarEvent: Codable, Hashable, Sendable { var accountID: String; var eventID: String; var iCalUID: String?; var subject: String
  var start: Date; var end: Date; var isAllDay: Bool; var isCancelled: Bool; var attendees: [Attendee]; var organizer: Attendee? }
enum EventMatch: Equatable, Sendable { case none, single(CalendarEvent), ambiguous([CalendarEvent]) }
enum EventMatcher { static func match(_ events: [CalendarEvent], at: Date, earlyJoin: TimeInterval = 600) -> EventMatch }
enum RecipientBuilder { static func recipients(for event: CalendarEvent, selfAddresses: [String]) -> [Recipient]
  static func untitledTitle(appName: String, at: Date, timeZone: TimeZone) -> String } // "Zoom call, 14:02"
```
Matching rules:
- a candidate satisfies `start - earlyJoin <= at <= end`;
- all-day and cancelled events are excluded;
- more than one candidate is `.ambiguous`, including the same `iCalUID` in two accounts.

Recipients are the organizer plus the attendees, deduplicated by lowercased email, excluding `selfAddresses` (case-insensitive), all `included = true`, in invite order with the organizer first.

- [ ] **Steps 1–5:** write tests for:
  - `singleMatch`
  - `earlyJoinWithin10Min`
  - `allDayIgnored`
  - `sameInviteBothAccountsIsAmbiguous`
  - `overlapIsAmbiguous`
  - `recipientsExcludeSelfCaseInsensitive`
  - `untitledTitle == "Zoom call, 14:02"`

  Then run them and see them fail, implement, run them and see them pass, and commit with the message `Add calendar matching and recipients`.

### Task 8: Microsoft Graph (device code sign-in, calendar, drafts, people)

**Depends on:** 2, 7

**Files:**
- Create: `Graph/{TokenStore,DeviceCodeAuthenticator,GraphClient}.swift`
- Test: `GraphTests.swift`

**Interfaces:**
```swift
struct TokenSet: Codable, Equatable, Sendable { var accessToken: String; var refreshToken: String?; var expiresAt: Date }
protocol TokenStore: Sendable { func load(account: String) throws -> TokenSet?; func save(_ t: TokenSet, account: String) throws; func delete(account: String) throws }
final class InMemoryTokenStore: TokenStore, @unchecked Sendable
struct DeviceCodePrompt: Equatable, Sendable { var userCode: String; var verificationURI: URL; var message: String; var deviceCode: String; var interval: Int; var expiresIn: Int }
struct DeviceCodeAuthenticator: Sendable { init(clientID: String, tenant: String, session: URLSession = .shared, sleep: @Sendable (UInt64) async -> Void = { try? await Task.sleep(nanoseconds: $0) })
  static let scopes = ["offline_access", "User.Read", "Calendars.Read", "Mail.ReadWrite", "People.Read"]
  func start() async throws -> DeviceCodePrompt; func poll(_ p: DeviceCodePrompt) async throws -> TokenSet; func refresh(_ refreshToken: String) async throws -> TokenSet }
actor GraphSession { init(account: String, authenticator: DeviceCodeAuthenticator, store: TokenStore, now: @escaping @Sendable () -> Date = Date.init); func accessToken() async throws -> String } // refreshes when < 5 min left
struct DraftResult: Equatable, Sendable { var id: String; var webLink: URL? }
struct GraphClient: Sendable { init(account: String, token: @escaping @Sendable () async throws -> String, session: URLSession = .shared)
  func me() async throws -> [String]                           // mail + userPrincipalName
  func events(from: Date, to: Date) async throws -> [CalendarEvent]
  func createDraft(subject: String, html: String, to: [Attendee]) async throws -> DraftResult
  func searchPeople(_ query: String) async throws -> [Attendee] }
```
Endpoints:
- Sign-in:
  - `POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/devicecode`
  - `POST .../token`, with `grant_type=urn:ietf:params:oauth:grant-type:device_code` or `refresh_token`;
  - `authorization_pending` keeps polling, `slow_down` adds 5 s.
- Calendar: `GET https://graph.microsoft.com/v1.0/me/calendarView?startDateTime=…&endDateTime=…&$select=id,iCalUId,subject,start,end,isAllDay,isCancelled,attendees,organizer&$top=50` with header `Prefer: outlook.timezone="UTC"`. `start.dateTime` has no zone and is UTC.
- Drafts: `POST /me/messages` with body `{subject, body:{contentType:"HTML",content}, toRecipients:[{emailAddress:{address,name}}]}`.
- People: `GET /me/people?$search="<q>"&$top=10`.

- [ ] **Steps 1–5:** write tests with stubs for:
  - `deviceCodeFlowPollsUntilToken` (pending, then slow_down, then token; check the sleep durations)
  - `refreshWhenNearExpiry`
  - `calendarViewParsesUTC`
  - `draftRequestShape`
  - `peopleSearchParses`

  Then run them and see them fail, implement, run them and see them pass, and commit with the message `Add Microsoft Graph sign-in and client`.

### Task 9: Recap email

**Depends on:** 2

**Files:**
- Create: `Email/RecapEmail.swift`
- Test: `RecapEmailTests.swift`

**Interfaces:**
```swift
enum RecapEmail { static func subject(title: String, date: Date, timeZone: TimeZone) -> String   // "Recap: Acme monthly sync, 22/10/2026"
  static func html(summary: Summary, speakerNames: [String: String]) -> String }
```
Copy per language (`nl`, `fr`, otherwise `en`):

| | nl | fr | en |
|---|---|---|---|
| greeting | Hallo allemaal, | Bonjour à tous, | Hi all, |
| intro | Bedankt voor het gesprek. Hieronder de samenvatting en de volgende stappen. | Merci pour l'échange. Voici le résumé et les prochaines étapes. | Thanks for today. Here are the summary and next steps. |
| actions heading | Actiepunten | Points d'action | Action points |
| closing | Met vriendelijke groeten, | Cordialement, | Best regards, |

Structure:
- each subject is an `<h3>` followed by a `<ul>` of bullets;
- then an `<h3>` with the actions heading and a `<ul>` of `<b>owner</b>: text` items, plus ` (dd/MM)` when there is a due date;
- all text is HTML-escaped.

- [ ] **Steps 1–5:** write tests for:
  - `subjectFormat`
  - `dutchCopy`
  - `escapesHTML` (`<script>` becomes `&lt;script&gt;`)
  - `dueDateFormatted` (`2026-11-07` becomes `(07/11)`)

  Then run them and see them fail, implement, run them and see them pass, and commit with the message `Add recap email rendering`.

### Task 10: Obsidian export

**Depends on:** 2

**Files:**
- Create: `Obsidian/{ClientMapper,NotePathResolver,MeetingNoteRenderer,ObsidianExporter}.swift`
- Test: `ObsidianTests.swift`

**Interfaces:**
```swift
enum ClientMapper { static func client(for attendees: [Attendee], domains: [String: String], selfAddresses: [String]) -> String? } // subdomain matches; most frequent mapped client wins; nil if none
enum NotePathResolver { static func relativePath(pattern: String, area: String, client: String?, date: Date, title: String, inbox: String, timeZone: TimeZone) -> String
  static func sanitize(_ title: String) -> String } // drop / \ : * ? " < > | ; collapse spaces; trim; max 80 chars
struct NoteOptions: Sendable { var transcriptLink: URL; var embeddedTranscript: String?
  var audioLinks: [URL]               // originals in Muninn storage, always rendered as [Audio (mic)](file://…), [Audio (call)](file://…)
  var embeddedAudioFileNames: [String] } // only when copied into the vault (vaultIncludesAudio): ![[name]]
enum MeetingNoteRenderer { static func render(meeting: Meeting, summary: Summary, options: NoteOptions) -> String }
enum ExportOutcome: Equatable, Sendable { case written(URL), alreadyExists(URL) }
struct ObsidianExporter: Sendable { init(vault: URL); func export(note: String, relativePath: String, attachments: [URL], overwrite: Bool) throws -> ExportOutcome }
```
Note format:
- YAML frontmatter with `type: meeting`, `date: yyyy-MM-dd`, `title`, `client`, `account`, `attendees` (a list of emails), `engine`, `muninn: <meeting id>`;
- `# <title>`, then `## Summary` with each subject as a `###` heading and its bullets;
- actions as `- [ ] <text> [owner:: <owner>]`, plus ` [due:: <date>]` when there is a due date;
- `## Attendees`;
- `## Transcript`, holding the link `[Full transcript](<file URL>)` or the embedded transcript;
- audio: always the `audioLinks` as `[Audio (mic)](file://…)` and `[Audio (call)](file://…)`, plus `![[<file>]]` embeds only for `embeddedAudioFileNames`.

Attachments are copied next to the note.

- [ ] **Steps 1–5:** write tests for:
  - `pathWithClient == "Meetings/Acme/2026-10-22 Acme sync.md"`
  - `pathWithoutClientGoesToInbox == "Inbox/2026-10-22 Acme sync.md"`
  - `titleWithSlashDoesNotCreateFolders`
  - `subdomainMaps`
  - `taskLineFormat == "- [ ] Confirm backup window [owner:: Jan] [due:: 2026-11-07]"`
  - `defaultNoteLinksAudioWithoutEmbeds` (two `file://` audio links, no `![[`)
  - `existingFileNotOverwritten` (`.alreadyExists`, contents unchanged)
  - `overwriteWhenAsked`

  Then run them and see them fail, implement, run them and see them pass, and commit with the message `Add Obsidian note export`.

### Task 11: Storage and settings

**Depends on:** 2

**Files:**
- Create: `Storage/{MuninnPaths,MeetingStore,TranscriptMarkdown,Settings,SettingsStore}.swift`
- Test: `StorageTests.swift`

**Interfaces:**
```swift
struct MuninnPaths: Sendable { init(home: URL, environment: [String: String]); var data: URL; var config: URL; var cache: URL; var meetings: URL; var settingsFile: URL }
final class MeetingStore: @unchecked Sendable { init(root: URL)
  func create(_ m: Meeting) throws; func save(_ m: Meeting) throws; func load(_ id: MeetingID) throws -> Meeting; func list() throws -> [Meeting] // newest first
  func directory(_ id: MeetingID) -> URL; func audioURL(_ id: MeetingID, track: Track) -> URL     // audio/mic.caf, audio/system.caf
  func saveTranscript(_ t: Transcript, for: MeetingID, speakerNames: [String: String]) throws     // transcript.json + transcript.md
  func loadTranscript(_ id: MeetingID) throws -> Transcript?
  func saveClean(_ c: CleanTranscript, transcript: Transcript, for: MeetingID, speakerNames: [String: String]) throws // transcript.clean.json + .md
  func loadClean(_ id: MeetingID) throws -> CleanTranscript?
  func saveSummary(_ s: Summary, for: MeetingID) throws; func loadSummary(_ id: MeetingID) throws -> Summary? } // summary.json + summary.md
enum TranscriptMarkdown { static func render(segments: [(id: Int, start: TimeInterval, speaker: String, text: String)], title: String) -> String } // "**[01:02] Jan:** text"
struct AccountSettings: Codable, Equatable, Sendable { var id: String; var displayName: String; var vaultArea: String; var tenant: String; var clientID: String; var selfAddresses: [String] }
struct EngineEndpoint: Codable, Equatable, Sendable { var api: EndpointAPI; var baseURL: String; var model: String; var keepAlive: String }
enum EndpointAPI: String, Codable, Sendable { case ollama, openAICompatible }
struct Hotkey: Codable, Equatable, Sendable { var key: String; var modifiers: [String] }
struct Settings: Codable, Equatable, Sendable { static let defaults: Settings }  // fields and defaults below
final class SettingsStore: @unchecked Sendable { init(file: URL); func load() -> Settings; func save(_ s: Settings) throws }
```
Settings fields and defaults:

| Field | Default |
|---|---|
| `defaultEngine` | `.macbook` |
| `macbook` | `EngineEndpoint(.ollama, "http://127.0.0.1:11434", "qwen3:8b", "0")` |
| `studio` | `EngineEndpoint(.ollama, "", "gpt-oss:20b", "10m")` |
| `claudeModel` | `"claude-opus-5-5"` |
| `claudeEffort` | `"medium"` |
| `useLLMCleanup` | `false` |
| `accounts` | one account, `work` (display name "Work", vault area "Work"), with tenant "organizations", empty clientID and no self addresses |
| `vaultPath` | `""` (empty until the user chooses a vault) |
| `notePattern` | `"Meetings/{client}/{date} {title}.md"` |
| `inboxFolder` | `"Inbox"` |
| `clientDomains` | `[:]` |
| `autoFileToObsidian` | `false` |
| `vaultIncludesTranscript` | `false` |
| `vaultIncludesAudio` | `false` |
| `dictionary` | `[]` |
| `watchList` | see below |
| `flagHotkey` | `Hotkey("F", ["control","option","command"])` |
| `showPill` | `true` |
| `liveModel` | `"parakeet-v3"` |
| `finalModel` | `"parakeet-v3"` |
| `userName` | `""` (resolved to the first word of the macOS full name, else "Me") |

The `watchList` default holds:
`com.microsoft.teams2`, `com.microsoft.teams`, `us.zoom.xos`, `com.cisco.webexmeetingsapp`, `com.tinyspeck.slackmacgap`, `com.apple.FaceTime`, `app.zen-browser.zen`, `com.google.Chrome`, `com.apple.Safari`, `org.mozilla.firefox`, `com.microsoft.edgemac`, `company.thebrowser.Browser`.

- [ ] **Steps 1–5:** write tests for:
  - `xdgOverrides`: `XDG_DATA_HOME=/x` gives `/x/muninn`
  - `defaultsUnderHome`
  - `meetingRoundTripOnDisk`
  - `listNewestFirst`
  - `transcriptMarkdownLine`
  - `settingsMissingFileGivesDefaults`
  - `settingsPartialFileKeepsGivenAndDefaultsRest`: a file with only `{"defaultEngine":"studio"}` gives `.studio` plus defaults
  - `settingsUnknownKeysIgnored`
  - `corruptSettingsNotOverwritten`: `load()` returns defaults and the file bytes are unchanged

  Then run them and see them fail, implement (custom `init(from:)` using `decodeIfPresent`), run them and see them pass, and commit with the message `Add meeting storage and settings`.

### Task 12: Processing pipeline and speaker attribution

**Depends on:** 3, 4, 5, 6, 11

**Files:**
- Create: `Pipeline/{Protocols,SpeakerAttribution,ProcessingPipeline}.swift`
- Test: `PipelineTests.swift`

**Interfaces:**
```swift
struct SpeakerTurn: Codable, Hashable, Sendable { var speaker: String; var start: TimeInterval; var end: TimeInterval }
protocol Transcribing: Sendable { func transcribe(audio: URL, track: Track, vocabulary: [String]) async throws -> [Segment] }   // speaker "" until attribution
protocol Diarizing: Sendable { func diarize(audio: URL) async throws -> [SpeakerTurn] }
protocol EnvironmentProbing: Sendable { func environment(settings: Settings) async -> EngineEnvironment }
enum SpeakerAttribution { static func attribute(mic: [Segment], system: [Segment], micTurns: [SpeakerTurn], systemTurns: [SpeakerTurn], mode: CaptureMode) -> [Segment] }
actor ProcessingPipeline { init(store: MeetingStore, settings: @escaping @Sendable () -> Settings, transcriber: Transcribing, diarizer: Diarizing,
                               cleaner: @escaping @Sendable (Settings, EngineDecision) -> TranscriptCleaning, summarizer: Summarizing, probe: EnvironmentProbing,
                               clock: @escaping @Sendable () -> Date = Date.init)
  func process(_ id: MeetingID) async            // runs/resumes stages; never throws, records .failed(message)
  func regenerate(_ id: MeetingID, engine: EngineKind) async   // forced engine
  func resumeWaiting() async                      // re-evaluates all .waiting meetings
  var onChange: (@Sendable (Meeting) -> Void)? }
```
Attribution rules:
- `.call`: every mic segment gets speaker `Transcript.youSpeaker`. System segments are split at word level where the system turn changes, with speakers `S1, S2…` in order of first appearance.
- `.micOnly`: mic segments are split by mic turns with speakers `S1…`. Nothing is `you`.
- The output is sorted by start, with ids renumbered from 0.

Stages:
1. **transcribing:** mic, plus system when `.call`. Skipped if `transcript.json` exists.
2. **diarizing**
3. **engine decision:** `EngineSelector.decide(preferred: settings.defaultEngine, forced:, environment:)`, made once, before any LLM stage.
4. **cleaning:** `cleaner(settings, decision)`. The factory returns `LLMTranscriptCleaner` for the decided engine only when `useLLMCleanup` is on and the decision is `.run`; on `.wait` it returns the rule cleaner, so cleanup never loads a model the gate refused. Skipped if `transcript.clean.json` exists.
5. **summarizing:**
   - On `.wait`, set the status and stop.
   - On `run(_, fallbackFrom: .studio)`, set `engineNotice = "Network Mac unreachable — summarized on This Mac"`.
6. **ready**

`regenerate` re-runs only summarizing, with the forced engine. Each stage's duration goes into `metrics`. Status is saved before each stage and `onChange` is called.

- [ ] **Steps 1–5:** write tests with fakes for:
  - `callModeMicIsYou`
  - `micOnlyNeverYou`
  - `systemSplitAtTurnChange` (one segment of 4 words, turns S1 [0,1.5) and S2 [1.5,3), becomes 2 segments)
  - `happyPathReachesReady`
  - `waitsWhenStudioUnreachableUnderPressure`
  - `resumeWaitingRunsWhenReachable`
  - `forcedMacbookRunsUnderPressure`
  - `summarizerErrorMarksFailedNotStuck`
  - `resumeSkipsCompletedTranscription` (the transcriber is called 0 times on the second run)
  - `fallbackNoticeSet`
  - `llmCleanupSkippedWhenGateWaits` (useLLMCleanup on, macbook default, warning pressure: the cleaner factory receives `.wait`, no LLM client is built, and the meeting ends `.waiting(.memoryPressure)`)

  Then run them and see them fail, implement, run them and see them pass, and commit with the message `Add processing pipeline`.

### Task 13: Metrics (WER and load sampling)

**Depends on:** 3

**Files:**
- Create: `Metrics/{WordErrorRate,LoadSampler}.swift`
- Test: `MetricsTests.swift`

**Interfaces:**
```swift
struct WERResult: Equatable, Sendable { var wer: Double; var substitutions: Int; var deletions: Int; var insertions: Int; var referenceWords: Int }
enum WordErrorRate { static func compute(reference: String, hypothesis: String) -> WERResult } // Tokenizer.normalizedWords
struct LoadSnapshot: Codable, Equatable, Sendable { var time: Date; var pressureLevel: Int; var freeBytes: UInt64; var compressedBytes: UInt64; var swapUsedBytes: UInt64; var swapIns: UInt64; var swapOuts: UInt64; var cpuBusyPercent: Double }
protocol LoadReading: Sendable { func snapshot() -> LoadSnapshot }
struct SystemLoadReader: LoadReading   // host_statistics64(HOST_VM_INFO64), sysctl vm.swapusage, kern.memorystatus_vm_pressure_level, host_processor_info deltas
enum LoadReport { static func csv(_ s: [LoadSnapshot]) -> String }  // header: time,pressure,free_mb,compressed_mb,swap_used_mb,swapins,swapouts,cpu_busy
```
- [ ] **Steps 1–5:** write tests for:
  - `werExact == 0`
  - `werOneSubstitution`: ref `"a b c d"`, hyp `"a x c d"` gives 0.25 with 1 substitution
  - `werInsertionDeletion`
  - `csvHeaderAndRow`
  - `systemReaderReturnsPlausibleValues`: pressure is 1, 2 or 4 and `cpuBusyPercent` is in 0…100

  Then run them and see them fail, implement, run them and see them pass, and commit with the message `Add WER and load sampling`.

### Task 14: Call detection (MuninnAudio)

**Depends on:** 1, 11

**Files:**
- Create: `Sources/MuninnAudio/{AudioProcessList,CallDetector}.swift`
- Test: `Tests/MuninnAudioTests/CallDetectorTests.swift`

**Interfaces:**
```swift
struct AudioProcessInfo: Hashable, Sendable { var pid: pid_t; var bundleID: String; var objectID: UInt32; var isRunningInput: Bool; var isRunningOutput: Bool }
protocol AudioProcessListing: Sendable { func processes() throws -> [AudioProcessInfo] }
struct CoreAudioProcessList: AudioProcessListing   // kAudioHardwarePropertyProcessObjectList + kAudioProcessPropertyBundleID/PID/IsRunningInput/IsRunningOutput
enum CallEvent: Equatable, Sendable { case started(bundleID: String, pid: pid_t), ended(bundleID: String) }
struct CallDiff { static func events(previous: Set<String>, current: [AudioProcessInfo], watchList: [String]) -> (events: [CallEvent], inputBundles: Set<String>) }
final class CallDetector: @unchecked Sendable { init(listing: AudioProcessListing, watchList: @escaping @Sendable () -> [String], interval: TimeInterval = 1.0)
  var events: AsyncStream<CallEvent> { get }; func start(); func stop() }
```
Bundle ids match exactly or as a prefix (helper processes such as `com.google.Chrome.helper` count as `com.google.Chrome`). Muninn's own bundle id is ignored.

- [ ] **Steps 1–5:** write tests for:
  - `startEventForWatchedApp`
  - `helperBundleMatchesPrefix`
  - `unwatchedIgnored`
  - `endEventWhenInputStops`
  - `ownProcessIgnored`

  Then run them and see them fail, implement, run them and see them pass. Also build, and run once by hand with `swift run muninn-spike detect` in Task 18. Commit with the message `Add call detection`.

### Task 15: Recording session (MuninnAudio)

**Depends on:** 14

**Files:**
- Create: `Sources/MuninnAudio/{RecordingSession,TrackWriter,LiveAudioStream,LevelMeter}.swift`
- Test: `Tests/MuninnAudioTests/RecordingTests.swift`

**Interfaces:**
```swift
enum TapTarget: Equatable, Sendable { case process(pid: pid_t), allSystemAudio }
struct RecordingConfig: Sendable { var micURL: URL; var systemURL: URL?; var tap: TapTarget?; var voiceProcessing: Bool }
final class RecordingSession: @unchecked Sendable { init(config: RecordingConfig)
  func start() throws; func pause(); func resume(); func stop() async throws -> TimeInterval  // returns duration
  var elapsed: TimeInterval { get }; var micLevel: Float { get }; var systemLevel: Float { get }  // dBFS
  var liveAudio: AsyncStream<LiveAudioChunk> { get } }   // LiveAudioChunk from MuninnCore (Task 2), both tracks tagged
final class TrackWriter { init(url: URL, sampleRate: Double, channels: Int) throws; func append(_ buffer: AVAudioPCMBuffer) throws; func close() }  // CAF, Float32
enum LevelMeter { static func dbfs(_ samples: UnsafeBufferPointer<Float>) -> Float }  // -160 for silence
enum Resampler { static func toMono16k(_ buffer: AVAudioPCMBuffer) -> [Float] }
```
System audio uses `CATapDescription(stereoMixdownOfProcesses: [processObjectID])` for `.process`, or `stereoGlobalTapButExcludeProcesses: [ownProcess]` for `.allSystemAudio`, in a private aggregate device with an IOProc. The mic uses `AVAudioEngine` input, with `setVoiceProcessingEnabled(voiceProcessing)`. Pause drops buffers and freezes `elapsed`.

- [ ] **Steps 1–5:** write tests for:
  - `levelMeterSilence == -160`
  - `levelMeterFullScale ≈ 0`
  - `resamplerHalvesLength32kTo16k`
  - `trackWriterRoundTrip` (write 1 s of a sine wave at 48 kHz, read it back, frame count 48000)

  Then run them and see them fail, implement, and run them and see them pass. Real capture is verified by the owner through the spike. Commit with the message `Add recording session with process taps`.

### Task 16: Speech adapters (MuninnSpeech)

**Depends on:** 12

**Files:**
- Create: `Sources/MuninnSpeech/{SegmentBuilder,SpeechModels,ParakeetTranscriber,ParakeetLiveTranscriber,WhisperKitTranscriber,FluidDiarizer}.swift`
- Test: `Tests/MuninnSpeechTests/SegmentBuilderTests.swift`

**Interfaces:**
```swift
struct TimedToken: Sendable { var text: String; var start: TimeInterval; var end: TimeInterval }   // SentencePiece-style: leading "▁" or " " starts a word
enum SegmentBuilder { static func words(from tokens: [TimedToken]) -> [Word]
  static func segments(from words: [Word], track: Track, pauseGap: TimeInterval = 0.8, maxDuration: TimeInterval = 20) -> [Segment] } // also split after . ? !
enum SpeechModelID: String, CaseIterable, Sendable { case parakeetV3 = "parakeet-v3", parakeetUltra = "parakeet-ultra", whisperLargeV3Turbo = "whisper-large-v3-turbo" }
struct ParakeetTranscriber: Transcribing { init(model: SpeechModelID) }        // FluidAudio AsrModels/AsrManager batch over the file; vocabulary via CustomVocabularyContext when non-empty
struct WhisperKitTranscriber: Transcribing { init(model: String = "large-v3-v20240930_turbo") }
struct FluidDiarizer: Diarizing { init() }                                     // OfflineDiarizerManager
enum TranscriberFactory { static func make(_ id: SpeechModelID) -> Transcribing }  // parakeet* → ParakeetTranscriber, whisper* → WhisperKitTranscriber
final class ParakeetLiveTranscriber: @unchecked Sendable { init(model: SpeechModelID)
  func start() async throws; func feed(_ chunk: LiveAudioChunk) async; func finish() async
  var updates: AsyncStream<LiveTranscriptUpdate> { get } }
struct LiveTranscriptUpdate: Sendable { var track: Track; var text: String; var isFinal: Bool; var audioTime: TimeInterval; var producedAt: Date }  // lag = wall clock vs audio time
```
The exact FluidAudio and WhisperKit calls are to be found in `Vendor/FluidAudio/Sources`, its `Documentation/`, and `.build/checkouts/WhisperKit`. Models download on first use into each library's default cache.

- [ ] **Steps 1–5:** write tests for:
  - `wordsJoinSubwordTokens` (`["▁hel","lo","▁world"]` gives `["hello","world"]` with combined timings)
  - `segmentsSplitOnPause`
  - `segmentsSplitOnSentenceEnd`
  - `segmentsCapDuration`
  - `factoryDispatchesEveryModel` (each `SpeechModelID.allCases` maps to its adapter type: `whisperLargeV3Turbo` → `WhisperKitTranscriber`, the others → `ParakeetTranscriber`)

  Then run them and see them fail, implement, and run them and see them pass. `swift build` must compile all adapters. Commit with the message `Add FluidAudio and WhisperKit adapters`.

### Task 17: System services (MuninnSystem)

**Depends on:** 5, 8, 11

**Files:**
- Create: `Sources/MuninnSystem/{KeychainStore,SystemMemoryPressure,StudioProbe,GlobalHotkey}.swift`
- Test: `Tests/MuninnSystemTests/SystemTests.swift`

**Interfaces:**
```swift
struct KeychainSecrets: Sendable { init(service: String = "be.netronix.muninn"); func get(_ key: String) throws -> String?; func set(_ v: String, for key: String) throws; func delete(_ key: String) throws } // generic password
struct KeychainTokenStore: TokenStore { init(secrets: KeychainSecrets) }   // key "graph.<account>" JSON
enum SystemMemoryPressure { static func current() -> MemoryPressureLevel }   // sysctl kern.memorystatus_vm_pressure_level
struct LiveEnvironmentProbe: EnvironmentProbing { init(secrets: KeychainSecrets, session: URLSession = .shared) } // network Mac: GET {base}/api/tags (ollama) or {base}/v1/models, 2 s timeout; claude key "claude.apiKey"
final class GlobalHotkey { init(hotkey: Hotkey, handler: @escaping () -> Void) throws; func unregister() }  // Carbon RegisterEventHotKey
enum HotkeyParser { static func carbon(_ h: Hotkey) -> (keyCode: UInt32, modifiers: UInt32)? }
```
- [ ] **Steps 1–5:** write tests for:
  - `hotkeyParserControlOptionCommandF` (key code 3, modifiers `controlKey|optionKey|cmdKey`)
  - `memoryPressureReadsValidLevel`
  - `probeUnreachableForEmptyBaseURL`
  - `keychainRoundTrip` (service `be.netronix.muninn.tests`, cleaned up afterwards)

  Then run them and see them fail, implement, run them and see them pass, and commit with the message `Add Keychain, memory pressure, Studio probe and hotkey`.

### Task 18: Spike CLI (`muninn-spike`)

**Depends on:** 12, 13, 15, 16, 17

**Files:**
- Create: `Sources/MuninnSpike/main.swift`, `Sources/MuninnSpike/Commands/*.swift`, `docs/spike.md`

**Interfaces:** the `muninn-spike` subcommands, all of which write their output files into `--out <dir>`:

| Command | What it does |
|---|---|
| `detect [--seconds N]` | Prints `CallEvent`s for the watch list. |
| `record --seconds N [--app <bundleID>] [--all-system] [--mic-only] [--voice-processing] --out <dir>` | Writes `mic.caf` and `system.caf`, and prints the tracks' sizes and levels. |
| `transcribe <audio> --model <SpeechModelID> --out <dir>` | Writes `transcript.json` and `.md`, and prints the RTF and elapsed time. |
| `diarize <audio> --out <dir>` | Writes `turns.json`. |
| `live <audio> --model <id> --out <dir>` | Replays the file in real time through `ParakeetLiveTranscriber` and writes `lag.csv` (audio time, produced time, lag). |
| `summarize <transcript.json> --engine macbook\|studio\|claude [--language nl] --out <dir>` | Writes `summary.json` and `.md` plus the timing. |
| `e2e <recording-dir> --engine … --out <dir>` | Runs `ProcessingPipeline` on a recorded folder and prints per-stage seconds and the total. |
| `measure --seconds N --out load.csv` | Samples `SystemLoadReader` every second. |
| `wer <reference.txt> <hypothesis.txt>` | Prints the WER breakdown. |

`docs/spike.md` is the runbook for the spec's spike steps 1–6, giving each command line, what to look at, and the pass criteria quoted from the spec.

- [ ] **Step 1:** Implement the commands with ArgumentParser `AsyncParsableCommand`. Engines read settings from `SettingsStore(MuninnPaths(...).settingsFile)` and secrets from `KeychainSecrets`.
- [ ] **Step 2:** Run `swift build --product muninn-spike`, then:
  - `.build/debug/muninn-spike wer` on two fixture texts, expecting the correct numbers;
  - `.build/debug/muninn-spike measure --seconds 2 --out $TMPDIR/l.csv`, expecting 2 rows.
- [ ] **Step 3:** Write `docs/spike.md`.
- [ ] **Step 4:** Commit with the message `Add spike CLI and runbook`.

### Task 25: Meeting preparation, recipient editing and the recording flow (core)

**Depends on:** 7, 10, 11

**Files:**
- Create: `Packages/MuninnCore/Sources/MuninnCore/Pipeline/{MeetingPreparation,MeetingActions,RecordingFlow}.swift`
- Test: `Packages/MuninnCore/Tests/MuninnCoreTests/MeetingPreparationTests.swift`, `RecordingFlowTests.swift`

**Interfaces:**
```swift
enum MeetingPreparation { static func prepare(startedAt: Date, mode: CaptureMode, appName: String?, match: EventMatch, accounts: [AccountSettings],
                                            clientDomains: [String: String], timeZone: TimeZone, existingIDs: Set<String>) -> Meeting
  static func choose(_ event: CalendarEvent, for m: Meeting, accounts: [AccountSettings], clientDomains: [String: String]) -> Meeting } // resolves an ambiguous match
enum MeetingActions { static func canDraft(_ m: Meeting) -> Bool   // accountID != nil && recipients.contains(where: \.included)
  static func addRecipient(_ a: Attendee, to m: Meeting, selfAddresses: [String]) -> Meeting  // dedupe by lowercased email, ignore self, included = true
  static func setIncluded(_ email: String, _ included: Bool, in m: Meeting) -> Meeting }
struct CallIdentity: Equatable, Sendable { var appName: String; var bundleID: String; var pid: pid_t }
enum RecordingFlowState: Equatable, Sendable { case idle, offering(CallIdentity), confirmAllAudio(CallIdentity), recording(TapPlan, call: CallIdentity?) }
enum TapPlan: Equatable, Sendable { case process(pid: pid_t), allSystemAudio, micOnly }
enum RecordingFlowEvent: Equatable, Sendable { case callStarted(appName: String, bundleID: String, pid: pid_t), callEnded(bundleID: String),
  recordTapped, declined, processTapFailed, confirmAllAudio, cancel, manualConversation, stopped }
enum RecordingFlow { static func next(_ s: RecordingFlowState, _ e: RecordingFlowEvent) -> RecordingFlowState }
```
`prepare` rules:
- `.single`: title, attendees, recipients (via `RecipientBuilder`), `accountID`, `association` and `client` (`ClientMapper`) come from the event.
- `.ambiguous`: `candidateEvents` is filled and title, account and recipients are left empty until `choose`.
- `.none`: title `RecipientBuilder.untitledTitle(appName ?? "Conversation", …)`, no account, no recipients.

Recording flow: `offering(call)` + `recordTapped` → `recording(.process(pid: call.pid), call: call)`. If the process tap then fails (`processTapFailed`), `recording(.process, call)` goes to `confirmAllAudio(call)`, and only the `confirmAllAudio` event starts `recording(.allSystemAudio, call: call)`; `cancel` returns to `idle`. Recording all system audio is never started without that confirmation. `manualConversation` from `idle` → `recording(.micOnly, call: nil)`. `callEnded(bundleID)` while `offering(call)` or `confirmAllAudio(call)` → `idle` only when `bundleID == call.bundleID`; another app's end changes nothing. `stopped` → `idle`.

- [ ] **Step 1: Write the failing tests:**
  - `noEventGivesUntitledAndNoAccount` (Review Focus 1)
  - `singleEventFillsRecipientsAndClient`
  - `ambiguousLeavesChoice`, `chooseResolvesAmbiguous`
  - `canDraftRequiresAccountAndRecipient`
  - `noEventToDraftable`: prepare with `.none`, set `accountID = "work"`, `addRecipient(jan@acme.be)` → `canDraft == true`
  - `addRecipientIgnoresSelfAndDuplicates`
  - `processTapFailureAsksBeforeAllAudio`: offering → recordTapped → processTapFailed → state is `confirmAllAudio`, not `recording`
  - `confirmStartsAllAudio` (keeps the call identity), `cancelReturnsIdle`, `callEndedDismissesPrompt`, `otherAppEndingKeepsPrompt`, `manualConversationIsMicOnly`
- [ ] **Step 2:** Run them and see them fail, implement, run them and see them pass.
- [ ] **Step 3:** Commit with the message `Add meeting preparation, recipients and recording flow`.

### Task 19: App shell and bundling

**Depends on:** 25, 12, 16, 17, 11

**Files:**
- Create: `Sources/MuninnApp/MuninnApp.swift`, `Sources/MuninnApp/AppModel.swift`, `scripts/bundle-app.sh`, `scripts/Info.plist`, `scripts/Muninn.entitlements`

**Interfaces:**
```swift
@main struct MuninnApp: App   // MenuBarExtra("Muninn", systemImage: model.isRecording ? "record.circle.fill" : "waveform") + Window("Meetings", id: "meetings") + Settings
@MainActor final class AppModel: ObservableObject { @Published var meetings: [Meeting]; @Published var isRecording: Bool; @Published var settings: Settings
  let paths: MuninnPaths; let store: MeetingStore; let settingsStore: SettingsStore; let secrets: KeychainSecrets; let pipeline: ProcessingPipeline
  func reloadMeetings(); func saveSettings(_ s: Settings); func update(_ m: Meeting)                     // save + publish
  func prepareMeeting(startedAt: Date, mode: CaptureMode, appName: String?) async -> Meeting           // MeetingPreparation with eventMatch(at:)
  func eventMatch(at: Date) async -> EventMatch                                                         // returns .none in this task; Task 23 fetches Graph events
  func searchPeople(account: String, query: String) async -> [Attendee]                                 // returns [] in this task; Task 23 uses Graph
  func process(_ id: MeetingID); func regenerate(_ id: MeetingID, engine: EngineKind) }                 // forward to pipeline
```
`AppModel` builds `ProcessingPipeline` with `TranscriberFactory.make(SpeechModelID(rawValue: settings.finalModel) ?? .parakeetV3)`, `FluidDiarizer`, the cleaner factory from Task 12, `LLMSummarizer` whose `clientFor` maps engines to `OllamaClient`/`OpenAICompatibleClient` (from `settings.macbook`/`settings.studio`) and `ClaudeClient` (key from Keychain `claude.apiKey`), and `LiveEnvironmentProbe`.
`Info.plist` contents:
- `CFBundleIdentifier be.netronix.muninn`, `CFBundleExecutable Muninn`, `CFBundleName Muninn`
- `LSUIElement true`, `LSMinimumSystemVersion 15.0`
- `NSMicrophoneUsageDescription` "Muninn records your microphone during calls you choose to record."
- `NSAudioCaptureUsageDescription` "Muninn records the audio of calls you choose to record."
- `CFBundleShortVersionString 0.1.0`, `CFBundleVersion 1`

The entitlements file sets `com.apple.security.device.audio-input`.

`scripts/bundle-app.sh` does the following:
1. runs `swift build -c release --product Muninn`;
2. assembles `build/Muninn.app`, copying the binary and every `*.bundle` from the release folder into `Contents/Resources`;
3. runs `codesign --force --options runtime --entitlements scripts/Muninn.entitlements --sign "${MUNINN_SIGN_IDENTITY:--}"`;
4. runs `codesign --verify`.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Run `scripts/bundle-app.sh`. Expected: `build/Muninn.app` exists, `codesign --verify --verbose build/Muninn.app` passes, and `plutil -lint` passes.
- [ ] **Step 3:** Commit with the message `Add app shell and bundling script`.

### Task 20: Recording UI

**Depends on:** 19, 15, 16

**Files:**
- Create: `Sources/MuninnApp/Views/{MenuBarContent,CallPromptPanel,RecordingPill,LiveTranscriptWindow}.swift`, `Sources/MuninnApp/RecordingController.swift`

**Interfaces:**
```swift
@MainActor final class RecordingController: ObservableObject { init(model: AppModel)
  @Published var state: RecordingFlowState      // Task 25; transitions only through RecordingFlow.next
  @Published var meetingID: MeetingID?; @Published var isPaused: Bool
  @Published var liveLines: [LiveTranscriptUpdate]; @Published var micLevel: Float; @Published var systemLevel: Float
  func handle(_ e: CallEvent); func startCall(bundleID: String, pid: pid_t); func startConversation(); func flag(); func pause(); func resume(); func stop() async }
```
Behaviour:
- A `CallEvent.started` for a watched app shows `CallPromptPanel`, a floating, non-activating `NSPanel` at the top right with the app name, **Record** and **Not this one**. It is dismissed when the call ends.
- **Record** creates the `Meeting` through `AppModel.prepareMeeting` (capture mode `.call`), then starts the `RecordingSession` with `.process(pid)`, then live transcription. If the process tap fails, the controller feeds `processTapFailed` and the panel changes to "Can't isolate <App>'s audio. Record all system audio instead?" with **Record all audio** and **Cancel**; all-system capture starts only after **Record all audio**.
- **The pill** is a floating `NSPanel`, draggable, joining all Spaces. It shows a red dot, the elapsed time, a level meter, 🚩 and ■. It is hidden when `settings.showPill` is false.
- **The menu bar** shows recording controls when recording, plus "Record a conversation…", "Show live transcript", up to 5 recent meetings, and "Open meetings… ⌘O".
- **The flag** appends `Flag(offset: elapsed)`. The global hotkey from `settings.flagHotkey` triggers `flag()`.
- **Stop** finalises the files, sets `endedAt`, saves the meeting, and calls `AppModel.process(id)`.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Run `swift build`, then `scripts/bundle-app.sh`. Expected: success.
- [ ] **Step 3:** Commit with the message `Add recording prompt, pill and menu bar`.

### Task 21: Main window

**Depends on:** 19, 12, 3

**Files:**
- Create: `Sources/MuninnApp/Views/{MainWindow,MeetingDetail,SummaryEditor,TranscriptView}.swift`

Behaviour:
- **Sidebar:** meetings grouped Today, Yesterday, This week and Earlier, with search over titles, attendees and summary text.
- **Header:**
  - title (editable), date and time, duration, attendees, language and status;
  - an **event/account/client picker** listing `candidateEvents` when the match was ambiguous, plus "No event" (`MeetingPreparation.choose`);
  - an account picker, and client text stored in `Meeting.client`;
  - a **recipients editor**: each recipient with an include toggle (`MeetingActions.setIncluded`), a search field that calls `AppModel.searchPeople(account:query:)` for the meeting's account, and manual entry of an email address (`MeetingActions.addRecipient`).
- **Summary tab:**
  - editable subjects, bullets and actions (owner, text, due);
  - a "Written by: <engine> ▾" menu calling `regenerate`;
  - a waiting banner with **Run on This Mac anyway** and **Use Claude**, both `regenerate`;
  - the engine notice;
  - actions **✉ Outlook draft**, enabled only when `MeetingActions.canDraft`, and **◆ To Obsidian** (both call `AppModel` methods that Task 23 implements; in this task they are disabled stubs).
- **Transcript tab:**
  - a segmented control **Clean / Show changes / Verbatim**, where Show changes renders `ChangeView.tokens` with removed tokens struck through at 45% opacity;
  - 🚩 on flagged segments;
  - click a speaker to rename it (into `speakerNames`);
  - clicking a source chip in the Summary tab switches to the transcript and scrolls to that segment.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Run `swift build`. Expected: success.
- [ ] **Step 3:** Commit with the message `Add meetings window with summary and transcript views`.

### Task 22: Settings and sign-in UI

**Depends on:** 19, 8, 17

**Files:**
- Create: `Sources/MuninnApp/Views/{SettingsView,SignInSheet}.swift`

The tabs:

| Tab | Holds |
|---|---|
| Engines | Default engine picker; This Mac and Network Mac endpoints (api, URL, model, keep-alive); Claude model, effort and an API key field saved to Keychain `claude.apiKey`; "Use LLM cleanup". |
| Accounts | Per account: client ID, tenant, self addresses, and a **Sign in** button, plus **Add Account** and **Remove Account…**. Sign-in opens `SignInSheet`, which shows the device code and URL, polls, and stores the tokens via `KeychainTokenStore`. On success, `me()` fills the self addresses. |
| Obsidian | Vault path, note pattern, inbox, auto-file, include transcript and audio, client domains table. |
| Recording | Watch list, flag hotkey, show pill, live and final models. |
| Dictionary | The personal dictionary. |
| Permissions | Mic and system audio status, with buttons to open the matching System Settings panes. |

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Run `swift build`. Expected: success.
- [ ] **Step 3:** Commit with the message `Add settings and Microsoft sign-in`.

### Task 23: Integration

**Depends on:** 20, 21, 22, 25, 8, 9, 10

**Files:**
- Create: `Sources/MuninnApp/Services.swift`
- Modify: `Sources/MuninnApp/AppModel.swift`, `Sources/MuninnApp/Views/MeetingDetail.swift`

Wiring in the app:
- `CallDetector` feeds `RecordingController`.
- `eventMatch(at:)` fetches events from every signed-in account (`GraphClient.events`) for `now-1h…now+1h` and runs `EventMatcher.match`; failures fall back to `.none` with a logged warning.
- `searchPeople(account:query:)` uses `GraphClient.searchPeople` for that account.
- A timer runs `resumeWaiting()` every 60 s.
- A notification "Recap ready: <title>" is posted on `.ready`, and auto-filing happens then when it is enabled.
- **Outlook draft:** `RecapEmail` → `GraphClient.createDraft` in the meeting's account; store `draftWebLink` and open it.
- **To Obsidian:** `ObsidianExporter`. On `.alreadyExists`, ask before overwriting. Store `exportedNotePath`.

- [ ] **Step 1:** Wire the app as above, enabling the draft and Obsidian actions in `MeetingDetail`.
- [ ] **Step 2:** Run `swift build && swift test && swift test --package-path Packages/MuninnCore && scripts/bundle-app.sh`. Expected: all pass.
- [ ] **Step 3:** Commit with the message `Wire detection, Graph, drafts and Obsidian`.

### Task 24: Setup guide and final verification

**Depends on:** 23, 18

**Files:**
- Create: `docs/setup.md`

`docs/setup.md` gives the first-run steps in order:
1. `scripts/vendor-fluidaudio.sh` and `scripts/bundle-app.sh`;
2. create a code-signing certificate (Keychain Access → Certificate Assistant → "Muninn Local", type Code Signing) and rebuild with `MUNINN_SIGN_IDENTITY="Muninn Local"`;
3. allow Muninn in your outbound firewall, if you run one (Graph, Anthropic, the network Mac, Hugging Face for model downloads);
4. grant the Microphone and System Audio Recording permissions;
5. `brew install ollama`, then `ollama pull qwen3:8b`;
6. on the network Mac, install Ollama, set `OLLAMA_HOST=0.0.0.0`, run `ollama pull gpt-oss:20b`, and set the network Mac's URL;
7. register the Entra apps (public client, "Allow public client flows", delegated `User.Read Calendars.Read Mail.ReadWrite People.Read offline_access`) in each tenant you sign in to, enter the client IDs and sign in;
8. save the Claude API key in Settings;
9. run the spike (`docs/spike.md`).

- [ ] **Step 1:** Write `docs/setup.md`.
- [ ] **Step 2:** Run the full suite: `swift test --package-path Packages/MuninnCore`, `swift test`, `scripts/bundle-app.sh`. Expected: everything passes. Record the totals as passed/total.
- [ ] **Step 3:** Commit with the message `Add setup guide`.
