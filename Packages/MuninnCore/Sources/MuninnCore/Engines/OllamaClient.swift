import Foundation

public struct OllamaClient: LLMClient {
    let baseURL: URL
    let model: String
    let keepAlive: String
    /// The largest context this engine is asked to allocate; each request is sized within it.
    public let contextTokens: Int
    let session: URLSession

    static let minimumContext = 8192
    static let contextStep = 4096
    /// A prompt that fills all but this many tokens of the window was cut to fit it.
    static let truncationMargin = 512

    public init(baseURL: URL, model: String, keepAlive: String, contextTokens: Int = 32768, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.keepAlive = keepAlive
        self.contextTokens = contextTokens
        self.session = session
    }

    private struct Response: Decodable {
        struct Message: Decodable {
            var content: String?
        }
        var message: Message?
        var promptEvalCount: Int?
        var evalCount: Int?

        private enum CodingKeys: String, CodingKey {
            case message
            case promptEvalCount = "prompt_eval_count"
            case evalCount = "eval_count"
        }
    }

    static func estimatedPromptTokens(_ request: LLMRequest) -> Int {
        (request.system.count + request.user.count + 2) / 3
    }

    /// The context to allocate: prompt estimate plus the reply budget, rounded up to a step, clamped to the engine's limit.
    static func contextSize(for request: LLMRequest, limit: Int) -> Int {
        let needed = estimatedPromptTokens(request) + request.maxTokens
        let rounded = (needed + contextStep - 1) / contextStep * contextStep
        return min(limit, max(minimumContext, rounded))
    }

    /// Ollama cuts an over-long prompt to fit, so a cut prompt reports about `num_ctx` evaluated tokens.
    /// A prompt plus reply that fill the window mean the context shifted mid-reply and dropped the start of the prompt.
    static func isTruncated(promptEvalCount: Int?, evalCount: Int?, contextSize: Int) -> Bool {
        guard let promptEvalCount else { return false }
        return promptEvalCount >= contextSize - truncationMargin || promptEvalCount + (evalCount ?? 0) >= contextSize
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        let numCtx = Self.contextSize(for: request, limit: contextTokens)
        var body: [String: JSONValue] = [
            "model": .string(model),
            "stream": .bool(false),
            "think": .bool(false),
            "keep_alive": .string(keepAlive),
            "options": .object(["num_ctx": .number(Double(numCtx)), "num_predict": .number(Double(request.maxTokens))]),
            "messages": LLMTransport.chatMessages(request),
        ]
        if let schema = request.jsonSchema {
            body["format"] = schema
        }
        let data = try await LLMTransport.post(LLMTransport.url(base: baseURL, path: "api/chat"), headers: [:], body: .object(body), session: session)
        let response = try LLMTransport.decode(Response.self, from: data)
        if Self.isTruncated(promptEvalCount: response.promptEvalCount, evalCount: response.evalCount, contextSize: numCtx) {
            throw LLMError.promptTruncated(model: model, contextTokens: numCtx)
        }
        guard let content = response.message?.content, !content.isEmpty else { throw LLMError.emptyResponse }
        return content
    }
}
