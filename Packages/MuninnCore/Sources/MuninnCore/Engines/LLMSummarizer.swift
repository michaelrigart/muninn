import Foundation

public protocol Summarizing: Sendable {
    func summarize(meeting: Meeting, transcript: Transcript, clean: CleanTranscript, engine: EngineKind) async throws -> Summary
}

public struct LLMSummarizer: Summarizing {
    let clientFor: @Sendable (EngineKind) throws -> LLMClient
    let settings: @Sendable () -> Settings
    let now: @Sendable () -> Date
    let currentTimeZone: @Sendable () -> TimeZone

    public init(
        clientFor: @escaping @Sendable (EngineKind) throws -> LLMClient,
        settings: @escaping @Sendable () -> Settings = { Settings.defaults },
        now: @escaping @Sendable () -> Date = { Date() },
        currentTimeZone: @escaping @Sendable () -> TimeZone = { .current }
    ) {
        self.clientFor = clientFor
        self.settings = settings
        self.now = now
        self.currentTimeZone = currentTimeZone
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
            do {
                result = try await attempt(client, meeting: meeting, transcript: transcript, clean: clean, engine: engine, retryNote: note)
            } catch where LLMTransport.isCancellation(error) {
                throw error
            } catch {
            }
        }
        return FlagCoverage.ensureCovered(result.summary, uncovered: result.uncoveredFlagSegments, clean: clean)
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
