import Foundation

public protocol Summarizing: Sendable {
    func summarize(meeting: Meeting, transcript: Transcript, clean: CleanTranscript, engine: EngineKind) async throws -> Summary
}

public struct LLMSummarizer: Summarizing {
    let clientFor: @Sendable (EngineKind) throws -> LLMClient
    let settings: @Sendable () -> Settings
    let now: @Sendable () -> Date
    let currentTimeZone: @Sendable () -> TimeZone
    let activity: ActivityRecording

    public init(
        clientFor: @escaping @Sendable (EngineKind) throws -> LLMClient,
        settings: @escaping @Sendable () -> Settings = { Settings.defaults },
        now: @escaping @Sendable () -> Date = { Date() },
        currentTimeZone: @escaping @Sendable () -> TimeZone = { .current },
        activity: ActivityRecording = NoActivity()
    ) {
        self.clientFor = clientFor
        self.settings = settings
        self.now = now
        self.currentTimeZone = currentTimeZone
        self.activity = activity
    }

    public func summarize(meeting: Meeting, transcript: Transcript, clean: CleanTranscript, engine: EngineKind) async throws -> Summary {
        let client = try clientFor(engine)
        var result = try await attempt(client, meeting: meeting, transcript: transcript, clean: clean, engine: engine, retryNote: nil)
        if !result.uncoveredFlagSegments.isEmpty || !result.unsourcedItems.isEmpty {
            var notes: [String] = []
            if !result.uncoveredFlagSegments.isEmpty {
                let missing = result.uncoveredFlagSegments.map { "S\($0)" }.joined(separator: ", ")
                notes.append("Your previous answer did not cover flagged segments \(missing). Cover them.")
            }
            if !result.unsourcedItems.isEmpty {
                notes.append("Every bullet and action must cite at least one existing segment id; these did not: \(result.unsourcedItems.joined(separator: "; ")).")
            }
            let note = notes.joined(separator: " ")
            record(.info, "Asked \(engine.displayName) again: the first recap missed flagged moments or sources")
            do {
                result = try await attempt(client, meeting: meeting, transcript: transcript, clean: clean, engine: engine, retryNote: note)
            } catch where LLMTransport.isCancellation(error) {
                throw error
            } catch {
                let context = ProblemContext.engine(engine, settings: settings(), stage: .writingRecap, claudeKeyPresent: false)
                record(.warning, "The second attempt failed; Muninn kept the first recap", details: ProblemTranslator.problem(for: error, in: context).details)
            }
        }
        return FlagCoverage.ensureCovered(result.summary, uncovered: result.uncoveredFlagSegments, clean: clean)
    }

    private func record(_ level: ActivityLevel, _ message: String, details: ProblemDetails? = nil) {
        activity.record(ActivityEntry(time: now(), level: level, area: .recap, meeting: ActivityScope.meeting, message: message, details: details))
    }

    private func attempt(
        _ client: LLMClient, meeting: Meeting, transcript: Transcript, clean: CleanTranscript, engine: EngineKind, retryNote: String?
    ) async throws -> SummaryParseResult {
        let settings = settings()
        let request = SummaryRequestBuilder.build(
            meeting: meeting, transcript: transcript, clean: clean, retryNote: retryNote,
            userName: settings.userName, selfAddresses: settings.accounts.flatMap(\.selfAddresses),
            maxTokens: SummaryRequestBuilder.summaryMaxTokens(for: engine),
            timeZone: TimeZone(identifier: meeting.timeZone ?? "") ?? currentTimeZone()
        )
        let reply = try await client.complete(request)
        return try SummaryParser.parse(reply, transcript: transcript, flags: meeting.flags, engine: engine, now: now())
    }
}
