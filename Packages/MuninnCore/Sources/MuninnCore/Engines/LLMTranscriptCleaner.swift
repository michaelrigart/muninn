import Foundation

public struct LLMTranscriptCleaner: TranscriptCleaning {
    static let maxTokens = 16000
    static let maxDeletedShare = 0.4

    static let system = """
    You clean up a speech transcript. You receive JSON `{"segments":[{"id":1,"text":"…"}]}`.
    Rules:
    - Only delete filler words, false starts and repeated words, and fix punctuation and capitalisation.
    - Never rephrase, reorder, translate or add words.
    - Keep every id, and keep the language of each segment.
    - Reply with a single JSON object of the same shape, and nothing else.
    """

    static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "segments": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object(["type": .string("integer")]),
                        "text": .object(["type": .string("string")]),
                    ]),
                    "required": .array([.string("id"), .string("text")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]),
        "required": .array([.string("segments")]),
        "additionalProperties": .bool(false),
    ])

    let client: LLMClient
    let batchSize: Int
    /// Once LLM cleanup has run this long (seconds), the remaining batches use the rule cleaner.
    let budget: TimeInterval
    let clock: @Sendable () -> Date

    public init(client: LLMClient, batchSize: Int = 40, budget: TimeInterval = 180, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.batchSize = max(1, batchSize)
        self.budget = budget
        self.clock = clock
    }

    private struct Reply: Decodable {
        var segments: [CleanSegment]
    }

    public func clean(_ transcript: Transcript) async throws -> CleanTranscript {
        var cleaned: [CleanSegment] = []
        var start = 0
        var engineUsable = true
        let began = clock()
        while start < transcript.segments.count {
            let batch = Array(transcript.segments[start..<min(start + batchSize, transcript.segments.count)])
            start += batch.count
            if engineUsable, clock().timeIntervalSince(began) >= budget { engineUsable = false }
            var proposed: [Int: String] = [:]
            if engineUsable {
                if let reply = try await propose(batch) {
                    proposed = reply
                } else {
                    engineUsable = false
                }
            }
            cleaned += batch.map { segment in
                let rules = RuleCleaner.clean(segment.text)
                if let text = proposed[segment.id], Self.accepts(text, verbatim: segment.text, rules: rules) {
                    return CleanSegment(id: segment.id, text: text)
                }
                return CleanSegment(id: segment.id, text: rules)
            }
        }
        return CleanTranscript(segments: cleaned)
    }

    private static func accepts(_ text: String, verbatim: String, rules: String) -> Bool {
        guard CleanupVerifier.isDeletionOnly(verbatim: verbatim, clean: text) else { return false }
        let cleanWords = Tokenizer.normalizedWords(text)
        if cleanWords.isEmpty && !Tokenizer.normalizedWords(rules).isEmpty { return false }
        let content = Tokenizer.normalizedWords(verbatim).filter { !RuleCleaner.fillers.contains($0) }.count
        let kept = cleanWords.filter { !RuleCleaner.fillers.contains($0) }.count
        if content >= 5 && Double(content - kept) / Double(content) > maxDeletedShare { return false }
        return true
    }

    /// Nil when the engine failed to answer; an empty result when it answered with something unusable.
    private func propose(_ batch: [Segment]) async throws -> [Int: String]? {
        let payload: JSONValue = .object(["segments": .array(batch.map {
            .object(["id": .number(Double($0.id)), "text": .string($0.text)])
        })])
        guard let data = try? JSONEncoder().encode(payload) else { return [:] }
        let request = LLMRequest(system: Self.system, user: String(decoding: data, as: UTF8.self), jsonSchema: Self.schema, maxTokens: Self.maxTokens)
        let reply: String
        do {
            reply = try await client.complete(request)
        } catch where LLMTransport.isCancellation(error) {
            throw error
        } catch {
            return nil
        }
        guard let object = LLMTransport.outermostJSONObject(in: reply),
              let parsed = try? JSONDecoder().decode(Reply.self, from: Data(object.utf8)) else { return [:] }
        return Dictionary(parsed.segments.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
    }
}
