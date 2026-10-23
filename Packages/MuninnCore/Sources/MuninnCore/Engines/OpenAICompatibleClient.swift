import Foundation

public struct OpenAICompatibleClient: LLMClient {
    let baseURL: URL
    let model: String
    let apiKey: String?
    let session: URLSession

    public init(baseURL: URL, model: String, apiKey: String?, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                var content: String?
            }
            var message: Message?
        }
        var choices: [Choice]?
    }

    public func complete(_ request: LLMRequest) async throws -> String {
        var body: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(request.maxTokens)),
            "messages": LLMTransport.chatMessages(request),
        ]
        if let schema = request.jsonSchema {
            body["response_format"] = .object([
                "type": .string("json_schema"),
                "json_schema": .object(["name": .string("summary"), "schema": schema, "strict": .bool(true)]),
            ])
        }
        var headers: [String: String] = [:]
        if let apiKey, !apiKey.isEmpty {
            headers["Authorization"] = "Bearer \(apiKey)"
        }
        let url = LLMTransport.url(base: baseURL, path: "v1/chat/completions")
        let data = try await LLMTransport.post(url, headers: headers, body: .object(body), session: session)
        let response = try LLMTransport.decode(Response.self, from: data)
        guard let content = response.choices?.first?.message?.content, !content.isEmpty else { throw LLMError.emptyResponse }
        return content
    }
}
