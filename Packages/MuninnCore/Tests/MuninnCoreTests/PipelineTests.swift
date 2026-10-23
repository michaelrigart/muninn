import Foundation
import Testing
@testable import MuninnCore

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&value)
    }
}

private final class Milestone: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func reach() {
        lock.lock()
        reached = true
        let pending = waiters
        waiters = [:]
        lock.unlock()
        pending.values.forEach { $0.resume() }
    }

    /// Returns once the milestone is reached. A cancelled task stops waiting and throws, so a stuck test ends at its time limit.
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if reached {
                    lock.unlock()
                    continuation.resume()
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[id] = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }
}

private final class FakeTranscriber: Transcribing, @unchecked Sendable {
    let results: [Track: [Segment]]
    let calls = Locked<[Track]>([])
    let running = Locked(0)
    let maxRunning = Locked(0)
    let started = Locked(false)
    let priorities = Locked<[TaskPriority]>([])
    var delay: UInt64 = 0
    var blocksUntilCancelled = false
    let afterTranscribe = Locked<(@Sendable (Track) -> Void)?>(nil)

    init(results: [Track: [Segment]]) {
        self.results = results
    }

    func transcribe(audio: URL, track: Track, vocabulary: [String]) async throws -> [Segment] {
        calls.update { $0.append(track) }
        priorities.update { $0.append(Task.currentPriority) }
        started.set(true)
        running.update { $0 += 1 }
        maxRunning.update { $0 = max($0, running.get()) }
        defer { running.update { $0 -= 1 } }
        if blocksUntilCancelled {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        if delay > 0 {
            try await Task.sleep(nanoseconds: delay)
        }
        afterTranscribe.get()?(track)
        return results[track] ?? []
    }
}

private struct DiarizerFailure: Error {}

private struct FakeDiarizer: Diarizing {
    let turns: [SpeakerTurn]
    let audio = Locked<[URL]>([])
    var failure: Error?

    func diarize(audio url: URL) async throws -> [SpeakerTurn] {
        audio.update { $0.append(url) }
        if let failure { throw failure }
        return turns
    }
}

private final class FakeProbe: EnvironmentProbing, @unchecked Sendable {
    let environment = Locked(EngineEnvironment(studioConfigured: true, studioReachable: true, memoryPressure: .normal, claudeKeyPresent: true))

    func environment(settings: Settings) async -> EngineEnvironment {
        environment.get()
    }
}

private struct SummarizerFailure: Error {}

private final class FakeSummarizer: Summarizing, @unchecked Sendable {
    let engines = Locked<[EngineKind]>([])
    let meetings = Locked<[String]>([])
    let failure = Locked<Error?>(nil)
    let onSummarize = Locked<(@Sendable () -> Void)?>(nil)
    let gate = Locked<Milestone?>(nil)
    let holdFirstCall = Locked(false)
    let released = Milestone()
    let entered = Milestone()
    let language = Locked("en")

    func summarize(meeting: Meeting, transcript: Transcript, clean: CleanTranscript, engine: EngineKind) async throws -> Summary {
        let isFirst = engines.get().isEmpty
        engines.update { $0.append(engine) }
        meetings.update { $0.append(meeting.id.rawValue) }
        let hook = onSummarize.get()
        let held = gate.get()
        entered.reach()
        hook?()
        if let held { try await held.wait() }
        if isFirst, holdFirstCall.get() {
            try await released.wait()
        }
        if let error = failure.get() { throw error }
        return Summary(language: language.get(), subjects: [], engine: engine, generatedAt: Date(timeIntervalSince1970: 0))
    }
}

private struct HookedCleaner: TranscriptCleaning {
    let afterClean: Locked<(@Sendable () -> Void)?>

