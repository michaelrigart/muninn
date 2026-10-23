import Foundation

public actor ProcessingPipeline {
    static let studioFallbackNotice = "Network Mac unreachable — summarized on This Mac"
    static let studioNotConfiguredFallbackNotice = "Network Mac not set up — summarized on This Mac"

    static func keptSummaryNotice(_ reason: WaitReason) -> String {
        switch reason {
        case .studioUnreachable: "Network Mac unreachable — kept the existing summary"
        case .studioNotConfigured: "Network Mac address not set — kept the existing summary"
        case .memoryPressure: "Memory pressure too high — kept the existing summary"
        case .claudeKeyMissing: "No Claude API key — kept the existing summary"
        case .recording: "A recording is running — kept the existing summary"
        }
    }

    static let callDiarizationNotice = "Couldn't tell the other speakers apart; the call side is one speaker."
    static let micDiarizationNotice = "Couldn't tell the speakers apart; the conversation is one speaker."

    private static func notice(_ new: String?, keeping existing: String?) -> String? {
        let kept = [callDiarizationNotice, micDiarizationNotice].first { existing?.contains($0) == true }
        let parts = [kept, new].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private enum PipelineError: Error {
        case missingCleanTranscript
    }

    private struct Request {
        var forced: EngineKind?
        var regenerating: Bool
    }

    private final class Job: @unchecked Sendable {
        var request: Request
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
        var finished = false
        var turn: CheckedContinuation<Void, Never>?

        init(_ request: Request) {
            self.request = request
        }
    }

    private let store: MeetingStore
    private let settings: @Sendable () -> Settings
    private let transcriber: Transcribing
    private let diarizer: Diarizing
    private let cleaner: @Sendable (Settings, EngineDecision) -> TranscriptCleaning
    private let summarizer: Summarizing
    private let probe: EnvironmentProbing
    private let isRecording: @Sendable () -> Bool
    private let clock: @Sendable () -> Date
    private var queuedJobs: [MeetingID: Job] = [:]
    private var activeJobs: [MeetingID: Int] = [:]
    private var busy = false
    private var turnOrder: [Job] = []

    public private(set) var onChange: (@Sendable (Meeting) -> Void)?

    public init(
        store: MeetingStore,
        settings: @escaping @Sendable () -> Settings,
        transcriber: Transcribing,
        diarizer: Diarizing,
        cleaner: @escaping @Sendable (Settings, EngineDecision) -> TranscriptCleaning,
        summarizer: Summarizing,
        probe: EnvironmentProbing,
        isRecording: @escaping @Sendable () -> Bool = { false },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.settings = settings
        self.transcriber = transcriber
        self.diarizer = diarizer
        self.cleaner = cleaner
        self.summarizer = summarizer
        self.probe = probe
        self.isRecording = isRecording
        self.clock = clock
    }

    /// True while a job for the meeting is queued or running. A meeting with a job must not be deleted.
    public func hasJob(for id: MeetingID) -> Bool {
        activeJobs[id, default: 0] > 0
    }

    /// How many callers wait on the meeting's queued job and which engine it forces. A test waits on it to know its requests have arrived.
    func queuedJobState(for id: MeetingID) -> (callers: Int, engine: EngineKind?)? {
        queuedJobs[id].map { ($0.waiters.count, $0.request.forced) }
    }

    public func setOnChange(_ handler: (@Sendable (Meeting) -> Void)?) {
        onChange = handler
    }

    public func process(_ id: MeetingID) async {
        await submit(id, Request(forced: nil, regenerating: false))
    }

    public func regenerate(_ id: MeetingID, engine: EngineKind) async {
        if let meeting = try? store.load(id), meeting.status != .recording, ((try? store.loadSummary(id)) ?? nil) == nil {
            _ = try? update(id, notify: false) { $0.requestedEngine = engine }
        }
        await submit(id, Request(forced: engine, regenerating: true))
    }

    /// Resubmits held meetings oldest first. Every job is queued before any is awaited, so the
    /// order of the queue is the order of the meetings.
    public func resumeWaiting() async {
        let waiting = ((try? store.list()) ?? [])
            .filter {
                if case .waiting = $0.status { return true }
                return false
            }
            .sorted { $0.startedAt == $1.startedAt ? $0.id.rawValue < $1.id.rawValue : $0.startedAt < $1.startedAt }
        let jobs = waiting.map { enqueue($0.id, Request(forced: nil, regenerating: false)) }
        for job in jobs {
            await wait(for: job)
        }
    }

    private func submit(_ id: MeetingID, _ request: Request) async {
        await wait(for: enqueue(id, request))
    }

    /// Runs one meeting at a time across the pipeline (FIFO). A request for a meeting that is
    /// already queued replaces the queued one, so the last request wins, except that a plain
    /// request never replaces a queued regeneration. Jobs run in tasks owned by the actor, so
    /// cancelling a caller only abandons that caller's wait.
    private func enqueue(_ id: MeetingID, _ request: Request) -> Job {
        if let queued = queuedJobs[id] {
            if request.regenerating || !queued.request.regenerating {
                queued.request = request
            }
            return queued
        }
        let job = Job(request)
        queuedJobs[id] = job
        activeJobs[id, default: 0] += 1
        turnOrder.append(job)
        Task(priority: .background) { await self.run(id, job) }
        return job
    }

    private func run(_ id: MeetingID, _ job: Job) async {
        await acquireTurn(job)
        queuedJobs[id] = nil
        await execute(id, job.request)
        if let remaining = activeJobs[id], remaining > 1 {
            activeJobs[id] = remaining - 1
        } else {
            activeJobs[id] = nil
        }
        releaseTurn()
        job.finished = true
        let waiters = job.waiters
        job.waiters = [:]
        for waiter in waiters.values {
            waiter.resume()
        }
    }

    private func wait(for job: Job) async {
        let key = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if job.finished || Task.isCancelled {
                    continuation.resume()
                } else {
                    job.waiters[key] = continuation
                }
            }
        } onCancel: {
            Task { await self.abandon(job, key) }
        }
    }

    private func abandon(_ job: Job, _ key: UUID) {
        job.waiters.removeValue(forKey: key)?.resume()
    }

    private func acquireTurn(_ job: Job) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            job.turn = continuation
            grantTurns()
        }
    }

    private func releaseTurn() {
        busy = false
        grantTurns()
    }

    private func grantTurns() {
        while !busy, let next = turnOrder.first, let turn = next.turn {
            busy = true
            turnOrder.removeFirst()
            next.turn = nil
            turn.resume()
        }
    }

    private func execute(_ id: MeetingID, _ request: Request) async {
        guard let current = try? store.load(id) else { return }
        switch current.status {
        case .recording: return
        case .ready where !request.regenerating: return
        default: break
        }

        var metrics = current.metrics
        do {
            try await stages(id, current: current, request: request, metrics: &metrics)
        } catch {
            fail(id, fallback: current, message: Self.message(error), metrics: metrics)
        }
    }

    private func stages(_ id: MeetingID, current: Meeting, request: Request, metrics: inout ProcessingMetrics) async throws {
        let settings = settings()
        let hasSummary = try store.loadSummary(id) != nil
        let forced = request.forced ?? current.requestedEngine
        var meeting = try store.load(id)

        func hold(_ meeting: Meeting) throws {
            if meeting.status != .waiting(.recording) {
                try update(id) {
                    $0.status = .waiting(.recording)
                    $0.metrics = metrics
                }
            }
        }

        let transcript: Transcript
        if let existing = try store.loadTranscript(id) {
            store.deleteTrackResults(id)
            transcript = existing
        } else {
            let tracks: [Track]
            switch meeting.captureMode {
            case .call: tracks = [.mic, .system]
            case .micOnly: tracks = [.mic]
            }
            var results = (try? store.loadTrackResults(id)) ?? TrackResults()
            if results.isEmpty { metrics.transcribeSeconds = nil }
            let earlierSeconds = metrics.transcribeSeconds ?? 0
            var began: Date?

            func recordTranscribeTime() {
                if let began { metrics.transcribeSeconds = earlierSeconds + clock().timeIntervalSince(began) }
            }

            /// Holds the job while a recording runs, first saving the tracks already transcribed so a resume does only the rest.
            func holdForRecording() throws -> Bool {
                guard isRecording() else { return false }
                recordTranscribeTime()
                if !results.isEmpty { try store.saveTrackResults(results, for: id) }
                try hold(meeting)
                return true
            }

            for track in tracks where results[track] == nil {
                if try holdForRecording() { return }
                if began == nil {
                    meeting = try update(id) {
                        $0.status = .transcribing
                        $0.metrics = metrics
                    }
                    began = clock()
                }
                results[track] = try await transcriber.transcribe(audio: store.audioURL(id, track: track), track: track, vocabulary: settings.dictionary)
            }
            if try holdForRecording() { return }
            recordTranscribeTime()

            let mic = results.mic ?? []
            let system = results.system ?? []
            meeting = try update(id) {
                $0.status = .diarizing
                $0.metrics = metrics
            }
            let started = clock()
            var micTurns: [SpeakerTurn] = []
            var systemTurns: [SpeakerTurn] = []
            var degradedNotice: String?
            do {
                switch meeting.captureMode {
                case .call: systemTurns = try await diarizer.diarize(audio: store.audioURL(id, track: .system))
                case .micOnly: micTurns = try await diarizer.diarize(audio: store.audioURL(id, track: .mic))
                }
            } catch where Self.isCancellation(error) {
                throw error
            } catch {
                degradedNotice = meeting.captureMode == .micOnly ? Self.micDiarizationNotice : Self.callDiarizationNotice
            }
            metrics.diarizeSeconds = clock().timeIntervalSince(started)

            let segments = SpeakerAttribution.attribute(
                mic: mic, system: system, micTurns: micTurns, systemTurns: systemTurns, mode: meeting.captureMode
            )
            let attributed = Transcript(segments: segments, language: meeting.language)
            try store.saveTranscript(attributed, for: id, speakerNames: meeting.speakerNames, userName: settings.userName)
            store.deleteTrackResults(id)
            if degradedNotice != nil || Self.notice(nil, keeping: meeting.engineNotice) != nil {
                meeting = try update(id) { $0.engineNotice = degradedNotice }
            }
            transcript = attributed
        }

        func decide() async -> EngineDecision {
            var environment = await probe.environment(settings: settings)
            environment.isRecording = isRecording()
            return EngineSelector.decide(preferred: settings.defaultEngine, forced: forced, environment: environment)
        }

        var decision = await decide()
        var cleanedWithLLM = false
        let clean: CleanTranscript?
        if let existing = try store.loadClean(id) {
            clean = existing
        } else {
            if settings.useLLMCleanup, case .wait = decision {
                clean = nil
            } else {
                meeting = try update(id) {
                    $0.status = .cleaning
                    $0.metrics = metrics
                }
                let started = clock()
                let result = try await cleaner(settings, decision).clean(transcript)
                metrics.cleanSeconds = clock().timeIntervalSince(started)
                try store.saveClean(result, transcript: transcript, for: id, speakerNames: meeting.speakerNames, userName: settings.userName)
                clean = result
                cleanedWithLLM = settings.useLLMCleanup
            }
        }
        // LLM cleanup can take minutes, so what was true when it started may not be true now: a recording may have begun.
        if cleanedWithLLM, case .run = decision {
            decision = await decide()
        }

        switch (decision, clean) {
        case (.wait(let reason), _):
            try update(id) {
                if request.regenerating, hasSummary {
                    $0.status = .ready
                    $0.engineNotice = Self.notice(Self.keptSummaryNotice(reason), keeping: $0.engineNotice)
                } else {
                    $0.status = .waiting(reason)
                }
                $0.metrics = metrics
            }
        case (.run(let engine, let fallbackFrom, let because), let clean?):
            meeting = try update(id) {
                $0.status = .summarizing
                $0.metrics = metrics
            }
            let started = clock()
            let summary: Summary
            do {
                summary = try await summarizer.summarize(meeting: meeting, transcript: transcript, clean: clean, engine: engine)
            } catch where request.regenerating && hasSummary {
                try update(id) {
                    $0.status = .ready
                    $0.engineNotice = Self.notice("\(engine.displayName) failed: \(Self.message(error)) — kept the existing summary", keeping: $0.engineNotice)
                    if $0.requestedEngine == forced { $0.requestedEngine = nil }
                    $0.metrics = metrics
                }
                return
            }
            metrics.summarizeSeconds = clock().timeIntervalSince(started)
            try store.replaceSummary(summary, for: id)
            try update(id) {
                $0.status = .ready
                $0.summaryEngine = engine
                $0.language = summary.language
                $0.engineNotice = Self.notice(fallbackFrom == .studio ? (because == .studioNotConfigured ? Self.studioNotConfiguredFallbackNotice : Self.studioFallbackNotice) : nil, keeping: $0.engineNotice)
                if $0.requestedEngine == forced { $0.requestedEngine = nil }
                $0.metrics = metrics
            }
        case (.run, nil):
            throw PipelineError.missingCleanTranscript
        }
    }

    @discardableResult
    private func update(_ id: MeetingID, notify: Bool = true, _ change: (inout Meeting) -> Void) throws -> Meeting {
        let meeting = try store.update(id, change)
        if notify { onChange?(meeting) }
        return meeting
    }

    /// Records a failure, unless the meeting's folder is gone: a deleted meeting is never written to or announced again.
    private func fail(_ id: MeetingID, fallback: Meeting, message: String, metrics: ProcessingMetrics) {
        guard store.exists(id) else { return }
        let meeting: Meeting
        if let updated = try? store.update(id, { $0.status = .failed(message); $0.metrics = metrics }) {
            meeting = updated
        } else {
            var stored = fallback
            stored.status = .failed(message)
            stored.metrics = metrics
            try? store.save(stored)
            meeting = stored
        }
        guard store.exists(id) else { return }
        onChange?(meeting)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private static func message(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
