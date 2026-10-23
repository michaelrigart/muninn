import Foundation
import Testing
@testable import MuninnCore

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Reply] = []
    nonisolated(unsafe) private static var captured: [URLRequest] = []

    static func reset(_ replies: [Reply]) {
        lock.lock()
        defer { lock.unlock() }
        self.replies = replies
        captured = []
    }

    static var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            request.httpBody = data
        }
        Self.lock.lock()
        Self.captured.append(request)
        let reply = Self.replies.isEmpty ? Reply(status: 500, body: "no stubbed reply") : Self.replies.removeFirst()
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum LLMClientTests_Reply {
    static let ok = StubURLProtocol.Reply(status: 200, body: #"{"message":{"content":"{}"}}"#)
}

final class LockedBox<Value>: @unchecked Sendable {
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

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        change(&value)
    }
}

final class ScriptedClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Result<String, Error>]
    private var seen: [LLMRequest] = []

    init(_ replies: [Result<String, Error>]) {
        self.replies = replies
    }

    var requests: [LLMRequest] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    private func next(_ request: LLMRequest) -> Result<String, Error> {
        lock.lock()
        defer { lock.unlock() }
        seen.append(request)
        return replies.isEmpty ? .failure(LLMError.emptyResponse) : replies.removeFirst()
    }

    func complete(_ request: LLMRequest) async throws -> String {
        try next(request).get()
    }
}

@Suite(.serialized)
struct LLMClientTests {
    static let request = LLMRequest(system: "sys", user: "usr", jsonSchema: SummarySchema.jsonSchema, maxTokens: 16000)

    static func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    static func claude() -> ClaudeClient {
        ClaudeClient(apiKey: "sk-test", session: StubURLProtocol.session())
    }