    func clean(_ transcript: Transcript) async throws -> CleanTranscript {
        let result = try await RuleTranscriptCleaner().clean(transcript)
        afterClean.get()?()
        return result
    }
}

private func waitUntil(_ condition: () async -> Bool) async {
    for _ in 0..<15_000 where await !condition() {
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

private func waitForQueuedJob(_ pipeline: ProcessingPipeline, _ id: MeetingID, callers: Int, engine: EngineKind?) async {
    await waitUntil {
        let state = await pipeline.queuedJobState(for: id)
        return state?.callers == callers && state?.engine == engine
    }
}

private struct Harness {
    let store: MeetingStore
    let root: URL
    let transcriber: FakeTranscriber
    let diarizer: FakeDiarizer
    let probe = FakeProbe()
    let summarizer = FakeSummarizer()
    let settings = Locked(Settings.defaults)
    let recording = Locked(false)
    let decisions = Locked<[EngineDecision]>([])
    let llmCleanersBuilt = Locked(0)
    let changes = Locked<[ProcessingStatus]>([])
    let afterClean = Locked<(@Sendable () -> Void)?>(nil)
    let ready = Milestone()
    let pipeline: ProcessingPipeline

    init(mode: CaptureMode = .call(appBundleID: "us.zoom.xos"), useLLMCleanup: Bool = false, diarizerFailure: Error? = nil, clock: @escaping @Sendable () -> Date = { Date() }) async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("muninn-pipeline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = MeetingStore(root: root)
        transcriber = FakeTranscriber(results: [
            .mic: [Segment(id: 0, track: .mic, speaker: "", start: 0, end: 1, text: "Hello there", words: [
                Word(text: "Hello", start: 0, end: 0.5), Word(text: "there", start: 0.5, end: 1),
            ])],
            .system: [Segment(id: 0, track: .system, speaker: "", start: 2, end: 3, text: "Good morning", words: [
                Word(text: "Good", start: 2, end: 2.5), Word(text: "morning", start: 2.5, end: 3),
            ])],
        ])
        diarizer = FakeDiarizer(turns: [SpeakerTurn(speaker: "A", start: 0, end: 3)], failure: diarizerFailure)
        var initial = Settings.defaults
        initial.useLLMCleanup = useLLMCleanup
        settings.set(initial)
        let decisions = decisions
        let built = llmCleanersBuilt
        let settingsBox = settings
        let recordingBox = recording
        let hook = afterClean
        pipeline = ProcessingPipeline(
            store: store,
            settings: { settingsBox.get() },
            transcriber: transcriber,
            diarizer: diarizer,
            cleaner: { settings, decision in
                decisions.update { $0.append(decision) }
                if settings.useLLMCleanup, case .run = decision {
                    built.update { $0 += 1 }
                }
                return HookedCleaner(afterClean: hook)
            },
            summarizer: summarizer,
            probe: probe,
            isRecording: { recordingBox.get() },
            clock: clock
        )
        let changes = changes
        let ready = ready
        await pipeline.setOnChange { meeting in
            changes.update { $0.append(meeting.status) }
            if meeting.status == .ready { ready.reach() }
        }
        try store.create(Self.meeting("m1", mode: mode))
    }

    static func meeting(_ id: String, mode: CaptureMode, status: ProcessingStatus = .transcribing) -> Meeting {
        Meeting(
            id: MeetingID(rawValue: id), title: "Acme sync", startedAt: Date(timeIntervalSince1970: 1_792_000_000), endedAt: nil,
            captureMode: mode, language: "en", accountID: nil, association: nil, client: nil, candidateEvents: [],
            attendees: [], recipients: [], flags: [], speakerNames: [:], status: status, summaryEngine: nil,
            engineNotice: nil, exportedNotePath: nil, draftWebLink: nil, metrics: ProcessingMetrics()
        )
    }

    var id: MeetingID { MeetingID(rawValue: "m1") }

    func meetingNow() throws -> Meeting {
        try store.load(id)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension EngineEnvironment {
    static func make(studioReachable: Bool = true, memoryPressure: MemoryPressureLevel = .normal, claudeKeyPresent: Bool = true) -> EngineEnvironment {
        EngineEnvironment(studioConfigured: true, studioReachable: studioReachable, memoryPressure: memoryPressure, claudeKeyPresent: claudeKeyPresent)
    }
}

struct PipelineTests {
    private func words(_ pairs: [(String, TimeInterval, TimeInterval)]) -> [Word] {
        pairs.map { Word(text: $0.0, start: $0.1, end: $0.2) }
    }

    private func segment(_ track: Track, _ start: TimeInterval, _ end: TimeInterval, _ text: String, id: Int = 0) -> Segment {
        let parts = text.split(separator: " ").map(String.init)
        let step = (end - start) / Double(max(parts.count, 1))
        let ws = parts.enumerated().map { Word(text: $0.element, start: start + Double($0.offset) * step, end: start + Double($0.offset + 1) * step) }
        return Segment(id: id, track: track, speaker: "", start: start, end: end, text: text, words: ws)
    }

    @Test func callModeMicIsYou() {
        let result = SpeakerAttribution.attribute(
            mic: [segment(.mic, 0, 1, "hello there")],
            system: [segment(.system, 2, 3, "good morning")],
            micTurns: [SpeakerTurn(speaker: "X", start: 0, end: 1)],
            systemTurns: [SpeakerTurn(speaker: "B", start: 2, end: 3)],
            mode: .call(appBundleID: "us.zoom.xos")
        )
        #expect(result.map(\.speaker) == [Transcript.youSpeaker, "S1"])
        #expect(result.map(\.id) == [0, 1])
    }

    private func attribute(mic: [Segment], system: [Segment]) -> [Segment] {
        SpeakerAttribution.attribute(
            mic: mic, system: system, micTurns: [], systemTurns: [SpeakerTurn(speaker: "a", start: 0, end: 100)],
            mode: .call(appBundleID: "x")
        )
    }

    @Test func echoedSentenceOnTheMicIsDropped() {
        let system = segment(.system, 0, 3, "We will send the offer tomorrow.")
        let echo = Segment(id: 0, track: .mic, speaker: "", start: 0.2, end: 3.2, text: "we will send the offer tomorrow", words: words([
            ("we", 0.2, 0.5), ("will", 0.7, 1.0), ("send", 1.2, 1.5), ("the", 1.7, 2.0), ("offer", 2.2, 2.5), ("tomorrow", 2.7, 3.2),
        ]))
        let result = attribute(mic: [echo], system: [system])
        #expect(result.count == 1)
        #expect(result.map(\.speaker) == ["S1"])
    }

    private func echoPair(micLag: TimeInterval) -> (mic: Segment, system: Segment) {
        let system = Segment(id: 0, track: .system, speaker: "", start: 1, end: 3, text: "we will send the offer", words: words([
            ("we", 1.0, 1.3), ("will", 1.5, 1.8), ("send", 2.0, 2.3), ("the", 2.5, 2.8), ("offer", 3.0, 3.3),
        ]))
        let mic = Segment(id: 0, track: .mic, speaker: "", start: 1 + micLag, end: 3 + micLag, text: "we will send the offer", words: words([
            ("we", 1.0 + micLag, 1.3 + micLag), ("will", 1.5 + micLag, 1.8 + micLag), ("send", 2.0 + micLag, 2.3 + micLag),
            ("the", 2.5 + micLag, 2.8 + micLag), ("offer", 3.0 + micLag, 3.3 + micLag),
        ]))
        return (mic, system)
    }

    @Test func echoLaggingTheCallTrackByAThirdOfASecondIsDropped() {
        let pair = echoPair(micLag: 0.3)
        let result = attribute(mic: [pair.mic], system: [pair.system])
        #expect(result.map(\.speaker) == ["S1"])
    }

    @Test func micCopyLeadingTheCallTrackIsKept() {
        let pair = echoPair(micLag: -0.3)
        let result = attribute(mic: [pair.mic], system: [pair.system])
        #expect(result.contains { $0.speaker == Transcript.youSpeaker && $0.text == "we will send the offer" })
        #expect(result.count == 2)
    }

    @Test func micCopyLeadingByLessThanTheToleranceIsStillEcho() {
        let pair = echoPair(micLag: -0.1)
        let result = attribute(mic: [pair.mic], system: [pair.system])
        #expect(result.map(\.speaker) == ["S1"])
    }

    @Test func shortMatchingRepliesAreKept() {
        let system = segment(.system, 5, 6, "Okay, thanks")
        let reply = segment(.mic, 5.1, 6.1, "okay thanks")
        let result = attribute(mic: [reply], system: [system])
        #expect(result.count == 2)
        #expect(result.contains { $0.speaker == Transcript.youSpeaker && $0.text == "okay thanks" })
    }

    @Test func matchingRunMoreThanHalfASecondApartIsKept() {
        let system = segment(.system, 0, 3, "we will send the offer tomorrow")
        let later = segment(.mic, 2, 5, "we will send the offer tomorrow")
        let result = attribute(mic: [later], system: [system])
        #expect(result.contains { $0.speaker == Transcript.youSpeaker && $0.text == "we will send the offer tomorrow" })
    }

    @Test func onlyTheEchoedWordsAreRemovedFromAMixedSegment() {
        let system = segment(.system, 0, 3, "send the offer tomorrow")
        let mixed = Segment(id: 0, track: .mic, speaker: "", start: -1, end: 3, text: "yes send the offer tomorrow", words: words([
            ("yes", -1, -0.5), ("send", 0.1, 0.6), ("the", 0.8, 1.4), ("offer", 1.6, 2.1), ("tomorrow", 2.3, 3),
        ]))
        let result = attribute(mic: [mixed], system: [system])
        let mine = result.filter { $0.speaker == Transcript.youSpeaker }
        #expect(mine.map(\.text) == ["yes"])
        #expect(result.count == 2)
    }

    @Test func micOnlyNeverYou() {
        let result = SpeakerAttribution.attribute(
            mic: [segment(.mic, 0, 2, "hello there", id: 0), segment(.mic, 3, 5, "good morning", id: 1)],
            system: [],
            micTurns: [SpeakerTurn(speaker: "p", start: 0, end: 2), SpeakerTurn(speaker: "q", start: 3, end: 5)],
            systemTurns: [],
            mode: .micOnly
        )
        #expect(result.map(\.speaker) == ["S1", "S2"])
        #expect(!result.contains { $0.speaker == Transcript.youSpeaker })
    }

    @Test func systemSplitAtTurnChange() {
        let source = Segment(id: 0, track: .system, speaker: "", start: 0, end: 3, text: "one two three four", words: words([
            ("one", 0, 0.7), ("two", 0.75, 1.4), ("three", 1.5, 2.2), ("four", 2.3, 3),
        ]))
        let result = SpeakerAttribution.attribute(
            mic: [], system: [source], micTurns: [],
            systemTurns: [SpeakerTurn(speaker: "a", start: 0, end: 1.5), SpeakerTurn(speaker: "b", start: 1.5, end: 3)],
            mode: .call(appBundleID: "us.zoom.xos")
        )
        #expect(result.count == 2)
        #expect(result.map(\.speaker) == ["S1", "S2"])
        #expect(result.map(\.text) == ["one two", "three four"])
        #expect(result.map(\.id) == [0, 1])
        #expect(result[0].start == 0 && result[0].end == 1.4)
        #expect(result[1].start == 1.5 && result[1].end == 3)
        #expect(result[1].words.count == 2)
    }

    @Test func labelsFollowFirstAppearanceAndOutputIsSorted() {
        let result = SpeakerAttribution.attribute(
            mic: [segment(.mic, 5, 6, "later")],
            system: [segment(.system, 2, 3, "early one"), segment(.system, 8, 9, "late one")],
            micTurns: [],
            systemTurns: [SpeakerTurn(speaker: "z", start: 8, end: 9), SpeakerTurn(speaker: "k", start: 2, end: 3)],
            mode: .call(appBundleID: "x")
        )
        #expect(result.map(\.start) == [2, 5, 8])
        #expect(result.map(\.speaker) == ["S1", Transcript.youSpeaker, "S2"])
        #expect(result.map(\.id) == [0, 1, 2])
    }

    @Test func wordWithoutOverlapUsesNearestTurn() {
        let source = Segment(id: 0, track: .system, speaker: "", start: 0, end: 4, text: "a b", words: words([("a", 0, 1), ("b", 2.6, 2.8)]))
        let result = SpeakerAttribution.attribute(
            mic: [], system: [source], micTurns: [],
            systemTurns: [SpeakerTurn(speaker: "a", start: 0, end: 1), SpeakerTurn(speaker: "b", start: 3, end: 4)],
            mode: .call(appBundleID: "x")
        )
        #expect(result.map(\.speaker) == ["S1", "S2"])
    }

    @Test func happyPathReachesReady() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        await h.pipeline.process(h.id)
        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.summaryEngine == .macbook)
        #expect(meeting.engineNotice == nil)
        #expect(meeting.metrics.transcribeSeconds != nil)
        #expect(meeting.metrics.diarizeSeconds != nil)
        #expect(meeting.metrics.cleanSeconds != nil)
        #expect(meeting.metrics.summarizeSeconds != nil)
        let transcript = try #require(try h.store.loadTranscript(h.id))
        #expect(transcript.segments.map(\.speaker) == [Transcript.youSpeaker, "S1"])
        #expect(try h.store.loadClean(h.id) != nil)
        #expect(try h.store.loadSummary(h.id) != nil)
        #expect(h.transcriber.calls.get() == [.mic, .system])
        #expect(h.diarizer.audio.get() == [h.store.audioURL(h.id, track: .system)])
        #expect(h.changes.get() == [.transcribing, .diarizing, .cleaning, .summarizing, .ready])
    }

    @Test func diarizerFailureDegradesToOneFarSideSpeaker() async throws {
        let h = try await Harness(diarizerFailure: DiarizerFailure())
        defer { h.cleanUp() }
        await h.pipeline.process(h.id)
        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.engineNotice == "Couldn't tell the other speakers apart; the call side is one speaker.")
        let transcript = try #require(try h.store.loadTranscript(h.id))
        #expect(transcript.segments.map(\.speaker) == [Transcript.youSpeaker, "S1"])
        #expect(transcript.segments.map(\.text) == ["Hello there", "Good morning"])
        #expect(try h.store.loadSummary(h.id) != nil)
    }

    @Test func diarizerFailureNoticeSurvivesAWaitingSummary() async throws {
        let h = try await Harness(diarizerFailure: DiarizerFailure())
        defer { h.cleanUp() }
        h.probe.environment.set(.make(memoryPressure: .warning))
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .waiting(.memoryPressure))
        h.probe.environment.set(.make())
        await h.pipeline.resumeWaiting()
        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.engineNotice == "Couldn't tell the other speakers apart; the call side is one speaker.")
    }

