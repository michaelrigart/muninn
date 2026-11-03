import Foundation
import Testing
@testable import MuninnCore

/// Replies to every request with one canned response. Private to this suite, because `StubURLProtocol` holds
/// process-wide state that `LLMClientTests` resets while other suites run.
private final class CannedProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 500
    nonisolated(unsafe) static var body = ""

    static func session(status: Int, body: String) -> URLSession {
        Self.status = status
        Self.body = body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CannedProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// None of the three paths may carry a transcript sentence into a problem, the Activity file or the diagnostics.
@Suite(.serialized)
struct TranscriptLeakTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let system = SystemInfo(appVersion: "test (1)", osVersion: "26.1")
    private static let meeting = ActivityMeeting(id: MeetingID(rawValue: "2026-11-03-1400-sync"), title: "Sync")
    private static let request = LLMRequest(system: "sys", user: "usr", jsonSchema: SummarySchema.jsonSchema, maxTokens: 16000)

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("muninn-leak-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func diagnostics(_ entries: [ActivityEntry]) -> String {
        Diagnostics.text(DiagnosticsInput(
            system: Self.system, macClass: "Mac15,6", settings: .defaults, permissions: [], entries: entries, homeDirectory: "/Users/tester"
        ))
    }

    /// Runs the problem through the Activity file and the diagnostics, and checks all three outputs.
    private func expectNoLeak(_ problem: Problem, recording entry: ActivityEntry) throws {
        let file = try folder().appendingPathComponent("activity.jsonl")
        let log = ActivityLog(file: file, clock: { Self.now })
        log.record(entry)

        let problemJSON = String(decoding: try JSONEncoder().encode(problem), as: UTF8.self)
        let activityBytes = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        let text = diagnostics(log.entries())
        #expect(!problemJSON.contains("Henderson"))
        #expect(!activityBytes.isEmpty && !activityBytes.contains("Henderson"))
        #expect(text.contains("Activity (last 1 entries") && !text.contains("Henderson"))
    }

    @Test func engineErrorBodyEchoingTheTranscript() async throws {
        let session = CannedProtocol.session(status: 400, body: #"{"type":"error","error":{"type":"invalid_request_error","message":"\#(SEED)"}}"#)
        let client = ClaudeClient(apiKey: "sk-test", session: session)
        let error = try #require(await #expect(throws: LLMError.self) { try await client.complete(Self.request) })
        let context = ProblemContext.engine(.claude, settings: .defaults, stage: .writingRecap, claudeKeyPresent: true)
        let problem = ProblemTranslator.problem(for: error, in: context, system: Self.system)
        try expectNoLeak(problem, recording: .problem(problem, area: .recap, meeting: Self.meeting, time: Self.now))
    }

    @Test func ollamaErrorMessageEchoingTheTranscript() async throws {
        let session = CannedProtocol.session(status: 404, body: #"{"error":"model 'qwen3:8b' not found, try pulling it first. \#(SEED)"}"#)
        let client = OllamaClient(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "qwen3:8b", keepAlive: "0", session: session)
        let error = try #require(await #expect(throws: LLMError.self) { try await client.complete(Self.request) })
        let context = ProblemContext.engine(.macbook, settings: .defaults, stage: .writingRecap, claudeKeyPresent: false)
        let problem = ProblemTranslator.problem(for: error, in: context, system: Self.system)
        try expectNoLeak(problem, recording: .problem(problem, area: .recap, meeting: Self.meeting, time: Self.now))
    }

    @Test func earlierVersionFailureStringWithTheTranscript() throws {
        let before = ModelTests.meeting(status: .summarizing)
        var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(before)) as? [String: Any])
        object["status"] = ["type": "failed", "message": "Error Domain=NSURLErrorDomain Code=-1004 \(SEED)"]
        let after = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))

        let entries = MeetingActivity.entries(from: before, to: after, settings: .defaults, time: Self.now)
        let entry = try #require(entries.first)
        guard case .failed(let problem) = after.status else {
            Issue.record("expected failed, got \(after.status)")
            return
        }
        try expectNoLeak(problem, recording: entry)
    }
}