    @Test func claudeRequestShape() async throws {
        StubURLProtocol.reset([.init(status: 200, body: #"{"stop_reason":"end_turn","content":[{"type":"text","text":"{}"}]}"#)])
        let text = try await Self.claude().complete(Self.request)
        #expect(text == "{}")

        let sent = try #require(StubURLProtocol.requests.first)
        #expect(sent.url?.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(sent.httpMethod == "POST")
        #expect(sent.timeoutInterval == 300)
        #expect(sent.value(forHTTPHeaderField: "x-api-key") == "sk-test")
        #expect(sent.value(forHTTPHeaderField: "anthropic-version") == "2026-10-21")
        #expect(sent.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01")
        #expect(sent.value(forHTTPHeaderField: "content-type") == "application/json")

        let body = try Self.body(sent)
        #expect(body["model"] as? String == "claude-opus-5-5")
        #expect(body["max_tokens"] as? Int == 16000)
        #expect(body["fallbacks"] as? String == "default")
        #expect(body["system"] as? String == "sys")
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "usr")
        let output = try #require(body["output_config"] as? [String: Any])
        #expect(output["effort"] as? String == "medium")
        let format = try #require(output["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        let schemaData = try JSONEncoder().encode(SummarySchema.jsonSchema)
        let expectedSchema = try #require(try JSONSerialization.jsonObject(with: schemaData) as? NSDictionary)
        #expect(format["schema"] as? NSDictionary == expectedSchema)
        for key in ["temperature", "top_p", "top_k", "thinking"] {
            #expect(body[key] == nil)
        }
    }

    @Test func claudeOmitsFormatWithoutSchema() async throws {
        StubURLProtocol.reset([.init(status: 200, body: #"{"content":[{"type":"text","text":"ok"}]}"#)])
        _ = try await Self.claude().complete(LLMRequest(system: "s", user: "u", jsonSchema: nil, maxTokens: 100))
        let sent = try #require(StubURLProtocol.requests.first)
        let output = try #require(try Self.body(sent)["output_config"] as? [String: Any])
        #expect(output["format"] == nil)
    }

    @Test func claudeJoinsTextBlocksSkipsThinking() async throws {
        StubURLProtocol.reset([.init(status: 200, body: #"{"stop_reason":"end_turn","content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"{"},{"type":"text","text":"}"}]}"#)])
        #expect(try await Self.claude().complete(Self.request) == "{}")
    }

    @Test func claudeEmptyResponse() async throws {
        StubURLProtocol.reset([.init(status: 200, body: #"{"content":[{"type":"thinking","thinking":"hmm"}]}"#)])
        await #expect(throws: LLMError.emptyResponse) { try await Self.claude().complete(Self.request) }
    }

    @Test func claudeTruncated() async throws {
        StubURLProtocol.reset([.init(status: 200, body: #"{"stop_reason":"max_tokens","content":[{"type":"text","text":"{\"lang"}]}"#)])
        await #expect(throws: LLMError.truncated) { try await Self.claude().complete(Self.request) }
    }

    @Test func claudeRefusal() async throws {
        StubURLProtocol.reset([.init(status: 200, body: #"{"stop_reason":"refusal","stop_details":{"category":"cyber"},"content":[{"type":"text","text":"no"}]}"#)])
        await #expect(throws: LLMError.refused("cyber")) { try await Self.claude().complete(Self.request) }
    }

    @Test func claudeHTTPError() async throws {
        StubURLProtocol.reset([.init(status: 401, body: #"{"error":"bad key"}"#)])
        await #expect(throws: LLMError.http(401, #"{"error":"bad key"}"#)) { try await Self.claude().complete(Self.request) }
    }

    @Test func httpErrorBodyIsTruncated() async throws {
        StubURLProtocol.reset([.init(status: 500, body: String(repeating: "x", count: 900))])
        do {
            _ = try await Self.claude().complete(Self.request)
            Issue.record("Expected an error")
        } catch let LLMError.http(status, body) {
            #expect(status == 500)
            #expect(body.count == 500)
        }
    }

    @Test func claudeDecodingError() async throws {
        StubURLProtocol.reset([.init(status: 200, body: "not json")])
        do {
            _ = try await Self.claude().complete(Self.request)
            Issue.record("Expected an error")
        } catch LLMError.decoding {
        }
    }

    @Test func ollamaRequestShape() async throws {
        StubURLProtocol.reset([.init(status: 200, body: #"{"message":{"role":"assistant","content":"{\"a\":1}"}}"#)])
        let client = OllamaClient(baseURL: URL(string: "http://studio.local:11434")!, model: "qwen", keepAlive: "0", session: StubURLProtocol.session())
        let text = try await client.complete(Self.request)
        #expect(text == #"{"a":1}"#)

        let sent = try #require(StubURLProtocol.requests.first)
        #expect(sent.url?.path == "/api/chat")
        #expect(sent.timeoutInterval == 300)
        let body = try Self.body(sent)
        #expect(body["model"] as? String == "qwen")
        #expect(body["stream"] as? Bool == false)
        #expect(body["keep_alive"] as? String == "0")
        #expect(body["think"] as? Bool == false)
        #expect((body["options"] as? [String: Any])?["num_ctx"] as? Int == 16384)
        #expect((body["options"] as? [String: Any])?["num_predict"] as? Int == 16000)
        let schemaData = try JSONEncoder().encode(SummarySchema.jsonSchema)
        let expected = try #require(try JSONSerialization.jsonObject(with: schemaData) as? NSDictionary)
        #expect(body["format"] as? NSDictionary == expected)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
        #expect(messages.map { $0["content"] as? String } == ["sys", "usr"])
    }

    private func ollama(limit: Int = 32768) -> OllamaClient {
        OllamaClient(baseURL: URL(string: "http://studio.local:11434")!, model: "qwen", keepAlive: "0", contextTokens: limit, session: StubURLProtocol.session())
    }

    private func numCtx() throws -> Int? {
        let sent = try #require(StubURLProtocol.requests.last)
        return (try Self.body(sent)["options"] as? [String: Any])?["num_ctx"] as? Int
    }

    @Test func ollamaContextIsSizedPerRequest() async throws {
        let reply = LLMClientTests_Reply.ok
        StubURLProtocol.reset([reply, reply, reply])
        _ = try await ollama().complete(LLMRequest(system: "s", user: "u", jsonSchema: nil, maxTokens: 1000))
        #expect(try numCtx() == 8192)
        _ = try await ollama().complete(LLMRequest(system: "s", user: String(repeating: "a", count: 60_000), jsonSchema: nil, maxTokens: 1000))
        #expect(try numCtx() == 24576)
        _ = try await ollama().complete(LLMRequest(system: "s", user: String(repeating: "a", count: 3 * 8000 - 1), jsonSchema: nil, maxTokens: 192))
        #expect(try numCtx() == 8192)
    }

    @Test func ollamaClampsTheContextToTheLimitInsteadOfFailing() async throws {
        StubURLProtocol.reset([LLMClientTests_Reply.ok])
        let request = LLMRequest(system: "s", user: String(repeating: "a", count: 120_000), jsonSchema: nil, maxTokens: 1000)
        #expect(try await ollama().complete(request) == "{}")
        #expect(try numCtx() == 32768)
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test func ollamaLimitIsConfigurable() async throws {
        StubURLProtocol.reset([LLMClientTests_Reply.ok])
        _ = try await ollama(limit: 65536).complete(LLMRequest(system: "s", user: String(repeating: "a", count: 120_000), jsonSchema: nil, maxTokens: 1000))
        #expect(try numCtx() == 45056)
    }

    @Test func ollamaTreatsAPromptThatFilledTheWindowAsTruncated() async throws {
        let request = LLMRequest(system: "s", user: "u", jsonSchema: nil, maxTokens: 1000)
        func reply(_ count: Int?) -> StubURLProtocol.Reply {
            let field = count.map { #","prompt_eval_count":\#($0)"# } ?? ""
            return .init(status: 200, body: #"{"message":{"content":"{}"}\#(field)}"#)
        }
        StubURLProtocol.reset([reply(8192 - 513), reply(nil), reply(100), reply(8192 - 512), reply(8192)])
        #expect(try await ollama().complete(request) == "{}")
        #expect(try await ollama().complete(request) == "{}")
        #expect(try await ollama().complete(request) == "{}")
        for _ in 0..<2 {
            do {
                _ = try await ollama().complete(request)
                Issue.record("Expected an error")
            } catch let error as LLMError {
                #expect(error == .promptTruncated(model: "qwen", contextTokens: 8192))
                #expect(error.localizedDescription == "The transcript is too long for qwen's context (8192 tokens) and was cut off; use the Network Mac or Claude")
            }
        }
    }

    @Test func ollamaTreatsAContextShiftDuringTheReplyAsTruncated() async throws {
        let request = LLMRequest(system: "s", user: "u", jsonSchema: nil, maxTokens: 1000)
        func reply(prompt: Int, eval: Int?) -> StubURLProtocol.Reply {
            let field = eval.map { #","eval_count":\#($0)"# } ?? ""
            return .init(status: 200, body: #"{"message":{"content":"{}"},"prompt_eval_count":\#(prompt)\#(field)}"#)
        }
        StubURLProtocol.reset([
            reply(prompt: 5000, eval: 8192 - 5000 - 1), reply(prompt: 5000, eval: 8192 - 5000),
            reply(prompt: 5000, eval: 4000),
        ])
        #expect(try await ollama().complete(request) == "{}")
        do {
            _ = try await ollama().complete(request)
            Issue.record("Expected an error")
        } catch let error as LLMError {
            #expect(error == .promptTruncated(model: "qwen", contextTokens: 8192))
        }
        do {
            _ = try await ollama().complete(request)
            Issue.record("Expected an error")
        } catch let error as LLMError {
            #expect(error == .promptTruncated(model: "qwen", contextTokens: 8192))
        }
    }

    @Test func openAIRequestShape() async throws {
        StubURLProtocol.reset([.init(status: 200, body: #"{"choices":[{"message":{"role":"assistant","content":"{}"}}]}"#)])
        let client = OpenAICompatibleClient(baseURL: URL(string: "http://localhost:1234")!, model: "m", apiKey: "k", session: StubURLProtocol.session())
        let text = try await client.complete(Self.request)
        #expect(text == "{}")

        let sent = try #require(StubURLProtocol.requests.first)
        #expect(sent.url?.path == "/v1/chat/completions")
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let body = try Self.body(sent)
        let format = try #require(body["response_format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(body["max_tokens"] as? Int == 16000)
        let jsonSchema = try #require(format["json_schema"] as? [String: Any])
        #expect(jsonSchema["strict"] as? Bool == true)
        #expect(jsonSchema["name"] as? String == "summary")
        #expect(jsonSchema["schema"] != nil)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.map { $0["role"] as? String } == ["system", "user"])
    }

    @Test func baseURLsDoNotDoubleThePath() async throws {
        StubURLProtocol.reset([
            .init(status: 200, body: #"{"choices":[{"message":{"content":"{}"}}]}"#),
            .init(status: 200, body: #"{"choices":[{"message":{"content":"{}"}}]}"#),
            .init(status: 200, body: #"{"message":{"content":"{}"}}"#),
        ])
        let session = StubURLProtocol.session()
        _ = try await OpenAICompatibleClient(baseURL: URL(string: "http://studio.local:1234/v1/")!, model: "m", apiKey: nil, session: session).complete(Self.request)
        _ = try await OpenAICompatibleClient(baseURL: URL(string: "http://studio.local:1234/v1")!, model: "m", apiKey: nil, session: session).complete(Self.request)
        _ = try await OllamaClient(baseURL: URL(string: "http://studio.local:11434/")!, model: "m", keepAlive: "0", session: session).complete(Self.request)
        let urls = StubURLProtocol.requests.map { $0.url?.absoluteString }
        #expect(urls == [
            "http://studio.local:1234/v1/chat/completions",
            "http://studio.local:1234/v1/chat/completions",
            "http://studio.local:11434/api/chat",
        ])
    }

    @Test func openAIWithoutKeySendsNoAuthorization() async throws {
        StubURLProtocol.reset([.init(status: 200, body: #"{"choices":[{"message":{"content":"{}"}}]}"#)])
        let client = OpenAICompatibleClient(baseURL: URL(string: "http://localhost:1234")!, model: "m", apiKey: nil, session: StubURLProtocol.session())
        _ = try await client.complete(LLMRequest(system: "s", user: "u", jsonSchema: nil, maxTokens: 10))
        let sent = try #require(StubURLProtocol.requests.first)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(try Self.body(sent)["response_format"] == nil)
    }

    @Test func openAIHTTPError() async throws {
        StubURLProtocol.reset([.init(status: 503, body: "down")])
        let client = OpenAICompatibleClient(baseURL: URL(string: "http://localhost:1234")!, model: "m", apiKey: nil, session: StubURLProtocol.session())
        await #expect(throws: LLMError.http(503, "down")) { try await client.complete(Self.request) }
    }
}

struct LLMSummarizerTests {
    static let flaggedMeeting = SummaryTests.meeting(flags: [Flag(offset: 65)])

    static func reply(sources: [Int]) -> String {
        let list = sources.map(String.init).joined(separator: ",")
        return #"{"language":"en","subjects":[{"title":"Release","bullets":[{"text":"Shipping","sources":[\#(list)]}],"actions":[]}]}"#
    }

    static func summarizer(_ client: ScriptedClient) -> LLMSummarizer {
        LLMSummarizer(clientFor: { _ in client }, now: { SummaryTests.now }, currentTimeZone: { brussels })
    }

    private static let brussels = TimeZone(identifier: "Europe/Brussels")!

    /// 2026-10-26 23:30 in Los Angeles, already Tuesday morning in Brussels.
    private static let lateMondayInLosAngeles: Date = {
        var components = DateComponents(year: 2026, month: 10, day: 26, hour: 23, minute: 30)
        components.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return Calendar(identifier: .gregorian).date(from: components)!
    }()

    @Test func theCallDateUsesTheZoneTheMeetingWasPreparedIn() async throws {
        var meeting = SummaryTests.meeting()
        meeting.startedAt = Self.lateMondayInLosAngeles
        meeting.timeZone = "America/Los_Angeles"
        let client = ScriptedClient([.success(Self.reply(sources: [1]))])
        _ = try await Self.summarizer(client).summarize(meeting: meeting, transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: .claude)
        #expect(client.requests[0].user.hasPrefix("Call date: 2026-10-26 (Monday)\n"))
    }

    @Test func aMeetingWithoutAStoredZoneUsesTheCurrentOne() async throws {
        var meeting = SummaryTests.meeting()
        meeting.startedAt = Self.lateMondayInLosAngeles
        for stored in [nil, "Not/AZone"] as [String?] {
            meeting.timeZone = stored
            let client = ScriptedClient([.success(Self.reply(sources: [1]))])
            _ = try await Self.summarizer(client).summarize(meeting: meeting, transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: .claude)
            let expected = SummaryRequestBuilder.build(meeting: meeting, transcript: SummaryTests.transcript, clean: SummaryTests.clean, timeZone: Self.brussels)
            #expect(client.requests[0].user == expected.user)
            #expect(client.requests[0].user.hasPrefix("Call date: 2026-10-27 (Tuesday)\n"))
        }
    }

    @Test func summarizerRetriesOnceForUncoveredFlags() async throws {
        let client = ScriptedClient([.success(Self.reply(sources: [1])), .success(Self.reply(sources: [1, 3]))])
        let summary = try await Self.summarizer(client).summarize(
            meeting: Self.flaggedMeeting, transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: .claude
        )
        #expect(client.requests.count == 2)
        #expect(!client.requests[0].system.contains("did not cover"))
        #expect(client.requests[1].system.contains("Your previous answer did not cover flagged segments S3. Cover them."))
        #expect(summary.subjects.count == 1)
        #expect(summary.subjects[0].bullets[0].sources == [1, 3])
        #expect(summary.engine == .claude)
    }

    private static func unsourcedReply(sources: [Int]) -> String {
        let list = sources.map(String.init).joined(separator: ",")
        return #"{"language":"en","subjects":[{"title":"Release","bullets":[{"text":"Shipping","sources":[1]},{"text":"Needs a moment","sources":[\#(list)]}],"actions":[{"owner":"you","text":"Send the notes","due":null,"sources":[\#(list)]}]}]}"#
    }

    @Test func unsourcedItemsTriggerOneRetryThatCanFixThem() async throws {
        let client = ScriptedClient([.success(Self.unsourcedReply(sources: [])), .success(Self.unsourcedReply(sources: [3]))])
        let summary = try await Self.summarizer(client).summarize(
            meeting: SummaryTests.meeting(), transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: .claude
        )
        #expect(client.requests.count == 2)
        let note = "Every bullet and action must cite at least one existing segment id; these did not: bullet \"Needs a moment\"; action \"Send the notes\"."
        #expect(client.requests[1].system.contains(note))
        #expect(summary.subjects[0].bullets.map(\.sources) == [[1], [3]])
        #expect(summary.subjects[0].actions.map(\.sources) == [[3]])
    }

    @Test func unsourcedItemsStayWhenTheRetryDoesNotFixThem() async throws {
        let client = ScriptedClient([.success(Self.unsourcedReply(sources: [99])), .success(Self.unsourcedReply(sources: []))])
        let summary = try await Self.summarizer(client).summarize(
            meeting: SummaryTests.meeting(), transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: .claude
        )
        #expect(client.requests.count == 2)
        #expect(summary.subjects[0].bullets.map(\.sources) == [[1], []])
        #expect(summary.subjects[0].actions.map(\.sources) == [[]])
    }

    @Test func oneRetryCarriesBothFlagAndSourceNotes() async throws {
        let reply = #"{"language":"en","subjects":[{"title":"R","bullets":[{"text":"Loose","sources":[]}],"actions":[]}]}"#
        let client = ScriptedClient([.success(reply), .success(Self.reply(sources: [1, 3]))])
        _ = try await Self.summarizer(client).summarize(
            meeting: Self.flaggedMeeting, transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: .claude
        )
        #expect(client.requests.count == 2)
        #expect(client.requests[1].system.contains("did not cover flagged segments S3. Cover them. Every bullet and action must cite"))
    }

    @Test func fullySourcedSummaryIsNotRetried() async throws {
        let client = ScriptedClient([.success(Self.unsourcedReply(sources: [3]))])
        _ = try await Self.summarizer(client).summarize(
            meeting: SummaryTests.meeting(), transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: .claude
        )
        #expect(client.requests.count == 1)
    }

    @Test func summaryReplyBudgetDependsOnTheEngine() async throws {
        for (engine, expected) in [(EngineKind.macbook, 8192), (.studio, 8192), (.claude, 16000)] {
            let client = ScriptedClient([.success(Self.reply(sources: [3]))])
            _ = try await Self.summarizer(client).summarize(
                meeting: Self.flaggedMeeting, transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: engine
            )
            #expect(client.requests.first?.maxTokens == expected)
        }
    }

    @Test func summarizerDoesNotRetryWhenCovered() async throws {
        let client = ScriptedClient([.success(Self.reply(sources: [3]))])
        _ = try await Self.summarizer(client).summarize(
            meeting: Self.flaggedMeeting, transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: .studio
        )
        #expect(client.requests.count == 1)
    }

    @Test func summarizerFallsBackToCoverage() async throws {
        let client = ScriptedClient([.success(Self.reply(sources: [1])), .success(Self.reply(sources: [1]))])
        let summary = try await Self.summarizer(client).summarize(
            meeting: Self.flaggedMeeting, transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: .claude
        )
        #expect(client.requests.count == 2)
        let flagged = try #require(summary.subjects.first { $0.title == "Flagged moments" })
        #expect(flagged.bullets == [Bullet(text: "We ship Friday.", sources: [3])])
    }

    @Test func summarizerKeepsFirstWhenRetryFails() async throws {
        let client = ScriptedClient([.success(Self.reply(sources: [1])), .failure(LLMError.http(529, ""))])
        let summary = try await Self.summarizer(client).summarize(
            meeting: Self.flaggedMeeting, transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: .claude
        )
        #expect(client.requests.count == 2)
        #expect(summary.subjects.first?.title == "Release")
        #expect(summary.subjects.contains { $0.title == "Flagged moments" })
    }

    @Test func summarizerKeepsFirstWhenRetryIsUnparseable() async throws {
        let client = ScriptedClient([.success(Self.reply(sources: [1])), .success("nonsense")])
        let summary = try await Self.summarizer(client).summarize(
            meeting: Self.flaggedMeeting, transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: .claude
        )
        #expect(summary.subjects.contains { $0.title == "Flagged moments" })
    }

    @Test func summarizerRethrowsCancellationFromRetry() async throws {
        let client = ScriptedClient([.success(Self.reply(sources: [1])), .failure(CancellationError())])
        await #expect(throws: CancellationError.self) {
            try await Self.summarizer(client).summarize(
                meeting: Self.flaggedMeeting, transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: .claude
            )
        }
    }

    @Test func summarizerPropagatesParseErrors() async throws {
        let client = ScriptedClient([.success("nonsense")])
        await #expect(throws: SummaryParseError.self) {
            try await Self.summarizer(client).summarize(
                meeting: Self.flaggedMeeting, transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: .claude
            )
        }
    }

    @Test func summarizerPropagatesClientErrors() async throws {
        let client = ScriptedClient([.failure(LLMError.refused("cyber"))])
        await #expect(throws: LLMError.refused("cyber")) {
            try await Self.summarizer(client).summarize(
                meeting: Self.flaggedMeeting, transcript: SummaryTests.transcript, clean: SummaryTests.clean, engine: .claude
            )
        }
    }
}

struct LLMTranscriptCleanerTests {
    static func transcript(_ texts: [String]) -> Transcript {
        Transcript(segments: texts.enumerated().map {
            SummaryTests.segment($0.offset + 1, Double($0.offset), Double($0.offset + 1), text: $0.element)
        }, language: "en")
    }

    @Test func llmCleanerRejectsRephrase() async throws {
        let transcript = Self.transcript(["um we we should uh ship it", "the cat sat down"])
        let reply = #"{"segments":[{"id":1,"text":"We should ship it."},{"id":2,"text":"A feline rested."}]}"#
        let cleaner = LLMTranscriptCleaner(client: ScriptedClient([.success(reply)]))
        let clean = try await cleaner.clean(transcript)
        #expect(clean.segments.map(\.id) == [1, 2])
        #expect(clean.segments[0].text == "We should ship it.")
        #expect(clean.segments[1].text == RuleCleaner.clean("the cat sat down"))
    }

    @Test func llmCleanerUsesRulesForMissingIds() async throws {
        let transcript = Self.transcript(["um hello there", "second one"])
        let cleaner = LLMTranscriptCleaner(client: ScriptedClient([.success(#"{"segments":[{"id":2,"text":"Second one."}]}"#)]))
        let clean = try await cleaner.clean(transcript)
        #expect(clean.segments[0].text == RuleCleaner.clean("um hello there"))
        #expect(clean.segments[1].text == "Second one.")
    }

    @Test func llmCleanerBatchesAndFallsBackPerBatch() async throws {
        let transcript = Self.transcript(["one", "two", "three"])
        let client = ScriptedClient([.success(#"{"segments":[{"id":1,"text":"One."},{"id":2,"text":"Two."}]}"#), .failure(LLMError.http(500, "boom"))])
        let clean = try await LLMTranscriptCleaner(client: client, batchSize: 2).clean(transcript)
        #expect(client.requests.count == 2)
        #expect(clean.segments.map(\.text) == ["One.", "Two.", RuleCleaner.clean("three")])

        let first = try #require(try JSONSerialization.jsonObject(with: Data(client.requests[0].user.utf8)) as? [String: Any])
        let items = try #require(first["segments"] as? [[String: Any]])
        #expect(items.map { $0["id"] as? Int } == [1, 2])
        #expect(items.map { $0["text"] as? String } == ["one", "two"])
        #expect(client.requests[0].jsonSchema == LLMTranscriptCleaner.schema)
    }

    @Test func llmCleanerStopsCallingAFailingEngine() async throws {
        let transcript = Self.transcript(["um one", "um two", "um three"])
        let client = ScriptedClient([.failure(URLError(.timedOut)), .success(#"{"segments":[{"id":2,"text":"Two."},{"id":3,"text":"Three."}]}"#)])
        let clean = try await LLMTranscriptCleaner(client: client, batchSize: 1).clean(transcript)
        #expect(client.requests.count == 1)
        #expect(clean.segments.map(\.text) == ["One", "Two", "Three"].map { RuleCleaner.clean("um " + $0.lowercased()) })
    }

    @Test func llmCleanerKeepsCallingAfterAnUnparseableReply() async throws {
        let transcript = Self.transcript(["um one", "um two"])
        let client = ScriptedClient([.success("garbage"), .success(#"{"segments":[{"id":2,"text":"Two."}]}"#)])
        let clean = try await LLMTranscriptCleaner(client: client, batchSize: 1).clean(transcript)
        #expect(client.requests.count == 2)
        #expect(clean.segments.map(\.text) == [RuleCleaner.clean("um one"), "Two."])
    }

    @Test func llmCleanerStopsOnceTheTimeBudgetIsSpent() async throws {
        final class SlowClient: LLMClient, @unchecked Sendable {
            let now = LockedBox(Date(timeIntervalSince1970: 0))
            let calls = LockedBox(0)
            func complete(_ request: LLMRequest) async throws -> String {
                calls.update { $0 += 1 }
                now.update { $0 = $0.addingTimeInterval(200) }
                return #"{"segments":[]}"#
            }
        }
        let client = SlowClient()
        let transcript = Self.transcript(["um one", "um two", "um three"])
        let now = client.now
        let clean = try await LLMTranscriptCleaner(client: client, batchSize: 1, budget: 180, clock: { now.get() }).clean(transcript)
        #expect(client.calls.get() == 1)
        #expect(clean.segments.map(\.text) == ["um one", "um two", "um three"].map { RuleCleaner.clean($0) })
    }

    @Test func llmCleanerRejectsHeavyDeletion() async throws {
        let transcript = Self.transcript(["we ship the release on Friday morning"])
        let cleaner = LLMTranscriptCleaner(client: ScriptedClient([.success(#"{"segments":[{"id":1,"text":"We ship."}]}"#)]))
        let clean = try await cleaner.clean(transcript)
        #expect(clean.segments[0].text == RuleCleaner.clean("we ship the release on Friday morning"))
    }

    @Test func llmCleanerAcceptsLightDeletionInLongSegment() async throws {
        let transcript = Self.transcript(["we ship the release on Friday morning"])
        let cleaner = LLMTranscriptCleaner(client: ScriptedClient([.success(#"{"segments":[{"id":1,"text":"We ship the release Friday morning."}]}"#)]))
        let clean = try await cleaner.clean(transcript)
        #expect(clean.segments[0].text == "We ship the release Friday morning.")
    }

    @Test func llmCleanerAcceptsFillerHeavySegment() async throws {
        let transcript = Self.transcript(["euh ja euh dus euh we doen dat euh morgen"])
        let cleaner = LLMTranscriptCleaner(client: ScriptedClient([.success(#"{"segments":[{"id":1,"text":"Ja, dus we doen dat morgen."}]}"#)]))
        let clean = try await cleaner.clean(transcript)
        #expect(clean.segments[0].text == "Ja, dus we doen dat morgen.")
    }

    @Test func llmCleanerRejectsEmptiedSegment() async throws {
        let transcript = Self.transcript(["yes"])
        let cleaner = LLMTranscriptCleaner(client: ScriptedClient([.success(#"{"segments":[{"id":1,"text":""}]}"#)]))
        let clean = try await cleaner.clean(transcript)
        #expect(clean.segments[0].text == RuleCleaner.clean("yes"))
        #expect(!clean.segments[0].text.isEmpty)
    }

    @Test func llmCleanerExtractsObjectFromWrappedReply() async throws {
        let transcript = Self.transcript(["um hello there"])
        let reply = "Here you go:\n```json\n{\"segments\":[{\"id\":1,\"text\":\"Hello there.\"}]}\n```"
        let clean = try await LLMTranscriptCleaner(client: ScriptedClient([.success(reply)])).clean(transcript)
        #expect(clean.segments[0].text == "Hello there.")
    }

    @Test func llmCleanerRethrowsCancellation() async throws {
        let transcript = Self.transcript(["one"])
        await #expect(throws: CancellationError.self) {
            try await LLMTranscriptCleaner(client: ScriptedClient([.failure(CancellationError())])).clean(transcript)
        }
        await #expect(throws: URLError.self) {
            try await LLMTranscriptCleaner(client: ScriptedClient([.failure(URLError(.cancelled))])).clean(transcript)
        }
    }

    @Test func llmCleanerFallsBackOnUnparseableReply() async throws {
        let transcript = Self.transcript(["um hello"])
        let clean = try await LLMTranscriptCleaner(client: ScriptedClient([.success("garbage")])).clean(transcript)
        #expect(clean.segments[0].text == RuleCleaner.clean("um hello"))
    }
}