    @Test func jobsRunAtBackgroundPriority() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        await Task(priority: .userInitiated) { await h.pipeline.process(h.id) }.value
        #expect(!h.transcriber.priorities.get().isEmpty)
        #expect(h.transcriber.priorities.get().allSatisfy { $0 == .background })
    }

    @Test func jobSubmittedWhileRecordingWaitsUntilResumed() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        h.recording.set(true)
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .waiting(.recording))
        #expect(h.transcriber.calls.get().isEmpty)
        #expect(h.diarizer.audio.get().isEmpty)

        await h.pipeline.resumeWaiting()
        #expect(try h.meetingNow().status == .waiting(.recording))
        #expect(h.transcriber.calls.get().isEmpty)
        #expect(h.changes.get() == [.waiting(.recording)])

        h.recording.set(false)
        await h.pipeline.resumeWaiting()
        #expect(try h.meetingNow().status == .ready)
        #expect(h.transcriber.calls.get() == [.mic, .system])
    }

    @Test func recordingThatStartsDuringTranscriptionHoldsTheJobBeforeDiarization() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        let recording = h.recording
        h.transcriber.afterTranscribe.set { track in
            if track == .system { recording.set(true) }
        }
        let tracksFile = h.store.directory(h.id).appendingPathComponent("tracks.json")

        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .waiting(.recording))
        #expect(h.transcriber.calls.get() == [.mic, .system])
        #expect(h.diarizer.audio.get().isEmpty)
        #expect(FileManager.default.fileExists(atPath: tracksFile.path))
        #expect(try h.store.loadTranscript(h.id) == nil)

        await h.pipeline.resumeWaiting()
        #expect(try h.meetingNow().status == .waiting(.recording))
        #expect(h.diarizer.audio.get().isEmpty)

        h.transcriber.afterTranscribe.set(nil)
        recording.set(false)
        await h.pipeline.resumeWaiting()
        #expect(try h.meetingNow().status == .ready)
        #expect(h.transcriber.calls.get() == [.mic, .system])
        #expect(h.diarizer.audio.get().count == 1)
        #expect(!FileManager.default.fileExists(atPath: tracksFile.path))
        let transcript = try #require(try h.store.loadTranscript(h.id))
        #expect(transcript.segments.map(\.text) == ["Hello there", "Good morning"])
        #expect(try h.meetingNow().metrics.transcribeSeconds != nil)
    }

    @Test func recordingThatStartsDuringMicTranscriptionHoldsTheJobBeforeTheSystemTrack() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        let recording = h.recording
        h.transcriber.afterTranscribe.set { track in
            if track == .mic { recording.set(true) }
        }

        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .waiting(.recording))
        #expect(h.transcriber.calls.get() == [.mic])
        #expect(h.diarizer.audio.get().isEmpty)
        let saved = try #require(try h.store.loadTrackResults(h.id))
        #expect(saved.mic?.map(\.text) == ["Hello there"])
        #expect(saved.system == nil)

        await h.pipeline.resumeWaiting()
        #expect(h.transcriber.calls.get() == [.mic])

        h.transcriber.afterTranscribe.set(nil)
        recording.set(false)
        await h.pipeline.resumeWaiting()
        #expect(try h.meetingNow().status == .ready)
        #expect(h.transcriber.calls.get() == [.mic, .system])
        #expect(try #require(try h.store.loadTranscript(h.id)).segments.map(\.text) == ["Hello there", "Good morning"])
        #expect(!FileManager.default.fileExists(atPath: h.store.directory(h.id).appendingPathComponent("tracks.json").path))
    }

    @Test func recordingThatStartsDuringMacbookCleanupHoldsTheJobBeforeTheSummary() async throws {
        let h = try await Harness(useLLMCleanup: true)
        defer { h.cleanUp() }
        let recording = h.recording
        h.afterClean.set { recording.set(true) }

        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .waiting(.recording))
        #expect(h.summarizer.engines.get().isEmpty)
        #expect(try h.store.loadClean(h.id) != nil)

        h.afterClean.set(nil)
        recording.set(false)
        await h.pipeline.resumeWaiting()
        #expect(try h.meetingNow().status == .ready)
        #expect(h.summarizer.engines.get() == [.macbook])
        #expect(h.decisions.get().count == 1)
    }

    @Test func aLeftoverTracksFileIsRemovedOnceTheTranscriptExists() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .ready)
        let tracksFile = h.store.directory(h.id).appendingPathComponent("tracks.json")

        try Data("{}".utf8).write(to: tracksFile)
        await h.pipeline.regenerate(h.id, engine: .macbook)
        #expect(!FileManager.default.fileExists(atPath: tracksFile.path))

        var held = try h.meetingNow()
        held.status = .waiting(.recording)
        try h.store.save(held)
        try Data("{}".utf8).write(to: tracksFile)
        await h.pipeline.resumeWaiting()
        #expect(try h.meetingNow().status == .ready)
        #expect(!FileManager.default.fileExists(atPath: tracksFile.path))
    }

    @Test func resumeSubmitsHeldMeetingsOldestFirst() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        for (id, offset) in [("c-newer", 1000.0), ("a-older", -1000.0)] {
            var meeting = Harness.meeting(id, mode: .micOnly, status: .waiting(.recording))
            meeting.startedAt = meeting.startedAt.addingTimeInterval(offset)
            try h.store.create(meeting)
        }
        var held = try h.meetingNow()
        held.status = .waiting(.recording)
        try h.store.save(held)

        await h.pipeline.resumeWaiting()
        #expect(h.summarizer.meetings.get() == ["a-older", "m1", "c-newer"])
        #expect(try h.store.list().allSatisfy { $0.status == .ready })
    }

    @Test func macbookSummaryWaitsForTheRecordingButStudioAndClaudeDoNot() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        let transcript = Transcript(segments: [Segment(id: 0, track: .mic, speaker: Transcript.youSpeaker, start: 0, end: 1, text: "Hello", words: [])], language: "en")
        try h.store.saveTranscript(transcript, for: h.id, speakerNames: [:])
        h.recording.set(true)

        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .waiting(.recording))
        #expect(h.summarizer.engines.get().isEmpty)

        var settings = h.settings.get()
        settings.defaultEngine = .studio
        h.settings.set(settings)
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .ready)
        #expect(h.summarizer.engines.get() == [.studio])

        await h.pipeline.regenerate(h.id, engine: .claude)
        #expect(h.summarizer.engines.get() == [.studio, .claude])
        #expect(try h.meetingNow().summaryEngine == .claude)
    }

    @Test func regenerateKeepsThePreviousSummaryAndRestoreSwapsBack() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        await h.pipeline.process(h.id)
        #expect(!h.store.hasPreviousSummary(h.id))
        #expect(try h.store.loadSummary(h.id)?.engine == .macbook)

        await h.pipeline.regenerate(h.id, engine: .claude)
        #expect(try h.store.loadSummary(h.id)?.engine == .claude)
        #expect(h.store.hasPreviousSummary(h.id))
        #expect(try h.store.loadPreviousSummary(h.id)?.engine == .macbook)

        let restored = try h.store.restorePreviousSummary(h.id)
        #expect(restored.engine == .macbook)
        #expect(try h.store.loadSummary(h.id)?.engine == .macbook)
        #expect(try h.store.loadPreviousSummary(h.id)?.engine == .claude)

        await h.pipeline.regenerate(h.id, engine: .studio)
        #expect(try h.store.loadSummary(h.id)?.engine == .studio)
        #expect(try h.store.loadPreviousSummary(h.id)?.engine == .macbook)
    }

    @Test func editedSummaryStaysThePreviousAcrossRegenerations() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        await h.pipeline.process(h.id)
        try h.store.saveEditedSummary(try #require(try h.store.loadSummary(h.id)), for: h.id)

        await h.pipeline.regenerate(h.id, engine: .claude)
        #expect(try h.store.loadSummary(h.id)?.engine == .claude)
        #expect(try h.store.loadPreviousSummary(h.id)?.edited == true)

        await h.pipeline.regenerate(h.id, engine: .studio)
        #expect(try h.store.loadSummary(h.id)?.engine == .studio)
        let previous = try #require(try h.store.loadPreviousSummary(h.id))
        #expect(previous.edited)
        #expect(previous.engine == .macbook)
    }

    @Test func meetingLanguageFollowsTheSummary() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        var meeting = try h.meetingNow()
        meeting.language = nil
        try h.store.save(meeting)
        h.summarizer.language.set("nl")
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().language == "nl")
        h.summarizer.language.set("fr")
        await h.pipeline.regenerate(h.id, engine: .macbook)
        #expect(try h.meetingNow().language == "fr")
    }

    @Test func micOnlyTranscribesAndDiarizesMicOnly() async throws {
        let h = try await Harness(mode: .micOnly)
        defer { h.cleanUp() }
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .ready)
        #expect(h.transcriber.calls.get() == [.mic])
        #expect(h.diarizer.audio.get() == [h.store.audioURL(h.id, track: .mic)])
        let transcript = try #require(try h.store.loadTranscript(h.id))
        #expect(transcript.segments.map(\.speaker) == ["S1"])
    }

    @Test func waitsWhenStudioUnreachableUnderPressure() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        var settings = h.settings.get()
        settings.defaultEngine = .studio
        h.settings.set(settings)
        h.probe.environment.set(.make(studioReachable: false, memoryPressure: .warning))
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .waiting(.studioUnreachable))
        #expect(h.summarizer.engines.get().isEmpty)
        #expect(try h.store.loadClean(h.id) != nil)
    }

    @Test func resumeWaitingRunsWhenReachable() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        var settings = h.settings.get()
        settings.defaultEngine = .studio
        h.settings.set(settings)
        h.probe.environment.set(.make(studioReachable: false, memoryPressure: .warning))
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .waiting(.studioUnreachable))

        h.probe.environment.set(.make(studioReachable: true, memoryPressure: .warning))
        await h.pipeline.resumeWaiting()
        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.summaryEngine == .studio)
        #expect(meeting.engineNotice == nil)
    }

    @Test func forcedMacbookRunsUnderPressure() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        var settings = h.settings.get()
        settings.defaultEngine = .studio
        h.settings.set(settings)
        h.probe.environment.set(.make(studioReachable: false, memoryPressure: .warning))
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .waiting(.studioUnreachable))

        await h.pipeline.regenerate(h.id, engine: .macbook)
        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.summaryEngine == .macbook)
        #expect(h.summarizer.engines.get() == [.macbook])
    }

    @Test func regenerateKeepsCleanTranscriptAndRerunsSummary() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        await h.pipeline.process(h.id)
        let decisionsBefore = h.decisions.get().count
        await h.pipeline.regenerate(h.id, engine: .claude)
        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.summaryEngine == .claude)
        #expect(h.transcriber.calls.get() == [.mic, .system])
        #expect(h.decisions.get().count == decisionsBefore)
        #expect(h.summarizer.engines.get() == [.macbook, .claude])
    }

    @Test func summarizerErrorMarksFailedNotStuck() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        h.summarizer.failure.set(SummarizerFailure())
        await h.pipeline.process(h.id)
        guard case .failed(let message) = try h.meetingNow().status else {
            Issue.record("expected failed, got \(try h.meetingNow().status)")
            return
        }
        #expect(message.contains("SummarizerFailure"))
        #expect(h.changes.get().last.map { if case .failed = $0 { true } else { false } } == true)
    }

    @Test func resumeSkipsCompletedTranscription() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        h.summarizer.failure.set(SummarizerFailure())
        await h.pipeline.process(h.id)
        #expect(h.transcriber.calls.get() == [.mic, .system])

        h.summarizer.failure.set(nil)
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .ready)
        #expect(h.transcriber.calls.get() == [.mic, .system])
        #expect(h.diarizer.audio.get().count == 1)
        #expect(h.decisions.get().count == 1)
        #expect(h.summarizer.engines.get() == [.macbook, .macbook])
    }

    @Test func readyAndRecordingMeetingsAreNotProcessed() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        await h.pipeline.process(h.id)
        let changes = h.changes.get().count
        await h.pipeline.process(h.id)
        #expect(h.changes.get().count == changes)

        var recording = try h.meetingNow()
        recording.status = .recording
        try h.store.save(recording)
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .recording)
        #expect(h.summarizer.engines.get().count == 1)
    }

    @Test func finishedRecordingIsProcessedToReady() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        for track in [Track.mic, .system] {
            try Data("caf".utf8).write(to: h.store.audioURL(h.id, track: track))
        }
        var recording = try h.meetingNow()
        recording.status = .recording
        try h.store.save(recording)
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .recording)

        let endedAt = Date(timeIntervalSince1970: 1_792_000_600)
        try h.store.save(MeetingActions.finishRecording(try h.meetingNow(), endedAt: endedAt))
        #expect(try h.meetingNow().status == .transcribing)
        await h.pipeline.process(h.id)

        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.endedAt == endedAt)
        #expect(h.changes.get() == [.transcribing, .diarizing, .cleaning, .summarizing, .ready])
    }

    @Test func finishRecordingOnlyMovesARecordingMeeting() throws {
        let endedAt = Date(timeIntervalSince1970: 5)
        var m = Harness.meeting("m", mode: .micOnly, status: .recording)
        #expect(MeetingActions.finishRecording(m, endedAt: endedAt).status == .transcribing)
        #expect(MeetingActions.finishRecording(m, endedAt: endedAt).endedAt == endedAt)
        m.status = .failed("x")
        #expect(MeetingActions.finishRecording(m, endedAt: endedAt).status == .failed("x"))
    }

    @Test func fallbackNoticeSet() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        var settings = h.settings.get()
        settings.defaultEngine = .studio
        h.settings.set(settings)
        h.probe.environment.set(.make(studioReachable: false, memoryPressure: .normal))
        await h.pipeline.process(h.id)
        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.summaryEngine == .macbook)
        #expect(meeting.engineNotice == "Network Mac unreachable — summarized on This Mac")
    }

    @Test func fallbackNoticeSaysWhenTheNetworkMacIsNotSetUp() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        var settings = h.settings.get()
        settings.defaultEngine = .studio
        h.settings.set(settings)
        h.probe.environment.set(EngineEnvironment(studioConfigured: false, studioReachable: false, memoryPressure: .normal, claudeKeyPresent: true))
        await h.pipeline.process(h.id)
        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.summaryEngine == .macbook)
        #expect(meeting.engineNotice == "Network Mac not set up — summarized on This Mac")
    }

    @Test func regenerateWaitKeepsTheSummaryWhenTheNetworkMacIsNotSetUp() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        await h.pipeline.process(h.id)
        h.probe.environment.set(EngineEnvironment(studioConfigured: false, studioReachable: false, memoryPressure: .normal, claudeKeyPresent: true))
        await h.pipeline.regenerate(h.id, engine: .studio)
        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.engineNotice == "Network Mac address not set — kept the existing summary")
    }

    @Test func llmCleanupSkippedWhenGateWaits() async throws {
        let h = try await Harness(useLLMCleanup: true)
        defer { h.cleanUp() }
        h.probe.environment.set(.make(memoryPressure: .warning))
        await h.pipeline.process(h.id)
        #expect(h.decisions.get().isEmpty)
        #expect(h.llmCleanersBuilt.get() == 0)
        #expect(try h.store.loadClean(h.id) == nil)
        #expect(try h.meetingNow().status == .waiting(.memoryPressure))
    }

    @Test func resumeAfterWaitRunsLLMCleanup() async throws {
        let h = try await Harness(useLLMCleanup: true)
        defer { h.cleanUp() }
        h.probe.environment.set(.make(memoryPressure: .warning))
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .waiting(.memoryPressure))

        h.probe.environment.set(.make(memoryPressure: .normal))
        await h.pipeline.resumeWaiting()
        #expect(h.decisions.get() == [.run(.macbook, fallbackFrom: nil)])
        #expect(h.llmCleanersBuilt.get() == 1)
        #expect(try h.store.loadClean(h.id) != nil)
        #expect(try h.meetingNow().status == .ready)
    }

    @Test func ruleCleaningRunsImmediatelyWhenLLMCleanupOffAndGateWaits() async throws {
        let h = try await Harness(useLLMCleanup: false)
        defer { h.cleanUp() }
        h.probe.environment.set(.make(memoryPressure: .warning))
        await h.pipeline.process(h.id)
        #expect(h.decisions.get() == [.wait(.memoryPressure)])
        #expect(try h.store.loadClean(h.id) != nil)
        #expect(try h.meetingNow().status == .waiting(.memoryPressure))
    }

    @Test func processRetriesFailedMeeting() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        h.summarizer.failure.set(SummarizerFailure())
        await h.pipeline.process(h.id)
        guard case .failed = try h.meetingNow().status else {
            Issue.record("expected failed")
            return
        }
        h.summarizer.failure.set(nil)
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .ready)
        #expect(h.transcriber.calls.get() == [.mic, .system])
        #expect(h.summarizer.engines.get().count == 2)
    }

    @Test func llmCleanupBuiltWhenGateRuns() async throws {
        let h = try await Harness(useLLMCleanup: true)
        defer { h.cleanUp() }
        await h.pipeline.process(h.id)
        #expect(h.decisions.get() == [.run(.macbook, fallbackFrom: nil)])
        #expect(h.llmCleanersBuilt.get() == 1)
    }

    @Test func noiseTurnWithoutWordsLeavesNoLabelGap() {
        let source = Segment(id: 0, track: .system, speaker: "", start: 1, end: 3, text: "x y z", words: words([
            ("x", 1, 1.4), ("y", 1.5, 1.9), ("z", 2.1, 3),
        ]))
        let result = SpeakerAttribution.attribute(
            mic: [], system: [source], micTurns: [],
            systemTurns: [
                SpeakerTurn(speaker: "noise", start: 0, end: 0.5),
                SpeakerTurn(speaker: "a", start: 1, end: 2),
                SpeakerTurn(speaker: "b", start: 2, end: 3),
            ],
            mode: .call(appBundleID: "x")
        )
        #expect(result.map(\.speaker) == ["S1", "S2"])
        #expect(result.map(\.text) == ["x y", "z"])
    }

    @Test func requestedEngineDecodesWhenAbsent() throws {
        var meeting = Harness.meeting("m1", mode: .micOnly)
        meeting.requestedEngine = .claude
        let encoder = JSONEncoder()
        let data = try encoder.encode(meeting)
        #expect(try JSONDecoder().decode(Meeting.self, from: data).requestedEngine == .claude)

        meeting.requestedEngine = nil
        var object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(meeting)) as? [String: Any])
        object.removeValue(forKey: "requestedEngine")
        let stripped = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(Meeting.self, from: stripped).requestedEngine == nil)
    }

    @Test func regenerateWaitKeepsReadySummary() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        await h.pipeline.process(h.id)
        let summaryBefore = try #require(try h.store.loadSummary(h.id))

        h.probe.environment.set(.make(studioReachable: false))
        await h.pipeline.regenerate(h.id, engine: .studio)
        var meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.summaryEngine == .macbook)
        #expect(meeting.engineNotice == "Network Mac unreachable — kept the existing summary")
        #expect(meeting.requestedEngine == nil)
        #expect(try h.store.loadSummary(h.id) == summaryBefore)
        #expect(h.summarizer.engines.get() == [.macbook])

        h.probe.environment.set(.make(memoryPressure: .warning, claudeKeyPresent: false))
        await h.pipeline.regenerate(h.id, engine: .claude)
        meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.engineNotice == "No Claude API key — kept the existing summary")
    }

    @Test func requestedEngineSurvivesResume() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        h.probe.environment.set(.make(studioReachable: false, memoryPressure: .warning))
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .waiting(.memoryPressure))

        await h.pipeline.regenerate(h.id, engine: .studio)
        var meeting = try h.meetingNow()
        #expect(meeting.status == .waiting(.studioUnreachable))
        #expect(meeting.requestedEngine == .studio)

        h.probe.environment.set(.make(studioReachable: true, memoryPressure: .normal))
        await h.pipeline.resumeWaiting()
        meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.summaryEngine == .studio)
        #expect(meeting.requestedEngine == nil)
        #expect(h.summarizer.engines.get() == [.studio])
    }

    @Test(.timeLimit(.minutes(1))) func requestWhileInFlightRunsAfterwardsAndLastWins() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        h.summarizer.holdFirstCall.set(true)
        let pipeline = h.pipeline
        let id = h.id
        let first = Task { await pipeline.process(id) }
        try await h.summarizer.entered.wait()

        let second = Task { await pipeline.regenerate(id, engine: .studio) }
        await waitForQueuedJob(pipeline, id, callers: 1, engine: .studio)
        let third = Task { await pipeline.regenerate(id, engine: .claude) }
        await waitForQueuedJob(pipeline, id, callers: 2, engine: .claude)
        #expect(h.summarizer.engines.get() == [.macbook])

        h.summarizer.released.reach()
        await first.value
        await second.value
        await third.value
        #expect(h.summarizer.engines.get() == [.macbook, .claude])
        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.summaryEngine == .claude)
    }

    @Test func heavyWorkIsSerialisedAcrossMeetings() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        h.transcriber.delay = 15_000_000
        try h.store.create(Harness.meeting("m2", mode: .call(appBundleID: "x"), status: .waiting(.memoryPressure)))
        try h.store.create(Harness.meeting("m3", mode: .call(appBundleID: "x")))
        let pipeline = h.pipeline
        let id = h.id
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await pipeline.process(id) }
            group.addTask { await pipeline.resumeWaiting() }
            group.addTask { await pipeline.process(MeetingID(rawValue: "m3")) }
        }
        #expect(h.transcriber.maxRunning.get() == 1)
        #expect(h.transcriber.calls.get().count == 6)
        for name in ["m1", "m2", "m3"] {
            #expect(try h.store.load(MeetingID(rawValue: name)).status == .ready)
        }
    }

    @Test func perStageMetricsUseTheClock() async throws {
        let times = Locked([0.0, 1, 10, 12, 20, 23, 30, 34])
        let index = Locked(0)
        let h = try await Harness(clock: {
            let i = index.get()
            index.set(i + 1)
            return Date(timeIntervalSince1970: times.get()[min(i, 7)])
        })
        defer { h.cleanUp() }
        await h.pipeline.process(h.id)
        let metrics = try h.meetingNow().metrics
        #expect(metrics.transcribeSeconds == 1)
        #expect(metrics.diarizeSeconds == 2)
        #expect(metrics.cleanSeconds == 3)
        #expect(metrics.summarizeSeconds == 4)
    }

    @Test func staleEngineNoticeClearedAfterNormalRun() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        var meeting = try h.meetingNow()
        meeting.engineNotice = "old notice"
        try h.store.save(meeting)
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().engineNotice == nil)
    }

    @Test func concurrentTitleEditSurvivesStatusUpdates() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        let store = h.store
        let id = h.id
        h.summarizer.onSummarize.set {
            if var edited = try? store.load(id) {
                edited.title = "Renamed while summarizing"
                try? store.save(edited)
            }
        }
        await h.pipeline.process(h.id)
        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.title == "Renamed while summarizing")
    }

    @Test(.timeLimit(.minutes(1))) func callerCancellationDoesNotFailJob() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        h.summarizer.holdFirstCall.set(true)
        let pipeline = h.pipeline
        let id = h.id
        let task = Task { await pipeline.process(id) }
        try await h.summarizer.entered.wait()
        task.cancel()
        await task.value
        #expect(try h.meetingNow().status == .summarizing)

        h.summarizer.released.reach()
        try await h.ready.wait()
        #expect(try h.meetingNow().status == .ready)
        #expect(h.summarizer.engines.get() == [.macbook])
    }

    @Test func cancellationReachingTheJobMarksFailed() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        h.summarizer.failure.set(CancellationError())
        await h.pipeline.process(h.id)
        guard case .failed = try h.meetingNow().status else {
            Issue.record("expected failed, got \(try h.meetingNow().status)")
            return
        }
    }

    @Test(.timeLimit(.minutes(1))) func queuedRegenerateSurvivesProcess() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        var waiting = try h.meetingNow()
        waiting.status = .waiting(.memoryPressure)
        try h.store.save(waiting)
        try h.store.create(Harness.meeting("m2", mode: .call(appBundleID: "x")))
        h.summarizer.holdFirstCall.set(true)
        let pipeline = h.pipeline
        let id = h.id

        let holder = Task { await pipeline.process(MeetingID(rawValue: "m2")) }
        try await h.summarizer.entered.wait()
        let regenerate = Task { await pipeline.regenerate(id, engine: .claude) }
        await waitForQueuedJob(pipeline, id, callers: 1, engine: .claude)
        let plain = Task { await pipeline.process(id) }
        await waitForQueuedJob(pipeline, id, callers: 2, engine: .claude)

        h.summarizer.released.reach()
        await holder.value
        await regenerate.value
        await plain.value
        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.summaryEngine == .claude)
        #expect(meeting.requestedEngine == nil)
        #expect(h.summarizer.engines.get() == [.macbook, .claude])
    }

    @Test func keptSummaryPathEndsReadyEvenAfterMissingTranscriptFiles() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        await h.pipeline.process(h.id)
        let summaryBefore = try #require(try h.store.loadSummary(h.id))
        let directory = h.store.directory(h.id)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("transcript.json"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("transcript.clean.json"))
        var failed = try h.meetingNow()
        failed.status = .failed("earlier problem")
        try h.store.save(failed)

        h.probe.environment.set(.make(studioReachable: false))
        await h.pipeline.regenerate(h.id, engine: .studio)
        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.engineNotice == "Network Mac unreachable — kept the existing summary")
        #expect(try h.store.loadSummary(h.id) == summaryBefore)
        #expect(h.transcriber.calls.get().count == 4)
    }

    @Test func regenerateFailureKeepsReadySummary() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        await h.pipeline.process(h.id)
        let summaryBefore = try #require(try h.store.loadSummary(h.id))

        h.summarizer.failure.set(SummarizerFailure())
        await h.pipeline.regenerate(h.id, engine: .claude)
        let meeting = try h.meetingNow()
        #expect(meeting.status == .ready)
        #expect(meeting.summaryEngine == .macbook)
        #expect(meeting.engineNotice == "Claude failed: SummarizerFailure() — kept the existing summary")
        #expect(meeting.requestedEngine == nil)
        #expect(try h.store.loadSummary(h.id) == summaryBefore)
    }

    @Test func failedSaveStillNotifiesWithFailedMeeting() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        let store = h.store
        let id = h.id
        h.summarizer.failure.set(SummarizerFailure())
        h.summarizer.onSummarize.set {
            let meetingFile = store.directory(id).appendingPathComponent("meeting.json")
            try? FileManager.default.removeItem(at: meetingFile)
            try? FileManager.default.createDirectory(at: meetingFile, withIntermediateDirectories: false)
        }
        await h.pipeline.process(h.id)
        let last = try #require(h.changes.get().last)
        guard case .failed = last else {
            Issue.record("expected failed notification, got \(last)")
            return
        }
    }

    @Test func aMeetingDeletedMidRunStaysDeletedAndSilent() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        let store = h.store
        let id = h.id
        h.summarizer.onSummarize.set {
            try? FileManager.default.removeItem(at: store.directory(id))
        }
        await h.pipeline.process(h.id)
        #expect(!FileManager.default.fileExists(atPath: store.directory(id).path))
        #expect(!h.changes.get().contains { if case .failed = $0 { true } else { false } })
        #expect(!h.changes.get().contains(.ready))
        #expect(!(await h.pipeline.hasJob(for: id)))
    }

    @Test func aMeetingDeletedBeforeItsQueuedJobRunsIsNotRecreated() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        h.recording.set(true)
        await h.pipeline.process(h.id)
        #expect(try h.meetingNow().status == .waiting(.recording))
        try h.store.delete(h.id)
        h.recording.set(false)
        await h.pipeline.resumeWaiting()
        await h.pipeline.process(h.id)
        #expect(!FileManager.default.fileExists(atPath: h.store.directory(h.id).path))
        #expect(h.transcriber.calls.get().isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func aMeetingWithAQueuedOrRunningJobReportsIt() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        #expect(!(await h.pipeline.hasJob(for: h.id)))
        h.summarizer.holdFirstCall.set(true)
        let run = Task { await h.pipeline.process(h.id) }
        try await h.summarizer.entered.wait()
        #expect(await h.pipeline.hasJob(for: h.id))
        h.summarizer.released.reach()
        await run.value
        #expect(!(await h.pipeline.hasJob(for: h.id)))
    }

    @Test(.timeLimit(.minutes(1))) func aSecondJobForTheSameMeetingKeepsItReportedUntilItFinishes() async throws {
        let h = try await Harness()
        defer { h.cleanUp() }
        h.summarizer.holdFirstCall.set(true)
        let first = Task { await h.pipeline.process(h.id) }
        try await h.summarizer.entered.wait()
        let secondEntered = Milestone()
        let releaseSecond = Milestone()
        h.summarizer.gate.set(releaseSecond)
        h.summarizer.onSummarize.set {
            secondEntered.reach()
        }
        let second = Task { await h.pipeline.regenerate(h.id, engine: .claude) }
        await waitForQueuedJob(h.pipeline, h.id, callers: 1, engine: .claude)
        #expect(await h.pipeline.hasJob(for: h.id))
        h.summarizer.released.reach()
        try await secondEntered.wait()
        let duringSecond = await h.pipeline.hasJob(for: h.id)
        releaseSecond.reach()
        await first.value
        await second.value
        #expect(h.summarizer.engines.get() == [.macbook, .claude])
        #expect(duringSecond, "hasJob is false while the second job for the meeting is running")
        #expect(!(await h.pipeline.hasJob(for: h.id)))
    }
}
